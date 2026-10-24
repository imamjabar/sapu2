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
        if layer == .projects, let d = lastDiscovery, !d.isEmpty { snap.discoveryCache = d; snap.discoveryRules = ProjectScanner.rulesVersion }
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
        jobs += browserCacheJobs(running: running)
        jobs += toolVersionJobs()
        jobs += supportCacheJobs(running: running)
        jobs += devExtraJobs(running: running, previous: previous)
        jobs += catalogJobs(running: running, existing: jobs.map(\.path))

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
                guard r.bytes >= Self.bloatFloor else { return nil }
                let id = path.lastComponent
                let app = SystemProbe.app(forBundleID: id)
                let updater = id.lowercased().hasSuffix("-updater") ? Self.capitalized(String(id.dropLast("-updater".count))) : nil
                let name = app?.name ?? updater ?? Self.prettyName(id)
                let open = [app?.executable, app?.name].compactMap { $0 }.contains { running.contains($0) }
                // macOS rebuilds its own caches by redoing the work, so they are optional, not bloat.
                return Finding(path: path, title: updater != nil && app == nil ? "\(name) update downloads" : "\(name) cache", category: .appCaches, safety: id.hasPrefix("com.apple.") ? .check : .safe, bytes: r.bytes, files: r.files,
                               lastModified: r.newestDate,
                               reason: "\(name) keeps downloaded and rendered data here to load faster. Apps rarely trim it.",
                               usedFor: "Speeding up \(name).", owner: name, rebuild: "\(name) refills it as needed.", action: .trash,
                               lockedReason: open ? "\(name) is running. Quit it first." : nil, layer: .quick)
            }
        }
    }

    private func dotCacheJobs() -> [Job] {
        // lm-studio may hold models (listed under DevExtras to manage in LM Studio).
        let covered: Set<String> = ["huggingface", "torch", "uv", "puppeteer", "composer", "lm-studio"]
        return DiskSizer.children("~/.cache".expandingTilde).filter { !covered.contains($0.lastComponent) && DiskSizer.isDirectory($0) }.map { path in
            Job(path: path) { r in
                guard r.bytes >= Self.bloatFloor else { return nil }
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
            let subs = Self.chromiumProfiles(base).flatMap { root in
                (Self.chromiumCacheDirs + Self.chromiumSharedCaches + (root == base ? ["CachedData", "CachedExtensionVSIXs", "WebStorage"] : []))
                    .map { (root + "/" + $0, String((root + "/" + $0).dropFirst(base.count + 1))) }
            }
            for (path, sub) in subs {
                guard DiskSizer.isDirectory(path), !DiskSizer.isSymlink(path) else { continue }
                // WebStorage holds extension webview state (IndexedDB, local storage), not just cache.
                let webStorage = sub == "WebStorage"
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= Self.bloatFloor else { return nil }
                    let open = running.contains(app.name) || running.contains(app.exe) || running.contains(app.dir)
                    return Finding(path: path, title: "\(app.name) \(Self.friendlyCache(sub))", category: .appCaches, safety: webStorage ? .check : .safe,
                                   bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                                   reason: webStorage
                                       ? "Storage used by \(app.name) extension panels and webviews. Mostly cached web data, but some extensions keep settings here."
                                       : "Electron/Chromium cache of \(app.name): web assets, compiled code and old update data.",
                                   usedFor: "Speeding up \(app.name).", owner: app.name,
                                   rebuild: webStorage ? "Extensions recreate it; a few may ask you to sign in again." : "Rebuilt on next launch.",
                                   action: .trash, lockedReason: open ? "\(app.name) is running. Quit it first." : nil, layer: .quick)
                })
            }
        }
        return jobs
    }

    /// Bloat under 1 MB isn't worth a row.
    static let bloatFloor: Int64 = 1_000_000

    /// Chromium's profile-wide caches (shaders, downloaded components), in browsers and Electron apps alike.
    static let chromiumSharedCaches = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache", "DawnCache",
                                       "component_crx_cache", "extensions_crx_cache", "Crashpad/completed"]

    /// Where an Electron or Chromium app keeps profiles: the folder itself, Default, Partitions/<name>, User Data/<profile>.
    public static func chromiumProfiles(_ base: String) -> [String] {
        var out = [base]
        for sub in ["Default", "User Data", "User Data/Default", "cefcache"] where DiskSizer.isDirectory(base + "/" + sub) { out.append(base + "/" + sub) }
        for holder in [base + "/Partitions", base + "/User Data", base + "/DesktopProfile"] {
            for p in DiskSizer.children(holder, includeHidden: false) where DiskSizer.isDirectory(p) && !DiskSizer.isSymlink(p) && !out.contains(p) {
                let n = p.lastComponent
                if holder.hasSuffix("/User Data"), !(n == "Default" || n.hasPrefix("Profile ")) { continue }
                out.append(p)
            }
        }
        return out
    }

    /// Cache folders every Chromium-based app writes, per profile or at the top of its data folder.
    static let chromiumCacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
                                    "Service Worker/CacheStorage", "Service Worker/ScriptCache"]

    /// Chromium browsers: per-profile caches plus shared shader, component and crash caches.
    /// Cookies, history, passwords and extensions are never touched (only these named cache folders).
    private func browserCacheJobs(running: Set<String>) -> [Job] {
        let support = "~/Library/Application Support".expandingTilde
        let browsers: [(dir: String, name: String, exe: String)] = [
            ("Google/Chrome", "Chrome", "Google Chrome"), ("Arc/User Data", "Arc", "Arc"),
            ("BraveSoftware/Brave-Browser", "Brave", "Brave Browser"), ("Microsoft Edge", "Edge", "Microsoft Edge"),
            ("Vivaldi", "Vivaldi", "Vivaldi"), ("com.operasoftware.Opera", "Opera", "Opera"),
        ]
        let shared = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "GPUPersistentCache", "component_crx_cache",
                      "extensions_crx_cache", "optimization_guide_model_store", "Crashpad/completed"]
        var jobs: [Job] = []
        for b in browsers {
            let base = support + "/" + b.dir
            guard DiskSizer.isDirectory(base) else { continue }
            let profiles = DiskSizer.children(base, includeHidden: false).filter {
                let n = $0.lastComponent
                return (n == "Default" || n.hasPrefix("Profile ") || n == "Guest Profile") && DiskSizer.isDirectory($0)
            }
            var paths = shared.map { base + "/" + $0 }
            for p in profiles { paths += Self.chromiumCacheDirs.map { p + "/" + $0 } }
            for path in paths where DiskSizer.isDirectory(path) {
                let label = String(path.dropFirst(base.count + 1))
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= Self.bloatFloor else { return nil }
                    let open = running.contains(b.exe) || running.contains(b.name)
                    return Finding(path: path, title: "\(b.name) \(Self.friendlyCache(label))", category: .appCaches, safety: .safe, bytes: r.bytes,
                                   files: r.files, lastModified: r.newestDate,
                                   reason: "\(b.name) keeps copies of pages, scripts, shaders and downloaded components here. Your logins, history and bookmarks live elsewhere.",
                                   usedFor: "Loading sites and the browser faster.", owner: b.name,
                                   rebuild: "Sites refill it as you browse; first loads are a little slower.", action: .trash,
                                   lockedReason: open ? "\(b.name) is running. Quit it first." : nil, layer: .quick)
                })
            }
        }
        // Chrome's updater keeps every component and update package it downloaded.
        let updater = support + "/Google/GoogleUpdater/crx_cache"
        if DiskSizer.isDirectory(updater) {
            jobs.append(Job(path: updater) { r in
                guard r.bytes >= Self.bloatFloor else { return nil }
                return Finding(path: updater, title: "Google Updater downloads", category: .appCaches, safety: .safe, bytes: r.bytes,
                               files: r.files, lastModified: r.newestDate,
                               reason: "Update packages Google Updater already installed. It keeps them in case it needs to repair Chrome.",
                               usedFor: "Repairing or re-applying Chrome updates.", owner: "Chrome",
                               rebuild: "Downloaded again if an update ever needs it.", action: .trash, layer: .quick)
            })
        }
        return jobs
    }

    /// Old versions of self-updating tools. The version in use and any version a running process uses are kept.
    private func toolVersionJobs() -> [Job] {
        var jobs: [Job] = []
        let processes = Shell.run(["ps", "-axo", "comm="], timeout: 5).out
        let claude = "~/.local/share/claude/versions".expandingTilde
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: "~/.local/bin/claude".expandingTilde)) ?? ""
        for v in DiskSizer.children(claude, includeHidden: false) where v != current && !processes.contains(v) {
            jobs.append(Job(path: v) { r in
                guard r.bytes >= Self.bloatFloor else { return nil }
                return Finding(path: v, title: "Claude Code \(v.lastComponent) (old version)", category: .devCaches, safety: .safe,
                               bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                               reason: "Claude Code downloads each new version next to the old ones. You run \(current.lastComponent.isEmpty ? "a newer one" : current.lastComponent).",
                               usedFor: "Nothing; an older Claude Code release.", owner: "Claude Code",
                               rebuild: "Not needed.", action: .trash, layer: .quick)
            })
        }
        let pyinstaller = "~/Library/Application Support/pyinstaller".expandingTilde
        if DiskSizer.isDirectory(pyinstaller) {
            jobs.append(Job(path: pyinstaller) { r in
                guard r.bytes >= Self.bloatFloor else { return nil }
                return Finding(path: pyinstaller, title: "PyInstaller cache", category: .devCaches, safety: .safe, bytes: r.bytes,
                               files: r.files, lastModified: r.newestDate,
                               reason: "Bootloaders and analysed binaries PyInstaller kept from earlier app builds.",
                               usedFor: "Faster PyInstaller builds.", owner: "PyInstaller",
                               rebuild: "Recreated on the next build.", action: .trash, layer: .quick)
            })
        }
        // Chrome keeps the previous version inside the app until it restarts. Outside home, so information only.
        let versions = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions"
        if let live = try? FileManager.default.destinationOfSymbolicLink(atPath: versions + "/Current") {
            for v in DiskSizer.children(versions, includeHidden: false) where v.lastComponent != live && v.lastComponent != "Current" {
                jobs.append(Job(path: v) { r in
                    guard r.bytes >= Self.bloatFloor else { return nil }
                    return Finding(path: v, title: "Chrome \(v.lastComponent) (previous version)", category: .apps, safety: .safe,
                                   bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                                   reason: "Chrome updated to \(live) but keeps the old version inside the app until you fully quit and reopen it.",
                                   usedFor: "Nothing after the update.", owner: "Chrome",
                                   rebuild: "Quit Chrome (⌘Q) and open it again; Chrome removes this itself.", action: .none, layer: .quick)
                })
            }
        }
        return jobs
    }

    /// Known locations of popular apps and tools (AppCatalog). A location already covered by another
    /// rule, inside one, or holding one is skipped so nothing is counted twice.
    private func catalogJobs(running: Set<String>, existing: [String]) -> [Job] {
        let taken = Set(existing)
        func overlaps(_ p: String) -> Bool {
            if taken.contains(p) { return true }
            var q = p.parentPath
            while q.count > 1 { if taken.contains(q) { return true }; q = q.parentPath }
            return existing.contains { $0.hasPrefix(p + "/") }
        }
        let runningLower = Set(running.map { $0.lowercased() })
        var seen = Set<String>()
        var jobs: [Job] = []
        for entry in AppCatalog.entries {
            for path in Self.glob(entry.pattern.expandingTilde) where !seen.contains(path) && !overlaps(path) {
                seen.insert(path)
                // The owning app: a bundle-id segment resolved through LaunchServices, else the label's first word.
                let idSegment = path.split(separator: "/").map(String.init).first { $0.filter { $0 == "." }.count >= 2 && !$0.hasPrefix(".") }
                let app = idSegment.flatMap { SystemProbe.app(forBundleID: $0) }
                let owner = app?.name ?? String(entry.label.split(separator: " ").first ?? "")
                let names = [app?.name, app?.executable, owner].compactMap { $0?.lowercased() }
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= Self.bloatFloor else { return nil }
                    let open = names.contains { runningLower.contains($0) }
                    let isLog = entry.category == .logs
                    let title = app.map { a in entry.label.replacingOccurrences(of: owner, with: a.name) } ?? entry.label
                    // macOS rebuilds its own caches by redoing the work (photo analysis, maps), which costs battery and time.
                    let apple = path.contains("/com.apple.")
                    return Finding(path: path, title: title.prefix(1).uppercased() + title.dropFirst(), category: entry.category,
                                   safety: apple && !isLog ? .check : .safe, bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                                   reason: isLog ? "Logs and crash reports \(owner) writes and rarely deletes."
                                       : apple ? "A macOS cache. It comes back, but macOS redoes the work to rebuild it (for photo analysis that can take hours of background processing)."
                                       : "Data \(owner) downloads or generates to work faster. It is rebuilt when needed.",
                                   usedFor: isLog ? "Troubleshooting \(owner)." : "Speeding up \(owner).", owner: owner,
                                   rebuild: isLog ? "Not needed." : "\(owner) recreates it as needed.", action: .trash,
                                   lockedReason: open ? "\(owner) is running. Quit it first." : nil, layer: .quick)
                })
            }
        }
        return jobs
    }

    /// Expands `*` patterns (never following symlinks into other places).
    public static func glob(_ pattern: String) -> [String] {
        guard pattern.contains("*") else { return DiskSizer.exists(pattern) && !DiskSizer.isSymlink(pattern) ? [pattern] : [] }
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }.filter { !DiskSizer.isSymlink($0) }
    }

    /// Cache and log folders apps keep inside their Application Support folder.
    private func supportCacheJobs(running: Set<String>) -> [Job] {
        let support = "~/Library/Application Support".expandingTilde
        // Covered by the Electron and browser rules, or holding data that only looks like a cache.
        let skip: Set<String> = ["Code", "Cursor", "Slack", "discord", "Microsoft Teams", "Notion", "Antigravity", "Claude",
                                 "Windsurf", "Google", "Arc", "BraveSoftware", "Microsoft Edge", "Vivaldi", "com.operasoftware.Opera",
                                 "MobileSync", "Sapu", "CloudDocs", "Knowledge", "AddressBook", "CallHistoryDB", "com.apple.TCC",
                                 "1Password", "Bitwarden", "Dashlane", "Keeper", "pyinstaller", "JetBrains"]
        var jobs: [Job] = []
        for app in DiskSizer.children(support, includeHidden: false) where DiskSizer.isDirectory(app) && !skip.contains(app.lastComponent) {
            let name = app.lastComponent
            if name.hasPrefix("com.apple.") { continue }
            // Electron apps keep Chromium caches per profile (Notion's Partitions, Codex's Default) as well as at the top.
            var subs = ["Cache", "Caches", "Code Cache", "GPUCache", "logs", "Logs"].map { (app + "/" + $0, $0) }
            for root in Self.chromiumProfiles(app) {
                for c in Self.chromiumCacheDirs + Self.chromiumSharedCaches where root != app || !["Cache", "Code Cache", "GPUCache"].contains(c) {
                    subs.append((root + "/" + c, String((root + "/" + c).dropFirst(app.count + 1))))
                }
            }
            // Update packages electron-updater downloaded and already installed (~/Library/Application Support/Caches/notion-updater).
            if name == "Caches" {
                subs = DiskSizer.children(app, includeHidden: false).filter { $0.lastComponent.hasSuffix("-updater") }.map { ($0, $0.lastComponent) }
            }
            var once = Set<String>()
            for (path, sub) in subs {
                // The disk ignores case: logs and Logs are one folder.
                guard DiskSizer.isDirectory(path), !DiskSizer.isSymlink(path), once.insert(path.lowercased()).inserted else { continue }
                let isLog = sub.lowercased() == "logs"
                jobs.append(Job(path: path) { r in
                    guard r.bytes >= Self.bloatFloor else { return nil }
                    let pretty = name == "Caches" ? String(sub.dropLast("-updater".count)) : SystemProbe.app(forBundleID: name)?.name ?? (name.contains(".") ? Self.prettyName(name) : name)
                    let open = running.contains(pretty) || running.contains(name)
                    return Finding(path: path, title: name == "Caches" ? "\(Self.capitalized(pretty)) update downloads" : "\(Self.capitalized(pretty)) \(Self.friendlyCache(sub))", category: isLog ? .logs : .appCaches, safety: .safe,
                                   bytes: r.bytes, files: r.files, lastModified: r.newestDate,
                                   reason: isLog ? "Diagnostic logs \(pretty) writes in its own data folder. It rarely deletes old ones."
                                                 : "\(pretty) keeps downloaded and rendered data in its own data folder.",
                                   usedFor: isLog ? "Troubleshooting \(pretty)." : "Speeding up \(pretty).", owner: pretty,
                                   rebuild: isLog ? "Not needed." : "\(pretty) refills it as needed.", action: .trash,
                                   lockedReason: open ? "\(pretty) is running. Quit it first." : nil, layer: .quick)
                })
            }
        }
        return jobs
    }

    /// "Partitions/81df…/Service Worker/CacheStorage" → "offline web cache"; "User Data/Profile 1/Cache" → "web cache (Profile 1)".
    public static func friendlyCache(_ sub: String) -> String {
        let names: [String: String] = [
            "cache": "web cache", "code cache": "code cache", "gpucache": "GPU cache", "cachestorage": "offline web cache",
            "scriptcache": "service worker scripts", "dawngraphitecache": "graphics cache", "dawnwebgpucache": "graphics cache",
            "graphitedawncache": "graphics cache", "grshadercache": "shader cache", "shadercache": "shader cache",
            "gpupersistentcache": "graphics cache", "dawncache": "graphics cache", "component_crx_cache": "component downloads",
            "extensions_crx_cache": "extension downloads", "completed": "crash reports", "cacheddata": "compiled code cache",
            "cachedextensionvsixs": "extension downloads", "webstorage": "webview storage", "caches": "cache", "logs": "logs",
        ]
        let parts = sub.split(separator: "/").map(String.init)
        let base = names[parts.last?.lowercased() ?? ""] ?? sub
        let uuidLike = { (p: String) in p.count >= 16 && p.allSatisfy { $0.isHexDigit || $0 == "-" } }
        let skip: Set<String> = ["Partitions", "Default", "User Data", "Service Worker", "Crashpad", "DesktopProfile", "cefcache"]
        let qualifier = parts.dropLast().filter { !skip.contains($0) && !uuidLike($0) && names[$0.lowercased()] == nil }
        return qualifier.isEmpty ? base : "\(base) (\(qualifier.joined(separator: " ")))"
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

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
                }, changes: self.currentChanges, discoveryCache: self.currentChanges == nil || previous?.discoveryRules != ProjectScanner.rulesVersion ? [:] : (previous?.discoveryCache ?? [:]),
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
