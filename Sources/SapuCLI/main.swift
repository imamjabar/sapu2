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

    // A renamed node_modules is one item, and nothing inside a dependency tree is listed on its own.
    // PyInstaller (a .spec next to build/dist) and dbt (dbt_project.yml next to target) are recognised.
    let kinds = root + "/kinds"
    for d in ["old/node_modules-lama/pkg/dist", "old/node_modules-lama/pkg/node_modules/dep", "pyapp/build/pyapp", "pyapp/dist/pyapp", "dbt/target"] {
        try? fm.createDirectory(atPath: "\(kinds)/\(d)", withIntermediateDirectories: true)
    }
    fm.createFile(atPath: kinds + "/old/package.json", contents: Data("{}".utf8))
    fm.createFile(atPath: kinds + "/old/node_modules-lama/pkg/package.json", contents: Data("{}".utf8))
    fm.createFile(atPath: kinds + "/pyapp/pyapp.spec", contents: Data("a".utf8))
    fm.createFile(atPath: kinds + "/dbt/dbt_project.yml", contents: Data("name: x".utf8))
    for f in ["old/node_modules-lama/pkg/dist/x.js", "pyapp/build/pyapp/x", "pyapp/dist/pyapp/x", "dbt/target/x.sql"] {
        fm.createFile(atPath: "\(kinds)/\(f)", contents: Data(count: 1_500_000))
    }
    let kr = ProjectScanner().scan(roots: [root], cancelled: { false }, onDiscover: { _ in }, onArtifactsFound: { _ in }, sizeArtifact: { DiskSizer.size($0) })
    let kpaths = Set(kr.findings.map(\.path).filter { $0.hasPrefix(kinds) })
    check(kpaths == [kinds + "/old/node_modules-lama", kinds + "/pyapp/build", kinds + "/pyapp/dist", kinds + "/dbt/target"],
          "renamed node_modules is one item; PyInstaller and dbt output found (\(kpaths.count) items)")

    // Uninstaller: finds an app's own files, never a namesake tool's or another product's.
    let h = NSHomeDirectory(), L = h + "/Library"
    let vfs = Uninstaller.FileView.simulated([
        "\(L)/Application Support/Google/Chrome/Default/x", "\(L)/Application Support/Google/Chrome for Testing/x",
        "\(L)/Caches/com.google.Chrome/x", "\(L)/Group Containers/EQHXZ8M8AV.com.google.Chrome/x",
        "\(L)/Preferences/com.google.Chrome.plist", "\(L)/Cookies/com.google.Chrome.binarycookies",
        "\(h)/.claude/settings.json", "\(L)/Application Support/Claude/x", "\(L)/Caches/com.TechSmith.x/y",
    ])
    let chrome = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome"), fs: vfs)
    check(chrome.contains("\(L)/Application Support/Google/Chrome") && !chrome.contains { $0.contains("Chrome for Testing") },
          "uninstall: vendor folder found, Playwright's Chrome for Testing not claimed")
    check(chrome.contains("\(L)/Caches/com.google.Chrome") && chrome.contains("\(L)/Group Containers/EQHXZ8M8AV.com.google.Chrome")
          && chrome.contains("\(L)/Cookies/com.google.Chrome.binarycookies"), "uninstall: cache, app group and cookies found")
    let claude = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Claude.app", name: "Claude", bundleID: "com.anthropic.claudefordesktop"), fs: vfs)
    check(claude.contains("\(L)/Application Support/Claude") && !claude.contains("\(h)/.claude"), "uninstall: never claims Claude Code's ~/.claude")
    check(Uninstaller.holdBack("\(L)/Group Containers/EQHXZ8M8AV.com.google.Chrome") && Uninstaller.holdBack("\(L)/Application Support/Google/Chrome")
          && Uninstaller.classify("\(L)/Caches/com.google.Chrome") == .cache && Uninstaller.classify("\(L)/Preferences/com.google.Chrome.plist") == .data,
          "uninstall: caches preselected, data kept, profiles and app groups held back")
    let sys = InstalledApp(path: "/System/Applications/Mail.app", name: "Mail", bundleID: "com.apple.mail")
    check(Uninstaller.blockReason(sys, running: []) != nil && Uninstaller.blockReason(InstalledApp(path: "/Applications/Xcode.app", name: "Xcode", bundleID: "com.apple.dt.Xcode"), running: []) == nil,
          "uninstall: macOS apps blocked, Xcode allowed")
    var cookie = Finding(path: "\(L)/Cookies/com.google.Chrome.binarycookies", title: "c", category: .apps, safety: .check, reason: "", usedFor: "", action: .trash, layer: .full)
    let cookieOK = SafetyGuard.refusal(for: cookie, allowActiveProjects: false)
    cookie.path = "\(L)/Cookies/com.apple.Safari.binarycookies"
    check(cookieOK == nil || cookieOK == "Already gone.", "guard: an app's own cookie file may go")
    check(SafetyGuard.refusal(for: cookie, allowActiveProjects: false) == "Protected location.", "guard: Apple cookie files stay")

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
case "apps":
    // sapu-cli apps [name…] [--paths]  list installed apps, or show the uninstall plan for the named ones (read-only).
    let all = Uninstaller.installedApps()
    let wanted = args.dropFirst().filter { !$0.hasPrefix("--") }.map { $0.lowercased() }
    let running = SystemProbe.runningProcessNames()
    if wanted.isEmpty && !args.contains("--all") {
        for a in all { print("\(a.name)\t\(a.bundleID ?? "-")\t\(a.caskToken.map { "brew:\($0)" } ?? (a.fromAppStore ? "App Store" : ""))") }
    }
    for a in all where wanted.contains(a.name.lowercased()) || wanted.contains(a.bundleID?.lowercased() ?? "") || args.contains("--all") {
        let plan = Uninstaller.plan(for: a, running: running)
        print("\(a.name) (\(a.bundleID ?? "no id"))  total \(Format.bytes(plan.totalBytes)), selected \(Format.bytes(plan.selectedBytes))\(plan.blocked.map { "  BLOCKED: \($0)" } ?? "")")
        for i in plan.items { print("  [\(i.selected ? "x" : " ")] \(i.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(Format.bytes(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.path.tildePath)\(i.holdBack ? "  (kept)" : "")") }
    }
case "coverage":
    // sapu-cli coverage <cask.json> <app-names.txt>
    // For each listed app Homebrew knows, rebuild its documented leftovers ("zap" list) as a simulated
    // file system and check how many of them the uninstaller finds by its own rules.
    let rest = args.dropFirst().filter { !$0.hasPrefix("--") }.map(\.expandingTilde)
    guard rest.count == 2, let data = FileManager.default.contents(atPath: rest[0]),
          let casks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let names = try? String(contentsOfFile: rest[1], encoding: .utf8) else { print("usage: sapu-cli coverage <cask.json> <names.txt>"); exit(2) }
    func strings(_ v: Any?) -> [String] { (v as? [String]) ?? ((v as? String).map { [$0] } ?? []) }
    struct CaskInfo { var token: String; var app: String; var ids: [String]; var zap: [String] }
    var byName: [String: CaskInfo] = [:], byApp: [String: CaskInfo] = [:]
    for c in casks {
        guard let token = c["token"] as? String, let artifacts = c["artifacts"] as? [[String: Any]] else { continue }
        var app: String?, ids: [String] = [], zap: [String] = []
        for a in artifacts {
            if let apps = a["app"] as? [Any], let first = apps.first as? String, app == nil { app = first.replacingOccurrences(of: ".app", with: "") }
            for u in (a["uninstall"] as? [[String: Any]] ?? []) { ids += strings(u["quit"]) + strings(u["launchctl"]) }
            for z in (a["zap"] as? [[String: Any]] ?? []) { zap += strings(z["trash"]) + strings(z["rmdir"]) }
        }
        guard let app, !zap.isEmpty else { continue }
        let info = CaskInfo(token: token, app: app, ids: ids, zap: zap)
        // The app's own file name wins over marketing names ("ChatGPT" is ChatGPT.app, not the Codex cask).
        byApp[app.lowercased()] = byApp[app.lowercased()] ?? info
        for n in strings(c["name"]) + [token] { byName[n.lowercased()] = byName[n.lowercased()] ?? info }
    }
    let home = NSHomeDirectory()
    var tested = 0, matched = 0, totalPaths = 0, foundPaths = 0, unmatched: [String] = []
    var misses: [String: Int] = [:], examples: [String: String] = [:]
    for raw in names.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
        tested += 1
        let key = raw.lowercased().replacingOccurrences(of: ".app", with: "")
        guard let cask = byApp[key] ?? byName[key] ?? byName[key.replacingOccurrences(of: " ", with: "-")] else { unmatched.append(raw); continue }
        matched += 1
        // User-space leftovers only; "*" in a documented path stands for some name, so make one up.
        // "sfl*" is one of sfl2/3/4; a trailing "*" means "this name, maybe with a suffix"; any other "*" is some name.
        let zap = cask.zap.filter { $0.hasPrefix("~/") }.map { z -> String in
            var t = z.expandingTilde.replacingOccurrences(of: ".sfl*", with: ".sfl3")
            t = t.split(separator: "/", omittingEmptySubsequences: false).map { c -> String in
                var c = String(c)
                if c.hasSuffix("*"), c.count > 1 { c.removeLast() }
                return c.replacingOccurrences(of: "*", with: "x")
            }.joined(separator: "/")
            return t
        }
        guard !zap.isEmpty else { continue }
        // The app's bundle ID: what Homebrew quits, else the reverse-DNS name its preferences use.
        let idPattern = "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$"
        var id = cask.ids.first { $0.range(of: idPattern, options: .regularExpression) != nil && !$0.contains("Helper") }
        if id == nil {
            // The reverse-DNS name used most across its folders (Preferences, Containers, Caches…).
            var counts: [String: Int] = [:]
            for z in zap {
                var leaf = z.lastComponent
                for ext in [".plist", ".savedState", ".binarycookies", ".sfl2", ".sfl3", ".sfl4"] where leaf.hasSuffix(ext) { leaf = String(leaf.dropLast(ext.count)) }
                if leaf.range(of: idPattern, options: .regularExpression) != nil, !leaf.hasSuffix(".x"), !leaf.contains("x.") { counts[leaf, default: 0] += 1 }
            }
            id = counts.max { $0.value == $1.value ? $0.key.count > $1.key.count : $0.value < $1.value }?.key
        }
        let app = InstalledApp(path: "/Applications/\(cask.app).app", name: cask.app, bundleID: id, version: nil, executable: nil, fromAppStore: false, caskToken: cask.token)
        let found = Uninstaller.leftovers(for: app, fs: .simulated(zap)).map { $0.lowercased() }
        for z in zap {
            totalPaths += 1
            let l = z.lowercased()
            if found.contains(where: { l == $0 || l.hasPrefix($0 + "/") }) { foundPaths += 1; continue }
            // Group misses by where they live, to see which rule is missing.
            let rel = z.hasPrefix(home + "/Library/") ? String(z.dropFirst(home.count + 9)) : "~/" + String(z.dropFirst(home.count + 1))
            let bucket = rel.split(separator: "/").prefix(rel.hasPrefix("Application Support") || rel.hasPrefix("Containers") ? 1 : 1).joined(separator: "/")
            misses[bucket, default: 0] += 1
            if args.contains("--misses") { print("MISS\t\(cask.app)\t\(id ?? "-")\t\(z.tildePath)") }
            if examples[bucket] == nil { examples[bucket] = "\(cask.app) (\(id ?? "no id")): \(z.tildePath)" }
        }
    }
    print("Apps on the list: \(tested). Known to Homebrew with documented leftovers: \(matched).")
    print("Documented leftover paths in your home folder: \(totalPaths). Found by Sapu's rules: \(foundPaths) (\(totalPaths > 0 ? 100 * foundPaths / totalPaths : 0)%).")
    print("Missed, by location:")
    for (b, n) in misses.sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(n)\t\(b)\t e.g. \(examples[b]!)") }
    if args.contains("--unmatched") { print("Not in Homebrew: " + unmatched.joined(separator: ", ")) }
case "health":
    let h = Health.report()
    print("Health \(h.score)/100 — \(h.verdict)")
    print("Memory \(Format.bytes(h.memoryUsed)) of \(Format.bytes(h.memoryTotal)) used, pressure \(h.pressure.rawValue), swap \(Format.bytes(h.swapUsed)) of \(Format.bytes(h.swapTotal))")
    print("Load \(h.load.map { String(format: "%.2f", $0) }.joined(separator: " ")) on \(h.cores) cores, thermal \(h.thermal), up \(Format.duration(h.uptime))")
    if let b = h.battery { print("Battery \(b.percent)%\(b.charging ? " charging" : ""), \(b.cycles.map { "\($0) cycles" } ?? ""), health \(b.health.map { "\($0)%" } ?? "?") \(b.condition ?? "")") }
    print("Top memory: " + h.topMemory.map { "\($0.name) \(Format.bytes($0.memory))" }.joined(separator: ", "))
    print("Top CPU: " + h.topCPU.map { "\($0.name) \(Int($0.cpu))%" }.joined(separator: ", "))
    for a in h.advice { print("  • \(a)") }
case "maintenance":
    for t in Maintenance.check() {
        let icon = ["ok": "✓", "attention": "!", "info": "·"][t.status.rawValue]!
        print("\(icon) \(t.title)\n    \(t.detail)")
        if case .terminal(let c) = t.fix { print("    $ \(c)") }
    }
default:
    print("usage: sapu-cli scan [quick|projects|full|all] | report | versions [--offline] | apps [name…] | selftest")
}
