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
    case maintenance = "Maintenance"
    case security = "Security & versions"
    case receipts = "Receipts"

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
        }
    }

    func includes(_ f: Finding) -> Bool {
        switch self {
        case .cleanable: f.isCleanable && f.safety <= .check
        case .caches: [.devCaches, .appCaches, .xcode, .ml, .containers].contains(f.category) && f.action != .none
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
final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot
    @Published var section: Pane = .overview
    @Published var focused: Finding.ID?
    @Published var checked = Set<Finding.ID>()
    @Published var scanning: ScanLayer?
    @Published var queue: [ScanLayer] = []
    @Published var progress: ScanProgress?
    @Published var versions: [VersionFinding] = []
    @Published var versionsLive = false
    @Published var checkingVersions = false
    @Published var receipts: [CleanReceipt] = Store.receipts()
    @Published var reviewing = false
    @Published var cleaning = false
    @Published var cleanStatus = ""
    @Published var lastReceipt: CleanReceipt?
    @Published var search = ""
    @Published var audits: [String: String] = [:]
    @Published var allowActiveProjects = UserDefaults.standard.bool(forKey: "allowActiveProjects") {
        didSet { UserDefaults.standard.set(allowActiveProjects, forKey: "allowActiveProjects") }
    }
    @Published var activeDays = UserDefaults.standard.object(forKey: "activeDays") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(activeDays, forKey: "activeDays") }
    }

    // Uninstall, health and maintenance
    @Published var installedApps: [InstalledApp] = []
    @Published var loadingApps = false
    @Published var selectedApp: InstalledApp.ID?
    @Published var plan: UninstallPlan?
    @Published var planning = false
    @Published var uninstalling = false
    @Published var health: HealthReport?
    @Published var tasks: [MaintenanceTask] = []
    @Published var checkingTasks = false
    @Published var taskResults: [String: String] = [:]
    @Published var runningTask: String?

    let engine = ScanEngine()
    @Published var hasFullDiskAccess = SystemProbe.hasFullDiskAccess
    @Published var showAccessSetup = false
    /// Folders the last layer took from the cache because the change journal showed no change.
    @Published var lastReused = 0
    @Published var accessJustGranted = false
    private var accessTimer: Timer?

    init() {
        snapshot = Store.load() ?? Snapshot()
        snapshot.volume = SystemProbe.volume()
        // `open Sapu.app --args -SapuPane Projects` opens a pane directly (used for screenshots).
        if let p = UserDefaults.standard.string(forKey: "SapuPane"), let pane = Pane(rawValue: p) { section = pane }
    }

    /// First launch runs the two light layers; later launches show cached results instantly.
    func onLaunch() {
        if !hasFullDiskAccess && !UserDefaults.standard.bool(forKey: "accessSetupDismissed") {
            showAccessSetup = true
            watchFullDiskAccess()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recheckFullDiskAccess() }
        }
        if snapshot.layerDates.isEmpty { scan([.quick, .projects]) }
        refreshHealth()
        checkMaintenance()
        Task { await refreshVersions(network: false) }
    }

    // MARK: Scanning

    func scan(_ layers: [ScanLayer]) {
        guard scanning == nil else { queue.append(contentsOf: layers.filter { !queue.contains($0) }); return }
        queue = layers
        Task { await runQueue() }
    }

    private func runQueue() async {
        while !queue.isEmpty {
            let layer = queue.removeFirst()
            scanning = layer
            progress = nil
            let start = Date()
            let previous = snapshot
            let sink: @Sendable (ScanProgress) -> Void = { p in Task { @MainActor [weak self] in self?.progress = p } }
            switch layer {
            case .quick:
                let found = await engine.quick(previous: previous, progress: sink)
                if !engine.isCancelled { snapshot.replace(layer: .quick, with: found) }
            case .projects:
                let days = activeDays
                let r = await engine.projects(previous: previous, activeDays: days, progress: sink)
                if !engine.isCancelled { snapshot.replace(layer: .projects, with: r.findings); snapshot.projects = r.projects }
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
        checked = checked.filter { id in snapshot.findings.contains { $0.id == id && isSelectable($0) } }
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
        let q = search.lowercased()
        return snapshot.findings
            .filter { section.includes($0) }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) || ($0.owner ?? "").lowercased().contains(q) }
            .sorted { $0.bytes > $1.bytes }
    }

    func isSelectable(_ f: Finding) -> Bool {
        if f.safety == .protected || f.action == .none { return false }
        if let lock = f.lockedReason { return allowActiveProjects && lock.hasPrefix("Active project") }
        return true
    }

    func toggle(_ f: Finding) {
        guard isSelectable(f) else { return }
        if checked.contains(f.id) { checked.remove(f.id) } else { checked.insert(f.id) }
    }

    func selectSafe(in section: Pane) {
        for f in findings(for: section) where f.safety == .safe && isSelectable(f) { checked.insert(f.id) }
    }

    var checkedFindings: [Finding] { snapshot.findings.filter { checked.contains($0.id) }.sorted { $0.bytes > $1.bytes } }
    var checkedBytes: Int64 { checkedFindings.reduce(0) { $0 + $1.bytes } }

    var focusedFinding: Finding? { focused.flatMap { id in snapshot.findings.first { $0.id == id } } }

    // MARK: Cleaning

    func clean() {
        let items = checkedFindings
        let allow = allowActiveProjects
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
                let done = Set(receipt.items.filter(\.ok).map(\.path))
                self.snapshot.findings.removeAll { done.contains($0.path) && $0.action != .truncateLogs && !self.isCommand($0) }
                for i in self.snapshot.findings.indices where done.contains(self.snapshot.findings[i].path) {
                    self.snapshot.findings[i].bytes = 0
                }
                self.checked.subtract(done)
                self.finishSnapshot()
            }
        }
    }

    private func isCommand(_ f: Finding) -> Bool { if case .command = f.action { return true }; return false }

    // MARK: Uninstall

    func loadApps() {
        guard !loadingApps else { return }
        loadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = Uninstaller.installedApps()
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
        Task.detached(priority: .userInitiated) {
            let p = Uninstaller.plan(for: app, running: SystemProbe.runningProcessNames())
            await MainActor.run { if self.selectedApp == app.id { self.plan = p; self.planning = false } }
        }
    }

    func togglePlanItem(_ id: UninstallItem.ID) {
        guard var p = plan, let i = p.items.firstIndex(where: { $0.id == id }), p.items[i].kind != .app else { return }
        p.items[i].selected.toggle()
        plan = p
    }

    /// Selects or clears every personal-data item (never the held-back ones unless chosen one by one).
    func setPersonalData(_ on: Bool) {
        guard var p = plan else { return }
        for i in p.items.indices where p.items[i].kind == .data && !p.items[i].holdBack { p.items[i].selected = on }
        plan = p
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
        Task.detached(priority: .userInitiated) {
            let t = Maintenance.check()
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

    // MARK: Helpers

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Full Disk Access
    // macOS never lets an app grant itself Full Disk Access. Sapu does every other step: it gets itself
    // listed in the pane, opens the pane, offers its icon to drag in, and notices the switch being turned on.

    func openFullDiskAccessSettings() {
        _ = SystemProbe.hasFullDiskAccess   // denied open → Sapu appears in the list, switch off
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
