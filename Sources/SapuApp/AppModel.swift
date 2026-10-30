import AppKit
import SapuCore
import SwiftUI

enum Pane: String, Hashable, CaseIterable, Identifiable {
    case overview = "Overview"
    case cleanable = "Ready to clean"
    case caches = "Caches"
    case artifacts = "Build folders"
    case logs = "Logs"
    case apps = "Apps"
    case files = "Old & large files"
    case projects = "Projects"
    case map = "Disk map"
    case uninstall = "Uninstall apps"
    case health = "Health"
    case maintenance = "Optimize"
    case security = "Security & versions"
    case receipts = "Receipts"
    case protected = "Protect list"
    case updates = "Updates"
    case trash = "Trash"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cleanable: "sparkles"
        case .caches: "shippingbox"
        case .artifacts: "hammer"
        case .logs: "doc.text"
        case .apps: "app.dashed"
        case .files: "doc.on.doc"
        case .projects: "folder"
        case .map: "chart.bar.doc.horizontal"
        case .uninstall: "trash.square"
        case .health: "heart.text.square"
        case .maintenance: "wrench.and.screwdriver"
        case .security: "shield.lefthalf.filled"
        case .receipts: "list.bullet.clipboard"
        case .protected: "lock.shield"
        case .updates: "arrow.down.app"
        case .trash: "trash"
        }
    }

    func includes(_ f: Finding) -> Bool {
        switch self {
        case .cleanable: f.isCleanable && f.safety <= .check
        // VM disks and model libraries show too, under "Manage in their own app", so their space is explained.
        case .caches: [.devCaches, .appCaches, .xcode, .ml, .containers].contains(f.category) && (f.action != .none || [.ml, .containers].contains(f.category))
        case .artifacts: f.category == .projects
        case .logs: f.category == .logs
        case .apps: f.category == .apps
        case .files: f.category == .downloads
        case .map: f.layer == .full && (f.category == .home || f.category == .appData) || f.category == .trash
        default: false
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var snapshot: Snapshot { didSet { derive() } }
    var section: Pane = .overview { didSet { if section != oldValue { categoryFilter = nil } } }
    /// Set when a place opens Cleanup on one kind of item (a dev-stack tile); cleared when you move on.
    var categoryFilter: SapuCore.Category? { didSet { paneCache = [:] } }
    var focused: Finding.ID?
    var checked = Set<Finding.ID>()
    var scanning: ScanLayer?
    var queue: [ScanLayer] = []
    var progress: ScanProgress?
    /// When the scan last reported anything; a long silence usually means macOS is waiting on a permission prompt.
    @ObservationIgnored var lastProgressAt = Date()
    var versions: [VersionFinding] = []
    var versionsLive = false
    var checkingVersions = false
    var receipts: [CleanReceipt] = Store.receipts()
    var reviewing = false
    var cleaning = false
    var cleanStatus = ""
    var lastReceipt: CleanReceipt?
    var search = "" { didSet { paneCache = [:] } }
    var audits: [String: String] = [:]
    var securityIssues: [SecurityIssue] = []
    var checkingSecurity: String?
    var securityChecked: Date?
    /// Replaced by unlocking one item at a time; always off now, whatever an older version saved.
    var allowActiveProjects = false {
        didSet { derive() }
    }
    var activeDays = UserDefaults.standard.object(forKey: "activeDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(activeDays, forKey: "activeDays") }
    }

    // Uninstall, health and maintenance
    var installedApps: [InstalledApp] = []
    var loadingApps = false
    var selectedApp: InstalledApp.ID?
    var plan: UninstallPlan?
    var planning = false
    var uninstalling = false
    var health: HealthReport?
    var tasks: [MaintenanceTask] = []
    var checkingTasks = false
    /// Checks finished so far while `checkingTasks`, so the button counts up instead of looking stuck.
    var checkProgress: (done: Int, total: Int) = (0, 0)
    var taskResults: [String: String] = [:]
    var runningTask: String?

    let engine = ScanEngine()
    let explorer = ExplorerModel()
    var hasFullDiskAccess = SystemProbe.hasFullDiskAccess
    var showAccessSetup = false
    /// Folders the last layer took from the cache because the change journal showed no change.
    var lastReused = 0
    var accessJustGranted = false
    @ObservationIgnored private var accessTimer: Timer?

    init() {
        var s = Store.load() ?? Snapshot()
        s.volume = SystemProbe.volume()
        snapshot = s
        derive()
        // `open Sapu2.app --args -SapuPane Projects` opens a pane directly (used for screenshots).
        if let p = UserDefaults.standard.string(forKey: "SapuPane"), let pane = Pane(rawValue: p) { section = pane }
        // `--args -SapuCategory "Docker & VMs"` opens Cleanup on one kind of item (used for screenshots).
        if let c = UserDefaults.standard.string(forKey: "SapuCategory") { categoryFilter = SapuCore.Category(rawValue: c) }
        // `--args -SapuFocus <path>` opens that item's details (used for screenshots).
        if let f = UserDefaults.standard.string(forKey: "SapuFocus") { focused = (f as NSString).expandingTildeInPath }
    }

    /// First launch runs the two light layers; later launches show cached results instantly.
    /// Full Disk Access is never pushed at launch: the banner only informs. Sapu2 asks once per session, when you start a scan.
    func onLaunch() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recheckFullDiskAccess() }
        }
        if snapshot.layerDates.isEmpty { scan([.quick, .projects], userInitiated: false) }
        refreshHealth()
        checkMaintenance()
        loadTrash()
        if Updater.enabled { checkForUpdates(manual: false) }
        // `--args -SapuSmart 1` starts Smart Clean at launch (used for screenshots).
        if UserDefaults.standard.bool(forKey: "SapuSmart") { startSmartClean(userInitiated: false) }
        Task { await refreshVersions(network: false) }
    }

    // MARK: Scanning

    @ObservationIgnored private var askedForAccess = false

    func scan(_ layers: [ScanLayer], userInitiated: Bool = true) {
        // The scan runs either way; without access some app containers just can't be measured.
        if userInitiated, !hasFullDiskAccess, !askedForAccess, !UserDefaults.standard.bool(forKey: "accessSetupDismissed") {
            askedForAccess = true
            showAccessSetup = true
            watchFullDiskAccess()
        }
        guard scanning == nil else { queue.append(contentsOf: layers.filter { !queue.contains($0) }); return }
        queue = layers
        Task { await runQueue() }
    }

    private func runQueue() async {
        var scannedProjects = false
        while !queue.isEmpty {
            let layer = queue.removeFirst()
            scanning = layer
            progress = nil
            lastProgressAt = Date()
            let start = Date()
            let previous = snapshot
            // A scan reports every folder; the screen only needs about ten updates a second.
            let gate = Throttle(interval: 0.1)
            let sink: @Sendable (ScanProgress) -> Void = { p in
                guard gate.ready() else { return }
                Task { @MainActor [weak self] in self?.progress = p; self?.lastProgressAt = Date() }
            }
            switch layer {
            case .quick:
                let found = await engine.quick(previous: previous, progress: sink)
                if !engine.isCancelled { snapshot.replace(layer: .quick, with: found) }
            case .projects:
                let days = activeDays
                let r = await engine.projects(previous: previous, activeDays: days, progress: sink)
                if !engine.isCancelled { snapshot.replace(layer: .projects, with: r.findings); snapshot.projects = r.projects; scannedProjects = true }
            case .full:
                let found = await engine.full(previous: previous, progress: sink)
                if !engine.isCancelled { snapshot.replace(layer: .full, with: found) }
            }
            if engine.isCancelled { queue = []; break }
            engine.commit(into: &snapshot, layer: layer)
            lastReused = engine.reusedCount
            snapshot.layerDates[layer.rawValue] = Date()
            snapshot.layerDurations[layer.rawValue] = Date().timeIntervalSince(start)
            finishSnapshot()
        }
        scanning = nil
        progress = nil
        engine.forceFresh = false
        // Leak checks read only what git tracks; run them once the disk is quiet again.
        if scannedProjects { checkSecurity() }
        if smartStep == .scanning { buildSmartPlan() }
    }

    /// Measures every folder again, ignoring the cache (Scan › Full rescan).
    func rescanFresh() {
        guard scanning == nil else { return }
        engine.forceFresh = true
        scan(ScanLayer.allCases)
    }

    func cancelScan() { queue = []; engine.cancel() }

    private func finishSnapshot() {
        snapshot.volume = SystemProbe.volume()
        snapshot.insights = Insights.build(snapshot, versions: versions)
        let selectable = Set(snapshot.findings.lazy.filter(isSelectable).map(\.id))
        checked = checked.intersection(selectable)
        let s = snapshot
        Task.detached(priority: .utility) { Store.save(s) }
    }

    // MARK: Versions

    func refreshVersions(network: Bool) async {
        checkingVersions = true
        let projects = snapshot.projects
        let (found, live) = await Task.detached(priority: .utility) {
            await VersionAudit.audit(projects: projects, allowNetwork: network)
        }.value
        versions = found
        versionsLive = live
        checkingVersions = false
        snapshot.insights = Insights.build(snapshot, versions: versions)
    }

    /// Offline leak checks over every project (or one), one at a time at utility priority. Results appear as
    /// each project finishes. Projects in Desktop, Documents and Downloads go last: macOS may ask for access there.
    func checkSecurity(only project: Project? = nil) {
        guard checkingSecurity == nil else { return }
        let home = NSHomeDirectory()
        let guarded = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 + "/" }
        let projects = (project.map { [$0] } ?? snapshot.projects).sorted { a, b in
            let ga = guarded.contains { a.path.hasPrefix($0) }, gb = guarded.contains { b.path.hasPrefix($0) }
            return ga != gb ? !ga : (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
        guard !projects.isEmpty else { return }
        checkingSecurity = "1 of \(projects.count)"
        if project == nil { securityIssues = [] }
        Task.detached(priority: .utility) {
            for (i, p) in projects.enumerated() {
                await MainActor.run { self.checkingSecurity = "\(i + 1) of \(projects.count) · \(p.name)" }
                let found = ProjectSecurity.check(projectPath: p.path, name: p.name)
                await MainActor.run {
                    self.securityIssues = (self.securityIssues.filter { $0.projectPath != p.path } + found)
                        .sorted { ($0.level, $0.projectName, $0.file ?? "") < ($1.level, $1.projectName, $1.file ?? "") }
                }
            }
            await MainActor.run {
                if project == nil { self.securityChecked = Date() }
                self.checkingSecurity = nil
            }
        }
    }

    func audit(project: Project) {
        audits[project.path] = "Running…"
        let path = project.path
        Task.detached(priority: .utility) {
            let out = DependencyAudit.run(projectPath: path)
            await MainActor.run { self.audits[path] = out }
        }
    }

    // MARK: Selection

    func findings(for section: Pane) -> [Finding] {
        // Reading both registers the view's dependency; the work itself happens once per change.
        let q = search.lowercased()
        _ = snapshot.findings.count
        _ = categoryFilter
        if let hit = paneCache[section] { return hit }
        let out = snapshot.findings
            .filter { section.includes($0) }
            .filter { categoryFilter == nil || $0.category == categoryFilter }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) || ($0.owner ?? "").lowercased().contains(q) }
            .sorted { $0.bytes > $1.bytes }
        paneCache[section] = out
        return out
    }

    @ObservationIgnored private var paneCache: [Pane: [Finding]] = [:] { didSet { if paneCache.isEmpty { viewMemo = [:] } } }
    /// Groupings views derive from the results, kept until the results, filter or search change.
    @ObservationIgnored private var viewMemo: [String: Any] = [:]

    func memo<T>(_ key: String, _ make: () -> T) -> T {
        if let hit = viewMemo[key] as? T { return hit }
        let v = make()
        viewMemo[key] = v
        return v
    }

    func isSelectable(_ f: Finding) -> Bool {
        if f.safety == .protected || f.action == .none { return false }
        if let lock = f.lockedReason { return isActiveLock(lock) && (allowActiveProjects || unlocked.contains(f.id)) }
        return true
    }

    // MARK: Unlocking active projects

    /// Active-project items you unlocked one by one this session. Everything else stays locked; relaunching locks
    /// them all again.
    var unlocked = Set<Finding.ID>()

    func isActiveLock(_ reason: String?) -> Bool { reason?.hasPrefix("Active project") == true }
    func canUnlock(_ f: Finding) -> Bool { isActiveLock(f.lockedReason) && f.action != .none && f.safety != .protected && !unlocked.contains(f.id) }

    /// Unlocks and ticks them, in Cleanup and in the sweep.
    func unlock(_ items: [Finding]) {
        for f in items where canUnlock(f) { unlocked.insert(f.id); checked.insert(f.id); smartPicked.insert(f.id) }
    }

    func relock(_ f: Finding) {
        unlocked.remove(f.id); checked.remove(f.id); smartPicked.remove(f.id)
    }

    /// Cleaning may pass an active project's lock only for items unlocked one by one (or with the old setting on).
    private func allowsActive(_ items: [Finding]) -> Bool {
        allowActiveProjects || items.allSatisfy { !isActiveLock($0.lockedReason) || unlocked.contains($0.id) }
    }

    func toggle(_ f: Finding) {
        guard isSelectable(f) else { return }
        if checked.contains(f.id) { checked.remove(f.id) } else { checked.insert(f.id) }
    }

    func selectSafe(in section: Pane) {
        for f in findings(for: section) where f.safety == .safe && isSelectable(f) { checked.insert(f.id) }
    }

    var checkedFindings: [Finding] { checked.isEmpty ? [] : snapshot.findings.filter { checked.contains($0.id) }.sorted { $0.bytes > $1.bytes } }
    var checkedBytes: Int64 { checkedFindings.reduce(0) { $0 + $1.bytes } }

    var focusedFinding: Finding? { focused.flatMap { byID[$0] } }

    // MARK: Cleaning

    func clean() {
        let items = checkedFindings.filter(isSelectable)
        let allow = allowsActive(items)
        cleaning = true
        cleanStatus = "Starting…"
        Task.detached(priority: .userInitiated) {
            let receipt = Cleaner.clean(items, allowActiveProjects: allow) { i, title in
                Task { @MainActor in self.cleanStatus = "\(i + 1)/\(items.count) · \(title)" }
            }
            await MainActor.run {
                self.lastReceipt = receipt
                self.cleaning = false
                self.receipts = Store.receipts()
                self.apply(receipt)
            }
        }
    }

    /// Takes cleaned items out of the results.
    func apply(_ receipt: CleanReceipt) {
        let done = Set(receipt.items.filter(\.ok).map(\.path))
        snapshot.findings.removeAll { done.contains($0.path) && $0.action != .truncateLogs && !isCommand($0) }
        for i in snapshot.findings.indices where done.contains(snapshot.findings[i].path) { snapshot.findings[i].bytes = 0 }
        checked.subtract(done)
        smartPicked.subtract(done)
        finishSnapshot()
    }

    private func isCommand(_ f: Finding) -> Bool { if case .command = f.action { return true }; return false }

    // MARK: Uninstall

    func loadApps() {
        guard !loadingApps else { return }
        loadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = Uninstaller.installedApps()
            Task.detached(priority: .utility) { Uninstaller.warm(apps) }
            await MainActor.run {
                self.installedApps = apps; self.loadingApps = false
                // `--args -SapuApp Discord` opens that app's plan (used for screenshots).
                if let n = UserDefaults.standard.string(forKey: "SapuApp"), let a = apps.first(where: { $0.name == n }) { self.choose(a) }
            }
        }
    }

    func choose(_ app: InstalledApp) {
        selectedApp = app.id
        plan = nil
        planning = true
        let apps = installedApps
        Task.detached(priority: .userInitiated) {
            // The list first (a fraction of a second), then the sizes; choices made meanwhile are kept.
            let running = SystemProbe.runningProcessNames()
            let quick = Uninstaller.plan(for: app, running: running, apps: apps, sized: false)
            await MainActor.run { if self.selectedApp == app.id { self.plan = quick; self.planning = false } }
            let sizedPlan = Uninstaller.plan(for: app, running: running, apps: apps)
            await MainActor.run {
                guard self.selectedApp == app.id, let shown = self.plan else { return }
                var full = sizedPlan
                let picked = Dictionary(shown.items.map { ($0.path, $0.selected) }, uniquingKeysWith: { a, _ in a })
                for i in full.items.indices where full.items[i].locked == nil { if let s = picked[full.items[i].path] { full.items[i].selected = s } }
                self.plan = full
            }
        }
    }

    func togglePlanItem(_ id: UninstallItem.ID) {
        guard var p = plan, let i = p.items.firstIndex(where: { $0.id == id }), p.items[i].kind != .app, p.items[i].locked == nil else { return }
        p.items[i].selected.toggle()
        plan = p
    }

    /// Selects or clears every personal-data item (never the held-back ones unless chosen one by one).
    func setPersonalData(_ on: Bool) {
        guard var p = plan else { return }
        for i in p.items.indices where p.items[i].kind == .data && !p.items[i].holdBack && p.items[i].locked == nil { p.items[i].selected = on }
        plan = p
    }

    // MARK: Several apps at once

    var batch = Set<String>()
    var batchPlans: [UninstallPlan] = []
    var planningBatch = false

    func toggleBatch(_ app: InstalledApp) {
        if batch.contains(app.id) { batch.remove(app.id) } else { batch.insert(app.id) }
        planBatch()
    }

    /// Each ticked app with its default plan: the app, caches and helpers go; your data and locked items stay.
    func planBatch() {
        let picked = installedApps.filter { batch.contains($0.id) }
        guard picked.count > 1 else { batchPlans = []; return }
        planningBatch = true
        let apps = installedApps
        Task.detached(priority: .userInitiated) {
            let running = SystemProbe.runningProcessNames()
            let plans = picked.map { Uninstaller.plan(for: $0, running: running, apps: apps) }
            await MainActor.run {
                // Only if the ticks didn't change meanwhile.
                if Set(plans.map(\.app.id)) == self.batch { self.batchPlans = plans }
                self.planningBatch = false
            }
        }
    }

    func uninstallBatch() {
        let plans = batchPlans.filter { $0.blocked == nil }
        guard !plans.isEmpty else { return }
        uninstalling = true
        Task {
            for p in plans {
                let receipt = await Uninstaller.uninstall(p, running: SystemProbe.runningProcessNames())
                if receipt.items.first(where: { $0.path == p.app.path })?.ok == true {
                    installedApps.removeAll { $0.id == p.app.id }
                    batch.remove(p.app.id)
                }
                lastReceipt = receipt
            }
            receipts = Store.receipts()
            uninstalling = false
            batchPlans = []
            planBatch()
        }
    }

    func uninstall() {
        guard let p = plan else { return }
        uninstalling = true
        Task {
            let receipt = await Uninstaller.uninstall(p, running: SystemProbe.runningProcessNames())
            lastReceipt = receipt
            receipts = Store.receipts()
            uninstalling = false
            if receipt.items.first(where: { $0.path == p.app.path })?.ok == true {
                installedApps.removeAll { $0.id == p.app.id }
                plan = nil; selectedApp = nil
            } else if let app = installedApps.first(where: { $0.id == p.app.id }) {
                choose(app)
            }
        }
    }

    // MARK: Health & maintenance

    func refreshHealth() {
        Task.detached(priority: .userInitiated) {
            let h = Health.report()
            await MainActor.run { self.health = h }
        }
    }

    func checkMaintenance() {
        guard !checkingTasks else { return }
        checkingTasks = true
        checkProgress = (0, 0)
        Task.detached(priority: .userInitiated) {
            let t = Maintenance.check { done, total in Task { @MainActor in self.checkProgress = (done, total) } }
            await MainActor.run { self.tasks = t; self.checkingTasks = false }
        }
    }

    func runTask(_ t: MaintenanceTask) {
        runningTask = t.id
        Task.detached(priority: .userInitiated) {
            let r = Maintenance.run(t)
            let fresh = Maintenance.check()
            await MainActor.run {
                self.taskResults[t.id] = r.message
                self.tasks = fresh
                self.runningTask = nil
                self.receipts = Store.receipts()
            }
        }
    }

    // MARK: One-click tune-up

    /// Optimize tasks one click may run: only the harmless ones (no password, nothing restarted, anything removed
    /// goes to the Trash or is rebuilt by macOS), and only those that have something to do.
    var tuneUpTasks: [MaintenanceTask] { tasks.filter { Self.smartTaskIDs.contains($0.id) && $0.fix == .run && $0.status != .ok } }
    var tuning: String?
    var tuneLog: [(title: String, ok: Bool, message: String)] = []

    func tuneUp(_ list: [MaintenanceTask]) {
        guard tuning == nil, !list.isEmpty else { return }
        tuning = list[0].title
        tuneLog = []
        Task.detached(priority: .userInitiated) {
            var log: [(title: String, ok: Bool, message: String)] = []
            for t in list {
                await MainActor.run { self.tuning = t.title }
                let r = Maintenance.run(t)
                log.append((t.title, r.ok, r.message))
                let done = log
                await MainActor.run { self.taskResults[t.id] = r.message; self.tuneLog = done }
            }
            let fresh = Maintenance.check()
            await MainActor.run { self.tasks = fresh; self.tuning = nil; self.receipts = Store.receipts() }
        }
    }

    // MARK: Smart Clean

    enum SmartStep { case start, scanning, review, cleaning, done }
    struct SmartResult {
        var receipt: CleanReceipt?
        var tasks: [(title: String, ok: Bool, message: String)]
        var freeBefore: Int64
        var freeAfter: Int64
    }
    var smartStep: SmartStep = .start
    var smartPicked = Set<Finding.ID>()
    var smartTasks: [MaintenanceTask] = []
    var smartTaskPicked = Set<String>()
    var smartResult: SmartResult?
    var smartStatus = ""

    /// Optimize tasks that are harmless to run as part of Smart Clean: no password, nothing but the Trash or a rebuild.
    /// Left out on purpose: anything that asks for a password (DNS, memory, permissions, periodic scripts), restarts part
    /// of macOS (quick fixes), deletes history you might want (download history) or changes versions (Homebrew updates).
    static let smartTaskIDs = ["quicklook", "lsregister", "diskimages", "savedstate", "notifications", "spotlightrules", "dsstore",
                               "agents", "prefs", "sharedlists", "commandlinks", "overrides"]

    /// What Smart Clean could clean, split into what goes and what needs a look, and what it never touches.
    /// Worked out once whenever the results change, never while drawing.
    private(set) var smartSafe: [Finding] = []
    private(set) var smartCheck: [Finding] = []
    private(set) var smartStays: [Finding] = []
    private(set) var smartYours: [Finding] = []
    @ObservationIgnored private(set) var byID: [Finding.ID: Finding] = [:]
    var smartBytes: Int64 { smartPicked.reduce(Int64(0)) { $0 + (byID[$1]?.bytes ?? 0) } }

    private func derive() {
        paneCache = [:]
        byID = Dictionary(snapshot.findings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var safe: [Finding] = [], check: [Finding] = [], yours: [Finding] = [], stays: [Finding] = []
        // The full map's folder totals (Home folders, Applications, App data…) describe where space goes and contain
        // the items above, so they stay out of the bins; counting them would add the same bytes twice.
        for f in snapshot.findings where f.category != .trash && f.bytes > 0 && (f.layer != .full || f.category == .downloads) {
            let candidate = f.action != .none && isSelectable(f) && f.lockedReason == nil
            switch (candidate, f.safety) {
            case (true, .safe): safe.append(f)
            case (true, .check): check.append(f)
            case (true, .yours): yours.append(f)
            default: stays.append(f)
            }
        }
        smartSafe = safe.sorted { $0.bytes > $1.bytes }
        smartCheck = check.sorted { $0.bytes > $1.bytes }
        smartYours = yours.sorted { $0.bytes > $1.bytes }
        smartStays = stays.sorted { $0.bytes > $1.bytes }
    }

    func startSmartClean(userInitiated: Bool = true) {
        smartResult = nil
        undoMessage = nil
        smartStep = .scanning
        smartStatus = "Looking for caches, logs and leftovers…"
        // Project folders change slowly; a project scan from the last day is reused so Smart Clean stays quick.
        let fresh = snapshot.layerDates[ScanLayer.projects.rawValue].map { Date().timeIntervalSince($0) < 86_400 } ?? false
        scan(fresh ? [.quick] : [.quick, .projects], userInitiated: userInitiated)
    }

    /// Called when a scan finishes while Smart Clean waits for it.
    func buildSmartPlan() {
        smartStatus = "Checking what Optimize can do…"
        Task.detached(priority: .userInitiated) {
            let t = Maintenance.check()
            await MainActor.run {
                self.tasks = t
                // A sweep skips the one slow rebuild (Open With list); Optimize's Tune up runs it.
                self.smartTasks = t.filter { Self.smartTaskIDs.contains($0.id) && $0.id != "lsregister" && $0.fix == .run && ($0.status != .ok) }
                self.smartTaskPicked = Set(self.smartTasks.map(\.id))
                self.smartPicked = Set(self.smartSafe.map(\.id))
                self.smartStep = .review
            }
        }
    }

    func items(in bin: Bin) -> [Finding] {
        switch bin {
        case .go: smartSafe
        case .choice: smartCheck
        case .yours: smartYours
        case .stays: smartStays
        }
    }

    func cancelSmartClean() {
        if smartStep == .scanning { cancelScan() }
        smartStep = .start
    }

    func confirmSmartClean() {
        let items = smartPicked.compactMap { byID[$0] }.filter(isSelectable).sorted { $0.bytes > $1.bytes }
        let allow = allowsActive(items)
        let jobs = smartTasks.filter { smartTaskPicked.contains($0.id) }
        smartStep = .cleaning
        smartStatus = "Starting…"
        let before = SystemProbe.volume().free
        Task.detached(priority: .userInitiated) {
            let receipt: CleanReceipt? = items.isEmpty ? nil : Cleaner.clean(items, allowActiveProjects: allow) { i, title in
                Task { @MainActor in self.smartStatus = "\(i + 1) of \(items.count) · \(title)" }
            }
            var lines: [(String, Bool, String)] = []
            for j in jobs {
                await MainActor.run { self.smartStatus = j.title }
                let r = Maintenance.run(j)
                lines.append((j.title, r.ok, r.message))
            }
            let after = SystemProbe.volume().free
            let done = lines
            await MainActor.run {
                if let receipt { self.apply(receipt) }
                self.receipts = Store.receipts()
                self.smartResult = SmartResult(receipt: receipt, tasks: done, freeBefore: before, freeAfter: after)
                self.smartStep = .done
                self.checkMaintenance()
                self.loadTrash()
            }
        }
    }

    // MARK: App updates

    var appUpdates: [AppUpdate] = []
    var checkingUpdates: String?
    var updatesChecked: Date?
    var updateResults: [String: String] = [:]
    var updatingApp: String?

    func checkAppUpdates() {
        guard checkingUpdates == nil else { return }
        checkingUpdates = "Listing your apps…"
        let known = installedApps
        Task.detached(priority: .userInitiated) {
            let apps = known.isEmpty ? Uninstaller.installedApps() : known
            let found = await AppUpdates.check(apps) { msg in Task { @MainActor in self.checkingUpdates = msg } }
            await MainActor.run {
                if self.installedApps.isEmpty { self.installedApps = apps }
                self.appUpdates = found
                self.updatesChecked = Date()
                self.checkingUpdates = nil
            }
        }
    }

    func install(_ u: AppUpdate) {
        switch u.source {
        case .homebrew:
            updatingApp = u.id
            Task.detached(priority: .userInitiated) {
                let r = AppUpdates.upgrade(u)
                await MainActor.run {
                    self.updateResults[u.id] = r.message
                    self.updatingApp = nil
                    if r.ok { self.appUpdates.removeAll { $0.id == u.id } }
                }
            }
        case .sparkle:
            NSWorkspace.shared.open(URL(fileURLWithPath: u.app.path))
            updateResults[u.id] = "Opened \(u.app.name). Choose Check for Updates in its app menu."
        case .appStore(let id):
            NSWorkspace.shared.open(AppUpdates.appStoreURL(id))
            updateResults[u.id] = "Opened the App Store. Choose Update there."
        }
    }

    /// Opens Uninstall with this app chosen.
    func uninstallFlow(_ app: InstalledApp) {
        section = .uninstall
        if installedApps.isEmpty { installedApps = [app] }
        choose(app)
    }

    // MARK: Trash

    var trashSummary: TrashBin.Summary?
    var emptyingTrash = false
    var trashResult: String?

    func loadTrash() {
        Task.detached(priority: .utility) {
            let t = TrashBin.summary()
            await MainActor.run { self.trashSummary = t }
        }
    }

    func emptyTrash() {
        emptyingTrash = true
        Task.detached(priority: .userInitiated) {
            let r = TrashBin.empty()
            let t = TrashBin.summary()
            await MainActor.run {
                self.trashResult = r.message
                self.trashSummary = t
                self.emptyingTrash = false
                self.receipts = Store.receipts()
                self.snapshot.volume = SystemProbe.volume()
            }
        }
    }

    // MARK: Navigation

    /// The tab last used in each area, so going back lands where you were.
    @ObservationIgnored private var lastPane: [Area: Pane] = [:]
    func open(_ a: Area) {
        lastPane[Area.of(section)] = section
        section = lastPane[a] ?? a.panes[0]
    }

    // MARK: Helpers

    // MARK: Forgotten developer processes

    var devProcesses: [DevProcess] = []
    var devProcessResults: [Int32: String] = [:]

    func loadDevProcesses() {
        Task.detached(priority: .utility) {
            let p = DevProcesses.find()
            await MainActor.run { self.devProcesses = p }
        }
    }

    func quit(_ p: DevProcess) {
        Task.detached(priority: .userInitiated) {
            let r = DevProcesses.quit(p)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let fresh = DevProcesses.find()
            await MainActor.run { self.devProcessResults[p.pid] = r.message; self.devProcesses = fresh }
        }
    }

    // MARK: Updates

    var update: Updater.Release?
    var updateStatus: String?
    var updateDismissed = false

    /// Once a day on its own (quiet unless there is a newer release), or whenever you ask.
    func checkForUpdates(manual: Bool) {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard manual || Date().timeIntervalSince(last) > 86_400 else { return }
        if manual { updateStatus = "Checking for updates…"; updateDismissed = false }
        Task {
            do {
                let r = try await Updater.latest()
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                if Updater.isNewer(r.version, than: Updater.current) { update = r; updateStatus = nil }
                else if manual { updateStatus = "Sapu2 \(Updater.current) is the latest version." }
            } catch {
                if manual { updateStatus = "Couldn't check for updates: \(error.localizedDescription)" }
            }
        }
    }

    func downloadUpdate() {
        guard let r = update else { return }
        updateStatus = "Downloading Sapu2 \(r.version)…"
        Task {
            do {
                let dmg = try await Updater.download(r)
                updateStatus = "Downloaded and verified. Drag Sapu2 onto Applications in the window that opened, then reopen Sapu2."
                NSWorkspace.shared.open(dmg)
            } catch {
                updateStatus = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Protect list

    var protectList: [String] = ProtectList.load()

    func isProtected(_ path: String) -> Bool { ProtectList.entry(covering: path, in: protectList) != nil }

    func setProtected(_ path: String, _ on: Bool) {
        on ? ProtectList.add(path) : ProtectList.remove(path)
        protectList = ProtectList.load()
        snapshot.findings = snapshot.findings.map { ProtectList.apply($0, list: protectList) }
        checked = checked.filter { id in !isProtected(id) }
        Store.save(snapshot)
    }

    func addProtectedFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Never clean"
        if panel.runModal() == .OK { for u in panel.urls { setProtected(u.path, true) } }
    }

    // MARK: External drives

    var drives: [(drive: ExternalDrives.Drive, junk: ExternalDrives.Junk)] = []
    var driveResults: [String: String] = [:]
    var driveBusy: String?

    func loadDrives() {
        Task.detached(priority: .utility) {
            let found = ExternalDrives.drives().map { ($0, ExternalDrives.scan($0)) }
            await MainActor.run { self.drives = found }
        }
    }

    func cleanDrive(_ d: ExternalDrives.Drive, _ j: ExternalDrives.Junk) {
        driveBusy = d.id
        Task.detached(priority: .userInitiated) {
            let r = ExternalDrives.clean(d, j)
            let found = ExternalDrives.drives().map { ($0, ExternalDrives.scan($0)) }
            await MainActor.run { self.driveResults[d.id] = r.message; self.drives = found; self.driveBusy = nil; self.receipts = Store.receipts() }
        }
    }

    // MARK: Startup items

    var startup: [StartupItem] = []
    var startupBusy: String?
    var startupResults: [String: String] = [:]

    func loadStartup() {
        Task.detached(priority: .userInitiated) {
            let items = Startup.list()
            await MainActor.run { self.startup = items }
        }
    }

    enum StartupAction { case turnOff, turnOn, remove }

    func startup(_ item: StartupItem, _ action: StartupAction) {
        startupBusy = item.id
        Task.detached(priority: .userInitiated) {
            let r = switch action {
            case .turnOff: Startup.turnOff(item)
            case .turnOn: Startup.turnOn(item)
            case .remove: Startup.removeLeftover(item)
            }
            let items = Startup.list()
            await MainActor.run {
                self.startupResults[item.id] = r.message
                self.startup = items
                self.startupBusy = nil
                self.receipts = Store.receipts()
            }
        }
    }

    /// Messages from Put back that didn't work, keyed by "<receipt id>#<item>".
    var putBackResults: [String: String] = [:]

    func putBack(_ receipt: CleanReceipt, item: Int) {
        let r = Restorer.putBack(receipt, item: item)
        putBackResults["\(receipt.id)#\(item)"] = r.ok ? nil : r.message
        receipts = Store.receipts()
        if r.ok { explorer.refresh() }
    }

    /// What the last "Undo sweep" did, shown on the Done screen.
    var undoMessage: String?

    /// Puts everything the last sweep moved to the Trash back where it was.
    func undoSweep() {
        guard let receipt = smartResult?.receipt else { return }
        Task.detached(priority: .userInitiated) {
            let r = Restorer.putBackAll(receipt)
            await MainActor.run {
                self.smartResult?.receipt = r.receipt
                self.receipts = Store.receipts()
                self.explorer.refresh()
                let failed = r.failed > 0 ? " \(r.failed) could not be put back (emptied from the Trash, or something new is in the old place); see Receipt." : ""
                self.undoMessage = r.restored > 0 ? "Put back \(r.restored) item\(r.restored == 1 ? "" : "s").\(failed)" : "Nothing could be put back.\(failed)"
            }
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Full Disk Access
    // macOS never lets an app grant itself Full Disk Access. Sapu2 does every other step: it gets itself
    // listed in the pane, opens the pane, offers its icon to drag in, and notices the switch being turned on.

    func openFullDiskAccessSettings() {
        _ = SystemProbe.hasFullDiskAccess   // denied open → Sapu2 appears in the list, switch off
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        watchFullDiskAccess()
    }

    /// Polls with one open() per second until granted; stops itself after 10 minutes.
    func watchFullDiskAccess() {
        accessTimer?.invalidate()
        let started = Date()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                self.recheckFullDiskAccess()
                if self.hasFullDiskAccess || Date().timeIntervalSince(started) > 600 { t.invalidate() }
            }
        }
    }

    func recheckFullDiskAccess() {
        guard !hasFullDiskAccess, SystemProbe.hasFullDiskAccess else { return }
        hasFullDiskAccess = true
        accessJustGranted = true
        // Sizes measured without access left protected folders out; measure them again.
        explorer.remeasureAll()
        accessTimer?.invalidate()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissAccessSetup(forever: Bool) {
        if forever { UserDefaults.standard.set(true, forKey: "accessSetupDismissed") }
        showAccessSetup = false
        if accessJustGranted && scanning == nil { scan([.full]) }
        accessJustGranted = false
    }

    /// Settings sometimes asks to quit and reopen before the grant applies; this does it in one click.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}


/// Lets through at most one call per interval, from any thread.
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast
    init(interval: TimeInterval) { self.interval = interval }
    func ready() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
