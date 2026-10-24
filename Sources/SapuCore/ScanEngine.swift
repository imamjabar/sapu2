import AppKit
import Foundation

public struct ScanProgress: Sendable {
    public var layer: ScanLayer
    public var phase: String
    public var done: Int
    public var total: Int
    public var bytesSoFar: Int64
    public var currentPath: String
    public var elapsed: TimeInterval
    public var fraction: Double
    public var eta: TimeInterval?
    /// True when the estimate is based on the sizes from the last scan.
    public var etaFromHistory: Bool
}

/// Tracks progress of a set of sizing jobs. Each job is weighted by the size it had in the
/// previous scan, so the estimate tracks real work (bytes) instead of item counts.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    let start = Date()
    let layer: ScanLayer
    private var phase: String
    private var weights: [Double]
    private var partial: [Int: Double] = [:]
    private var finished = Set<Int>()
    private var bytes: Int64 = 0
    private var current = ""
    private let fromHistory: Bool
    private let sink: @Sendable (ScanProgress) -> Void
    private var lastEmit = Date.distantPast
    // Discovery phase before job count is known, e.g. the project walk.
    private var discoveryShare: Double

    init(layer: ScanLayer, phase: String, expected: [Int64?], discoveryShare: Double = 0, sink: @escaping @Sendable (ScanProgress) -> Void) {
        self.layer = layer; self.phase = phase; self.sink = sink; self.discoveryShare = discoveryShare
        let known = expected.compactMap { $0 }.filter { $0 > 0 }
        let history = !expected.isEmpty && Double(known.count) / Double(expected.count) > 0.5
        fromHistory = history
        let fallback = known.isEmpty ? 1.0 : Double(known.reduce(0, +)) / Double(known.count)
        weights = expected.map { e in history ? Double(e ?? Int64(fallback)).clamped(1_000_000) : 1 }
    }

    /// Duration of the same layer last time; used before any job is known (discovery walk).
    var historyDuration: TimeInterval?

    func reset(phase: String, expected: [Int64?]) {
        lock.lock()
        self.phase = phase
        let known = expected.compactMap { $0 }
        let fallback = known.isEmpty ? 1.0 : Double(known.reduce(0, +)) / Double(max(known.count, 1))
        weights = expected.map { Double($0 ?? Int64(fallback)).clamped(1_000_000) }
        partial = [:]; finished = []
        lock.unlock()
        emit(force: true)
    }

    func setPhase(_ p: String, path: String = "") {
        lock.lock(); phase = p; current = path; lock.unlock(); emit()
    }

    func update(_ job: Int, bytes jobBytes: Int64, path: String) {
        lock.lock()
        let w = job < weights.count ? weights[job] : 1
        // A job never reports more than 95 % until it finishes.
        partial[job] = min(Double(jobBytes) / max(w, 1), 0.95)
        current = path
        lock.unlock()
        emit()
    }

    func finish(_ job: Int, bytes jobBytes: Int64) {
        lock.lock()
        finished.insert(job); partial[job] = nil; bytes += jobBytes
        lock.unlock()
        emit()
    }

    func emit(force: Bool = false) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) > 0.15 else { lock.unlock(); return }
        lastEmit = now
        let total = weights.reduce(0, +)
        let doneW = finished.reduce(0.0) { $0 + ($1 < weights.count ? weights[$1] : 0) }
        let partW = partial.reduce(0.0) { $0 + $1.value * ($1.key < weights.count ? weights[$1.key] : 0) }
        let jobsFraction = total > 0 ? (doneW + partW) / total : 0
        let fraction = discoveryShare + (1 - discoveryShare) * jobsFraction
        let elapsed = now.timeIntervalSince(start)
        var eta: TimeInterval? = (fraction > 0.04 && elapsed > 0.8) ? elapsed * (1 - fraction) / fraction : nil
        var historic = fromHistory
        if let h = historyDuration, h > 0 {
            // Blend in last run's duration: dominant early, fading as real progress accumulates.
            let byHistory = max(h - elapsed, 1)
            eta = eta.map { $0 * fraction + byHistory * (1 - fraction) } ?? byHistory
            historic = true
        }
        let p = ScanProgress(layer: layer, phase: phase, done: finished.count, total: weights.count, bytesSoFar: bytes,
                             currentPath: current, elapsed: elapsed, fraction: min(fraction, 1), eta: eta, etaFromHistory: historic)
        lock.unlock()
        sink(p)
    }

    func discoveryProgress(_ share: Double, path: String) {
        lock.lock(); discoveryShare = share; current = path; lock.unlock(); emit()
    }
}

extension Double {
    func clamped(_ low: Double) -> Double { Swift.max(self, low) }
}

/// Layered scanner. Each layer is independent, cached, and can be re-run alone:
/// 1. Quick: known caches and logs (seconds).
/// 2. Projects: discovers projects, sizes their build artifacts, reads git and activity.
/// 3. Full map: everything else (home folders, Library, apps, large and old files) so totals reconcile.
///
/// Load is kept low on purpose: at most `concurrency` folders are sized at once, on a utility
/// QoS queue, with constant memory per walk.
public final class ScanEngine: @unchecked Sendable {
    public var concurrency = 2
    public var largeFileThreshold: Int64 = 1_000_000_000
    public var oldDownloadDays = 180
    private let lock = NSLock()
    private var _cancelled = false
    private let queue = DispatchQueue(label: "sapu.scan", qos: .utility, attributes: .concurrent)

    public init() {}

    /// Ignore the size cache and measure everything (Scan › Full rescan).
    public var forceFresh = false
    /// Cached sizes older than this are measured again regardless of the journal.
    public var cacheMaxAge: TimeInterval = 7 * 86_400

    // Per-layer bookkeeping, read by `commit(into:layer:)`.
    private let measured = Locked<[String: CachedSize]>([:])
    private let reusedPaths = Locked<Set<String>>([])
    private var startEventID: UInt64 = 0
    private var currentChanges: ChangeSet?
    private var lastDiscovery: [String: DiscoveryUnit]?
    public var reusedCount: Int { reusedPaths.value.count }

    /// Builds the lookup for one layer: a cached size for each folder that hasn't changed since the
    /// last scan of this layer, or nil to measure it. Falls back to measuring everything whenever the
    /// journal can't vouch for the gap.
    func prepareReuse(previous: Snapshot?, layer: ScanLayer) -> (String) -> SizeResult? {
        measured.mutate { $0.removeAll() }
        reusedPaths.mutate { $0.removeAll() }
        startEventID = ChangeJournal.currentEventID()
        currentChanges = nil
        lastDiscovery = nil
        let none: (String) -> SizeResult? = { _ in nil }
        guard !forceFresh, let prev = previous, let cache = prev.sizeCache,
              let since = prev.layerEvents?[layer.rawValue], since > 0,
              let date = prev.layerDates[layer.rawValue], Date().timeIntervalSince(date) < cacheMaxAge,
              let id = prev.journalID, id == ChangeJournal.journalID(),
              let changes = ChangeJournal.changes(since: since, roots: [NSHomeDirectory(), "/Applications", "/opt/homebrew"])
        else { return none }
        currentChanges = changes
        return { path in
            guard !changes.isDirty(path), let c = cache[path] else { return nil }
            return SizeResult(bytes: c.bytes, files: c.files, newest: c.newest, denied: false)
        }
    }

    func record(_ path: String, _ r: SizeResult, reused: Bool) {
        guard !r.denied, !isCancelled else { return }
        measured.mutate { $0[path] = CachedSize(bytes: r.bytes, files: r.files, newest: r.newest) }
        if reused { reusedPaths.mutate { $0.insert(path) } }
    }

    func wasReused(_ path: String) -> Bool { reusedPaths.value.contains(path) }

    /// Saves this layer's sizes and journal position into the snapshot. Call after a layer finishes.
    public func commit(into snap: inout Snapshot, layer: ScanLayer) {
        guard !isCancelled else { return }
        var cache = snap.sizeCache ?? [:]
        for (k, v) in measured.value { cache[k] = v }
        snap.sizeCache = cache
        snap.layerEvents = (snap.layerEvents ?? [:]).merging([layer.rawValue: startEventID]) { $1 }
        snap.journalID = ChangeJournal.journalID()
        if layer == .projects, let d = lastDiscovery, !d.isEmpty { snap.discoveryCache = d }
    }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func resetCancel() { lock.lock(); _cancelled = false; lock.unlock() }

    struct Job {
        var path: String
        var make: (SizeResult) -> Finding?
    }

    /// Size jobs with bounded concurrency and report progress weighted by previous sizes.
    private func run(_ jobs: [Job], tracker: ProgressTracker, reuse: @escaping (String) -> SizeResult? = { _ in nil },
                     largeFile: ((String, Int64, TimeInterval) -> Void)? = nil) async -> [Finding] {
        let results = Locked<[Int: Finding]>([:])
        let sem = DispatchSemaphore(value: concurrency)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (i, job) in jobs.enumerated() {
                if isCancelled { break }
                sem.wait()
                group.enter()
                queue.async {
                    defer { sem.signal(); group.leave() }
                    guard !self.isCancelled else { return }
                    let cached = reuse(job.path)
                    let r = cached ?? DiskSizer.size(job.path, cancelled: { self.isCancelled },
                                                     progress: { b, _ in tracker.update(i, bytes: b, path: job.path) },
                                                     largeFile: largeFile, largeThreshold: self.largeFileThreshold)
                    self.record(job.path, r, reused: cached != nil)
                    tracker.finish(i, bytes: r.bytes)
                    if let f = job.make(r) { results.mutate { $0[i] = f } }
                }
            }
            group.notify(queue: .global(qos: .utility)) { cont.resume() }
        }
        return results.value.sorted { $0.key < $1.key }.map(\.value)
    }

    // MARK: Layer 1 — quick

    public func quick(previous: Snapshot?, progress: @escaping @Sendable (ScanProgress) -> Void) async -> [Finding] {
        resetCancel()
        let running = SystemProbe.runningProcessNames()
        var jobs: [Job] = []

        for rule in RuleBook.all {
            for path in rule.paths.flatMap(RuleBook.expand) {
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= rule.minBytes || rule.category == .trash else { return nil }
                    let open = rule.whileRunning.first { running.contains($0) }
                    let isChild = rule.paths.contains { $0.hasSuffix("/*") }
                    return Finding(path: path, title: isChild ? "\(rule.title): \(path.lastComponent)" : rule.title,
                                   category: rule.category, safety: rule.safety, bytes: r.bytes, files: r.files,
                                   lastModified: r.newestDate, reason: rule.reason, usedFor: rule.usedFor, owner: rule.owner,
                                   rebuild: rule.rebuild, action: rule.action,
                                   lockedReason: open.map { "\($0) is running. Quit it first." }, layer: .quick)
                })
            }
        }
        jobs += appCacheJobs(running: running)
        jobs += dotCacheJobs()
        jobs += electronCacheJobs(running: running)

        let prev = Dictionary((previous?.findings ?? []).map { ($0.path, $0.bytes) }, uniquingKeysWith: max)
        let tracker = ProgressTracker(layer: .quick, phase: "Sizing \(jobs.count) known locations", expected: jobs.map { prev[$0.path] }, sink: progress)
        tracker.emit(force: true)
        let reuse = prepareReuse(previous: previous, layer: .quick)
        return await run(jobs, tracker: tracker, reuse: reuse)
    }

    private func appCacheJobs(running: Set<String>) -> [Job] {
        let dir = "~/Library/Caches".expandingTilde
        return DiskSizer.children(dir).filter {
            !RuleBook.coveredCacheNames.contains($0.lastComponent) && DiskSizer.isDirectory($0)
        }.map { path in
            Job(path: path) { r in
                guard r.bytes >= 50_000_000 else { return nil }
                let id = path.lastComponent
                let app = SystemProbe.app(forBundleID: id)
                let name = app?.name ?? Self.prettyName(id)
                let open = [app?.executable, app?.name].compactMap { $0 }.contains { running.contains($0) }
                return Finding(path: path, title: "\(name) cache", category: .appCaches, safety: .safe, bytes: r.bytes, files: r.files,
                               lastModified: r.newestDate,
                               reason: "\(name) keeps downloaded and rendered data here to load faster. Apps rarely trim it.",
                               usedFor: "Speeding up \(name).", owner: name, rebuild: "\(name) refills it as needed.", action: .trash,
                               lockedReason: open ? "\(name) is running. Quit it first." : nil, layer: .quick)
            }
        }
    }

    private func dotCacheJobs() -> [Job] {
        let covered: Set<String> = ["huggingface", "torch", "uv", "puppeteer", "composer"]
        return DiskSizer.children("~/.cache".expandingTilde).filter { !covered.contains($0.lastComponent) && DiskSizer.isDirectory($0) }.map { path in
            Job(path: path) { r in
                guard r.bytes >= 100_000_000 else { return nil }
                let name = path.lastComponent
                return Finding(path: path, title: "~/.cache/\(name)", category: .devCaches, safety: .check, bytes: r.bytes, files: r.files,
                               lastModified: r.newestDate,
                               reason: "Command-line tool cache (XDG). \(name) stores downloads or runtimes here.",
                               usedFor: "\(name) tooling.", owner: name, rebuild: "The tool re-downloads what it needs.", action: .trash, layer: .quick)
            }
        }
    }

    private func electronCacheJobs(running: Set<String>) -> [Job] {
        let apps: [(dir: String, name: String, exe: String)] = [
            ("Code", "VS Code", "Electron"), ("Cursor", "Cursor", "Cursor"), ("Slack", "Slack", "Slack"),
            ("discord", "Discord", "Discord"), ("Microsoft Teams", "Teams", "Microsoft Teams"), ("Notion", "Notion", "Notion"),
            ("Antigravity", "Antigravity", "Antigravity"), ("Claude", "Claude", "Claude"), ("Windsurf", "Windsurf", "Windsurf"),
        ]
        var jobs: [Job] = []
        for app in apps {
            let base = "~/Library/Application Support/\(app.dir)".expandingTilde
            guard DiskSizer.exists(base) else { continue }
            for sub in ["Cache", "CachedData", "Code Cache", "GPUCache", "CachedExtensionVSIXs", "Service Worker/CacheStorage"] {
                let path = base + "/" + sub
                guard DiskSizer.isDirectory(path) else { continue }
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= 50_000_000 else { return nil }
                    let open = running.contains(app.name) || running.contains(app.exe) || running.contains(app.dir)
                    return Finding(path: path, title: "\(app.name) \(sub)", category: .appCaches, safety: .safe, bytes: r.bytes,
                                   files: r.files, lastModified: r.newestDate,
                                   reason: "Electron/Chromium cache of \(app.name): web assets, compiled code and old update data.",
                                   usedFor: "Speeding up \(app.name).", owner: app.name, rebuild: "Rebuilt on next launch.", action: .trash,
                                   lockedReason: open ? "\(app.name) is running. Quit it first." : nil, layer: .quick)
                })
            }
        }
        return jobs
    }

    static func prettyName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    // MARK: Layer 2 — projects

    public func projects(previous: Snapshot?, roots: [String] = [NSHomeDirectory()], activeDays: Int = 30,
                         progress: @escaping @Sendable (ScanProgress) -> Void) async -> ProjectScanResult {
        resetCancel()
        let tracker = ProgressTracker(layer: .projects, phase: "Finding projects", expected: [], sink: progress)
        tracker.historyDuration = previous?.layerDurations[ScanLayer.projects.rawValue]
        let scanner = ProjectScanner()
        scanner.activeDays = activeDays
        let reuse = prepareReuse(previous: previous, layer: .projects)
        return await withCheckedContinuation { cont in
            queue.async {
                var dirs = 0
                var artifactCount = 0
                var sized = 0
                let result = scanner.scan(roots: roots, cancelled: { self.isCancelled }, onDiscover: { path in
                    dirs += 1
                    // Discovery is ~25 % of the layer; it creeps towards it, never past it.
                    tracker.discoveryProgress(min(0.25, 0.25 * Double(dirs) / Double(dirs + 400)), path: path)
                }, onArtifactsFound: { count in
                    artifactCount = count
                    tracker.reset(phase: "Sizing \(count) build folders", expected: Array(repeating: nil, count: count))
                    tracker.discoveryProgress(0.25, path: "")
                }, sizeArtifact: { path in
                    let i = sized
                    sized += 1
                    tracker.setPhase("Sizing build folders (\(sized)/\(artifactCount))", path: path)
                    let cached = reuse(path)
                    let r = cached ?? DiskSizer.size(path, cancelled: { self.isCancelled },
                                                     progress: { b, _ in tracker.update(i, bytes: b, path: path) })
                    self.record(path, r, reused: cached != nil)
                    tracker.finish(i, bytes: r.bytes)
                    return r
                }, changes: self.currentChanges, discoveryCache: self.currentChanges == nil ? [:] : (previous?.discoveryCache ?? [:]),
                   previousProjects: self.currentChanges == nil ? [] : (previous?.projects ?? []))
                self.lastDiscovery = result.discovery
                cont.resume(returning: result)
            }
        }
    }

    // MARK: Layer 3 — full map

    public func full(previous: Snapshot?, progress: @escaping @Sendable (ScanProgress) -> Void) async -> [Finding] {
        resetCancel()
        let home = NSHomeDirectory()
        let running = SystemProbe.runningProcessNames()
        var jobs: [Job] = []
        let protectedLibrary: Set<String> = ["Mail", "Messages", "Keychains", "Mobile Documents", "CloudStorage", "Photos", "Safari", "Cookies", "Accounts", "Calendars", "Contacts"]

        // Home top-level folders (Library is broken down separately below).
        for path in DiskSizer.children(home) where DiskSizer.isDirectory(path) && !["Library", ".Trash"].contains(path.lastComponent) {
            jobs.append(Job(path: path) { r in
                guard r.bytes >= 50_000_000 else { return nil }
                return Finding(path: path, title: path.lastComponent, category: .home, safety: .yours, bytes: r.bytes, files: r.files,
                               lastModified: r.newestDate, reason: "Everything inside this home folder, including projects and artifacts listed elsewhere.",
                               usedFor: "Your files and tools.", owner: nil, action: .none, layer: .full)
            })
        }
        for path in DiskSizer.children(home + "/Library") where DiskSizer.isDirectory(path) && path.lastComponent != "Caches" {
            let name = path.lastComponent
            let isProtected = protectedLibrary.contains(name)
            if name == "Application Support" || name == "Containers" || name == "Group Containers" {
                // Break these down one level so big app data is visible.
                for child in DiskSizer.children(path) where DiskSizer.isDirectory(child) && !DiskSizer.isSymlink(child) {
                    if DiskSizer.neverEnter.contains(child.lastComponent) { continue }
                    jobs.append(Job(path: child) { r in
                        guard r.bytes >= 200_000_000 else { return nil }
                        let id = child.lastComponent
                        let app = SystemProbe.app(forBundleID: id)?.name ?? (id.contains(".") ? Self.prettyName(id) : id)
                        return Finding(path: child, title: "\(app) data", category: .appData, safety: .yours, bytes: r.bytes, files: r.files,
                                       lastModified: r.newestDate,
                                       reason: "\(name) of \(app): settings, databases, offline files and caches the app manages itself.",
                                       usedFor: "\(app).", owner: app, rebuild: "Use the app's own settings to clear data; removing this folder resets the app.",
                                       action: .none, layer: .full)
                    })
                }
                continue
            }
            jobs.append(Job(path: path) { r in
                guard r.bytes >= 200_000_000 else { return nil }
                return Finding(path: path, title: "Library/\(name)", category: .appData, safety: isProtected ? .protected : .yours,
                               bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                               reason: isProtected ? "macOS personal data store. Sapu only measures it." : "System-managed app data in ~/Library.",
                               usedFor: name, owner: nil, action: .none, layer: .full)
            })
        }
        jobs += leftoverJobs(running: running)
        jobs += installerJobs()
        // Applications, with last-opened date from Spotlight.
        for app in DiskSizer.children("/Applications") where app.hasSuffix(".app") && !DiskSizer.isSymlink(app) {
            jobs.append(Job(path: app) { r in
                guard r.bytes >= 100_000_000 else { return nil }
                let name = app.lastComponent.replacingOccurrences(of: ".app", with: "")
                let exe = Bundle(path: app)?.executableURL?.lastPathComponent
                let open = running.contains(name) || exe.map(running.contains) == true
                let used = open ? Date() : SystemProbe.lastUsed(app: app)
                let days = used.map { Int(Date().timeIntervalSince($0) / 86_400) }
                let unused = days.map { $0 > 180 } ?? false
                return Finding(path: app, title: name, category: .apps, safety: unused ? .check : .yours, bytes: r.bytes, files: r.files,
                               lastModified: used,
                               reason: open ? "Open right now." : used == nil ? "No record of it being used on this Mac." : "Last used \(Format.age(used)).",
                               usedFor: "Application.", owner: name, rebuild: "Reinstall from the developer or App Store.", action: .trash,
                               lockedReason: open ? "\(name) is running." : nil, layer: .full)
            })
        }
        // Homebrew prefix (formulae, kegs).
        if DiskSizer.isDirectory("/opt/homebrew") {
            jobs.append(Job(path: "/opt/homebrew") { r in
                Finding(path: "/opt/homebrew", title: "Homebrew installs", category: .devCaches, safety: .yours, bytes: r.bytes, files: r.files,
                        lastModified: r.newestDate, reason: "Installed formulae and their old versions.", usedFor: "Command-line tools.",
                        owner: "Homebrew", rebuild: "brew cleanup removes old versions; brew uninstall removes tools.", action: .none, layer: .full)
            })
        }

        let prev = Dictionary((previous?.findings ?? []).map { ($0.path, $0.bytes) }, uniquingKeysWith: max)
        let tracker = ProgressTracker(layer: .full, phase: "Mapping \(jobs.count) folders", expected: jobs.map { prev[$0.path] }, sink: progress)
        tracker.emit(force: true)
        let large = Locked<[Finding]>([])
        let skipLarge = [home + "/Library", home + "/.Trash", "/opt/homebrew", "/Applications"]
        let reuse = prepareReuse(previous: previous, layer: .full)
        var findings = await run(jobs, tracker: tracker, reuse: reuse) { path, bytes, mtime in
            guard !skipLarge.contains(where: path.hasPrefix), !path.contains("/node_modules/"), !path.contains(".photoslibrary/") else { return }
            let date = Date(timeIntervalSince1970: mtime)
            large.mutate {
                $0.append(Finding(path: path, title: path.lastComponent, category: .downloads, safety: .yours, bytes: bytes, files: 1,
                                  lastModified: date, reason: "Single large file, last changed \(Format.age(date)).",
                                  usedFor: "Your file.", owner: path.parentPath.tildePath, rebuild: "Move it to cloud storage first if you still need it.",
                                  action: .trash, layer: .full))
            }
        }
        // Folders taken from the cache weren't walked, so keep the large files found in them last time.
        let carried = (previous?.findings ?? []).filter { f in
            f.layer == .full && f.category == .downloads && f.files == 1 && f.reason.hasPrefix("Single large file")
                && jobs.contains { wasReused($0.path) && f.path.hasPrefix($0.path + "/") } && DiskSizer.exists(f.path)
        }
        large.mutate { $0 += carried }
        findings += large.value
        findings += oldDownloads(skipping: Set(large.value.map(\.path)).union(findings.map(\.path)), reuse: reuse)
        return findings
    }

    // MARK: Leftovers and installers

    /// Data that apps you've removed left behind: containers, caches, preferences and saved state
    /// named after a bundle ID that no installed app owns. Apple's own, shared group containers,
    /// app extensions of installed apps and anything running are skipped.
    private func leftoverJobs(running: Set<String>) -> [Job] {
        let lib = NSHomeDirectory() + "/Library"
        var installed = Set<String>()
        for dir in ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Applications"] {
            for app in DiskSizer.children(dir) where app.hasSuffix(".app") {
                if let id = Bundle(path: app)?.bundleIdentifier { installed.insert(Self.family(id)) }
            }
        }
        func orphan(_ id: String) -> Bool {
            let parts = id.split(separator: ".")
            guard parts.count >= 3, !id.hasPrefix("com.apple."), !id.hasPrefix("group."),
                  !installed.contains(Self.family(id)),
                  NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil else { return false }
            return !running.contains { $0.lowercased() == String(parts.last!).lowercased() }
        }
        var jobs: [Job] = []
        let places: [(dir: String, suffix: String, what: String)] = [
            ("\(lib)/Containers", "", "sandbox container (documents, settings, caches)"),
            ("\(lib)/HTTPStorages", "", "web cookies and cache"),
            ("\(lib)/WebKit", "", "web view data"),
            ("\(lib)/Saved Application State", ".savedState", "saved windows"),
            ("\(lib)/Preferences", ".plist", "settings"),
        ]
        for place in places {
            for path in DiskSizer.children(place.dir) where !DiskSizer.isSymlink(path) {
                var id = path.lastComponent
                if !place.suffix.isEmpty {
                    guard id.hasSuffix(place.suffix) else { continue }
                    id.removeLast(place.suffix.count)
                }
                guard orphan(id) else { continue }
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= 5_000_000 else { return nil }
                    return Finding(path: path, title: "Leftover: \(id)", category: .apps, safety: .check, bytes: r.bytes, files: r.files,
                                   lastModified: r.newestDate,
                                   reason: "The \(place.what) of \(id), an app that is no longer installed. macOS never removes it when an app is dragged to the Trash.",
                                   usedFor: "Nothing, unless you reinstall that app and want its old settings back.", owner: id,
                                   rebuild: "Reinstalling the app starts fresh.", action: .trash, layer: .full)
                })
            }
        }
        return jobs
    }

    /// "com.microsoft.Excel.ShareExtension" and "com.microsoft.Excel" are one family.
    static func family(_ id: String) -> String { id.lowercased().split(separator: ".").prefix(3).joined(separator: ".") }

    /// Disk images and installer packages in Downloads and Desktop. Once the app is installed they're dead weight.
    private func installerJobs() -> [Job] {
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
        var jobs: [Job] = []
        for dir in ["~/Downloads", "~/Desktop"].map(\.expandingTilde) {
            for path in DiskSizer.children(dir) where exts.contains((path as NSString).pathExtension.lowercased()) && !DiskSizer.isSymlink(path) {
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= 10_000_000 else { return nil }
                    return Finding(path: path, title: path.lastComponent, category: .downloads, safety: .check, bytes: r.bytes, files: r.files,
                                   lastModified: r.newestDate,
                                   reason: "Installer file. Once the app is installed, the installer isn't needed any more.",
                                   usedFor: "Installing or reinstalling an app.", owner: dir.lastComponent,
                                   rebuild: "Download it again from the developer if you ever need it.", action: .trash, layer: .full)
                })
            }
        }
        return jobs
    }

    /// Items in ~/Downloads not modified for `oldDownloadDays`.
    private func oldDownloads(skipping: Set<String>, reuse: (String) -> SizeResult?) -> [Finding] {
        let now = Date()
        return DiskSizer.children("~/Downloads".expandingTilde).compactMap { path in
            guard !skipping.contains(path), !DiskSizer.isSymlink(path), let m = DiskSizer.mtime(path),
                  now.timeIntervalSince(m) > Double(oldDownloadDays) * 86_400 else { return nil }
            let cached = reuse(path)
            let r = cached ?? DiskSizer.size(path, cancelled: { self.isCancelled })
            record(path, r, reused: cached != nil)
            guard r.bytes >= 20_000_000 else { return nil }
            return Finding(path: path, title: path.lastComponent, category: .downloads, safety: .yours, bytes: r.bytes, files: r.files,
                           lastModified: m, reason: "In Downloads and untouched for \(Format.age(m).replacingOccurrences(of: " ago", with: "")).",
                           usedFor: "Downloaded file.", owner: "Downloads", rebuild: "Re-download, or move to cloud storage first.",
                           action: .trash, layer: .full)
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.lock(); defer { l.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }
}
