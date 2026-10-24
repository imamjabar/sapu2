import Foundation
import SapuCore

// sapu-cli: headless access to the same engine the app uses. Never deletes anything.
//   sapu-cli scan [quick|projects|full|all]   scan layers, save the snapshot the app opens with
//   sapu-cli report                            print the saved snapshot
//   sapu-cli versions [--offline]              runtime / CVE support check
//   sapu-cli selftest                          engine checks on a temp folder

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func progressLine(_ p: ScanProgress) {
    let pct = Int(p.fraction * 100)
    let eta = p.eta.map { " · ~\(Format.duration($0)) left\(p.etaFromHistory ? "" : " (est.)")" } ?? ""
    let path = p.currentPath.tildePath
    let short = path.count > 50 ? "…" + path.suffix(49) : path
    FileHandle.standardError.write("\r\u{1B}[K[\(p.layer.short)] \(pct)% \(p.phase)\(eta) \(short)".data(using: .utf8)!)
}

func printTable(_ findings: [Finding], limit: Int = 25) {
    for f in findings.sorted(by: { $0.bytes > $1.bytes }).prefix(limit) {
        let size = Format.bytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
        let safety = f.safety.label.padding(toLength: 11, withPad: " ", startingAt: 0)
        let lock = f.lockedReason != nil ? " 🔒" : ""
        print("  \(size) \(safety) \(f.title)\(lock)")
    }
}

func runScan(_ layers: [ScanLayer]) async {
    var snap = Store.load() ?? Snapshot()
    snap.volume = SystemProbe.volume()
    let engine = ScanEngine()
    engine.forceFresh = args.contains("--fresh")
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { err("\ncancelling…"); engine.cancel() }
    sigint.resume()
    for layer in layers {
        let start = Date()
        switch layer {
        case .quick:
            snap.replace(layer: .quick, with: await engine.quick(previous: snap, progress: progressLine))
        case .projects:
            let r = await engine.projects(previous: snap, progress: progressLine)
            snap.replace(layer: .projects, with: r.findings)
            snap.projects = r.projects
        case .full:
            snap.replace(layer: .full, with: await engine.full(previous: snap, progress: progressLine))
        }
        let took = Date().timeIntervalSince(start)
        engine.commit(into: &snap, layer: layer)
        let reused = engine.reusedCount > 0 ? " · \(engine.reusedCount) unchanged folders reused" : ""
        err("\r\u{1B}[K✓ \(layer.name) in \(Format.duration(took))\(reused)\(engine.isCancelled ? " (cancelled)" : "")")
        if engine.isCancelled { break }
        snap.layerDates[layer.rawValue] = Date()
        snap.layerDurations[layer.rawValue] = took
    }
    snap.insights = Insights.build(snap)
    Store.save(snap)
    report(snap)
}

func report(_ snap: Snapshot) {
    if let v = snap.volume {
        print("Disk: \(Format.bytes(v.used)) used of \(Format.bytes(v.total)) · \(Format.bytes(v.free)) free · swap \(Format.bytes(v.swapBytes))")
    }
    if let c = Insights.coverage(snap) {
        print("Accounted for: \(Format.bytes(c.accounted)) of \(Format.bytes(c.used)) used (\(Int(Double(c.accounted) / Double(max(c.used, 1)) * 100))%)")
    }
    for layer in ScanLayer.allCases {
        let f = snap.findings(in: layer).filter { $0.category != .home }
        guard !f.isEmpty else { continue }
        let cleanable = f.filter(\.isCleanable).reduce(0) { $0 + $1.bytes }
        print("\n\(layer.name) — \(f.count) items, \(Format.bytes(cleanable)) cleanable")
        printTable(f)
    }
    if !snap.projects.isEmpty {
        print("\nProjects: \(snap.projects.count) (\(snap.projects.filter { $0.status == .active }.count) active)")
        for p in snap.projects.prefix(12) {
            let git = p.git.map { g in g.dirtyFiles > 0 ? " · \(g.dirtyFiles) uncommitted" : (g.ahead > 0 ? " · \(g.ahead) unpushed" : "") } ?? ""
            print("  \(p.status.label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(Format.bytes(p.artifactBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.name) · \(Format.age(p.lastActivity))\(git)")
        }
    }
    if !snap.insights.isEmpty {
        print("\nInsights")
        for i in snap.insights { print("  [\(i.level.rawValue)] \(i.title)\n      \(i.detail)") }
    }
}

func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ name: String) { print("\(ok ? "✓" : "✗") \(name)"); if !ok { failures += 1 } }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("sapu-selftest-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: root) }
    try? fm.createDirectory(atPath: root + "/proj/node_modules/pkg", withIntermediateDirectories: true)
    fm.createFile(atPath: root + "/proj/package.json", contents: Data("{\"engines\":{\"node\":\">=16\"}}".utf8))
    fm.createFile(atPath: root + "/proj/package-lock.json", contents: Data("{}".utf8))
    fm.createFile(atPath: root + "/proj/node_modules/pkg/a.bin", contents: Data(count: 2_000_000))
    try? fm.linkItem(atPath: root + "/proj/node_modules/pkg/a.bin", toPath: root + "/proj/node_modules/pkg/hardlink.bin")
    try? fm.createSymbolicLink(atPath: root + "/proj/node_modules/link", withDestinationPath: "/System")

    let s = DiskSizer.size(root + "/proj/node_modules")
    check(s.bytes >= 2_000_000 && s.bytes < 2_200_000, "sizer counts hardlinks once and never follows symlinks (\(s.bytes) B)")
    check(s.files == 2, "sizer file count (\(s.files))")

    let scanner = ProjectScanner()
    let r = scanner.scan(roots: [root], cancelled: { false }, onDiscover: { _ in }, onArtifactsFound: { _ in }, sizeArtifact: { DiskSizer.size($0) })
    check(r.projects.count == 1 && r.projects.first?.status == .active, "fresh project detected as active")
    check(r.findings.first?.lockedReason != nil, "active project artifacts are locked")
    check(r.projects.first?.declared["nodejs"] == ">=16", "reads engines.node")

    var f = r.findings.first!
    check(SafetyGuard.refusal(for: f, allowActiveProjects: false) != nil, "guard refuses locked item")
    f.path = NSHomeDirectory() + "/Documents"; f.lockedReason = nil
    check(SafetyGuard.refusal(for: f, allowActiveProjects: false) != nil, "guard refuses home folder")
    f.path = NSHomeDirectory() + "/.ssh/id_rsa"
    check(SafetyGuard.refusal(for: f, allowActiveProjects: false) != nil, "guard refuses ~/.ssh")
    f.path = NSHomeDirectory() + "/Library/Mobile Documents/x"
    check(SafetyGuard.refusal(for: f, allowActiveProjects: false) != nil, "guard refuses iCloud Drive")
    f.path = "/System/Library"
    check(SafetyGuard.refusal(for: f, allowActiveProjects: false) != nil, "guard refuses /System")

    check(VersionAudit.compare("8.2.10", "8.2.9") == 1 && VersionAudit.compare("8.2", "8.2.0") == 0, "version compare")
    check(VersionAudit.constraintFloor("^8.1|^8.2") == "8.1" && VersionAudit.constraintFloor(">=18") == "18", "constraint floor")
    let cycles = ["php": [VersionAudit.Cycle(cycle: "8.2", eol: "2026-12-31", latest: "8.2.30"), VersionAudit.Cycle(cycle: "7.4", eol: "2022-11-28", latest: "7.4.33")]]
    let now = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!
    check(VersionAudit.evaluate(product: "php", version: "7.4.33", source: "t", cycles: cycles, now: now).level == .eol, "PHP 7.4 flagged end-of-life")
    check(VersionAudit.evaluate(product: "php", version: "8.2.20", source: "t", cycles: cycles, now: now).level == .outdated, "PHP 8.2.20 flagged behind patch")
    check(VersionAudit.evaluate(product: "php", version: "8.2.30", source: "t", cycles: cycles, now: now).level == .ok, "PHP 8.2.30 ok")

    let node = ["nodejs": [VersionAudit.Cycle(cycle: "18", eol: "2025-04-30", latest: "18.20.8"), VersionAudit.Cycle(cycle: "22", eol: "2027-04-30", latest: "22.20.0")]]
    check(VersionAudit.evaluateConstraint(product: "nodejs", constraint: ">=18", projects: ["a"], cycles: node, now: now) == nil, ">=18 is not flagged (allows 22)")
    check(VersionAudit.evaluateConstraint(product: "nodejs", constraint: "18", projects: ["a"], cycles: node, now: now)?.level == .eol, "exact 18 flagged EOL")
    let php = ["php": [VersionAudit.Cycle(cycle: "7.4", eol: "2022-11-28", latest: nil), VersionAudit.Cycle(cycle: "8.1", eol: "2025-12-31", latest: nil), VersionAudit.Cycle(cycle: "8.3", eol: "2027-12-31", latest: nil)]]
    check(VersionAudit.evaluateConstraint(product: "php", constraint: "^8.1", projects: ["a"], cycles: php, now: now) == nil, "^8.1 not flagged (allows 8.3)")
    check(VersionAudit.evaluateConstraint(product: "php", constraint: "^7.3", projects: ["a"], cycles: php, now: now)?.level == .eol, "^7.3 flagged EOL")
    check(VersionAudit.evaluateConstraint(product: "php", constraint: "^7.3|^8.0", projects: ["a"], cycles: php, now: now) == nil, "^7.3|^8.0 not flagged")

    // A workspace (README + several components, or a root manifest) is one project, not one per component.
    let ws = root + "/area/ws"
    for c in ["a", "b", "c/nested"] {
        try? fm.createDirectory(atPath: "\(ws)/\(c)", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(ws)/\(c)/package.json", contents: Data("{}".utf8))
    }
    fm.createFile(atPath: ws + "/README.md", contents: Data("# ws".utf8))
    let wr = ProjectScanner().scan(roots: [root], cancelled: { false }, onDiscover: { _ in }, onArtifactsFound: { _ in }, sizeArtifact: { DiskSizer.size($0) })
    check(wr.projects.map(\.path).filter { $0.hasPrefix(root + "/area") } == [ws], "workspace with README groups its components (\(wr.projects.count) project)")

    // The fast sizer and the reference walker agree byte for byte.
    let fast = DiskSizer.size(root + "/proj"), ref = DiskSizer.ftsSize(root + "/proj")
    check(fast.bytes == ref.bytes && fast.files == ref.files, "getattrlistbulk sizer matches fts (\(fast.files) files)")

    // Log truncation keeps the file.
    let log = root + "/svc.log"
    fm.createFile(atPath: log, contents: Data(count: 10_000))
    let t = Cleaner.truncateLogs(log)
    check(t.0 && (try? fm.attributesOfItem(atPath: log)[.size] as? Int) == 0, "truncate empties log in place")

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    return failures == 0 ? 0 : 1
}

switch command {
case "scan":
    let which = args.dropFirst().first ?? "quick"
    let layers: [ScanLayer] = switch which {
    case "projects": [.projects]
    case "full": [.full]
    case "all": ScanLayer.allCases
    default: [.quick]
    }
    await runScan(layers)
case "report":
    if let s = Store.load() { report(s) } else { err("No saved scan. Run: sapu-cli scan") }
case "versions":
    let snap = Store.load() ?? Snapshot()
    let (found, live) = await VersionAudit.audit(projects: snap.projects, allowNetwork: !args.contains("--offline"))
    print("Support data: \(live ? "endoflife.date (live, cached 24 h)" : "bundled (offline, end-of-life dates only)")")
    for f in found {
        let icon = ["eol": "⛔", "outdated": "⚠️", "ok": "✓", "unknown": "?"][f.level.rawValue]!
        print("\(icon) \(f.product) \(f.version) — \(f.source)\n    \(f.message)\(f.fix.map { "\n    → \($0)" } ?? "")")
    }
case "selftest":
    exit(selftest())
case "bench":
    // sapu-cli bench <path>…  compare the getattrlistbulk sizer with the fts reference walker.
    for path in args.dropFirst().map(\.expandingTilde) {
        func timed(_ f: () -> SizeResult) -> (SizeResult, Double) {
            let t = Date(); let r = f(); return (r, Date().timeIntervalSince(t))
        }
        // Warm the cache once, then best of three for each, so neither walker gets a warmer cache.
        _ = DiskSizer.ftsSize(path)
        var (bulk, tb) = timed { DiskSizer.size(path) }
        var (fts, tf) = timed { DiskSizer.ftsSize(path) }
        for _ in 0..<2 {
            let b = timed { DiskSizer.size(path) }; if b.1 < tb { (bulk, tb) = b }
            let f = timed { DiskSizer.ftsSize(path) }; if f.1 < tf { (fts, tf) = f }
        }
        let same = fts.bytes == bulk.bytes && fts.files == bulk.files
        print("\(path.tildePath)\n  fts  \(Format.bytes(fts.bytes)) \(fts.files) files \(String(format: "%.2f", tf)) s"
              + "\n  bulk \(Format.bytes(bulk.bytes)) \(bulk.files) files \(String(format: "%.2f", tb)) s"
              + "  → \(String(format: "%.1f", tf / max(tb, 0.0001)))× \(same ? "identical" : "DIFFERENT (\(bulk.bytes - fts.bytes) B, \(bulk.files - fts.files) files)")")
    }
default:
    print("usage: sapu-cli scan [quick|projects|full|all] | report | versions [--offline] | selftest")
}
