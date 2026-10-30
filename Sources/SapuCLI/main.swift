import Foundation
import SapuCore

// sapu2-cli: headless access to the same engine the app uses. Deletes nothing unless `clean --yes` is given.
//   sapu2-cli scan [quick|projects|full|all]   scan layers, save the snapshot the app opens with
//   sapu2-cli report                            print the saved snapshot
//   sapu2-cli clean [--bin sweep|choice|yours] [--json] [--yes] [--allow-active]
//                                              show what a sweep would do (dry run); --yes moves it to the Trash
//   sapu2-cli versions [--offline]              runtime / CVE support check
//   sapu2-cli selftest                          engine checks on a temp folder

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
    // Receipts and snapshots from the tests stay in the temporary folder, out of your History.
    setenv("SAPU_STORE_DIR", root + "/store", 1)
    setenv("SAPU_TEST_TRASH", root + "/trash", 1)
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
    check(["Google/ChromeDebug", "company.thebrowser.Browser", "net.imput.helium", "Dia/User Data"].allSatisfy { Uninstaller.holdBack("\(L)/Application Support/\($0)") }
          && Uninstaller.holdBack("\(L)/Caches/Dia/User Data"), "uninstall: holds back every browser profile the reference protects")
    check(Uninstaller.classify("\(L)/Application Support/apifox/blob_storage") == .cache && Uninstaller.classify("\(L)/Application Support/ShipIt_stderr.log") == .cache
          && Uninstaller.classify("\(L)/Containers/com.utmapp.UTM/Data/Library/Caches") == .cache && Uninstaller.classify("\(L)/Application Support/apifox") == .data
          && Credentials.isCredential(name: "key_datas"), "uninstall: bloat inside data goes first, the data and Telegram's login key stay")
    let subs = Uninstaller.FileView.simulated([
        "\(L)/Preferences/com.google.GeminiMacOS.launcher.plist", "\(L)/Preferences/com.google.GeminiMacOS.beta.plist",
        "\(L)/Containers/com.microsoft.errorreporting/x", "\(L)/Application Support/com.evernote.EvernoteHelper/x",
        "\(L)/Preferences/com.google.chrome.for.testing.plist", "\(L)/Application Support/iTerm2/x",
    ])
    let gemini = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Gemini.app", name: "Gemini", bundleID: "com.google.GeminiMacOS"), fs: subs)
    check(gemini.contains("\(L)/Preferences/com.google.GeminiMacOS.launcher.plist") && !gemini.contains { $0.contains(".beta") },
          "uninstall: <id>.helper found, <id>.beta (another channel) kept")
    let evernote = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Evernote.app", name: "Evernote", bundleID: "com.evernote.Evernote"), fs: subs)
    let iterm = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/iTerm.app", name: "iTerm", bundleID: "com.googlecode.iterm2"), fs: subs)
    check(evernote.contains("\(L)/Application Support/com.evernote.EvernoteHelper") && iterm.contains("\(L)/Application Support/iTerm2"),
          "uninstall: <id>Helper and the bundle-ID name (iTerm2) found")
    let chrome2 = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome"), fs: subs)
    let word = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Microsoft Word.app", name: "Microsoft Word", bundleID: "com.microsoft.Word"),
                                     fs: subs, otherIDs: ["com.microsoft.excel", "com.microsoft.errorreporting"])
    check(!chrome2.contains { $0.contains("for.testing") } && !word.contains { $0.contains("errorreporting") },
          "uninstall: Chrome for Testing and helpers shared with other apps are kept")
    // Sign-ins and keys stay; the caches beside them go.
    let prof = root + "/AppData"
    for f in ["Default/Cookies", "Default/Cache/data_0", "Partitions/x/Code Cache/js/a", "agent-session-authority.key"] {
        try? fm.createDirectory(atPath: (prof + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: prof + "/" + f, contents: Data("x".utf8))
    }
    let clean = root + "/Plain"
    for f in ["Trust Tokens", "AUTHORS.txt", "Cache/cookies"] {   // a cookie inside a cache folder isn't searched
        try? fm.createDirectory(atPath: (clean + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: clean + "/" + f, contents: Data("x".utf8))
    }
    let creds = Credentials.find(in: prof, limit: 5)
    check(creds.contains("Default/Cookies") && creds.contains("agent-session-authority.key") && Credentials.find(in: clean).isEmpty,
          "credentials: cookies and keys found inside a folder; Trust Tokens and AUTHORS aren't credentials")
    check(Set(Credentials.bloat(in: prof).map { $0.lastComponent }) == ["Cache", "Code Cache"] && Uninstaller.classify(L + "/HTTPStorages/a.b.binarycookies") == .data,
          "credentials: caches inside a locked folder are offered; cookie jars count as data")
    var cf = Finding(path: prof, title: "x", category: .apps, safety: .check, reason: "", usedFor: "", action: .trash, layer: .full)
    cf.bytes = 1
    let bundle = root + "/Old.app/Contents/Resources"
    try? fm.createDirectory(atPath: bundle, withIntermediateDirectories: true)
    fm.createFile(atPath: bundle + "/dsa_pub.pem", contents: Data("x".utf8))
    var unused = cf; unused.path = root + "/Old.app"
    check(Cleaner.credentialRefusal(cf) != nil && Cleaner.credentialRefusal(unused) == nil,
          "credentials: cleanup refuses a leftover that holds sign-ins, not an app bundle's public keys")

    // Electron profiles: caches in Partitions/<name>, Default and User Data/<profile> count, not other folders.
    let ele = root + "/Electron"
    for d in ["Partitions/notion/Cache", "Default/GPUCache", "User Data/Profile 1/Code Cache", "User Data/Crashpad", "Partitions/x/IndexedDB"] {
        try? fm.createDirectory(atPath: ele + "/" + d, withIntermediateDirectories: true)
    }
    let profs = Set(ScanEngine.chromiumProfiles(ele).map { String($0.dropFirst(ele.count)) })
    check(profs == ["", "/Default", "/User Data", "/Partitions/notion", "/Partitions/x", "/User Data/Profile 1"],
          "scan: Electron profiles found in Partitions, Default and User Data (\(profs.sorted()))")

    // Agents, IDEs and chat apps (the reference tool's developer and AI cleanup), on a fake home.
    let dh = root + "/DevHome"
    let old = "2026-01-01T00:00:00.000Z"
    func put(_ f: String, _ text: String = "x") {
        try? fm.createDirectory(atPath: (dh + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: dh + "/" + f, contents: Data(text.utf8))
    }
    put(".claude/jobs/done1/tmp/r1.png"); put(".claude/jobs/done1/state.json", #"{"state":"done","name":"Deck","lastTerminalAt":"\#(old)"}"#)
    put(".claude/jobs/run1/tmp/a"); put(".claude/jobs/run1/state.json", #"{"state":"running","updatedAt":"\#(old)"}"#)
    put(".claude/jobs/pin1/tmp/a"); put(".claude/jobs/pin1/state.json", #"{"state":"done","updatedAt":"\#(old)"}"#)
    put(".claude/jobs/pins.json", #"["pin1"]"#)
    for v in ["GoLand2024.3", "GoLand2025.2", "PyCharm2025.1", "consentOptions", "Toolbox"] { put("Library/Application Support/JetBrains/\(v)/x") }
    for r in ["0.1.0", "0.2.0"] { put(".codex/packages/app-server-daemon/releases/\(r)/bin") }
    put(".codex/worktrees/ab12/repo/.git"); put(".codex/worktrees/cd34/repo/.git")
    put("Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/p1/Cache/a")
    put("Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/p1/IndexedDB/a")
    put("Library/Application Support/Claude/vm_bundles/claudevm.bundle/disk")
    for v in ["v3", "v10"] { put("Library/pnpm/store/\(v)/files/00/a") }
    put("Code/app/package.json"); put("Code/app/perf/Launch_old.trace/x"); put("Code/app/perf/Launch_new.trace/x")
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: dh + "/Code/app/perf/Launch_old.trace")
    put("sys/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR/a.mov")
    put("ucache/clang/ModuleCache/ABC/Foundation.pcm")
    for r in ["iOS-17-0", "iOS-18-2", "watchOS-10-0"] { put("sys/Library/Developer/CoreSimulator/Images/\(r).dmg") }
    let simJSON = #"""
    {"A":{"identifier":"A","version":"17.0","platformIdentifier":"com.apple.platform.iphonesimulator","path":"/Library/Developer/CoreSimulator/Images/iOS-17-0.dmg","deletable":true},
     "B":{"identifier":"B","version":"18.2","platformIdentifier":"com.apple.platform.iphonesimulator","path":"/Library/Developer/CoreSimulator/Images/iOS-18-2.dmg","deletable":true},
     "C":{"identifier":"C","version":"10.0","platformIdentifier":"com.apple.platform.watchsimulator","path":"/Library/Developer/CoreSimulator/Images/watchOS-10-0.dmg","deletable":true}}
    """#
    let dc = DevExtras.candidates(home: dh, projects: [dh + "/Code/app"], now: Date(), system: dh + "/sys", userCache: dh + "/ucache",
                                  simRuntimes: { Data(simJSON.utf8) }, gitClean: { $0.contains("ab12") })
    let dp = Set(dc.map { String($0.path.dropFirst(dh.count + 1)) })
    check(dp.contains(".claude/jobs/done1/tmp") && !dp.contains(".claude/jobs/run1/tmp") && !dp.contains(".claude/jobs/pin1/tmp"),
          "dev: finished Claude Code jobs' files listed; running and pinned jobs stay")
    check(dp.contains("Library/Application Support/JetBrains/GoLand2024.3") && !dp.contains { $0.contains("GoLand2025.2") || $0.contains("PyCharm") || $0.contains("Toolbox") || $0.contains("consent") },
          "dev: only older JetBrains versions are listed, never the newest, unversioned or Toolbox")
    check(dc.filter { $0.path.contains("app-server-daemon") }.count == 1, "dev: older Codex server releases listed, newest kept")
    let wt = dc.filter { $0.path.contains("/worktrees/") }
    check(wt.count == 2 && wt.allSatisfy { $0.safety == Safety.yours } && wt.first { $0.path.contains("cd34") }?.lockedReason != nil,
          "dev: agent worktrees never preselected; one with uncommitted changes is locked")
    check(dp.contains { $0.hasSuffix("p1/Cache") } && !dp.contains { $0.contains("IndexedDB") }, "dev: WeChat browser cache listed, its stored data kept")
    let vm = dc.first { $0.path.hasSuffix("vm_bundles") }
    check(vm?.action == CleanAction.none && vm?.safety == Safety.yours,
          "dev: Claude's VM is explained under manage separately, never cleaned")
    let pn = dc.filter { $0.owner == "pnpm" }
    check(pn.count == 2 && pn.contains { $0.path.hasSuffix("store/v10") && $0.action == CleanAction.command("pnpm store prune") }
          && pn.contains { $0.path.hasSuffix("store/v3") && $0.action == CleanAction.trash && $0.safety == Safety.check },
          "dev: pnpm store pruned with pnpm; an older store layout (v3) listed apart, never preselected")
    let sims = dc.filter { $0.title.hasPrefix("Simulator runtime") }
    check(sims.count == 1 && sims[0].title.contains("iOS 17.0") && sims[0].action == CleanAction.command("xcrun simctl runtime delete A"),
          "dev: only older simulator runtimes listed, removed with simctl; newest per platform stays")
    let noXcode = DevExtras.candidates(home: dh, now: Date(), system: dh + "/sys", userCache: "", simRuntimes: { nil }, gitClean: { _ in true })
    check(noXcode.contains { $0.path.hasSuffix("CoreSimulator/Images") && $0.action == CleanAction.none },
          "dev: without Xcode, simulator images are only shown")
    let traces = dc.filter { $0.owner == "Instruments" }
    check(traces.count == 2 && traces.first { $0.path.contains("Launch_new") }?.lockedReason != nil
          && traces.first { $0.path.contains("Launch_old") }?.lockedReason == nil,
          "dev: Instruments recordings in projects listed; ones from the last week locked")
    check(dc.contains { $0.title == "Aerial wallpaper videos" && $0.action == CleanAction.none },
          "dev: aerial wallpaper videos explained, never cleaned (outside home)")
    check(dc.contains { $0.path.hasSuffix("ucache/clang/ModuleCache") && $0.action == CleanAction.none } && !noXcode.contains { $0.title == "Clang module cache" },
          "dev: clang module cache shown with how to remove it, never cleaned (outside home)")
    check(RuleBook.all.contains { $0.paths == ["~/.npm/_prebuilds"] && $0.safety == .safe }, "dev: npm prebuilt binaries are a safe cache")

    // Disk map: a fake home with a folder, a file, a link, an app package and key stores.
    let xh = NSTemporaryDirectory() + "sapu-explore-\(UUID().uuidString)"
    for d in ["Code/big", "Mine.app/Contents", ".ssh", "Library/Keychains", "Library/Mail/V10"] { try? fm.createDirectory(atPath: xh + "/" + d, withIntermediateDirectories: true) }
    fm.createFile(atPath: xh + "/Code/big/a.bin", contents: Data(count: 300_000))
    fm.createFile(atPath: xh + "/notes.txt", contents: Data(count: 10))
    try? fm.createSymbolicLink(atPath: xh + "/elsewhere", withDestinationPath: "/usr")
    let xe = Dictionary(uniqueKeysWithValues: DiskExplorer.entries(in: xh).map { ($0.name, $0) })
    check(xe["Code"]?.isFolder == true && xe["Mine.app"]?.isFolder == false && xe["elsewhere"]?.isLink == true && xe["elsewhere"]?.isFolder == false
          && xe["notes.txt"]?.isFolder == false, "disk map: folders open, packages stay one item, links are never followed")
    check(DiskExplorer.sealed(xh + "/.ssh", home: xh) != nil && DiskExplorer.sealed(xh + "/Library/Keychains", home: xh) != nil
          && DiskExplorer.sealed(xh + "/Library/Mail", home: xh) != nil && DiskExplorer.sealed(xh + "/Code", home: xh) == nil,
          "disk map: keys, keychains and mail are measured but never listed")
    let xf = [Finding(path: xh + "/Code/big", title: "x", category: .projects, safety: .safe, bytes: 300_000, files: 1, lastModified: nil,
                      reason: "", usedFor: "", owner: "", rebuild: nil, action: .trash, layer: .projects)]
    check(DiskExplorer.cleanable(under: xh + "/Code", in: xf) == 300_000 && DiskExplorer.cleanable(under: xh + "/Library", in: xf) == 0,
          "disk map: folders show what Sapu2 can clean inside them")
    try? fm.removeItem(atPath: xh)

    // v0.8: put back, startup items, AI chats and models, map safety, forgotten processes.
    let vh = NSTemporaryDirectory() + "sapu-v08-\(UUID().uuidString)"
    for d in [".Trash", "proj", ".claude/projects/-gone", ".claude/projects/-here", ".claude/projects/-nochats",
              ".ollama/models/manifests/registry.ollama.ai/library/llama3", "keys/.ssh", "big"] {
        try? fm.createDirectory(atPath: vh + "/" + d, withIntermediateDirectories: true)
    }
    fm.createFile(atPath: vh + "/.Trash/notes.txt", contents: Data("x".utf8))
    let item = CleanReceipt.Item(path: vh + "/proj/notes.txt", title: "notes", bytes: 1, action: "Move to Trash", ok: true, message: "", trashedTo: vh + "/.Trash/notes.txt")
    let back = Restorer.putBack(item, home: vh)
    check(back.ok && fm.fileExists(atPath: vh + "/proj/notes.txt") && !fm.fileExists(atPath: vh + "/.Trash/notes.txt")
          && !Restorer.putBack(item, home: vh).ok, "put back: an item returns from the Trash to its place; a second try is refused")
    var outside = item; outside.trashedTo = vh + "/proj/notes.txt"; outside.path = vh + "/proj/other.txt"
    check(!Restorer.putBack(outside, home: vh).ok, "put back: only moves things out of the Trash")

    // Undo sweep: everything still in the Trash returns; what was emptied is counted, not invented.
    for n in ["u1", "u2"] { fm.createFile(atPath: vh + "/.Trash/\(n).txt", contents: Data("x".utf8)) }
    func sweepItem(_ n: String) -> CleanReceipt.Item {
        CleanReceipt.Item(path: vh + "/proj/\(n).txt", title: n, bytes: 1, action: "Move to Trash", ok: true, message: "", trashedTo: vh + "/.Trash/\(n).txt")
    }
    let sweep = CleanReceipt(date: Date(), items: [sweepItem("u1"), sweepItem("u2"), sweepItem("emptied")], freeBefore: 0, freeAfter: 0)
    let undone = Restorer.putBackAll(sweep, home: vh)
    check(undone.restored == 2 && undone.failed == 1 && fm.fileExists(atPath: vh + "/proj/u1.txt") && fm.fileExists(atPath: vh + "/proj/u2.txt")
          && undone.receipt.items.filter { $0.restored == true }.count == 2, "undo sweep: items in the Trash return, an emptied one is counted as failed")
    // Error log: stays on this Mac, hides the home folder, and cannot grow without limit.
    ErrorLog.clear()
    ErrorLog.record("test", "failed at \(NSHomeDirectory())/secret/file")
    check(ErrorLog.read().contains("failed at ~/secret/file") && !ErrorLog.read().contains(NSHomeDirectory()), "error log: home folder is written as ~")
    for i in 0..<400 { ErrorLog.record("test", "line \(i) " + String(repeating: "x", count: 1_000)) }
    let logText = ErrorLog.read()
    check(logText.utf8.count <= 256 * 1024 && logText.contains("line 399") && !logText.contains("line 0 ") && logText.hasPrefix("20"), "error log: older lines are dropped past the size limit")
    ErrorLog.clear()
    check(Restorer.putBackAll(undone.receipt, home: vh).restored == 0 && !undone.receipt.items.contains(where: { $0.title != "emptied" && Restorer.canPutBack($0) }),
          "undo sweep: a second undo puts nothing back")

    check(Startup.loadedLabels("PID\tStatus\tLabel\n-\t0\tcom.a.one\n412\t0\thomebrew.mxcl.nginx\n") == ["com.a.one", "homebrew.mxcl.nginx"]
          && Startup.disabledLabels("\tdisabled services = {\n\t\t\"com.x.off\" => disabled\n\t\t\"com.x.on\" => enabled\n\t\t\"com.x.old\" => true\n\t}") == ["com.x.off", "com.x.old"],
          "startup: running and turned-off items read from launchctl")
    let brewItem = StartupItem(plist: "/x.plist", label: "homebrew.mxcl.php@8.1", program: nil, scope: .user, loaded: true, disabled: false, programMissing: false, app: nil)
    check(Startup.brewService(brewItem) == "php@8.1" && !Startup.removeLeftover(brewItem).ok,
          "startup: Homebrew services switch with brew services; only leftovers can be removed")

    fm.createFile(atPath: vh + "/.claude/projects/-gone/a.jsonl", contents: Data(#"{"type":"user","cwd":"/nonexistent/sapu/oldproject","x":1}"#.utf8))
    fm.createFile(atPath: vh + "/.claude/projects/-here/a.jsonl", contents: Data(#"{"cwd":"\#(vh)/proj"}"#.utf8))
    fm.createFile(atPath: vh + "/.claude/projects/-nochats/memory.md", contents: Data("m".utf8))
    let chats = DevExtras.orphanedClaudeChats(home: vh)
    check(chats.count == 1 && chats[0].path.hasSuffix("-gone") && chats[0].safety == .yours && chats[0].action == CleanAction.none
          && chats[0].title.contains("oldproject"),
          "ai: Claude Code chats of a deleted project are shown, never cleaned (chat history is yours)")
    fm.createFile(atPath: vh + "/.ollama/models/manifests/registry.ollama.ai/library/llama3/8b",
                  contents: Data(#"{"config":{"size":500},"layers":[{"size":4000000000},{"size":12000}]}"#.utf8))
    let om = DevExtras.ollamaModels(home: vh)
    check(om.count == 1 && om[0].title == "Ollama model llama3:8b" && om[0].bytes == 4_000_012_500 && om[0].action == CleanAction.none,
          "ai: Ollama models sized by their layers, shown, never cleaned")
    check(RuleBook.all.filter { $0.category == .ml || ["docker.desktop", "colima"].contains($0.id) }.allSatisfy { r in
              r.action == CleanAction.none || !(r.paths.contains { $0.contains("huggingface") || $0.contains("torch") || $0.contains("ollama") || $0.contains("lmstudio") })
          } && RuleBook.all.first { $0.id == "colima" }?.action == CleanAction.none && RuleBook.all.first { $0.id == "hf.cache" }?.action == CleanAction.none,
          "safety: models and Docker disks are shown with how to manage them, never cleaned by Sapu2")

    check(DiskExplorer.trashRefusal(vh + "/keys/.ssh", projects: [], home: vh) != nil
          && DiskExplorer.trashRefusal(vh + "/.Trash", projects: [], home: vh) != nil
          && DiskExplorer.trashRefusal("/usr/bin", projects: [], home: vh) != nil
          && DiskExplorer.trashRefusal(vh + "/keys/.ssh/huge.bin", projects: [], home: vh) != nil,
          "disk map: Move to Trash refuses private folders, the Trash and anything outside home")
    fm.createFile(atPath: vh + "/big/movie.mov", contents: Data(count: 2_000_000))
    fm.createFile(atPath: vh + "/keys/.ssh/huge.bin", contents: Data(count: 2_000_000))
    let lf = DiskExplorer.largestFiles(under: vh, minBytes: 1_000_000)
    check(lf.map { $0.path.lastComponent } == ["movie.mov"], "disk map: largest files found, private folders left out")

    let stat = """
      501     1 2-03:04:05  90000 /opt/homebrew/bin/node
      502   500    15:00:00 50000 /opt/homebrew/bin/node
      503     1 1-00:00:00  80000 /opt/homebrew/bin/postgres
      504     1 3-00:00:00  60000 /usr/local/bin/gopls
      505     1 5-00:00:00  70000 /opt/homebrew/bin/node
    """
    let pargs = "501 /opt/homebrew/bin/node server.js\n504 /usr/local/bin/gopls serve\n505 /opt/homebrew/bin/node agent.js\n"
    let fp = DevProcesses.parse(stat: stat, args: pargs, launchdJobs: [505], minAge: 12 * 3600, me: 1)
    check(Set(fp.map(\.pid)) == [501, 504] && DevProcesses.etime("2-03:04:05") == 183_845,
          "processes: forgotten dev servers and lone language servers found; launchd jobs, databases and live ones left alone")
    try? fm.removeItem(atPath: vh)

    // Protection policy, from the reference cleaner's own protection check on this Mac's findings.
    let ph = "/Users/x", pl = ph + "/Library"
    func adj(_ p: String, _ s: Safety = .safe) -> Finding {
        Protection.adjust(Finding(path: p, title: "t", category: .appCaches, safety: s, reason: "", usedFor: "", action: .trash, layer: .quick), home: ph)
    }
    check([pl + "/Caches/com.apple.akd", pl + "/Containers/com.apple.mediaanalysisd/Data/Library/Caches", pl + "/Application Support/Codex/Default/GPUCache",
           ph + "/.cache/codex-runtimes", pl + "/Caches/Codex", pl + "/Containers/com.utmapp.UTM", pl + "/Containers/com.microsoft.Outlook"]
            .allSatisfy { adj($0).action == CleanAction.none && adj($0).safety == .yours },
          "protection: Apple caches, Codex data, VM and mail leftovers are shown only")
    check(adj(pl + "/Caches/Codex/Default/Cache").action == CleanAction.trash
          && [pl + "/Caches/com.microsoft.VSCode", pl + "/Containers/com.microsoft.Excel/Data/Library/Logs", pl + "/Caches/com.openai.codex"]
            .allSatisfy { adj($0).safety == .check } && adj(pl + "/Caches/com.spotify.client").safety == .safe,
          "protection: IDE, Office and AI app caches never preselected; Codex's web cache and other apps' caches unchanged")
    let plist = [ph + "/Work", pl + "/Caches/com.spotify.client"]
    let locked = ProtectList.apply(adj(ph + "/Work/app/node_modules"), list: plist)
    check(ProtectList.entry(covering: ph + "/Work/app", in: plist) == ph + "/Work" && ProtectList.entry(covering: ph + "/Workshop", in: plist) == nil
          && locked.lockedReason == ProtectList.message && !locked.isCleanable
          && ProtectList.apply(locked, list: []).lockedReason == nil,
          "protect list: everything under an entry is locked, neighbours aren't, removing it unlocks")
    let rel = try? Updater.parse(Data(#"{"tag_name":"v0.10.0","html_url":"https://x/r","body":"n","assets":[{"name":"Sapu2-macOS-arm64.dmg","browser_download_url":"https://x/a.dmg"},{"name":"Sapu2-macOS-arm64.dmg.sha256","browser_download_url":"https://x/a.sha256"}]}"#.utf8))
    check(rel?.version == "0.10.0" && rel?.checksum != nil && Updater.isNewer("0.10.0", than: "0.9.2") && !Updater.isNewer("0.8.1", than: "0.8.1")
          && !Updater.isNewer("0.8.0", than: "0.8.1"), "updates: newest GitHub release read, versions compared as numbers")
    let eh = NSTemporaryDirectory() + "sapu-drive-\(UUID().uuidString)"
    for d in ["DCIM", ".Spotlight-V100"] { try? fm.createDirectory(atPath: eh + "/" + d, withIntermediateDirectories: true) }
    for f in [".DS_Store", "DCIM/.DS_Store", "DCIM/a.jpg", "DCIM/._a.jpg", "DCIM/._orphan.jpg", ".Spotlight-V100/.DS_Store", "notes.txt"] {
        fm.createFile(atPath: eh + "/" + f, contents: Data("x".utf8))
    }
    let ej = ExternalDrives.scan(ExternalDrives.Drive(path: eh, name: "T", format: "ExFAT", foreignFormat: true))
    let ejApfs = ExternalDrives.scan(ExternalDrives.Drive(path: eh, name: "T", format: "APFS", foreignFormat: false))
    check(ej.dsStore.count == 2 && ej.appleDouble.map { $0.lastComponent } == ["._a.jpg"] && ejApfs.appleDouble.isEmpty,
          "external drives: .DS_Store found, ._ only next to its file and only on Windows-format drives, system folders skipped")
    let lh = NSTemporaryDirectory() + "sapu-logs-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: lh, withIntermediateDirectories: true)
    fm.createFile(atPath: lh + "/old.log", contents: Data(count: 100)); fm.createFile(atPath: lh + "/big.log", contents: Data(count: 11_000_000))
    fm.createFile(atPath: lh + "/small.log", contents: Data(count: 100))
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: lh + "/old.log")
    let lr = Cleaner.splitLogs(lh, remove: { (try? fm.removeItem(atPath: $0)) != nil })
    check(lr.0 && !fm.fileExists(atPath: lh + "/old.log") && DiskSizer.size(lh + "/big.log").bytes == 0 && fm.fileExists(atPath: lh + "/big.log")
          && DiskSizer.size(lh + "/small.log").bytes > 0, "logs: old files to the Trash, big active ones emptied in place, small recent ones kept")
    try? fm.removeItem(atPath: lh)
    try? fm.removeItem(atPath: eh)

    // Optimize: the reference's tasks, with Sapu2's limits.
    let hdText: String = #"<?xml version="1.0"?><plist version="1.0"><dict><key>images</key><array>"#
        + #"<dict><key>image-path</key><string>/Users/x/Downloads/Tool.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk4</string></dict><dict><key>mount-point</key><string>/Volumes/Tool</string></dict></array></dict>"#
        + #"<dict><key>image-path</key><string>/System/Library/AssetsV2/x.dmg</string><key>system-entities</key><array><dict><key>mount-point</key><string>/Volumes/Cryptex</string></dict></array></dict>"#
        + #"<dict><key>image-path</key><string>/Users/x/Sim.dmg</string><key>system-entities</key><array><dict><key>mount-point</key><string>/Library/Developer/CoreSimulator/Volumes/iOS</string></dict></array></dict>"#
        + #"<dict><key>image-path</key><string>/Users/x/Downloads/Sapu2.dmg</string><key>system-entities</key><array><dict><key>mount-point</key><string>/Volumes/Sapu2</string></dict></array></dict>"#
        + #"</array></dict></plist>"#
    let hd = Data(hdText.utf8)
    let imgs = Maintenance.mountedImages(hd)
    check(imgs.count == 4 && imgs.filter { Maintenance.ejectable($0, protectList: [], running: "/Volumes/Sapu2/Sapu2.app") }.map { $0.mount } == ["/Volumes/Tool"]
          && !Maintenance.ejectable(imgs[0], protectList: ["/Users/x/Downloads"], running: "/Applications/Sapu2.app"),
          "optimize: only images you opened are ejected; macOS's, simulators', Sapu2's own and protected ones stay")
    let oh = NSTemporaryDirectory() + "sapu-opt-\(UUID().uuidString)"
    for d in ["states/com.old.app.savedState", "states/com.open.app.savedState", "states/com.new.app.savedState", "sfl/sub", "bin"] {
        try? fm.createDirectory(atPath: oh + "/" + d, withIntermediateDirectories: true)
    }
    for d in ["com.old.app", "com.open.app"] { try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)], ofItemAtPath: oh + "/states/\(d).savedState") }
    let states = Maintenance.oldSavedStates(in: oh + "/states", running: ["com.open.app"]).map { $0.lastComponent }
    check(states == ["com.old.app.savedState"], "optimize: window states older than 30 days go, open apps' and recent ones stay")
    let goodList = try! PropertyListSerialization.data(fromPropertyList: ["items": [1]], format: .binary, options: 0)
    fm.createFile(atPath: oh + "/sfl/com.apple.LSSharedFileList.FavoriteItems.sfl3", contents: goodList)
    fm.createFile(atPath: oh + "/sfl/sub/broken.sfl3", contents: Data("not a plist".utf8))
    fm.createFile(atPath: oh + "/sfl/com.apple.LSSharedFileList.ApplicationRecentDocuments.sfl3", contents: Data("x".utf8))
    check(Maintenance.brokenSharedLists(in: oh + "/sfl").map { $0.lastComponent } == ["broken.sfl3"],
          "optimize: unreadable sidebar lists found, readable ones and recent documents kept")
    fm.createFile(atPath: oh + "/real", contents: Data("x".utf8))
    try? fm.createSymbolicLink(atPath: oh + "/bin/good", withDestinationPath: oh + "/real")
    try? fm.createSymbolicLink(atPath: oh + "/bin/gone", withDestinationPath: oh + "/removed-app/tool")
    try? fm.createSymbolicLink(atPath: oh + "/bin/unplugged", withDestinationPath: "/Volumes/NotPluggedIn-\(UUID().uuidString)/tool")
    let bl = Maintenance.brokenLinks(in: [oh + "/bin"])
    check(bl.map { $0.lastComponent } == ["gone"], "optimize: commands pointing nowhere found; working ones and ones on unplugged drives kept")
    let tr = Maintenance.trashAll(bl, action: "test")
    check(tr.ok && !DiskSizer.isSymlink(oh + "/bin/gone") && fm.fileExists(atPath: oh + "/real") && DiskSizer.isSymlink(oh + "/bin/good"),
          "optimize: a broken link goes to the Trash as a link; nothing it pointed at is touched")
    check(Maintenance.spotlightOrphans(["com.gone.App", "com.here.App", "System.iphoneApps", "com.apple.mail", "not an id"], installed: { $0 == "com.here.App" }) == ["com.gone.App"],
          "optimize: Spotlight rows of removed apps found; Apple's, installed and odd ones kept")
    let ov = Maintenance.overrides { d, k in (d == "-g" && k == "NSAppSleepDisabled") ? "1\n" : (k == "skip-verify-remote" ? "YES" : (k == "skip-verify" ? "0" : "")) }
    check(ov.map { $0.key } == ["NSAppSleepDisabled", "skip-verify-remote"], "optimize: only overrides that are on are restored")
    let ndb = oh + "/n.db"
    _ = Shell.run(["sqlite3", ndb, "create table record(id integer, delivered_date real); insert into record values (1, strftime('%s','now') - 978307200 - 40*86400), (2, strftime('%s','now') - 978307200 - 86400);"], timeout: 10)
    _ = Shell.run(["sqlite3", ndb, Maintenance.notificationPrune], timeout: 10)
    check(Shell.run(["sqlite3", ndb, "select id from record"], timeout: 10).out.trimmingCharacters(in: .whitespacesAndNewlines) == "2",
          "optimize: notification records older than 30 days removed, last month's kept (Core Data dates)")
    check(Set(Maintenance.adminCommands.keys) == ["dns", "periodic", "permissions", "purge"] && Maintenance.runAdmin("rm").ok == false
          && !Maintenance.adminCommands.values.contains { $0.contains("\"") || $0.contains("rm ") },
          "optimize: only four fixed administrator commands exist; anything else is refused")
    check(Maintenance.volumeMounted("/Volumes/NotPluggedIn-x/a") == false && Maintenance.volumeMounted("/Users/x/a"),
          "optimize: programs on unplugged drives aren't called broken")
    try? fm.removeItem(atPath: oh)

    // v0.11: updates and Empty Trash.
    let cast = Data("""
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
    <item><title>2.1</title><sparkle:version>210</sparkle:version><sparkle:shortVersionString>2.1</sparkle:shortVersionString><sparkle:releaseNotesLink>https://x/notes21</sparkle:releaseNotesLink><enclosure url="https://x/a.zip"/></item>
    <item><title>3.0 beta</title><sparkle:channel>beta</sparkle:channel><enclosure url="https://x/b.zip" sparkle:version="300" sparkle:shortVersionString="3.0b1"/></item>
    <item><title>2.5</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion><enclosure url="https://x/c.zip" sparkle:version="250" sparkle:shortVersionString="2.5"/></item>
    <item><title>2.0</title><enclosure url="https://x/d.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
    </channel></rss>
    """.utf8)
    let castItems = AppUpdates.parseAppcast(cast)
    let best = AppUpdates.newest(castItems, os: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    check(castItems.count == 4 && best?.short == "2.1" && best?.notes?.absoluteString == "https://x/notes21",
          "updates: newest release for everyone on this macOS, betas and too-new releases skipped")
    let brewApps = [InstalledApp(path: "/Applications/Foo.app", name: "Foo", bundleID: "a.foo", version: "1.0", caskToken: "foo")]
    let bu = AppUpdates.parseBrew(Data(#"{"formulae":[],"casks":[{"name":"foo","installed_versions":["1.0"],"current_version":"1.2"},{"name":"bar","installed_versions":["1"],"current_version":"2"}]}"#.utf8), apps: brewApps)
    check(bu.count == 1 && bu[0].latest == "1.2" && bu[0].installed == "1.0", "updates: Homebrew casks matched to installed apps")
    let th = NSTemporaryDirectory() + "sapu-trash-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: th + "/.Trash/folder", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: th + "/keep", withIntermediateDirectories: true)
    fm.createFile(atPath: th + "/.Trash/a.txt", contents: Data(count: 1000)); fm.createFile(atPath: th + "/.Trash/folder/b.txt", contents: Data(count: 1000))
    fm.createFile(atPath: th + "/keep/k.txt", contents: Data("x".utf8))
    try? fm.createSymbolicLink(atPath: th + "/.Trash/link", withDestinationPath: th + "/keep")
    let ts = TrashBin.summary(home: th, receipts: [])
    let te = TrashBin.empty(home: th, save: false)
    check(ts.items == 3 && te.ok && DiskSizer.children(th + "/.Trash").isEmpty && fm.fileExists(atPath: th + "/keep/k.txt"),
          "empty trash: everything in the Trash goes, a link's target outside it stays")
    try? fm.removeItem(atPath: th)

    // v0.10.1: the reference's remaining caches, and the chats beside them.
    let byID = Dictionary(RuleBook.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    check(["xcode.sourcepackages", "sim.testdevices", "sim.inbox", "gradle.daemon", "claude.crashpad", "ios.updates", "netease.updater"].allSatisfy { byID[$0]?.safety == .safe }
          && ["cargo.git", "nuget.packages", "tart.cache", "parallels.downloads"].allSatisfy { byID[$0]?.safety == .check }
          && byID["conda.pkgs"]?.paths.contains("~/.conda/pkgs") == true && byID["ios.updates"]?.paths.contains("~/Library/iTunes/iPod Software Updates") == true
          && Set(RuleBook.all.map(\.id)).count == RuleBook.all.count,
          "rules: the reference's remaining caches added, slow-to-refetch ones as Check first")
    // v0.12: plain-language explanations reach the things people ask about, by the right rule.
    func explained(_ path: String, _ title: String = "x") -> Explainer.Explanation? {
        Explainer.explain(Finding(path: path, title: title, category: .system, safety: .yours, reason: "", usedFor: "", action: .none, layer: .quick))
    }
    check(explained(NSHomeDirectory() + "/.colima/_lima/colima/datadisk")?.commands.contains("colima delete") == true
          && explained(NSHomeDirectory() + "/code/web/node_modules")?.impact == .medium
          && explained(NSHomeDirectory() + "/code/api/.venv")?.plain.contains("virtual environment") == true
          && explained(NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData")?.impact == .low
          && explained(NSHomeDirectory() + "/code/outsourcing_app/src") == nil
          && explained(NSHomeDirectory() + "/Downloads/report.pdf")?.impact == .high
          && Set(Explainer.allFragments).count == Explainer.allFragments.count,
          "explainer: Colima, node_modules, venv, DerivedData and downloads explained; names match exactly; no duplicate rules")
    check(["claude.pastecache", "gemini.tmp", "editor.workspacestorage"].allSatisfy { byID[$0]?.safety == .yours && byID[$0]?.action == CleanAction.none },
          "rules: pasted text, Gemini chats and editor chat history are shown, never cleaned")
    check(["com.operasoftware.OperaGX", "Floorp", "LibreWolf", "TorBrowser-Data", "Orion", "DuckDuckGo", "Google/Chrome Canary", "Microsoft Edge Beta"]
            .allSatisfy { Uninstaller.holdBack("\(L)/Application Support/\($0)") } && Uninstaller.holdBack("\(L)/SafariTechnologyPreview"),
          "uninstall: every browser's profiles held back, beta channels and forks too")

    check(ScanEngine.friendlyCache("Partitions/81df339d-9913-4d99-88d8-4005c1b203c9/Cache") == "web cache"
          && ScanEngine.friendlyCache("User Data/Profile 1/Service Worker/CacheStorage") == "offline web cache (Profile 1)",
          "scan: cache titles read plainly, without profile IDs")

    // Project security: committed env files and keys, tokens in code and remote URLs, unignored env files.
    let repo = root + "/LeakyRepo"
    func rput(_ f: String, _ text: String) {
        try? fm.createDirectory(atPath: (repo + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: repo + "/" + f, contents: Data(text.utf8))
    }
    rput(".env", "DB_PASSWORD=hunter2"); rput(".env.example", "DB_PASSWORD="); rput("api/.env.local", "X=1")
    rput("src/config.js", "const k = 'AKIA" + "Q3EGRT7VBN2KXL5M';\nconst ok = 'sk-ant-your_key_here_xxxxxxxxxxxxxxxxxxxxxxxx';\n")
    rput("deploy/id_rsa", "x"); rput("package.json", "{}"); rput(".gitignore", "api/.env.local\n")
    rput("docs/fixture.js", "AIza" + String(repeating: "B", count: 35))
    _ = Shell.run(["git", "init", "-q"], cwd: repo)
    _ = Shell.run(["git", "add", ".env", ".env.example", "src/config.js", "deploy/id_rsa", "package.json", ".gitignore"], cwd: repo)
    _ = Shell.run(["git", "remote", "add", "origin", "https://bob:ghp_" + String(repeating: "a", count: 36) + "@github.com/bob/x.git"], cwd: repo)
    let sec = ProjectSecurity.check(projectPath: repo, name: "LeakyRepo")
    let byKind = Dictionary(grouping: sec, by: \.kind).mapValues { $0.compactMap(\.file) }
    check(byKind["env"]?.contains(".env") == true && byKind["env"]?.contains(".env.example") != true && byKind["env"]?.contains("api/.env.local") != true,
          "security: committed .env flagged; .env.example and an ignored .env.local are fine")
    check(byKind["key"] == ["deploy/id_rsa"] && byKind["secret"] == ["src/config.js"] && byKind["remote"]?.count == 1 && byKind["lockfile"]?.count == 1,
          "security: committed key, AWS key in code, token in remote URL and missing lockfile found (\(byKind))")
    check(!sec.contains { $0.detail.contains("Q3EGRT7VBN2KXL5M") || $0.detail.contains("hunter2") }, "security: secrets are masked, never shown")

    // Release-check finds: a separately installed CLI's folders, a vendor-wide updater, an earlier version's files.
    let H = NSHomeDirectory()
    var more = Uninstaller.FileView.simulated([
        "/opt/homebrew/bin/broom", "\(H)/.config/Broom/x", "\(L)/Logs/Broom/x", "\(L)/Caches/com.example.BroomApp/x",
        "/Applications/Google Chrome.app/Contents/Frameworks/G.framework/Helpers/GoogleUpdater.app/Contents/Info.plist",
        "\(L)/Caches/com.google.GoogleUpdater/x", "\(L)/Preferences/com.microsoft.teams.plist", "\(L)/Preferences/com.microsoft.teams2.plist",
    ])
    more.bundleID = { $0.hasSuffix("GoogleUpdater.app") ? "com.google.GoogleUpdater" : nil }
    let broomApp = InstalledApp(path: "/Applications/Broom.app", name: "Broom", bundleID: "com.example.BroomApp")
    let broomL = Uninstaller.leftovers(for: broomApp, fs: more)
    check(broomL.contains("\(L)/Caches/com.example.BroomApp") && !broomL.contains { $0.contains("/Broom/") || $0.hasSuffix("/Broom") },
          "uninstall: folders of a separately installed CLI (Homebrew broom) stay with Broom.app's removal")
    let chrome3 = Uninstaller.leftovers(for: InstalledApp(path: "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome"), fs: more)
    check(!chrome3.contains { $0.contains("GoogleUpdater") }, "uninstall: Google's shared updater is never one app's leftover")
    let teams = InstalledApp(path: "/Applications/Microsoft Teams.app", name: "Microsoft Teams", bundleID: "com.microsoft.teams2")
    let teamsL = Uninstaller.leftovers(for: teams, fs: more)
    let teamsOther = Uninstaller.leftovers(for: teams, fs: more, otherIDs: ["com.microsoft.teams"])
    check(teamsL.contains("\(L)/Preferences/com.microsoft.teams.plist") && Uninstaller.earlierVersion("\(L)/Preferences/com.microsoft.teams.plist", of: teams) != nil
          && !teamsOther.contains("\(L)/Preferences/com.microsoft.teams.plist"),
          "uninstall: an earlier version's files are labelled and kept, and skipped when that version is installed")
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

    // One walk, every folder: the sizes a walk keeps for folders inside match walking each one on its own, with
    // both walkers; and a folder stepped around (it has a walk of its own) adds back to exactly the full size.
    for bulk in [true, false] {
        DiskSizer.useBulk = bulk
        let kept = Locked([String: SizeResult]())
        let whole = DiskSizer.size(root, onDir: { d, s in kept.mutate { $0[d] = s } })
        let k = kept.value
        let agree = !k.isEmpty && k.allSatisfy { d, s in let own = DiskSizer.size(d); return own.bytes == s.bytes && own.files == s.files }
        check(agree, "one walk keeps each folder's size (\(bulk ? "bulk" : "fts"), \(k.count) folders)")
        let skip = root + "/proj"
        let short = Locked([String: SizeResult]())
        let part = DiskSizer.size(root, skipDir: { $0 == skip }, onDir: { d, s in short.mutate { $0[d] = s } })
        let own = DiskSizer.size(skip)
        check(part.bytes + own.bytes == whole.bytes && part.files + own.files == whole.files && short.value[skip] == nil,
              "a folder stepped around adds back to the full size (\(bulk ? "bulk" : "fts"))")
    }
    DiskSizer.useBulk = true

    // Log truncation keeps the file.
    let log = root + "/svc.log"
    fm.createFile(atPath: log, contents: Data(count: 10_000))
    let t = Cleaner.truncateLogs(log)
    check(t.0 && (try? fm.attributesOfItem(atPath: log)[.size] as? Int) == 0, "truncate empties log in place")

    // Groups: an app lives outside the home folder but is not a macOS cache.
    func finding(_ path: String, _ category: SapuCore.Category, _ safety: Safety = .safe, action: CleanAction = .trash, layer: ScanLayer = .quick,
                 lock: String? = nil, bytes: Int64 = 5_000_000) -> Finding {
        Finding(path: path, title: path.lastComponent, category: category, safety: safety, bytes: bytes, reason: "", usedFor: "", action: action,
                lockedReason: lock, layer: layer)
    }
    check(CleanGroup.of(finding("/Applications/Figma.app", .apps, .check)) == .unusedApps, "an unused app is in Unused apps, not System cache")
    check(CleanGroup.of(finding("/Library/Application Support/com.apple.idleassetsd/Customer", .system)) == .systemCache, "a macOS cache outside home stays System cache")

    // Sweep plan: the bins follow the safety label, and locked, protected and full-map totals stay out.
    let home = NSHomeDirectory()
    var planSnap = Snapshot()
    planSnap.findings = [
        finding(home + "/.sapu-selftest/a", .devCaches, .safe),
        finding(home + "/.sapu-selftest/b", .devCaches, .check),
        finding(home + "/.sapu-selftest/c", .downloads, .yours),
        finding(home + "/.sapu-selftest/d", .devCaches, .protected),
        finding(home + "/.sapu-selftest/e", .projects, .safe, lock: "Active project"),
        finding(home + "/.sapu-selftest/f", .home, .safe, layer: .full),
        finding(home + "/.sapu-selftest/g", .devCaches, .safe, action: .none),
    ]
    let plan = SweepPlan.build(from: planSnap)
    func binOf(_ s: String) -> SweepPlan.Bin? { plan.items.first { $0.path.hasSuffix("/" + s) }?.bin }
    check(binOf("a") == .sweep && binOf("b") == .choice && binOf("c") == .yours, "sweep plan: safe, check and yours land in their bins")
    check(binOf("d") == .stays && binOf("e") == .stays && binOf("g") == .stays, "sweep plan: protected, locked and info-only items stay")
    check(binOf("f") == nil, "sweep plan: full-map folder totals are not counted twice")
    check(SweepPlan.build(from: planSnap, allowActiveProjects: true).items.first { $0.path.hasSuffix("/e") }?.bin == .sweep, "sweep plan: --allow-active frees active-project items")
    check(plan.sweepBytes == 0 && plan.items.first { $0.path.hasSuffix("/a") }?.refusal == "Already gone.", "sweep plan: an item the guard would refuse is not counted")

    // Guard: spellings that reach a protected place still do.
    for (p, why) in [(home + "/Library/Caches/../../.ssh/id_rsa", "dot-dot path into .ssh"), (home + "/proj/.env", ".env file"),
                     (home + "/keys/server.pem", "private key file"), (home + "/.sapu-signing/p12.pass", "Sapu2's own signing folder"), (home + "/Library/Keychains/login.keychain-db", "keychain"),
                     ("/opt/homebrew/var/log/../../bin/brew", "dot-dot out of an allowed root")] {
        check(SafetyGuard.refusal(for: finding(p, .devCaches), allowActiveProjects: true) != nil, "guard refuses \(why)")
    }

    // Every rule says what removing it costs, and every rule has an explanation.
    var unexplained: [String] = [], noRebuild: [String] = []
    for rule in RuleBook.all where rule.action != .none {
        // "dir/*" rules list each child as its own item, so test a child.
        let first = rule.paths.first ?? ""
        let p = (first.hasSuffix("/*") ? String(first.dropLast(2)) + "/child" : first).expandingTilde
        if Explainer.explain(finding(p, rule.category)) == nil && Explainer.explain(Finding(path: p, title: rule.title, category: rule.category, safety: rule.safety, reason: "", usedFor: "", action: rule.action, layer: .quick)) == nil { unexplained.append(rule.id) }
        if (rule.rebuild ?? "").isEmpty { noRebuild.append(rule.id) }
    }
    for id in unexplained.prefix(20) { print("    no explanation: \(id)") }
    for id in noRebuild.prefix(20) { print("    no rebuild text: \(id)") }
    check(unexplained.isEmpty, "every cleanup rule has an explanation (\(unexplained.count) without)")
    check(noRebuild.isEmpty, "every cleanup rule says how it comes back (\(noRebuild.count) without)")

    // Release rule, replayed from this Mac's recording: everything the reference finds, nothing unreviewed, no path for two apps.
    if let fx = loadParity() {
        let problems = fx.problems(found: Uninstaller.leftoversForAll(fx.installedApps, fs: fx.replay()))
        for p in problems.prefix(20) { print("    \(p)") }
        check(problems.isEmpty, "uninstall parity: \(fx.apps.count) apps, all of the reference's \(fx.reference.values.reduce(0) { $0 + $1.count }) paths covered, \(fx.reviewed.values.reduce(0) { $0 + $1.count }) claims reviewed, none shared")
    } else {
        check(false, "uninstall parity: \(parityURL.path) is missing (run scripts/release-check.sh)")
    }
    let testedURL = parityURL.deletingLastPathComponent().appendingPathComponent("tested-apps-fixture.json")
    if let d = try? Data(contentsOf: testedURL), let tf = try? JSONDecoder().decode(TestedFixture.self, from: d) {
        let problems = tf.problems(found: tf.found())
        for p in problems.prefix(20) { print("    \(p)") }
        check(problems.isEmpty, "reference tested apps: \(tf.apps.count) installed side by side, all \(tf.reference.values.reduce(0) { $0 + $1.count }) of its paths covered, none shared")
    } else {
        check(false, "reference tested apps: \(testedURL.path) is missing")
    }

    // The reference tool's hand-tested app guides: every path they say goes with the app, all apps side by side.
    let guidesURL = parityURL.deletingLastPathComponent().appendingPathComponent("reference-guides-fixture.json")
    if let d = try? Data(contentsOf: guidesURL), let gf = try? JSONDecoder().decode(TestedFixture.self, from: d) {
        let problems = gf.problems(found: gf.found())
        for p in problems.prefix(20) { print("    \(p)") }
        check(problems.isEmpty, "reference guides: \(gf.apps.count) apps side by side, all \(gf.reference.values.reduce(0) { $0 + $1.count }) removable paths found, none shared")
    } else {
        check(false, "reference guides: \(guidesURL.path) is missing")
    }

    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    return failures == 0 ? 0 : 1
}

/// Tests/parity-fixture.json in the source tree this binary was built from.
let parityURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/parity-fixture.json")

func loadParity() -> ParityFixture? {
    guard let d = try? Data(contentsOf: parityURL) else { return nil }
    do { return try JSONDecoder().decode(ParityFixture.self, from: d) } catch { err("parity fixture: \(error)"); return nil }
}

func saveParity(_ fx: ParityFixture) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try? FileManager.default.createDirectory(at: parityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? enc.encode(fx).write(to: parityURL, options: .atomic)
}

/// The reference tool's per-app output from scripts/release-check.sh: "### name|id|path" then one path per line.
func readReference(_ file: String) -> [String: [String]] {
    var out: [String: [String]] = [:], cur: String?
    for line in ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) {
        if line.hasPrefix("### ") { cur = String(line.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false)[0]); out[cur!] = []; continue }
        guard let c = cur, !line.isEmpty, !line.hasPrefix("PROTECTED ") else { continue }
        out[c, default: []].append(ParityFixture.tilde(line))
    }
    return out
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
    if let s = Store.load() { report(s) } else { err("No saved scan. Run: sapu2-cli scan") }
case "clean":
    guard let snap = Store.load() else { err("No saved scan. Run: sapu2-cli scan"); exit(1) }
    let binName = args.firstIndex(of: "--bin").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "sweep"
    guard let bin = SweepPlan.Bin(rawValue: binName), bin != .stays else { err("--bin takes sweep, choice or yours."); exit(2) }
    let allowActive = args.contains("--allow-active")
    let plan = SweepPlan.build(from: snap, allowActiveProjects: allowActive)
    let chosen = plan.items.filter { $0.bin == bin && $0.refusal == nil }
    let skipped = plan.items.filter { $0.bin == bin && $0.refusal != nil }
    let apply = args.contains("--yes")
    var receipt: CleanReceipt?
    if apply {
        let byPath = Dictionary(snap.findings.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        receipt = Cleaner.clean(chosen.compactMap { byPath[$0.path] }, allowActiveProjects: allowActive)
    }
    let total = chosen.reduce(Int64(0)) { $0 + $1.bytes }
    if args.contains("--json") {
        struct Out: Encodable {
            var mode: String, bin: String, totalBytes: Int64
            var items: [SweepPlan.Entry], skipped: [SweepPlan.Entry]
            var cleanedBytes: Int64?, failed: Int?
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let out = Out(mode: apply ? "clean" : "dry-run", bin: bin.rawValue, totalBytes: total, items: chosen, skipped: skipped,
                      cleanedBytes: receipt?.cleanedBytes, failed: receipt.map { r in r.items.filter { !$0.ok }.count })
        print(String(data: try enc.encode(out), encoding: .utf8)!)
    } else {
        print("\(apply ? "Sweep" : "Dry run"): \(chosen.count) items in the \(bin.rawValue) bin, \(Format.bytes(total))")
        for e in chosen.prefix(40) {
            print("  \(Format.bytes(e.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(e.group.padding(toLength: 16, withPad: " ", startingAt: 0)) \(e.title)")
        }
        if chosen.count > 40 { print("  … and \(chosen.count - 40) more (use --json for the full list)") }
        for e in skipped.prefix(10) { print("  skipped \(e.title): \(e.refusal ?? "")") }
        if let r = receipt {
            let failed = r.items.filter { !$0.ok }.count
            print("Cleaned \(Format.bytes(r.cleanedBytes)); \(failed) item\(failed == 1 ? "" : "s") skipped or failed. Receipt saved; undo from the app's History.")
        } else {
            print("Nothing was changed. Add --yes to move these to the Trash.")
        }
    }
    exit(receipt.map { r in r.items.contains { !$0.ok } ? 3 : 0 } ?? 0)
case "log":
    // sapu2-cli log [--path|--clear]: the local error log. Nothing is sent anywhere; attach it to an issue if you want to.
    if args.contains("--path") { print(ErrorLog.url.path) }
    else if args.contains("--clear") { ErrorLog.clear(); print("Cleared.") }
    else { let t = ErrorLog.read(); print(t.isEmpty ? "No errors recorded." : t, terminator: t.isEmpty ? "\n" : "") }
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
    // sapu2-cli bench <path>…  compare the getattrlistbulk sizer with the fts reference walker.
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
    // sapu2-cli apps [name…|--all] [--no-size]  list installed apps, or show the uninstall plan for the named ones (read-only).
    let all = Uninstaller.installedApps()
    let wanted = args.dropFirst().filter { !$0.hasPrefix("--") }.map { $0.lowercased() }
    let running = SystemProbe.runningProcessNames()
    if wanted.isEmpty && !args.contains("--all") {
        for a in all { print("\(a.name)\t\(a.bundleID ?? "-")\t\(a.caskToken.map { "brew:\($0)" } ?? (a.fromAppStore ? "App Store" : ""))\t\(a.path)") }
    }
    for a in all where wanted.contains(a.name.lowercased()) || wanted.contains(a.bundleID?.lowercased() ?? "") || args.contains("--all") {
        let plan = Uninstaller.plan(for: a, running: running, apps: all, sized: !args.contains("--no-size"))
        print("\(a.name) (\(a.bundleID ?? "no id"))  total \(Format.bytes(plan.totalBytes)), selected \(Format.bytes(plan.selectedBytes))\(plan.blocked.map { "  BLOCKED: \($0)" } ?? "")")
        for i in plan.items { print("  [\(i.selected ? "x" : " ")] \(i.kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(Format.bytes(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.path.tildePath)\(i.locked != nil ? "  (locked: sign-ins or keys)" : i.holdBack ? "  (kept)" : "")") }
    }
case "secrets":
    // sapu2-cli secrets <project…>   offline leak checks: committed .env and keys, tokens in code and remotes
    for p in args.dropFirst() {
        let path = (p as NSString).standardizingPath
        for i in ProjectSecurity.check(projectPath: path, name: path.lastComponent) {
            print("[\(i.level.rawValue)] \(path.lastComponent): \(i.title)\n    \(i.detail)\n    fix: \(i.fix)")
        }
    }
case "devprocs":
    // sapu2-cli devprocs [hours]   forgotten developer processes (read-only; never stops anything)
    let hours = args.dropFirst().first.flatMap(Double.init) ?? 12
    let found = DevProcesses.find(minAge: hours * 3600)
    if found.isEmpty { print("No forgotten developer processes (\(Int(hours))+ hours).") }
    for p in found { print("\(p.pid)  \(Format.bytes(p.memory).padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.name): \(p.reason)\n      \(p.command.prefix(140))") }
case "update-check":
    // sapu2-cli update-check [--download]   latest GitHub release; --download fetches and verifies the DMG
    do {
        let r = try await Updater.latest()
        print("latest: \(r.version)  dmg: \(r.dmg.lastPathComponent)  checksum: \(r.checksum != nil ? "yes" : "no")")
        if args.contains("--download") { print("downloaded and verified: \(try await Updater.download(r).path)") }
    } catch { print("error: \(error.localizedDescription)") }
case "external":
    // sapu2-cli external [--clean]   Mac bookkeeping files on external drives (--clean: .DS_Store to the drive's Trash, ._ merged by dot_clean)
    let drives = ExternalDrives.drives()
    if drives.isEmpty { print("No writable external drive.") }
    for d in drives {
        let j = ExternalDrives.scan(d)
        print("\(d.name) (\(d.format)): \(j.dsStore.count) .DS_Store, \(j.appleDouble.count) ._ files, \(Format.bytes(j.bytes))")
        if args.contains("--clean"), j.count > 0 { print("  " + ExternalDrives.clean(d, j).message) }
    }
case "startup":
    // sapu2-cli startup   startup items and their state (read-only)
    for i in Startup.list() {
        let st = i.programMissing ? "LEFTOVER" : i.scope == .system ? "system" : i.disabled ? "off" : i.loaded ? "on, running" : "on, on demand"
        print("[\(i.scope.rawValue)] \(st.padding(toLength: 15, withPad: " ", startingAt: 0)) \(i.label)\(i.app.map { "  (\($0))" } ?? "")")
    }
case "du":
    // sapu2-cli du [path] [--top n]   a folder's children, biggest first, and what Sapu2 can clean in each (read-only)
    let dir = (args.dropFirst().first { !$0.hasPrefix("--") }.map { ($0 as NSString).standardizingPath.expandingTilde }) ?? NSHomeDirectory()
    let top = args.firstIndex(of: "--top").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 30
    let entries = DiskExplorer.entries(in: dir)
    let sizes = Locked([Int64](repeating: 0, count: entries.count))
    DispatchQueue.concurrentPerform(iterations: entries.count) { i in
        let b = DiskSizer.size(entries[i].path).bytes
        sizes.mutate { $0[i] = b }
    }
    let findings = Store.load()?.findings ?? []
    let ranked = entries.indices.sorted { sizes.value[$0] > sizes.value[$1] }
    print("\(dir.tildePath)  \(Format.bytes(sizes.value.reduce(0, +))) in \(entries.count) items")
    for i in ranked.prefix(top) {
        let e = entries[i], c = DiskExplorer.cleanable(under: e.path, in: findings)
        let mark = e.sealed != nil ? "  (not listed: private)" : e.isLink ? "  (link, not followed)" : c > 0 ? "  · \(Format.bytes(c)) cleanable" : ""
        print("  \(Format.bytes(sizes.value[i]).padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.name)\(e.isFolder ? "/" : "")\(mark)")
    }
case "creds":
    // sapu2-cli creds <path…>   what sign-ins or keys Sapu2 sees inside each path (read-only)
    for p in args.dropFirst() { print("\(Credentials.find(in: p, limit: 3).joined(separator: ", "))\t\(p)") }
case "tested-record":
    // sapu2-cli tested-record <export dir> <reference.txt> [--version v]   save the tested-apps comparison for selftest
    guard args.count >= 3, let d = FileManager.default.contents(atPath: args[1] + "/zap.json"),
          let raw = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { err("usage: sapu2-cli tested-record <dir> <reference.txt>"); exit(2) }
    // Each app gets the bundle ID the reference was given (the "### name|id|path" lines), so both tools judge the same app.
    var referenceIDs: [String: String] = [:]
    for line in ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "").split(separator: "\n") where line.hasPrefix("### ") {
        let f = line.dropFirst(4).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if f.count > 1 { referenceIDs[f[0]] = f[1] }
    }
    let apps = raw.map { r -> TestedFixture.App in
        let name = r["name"] as? String ?? ""
        return TestedFixture.App(name: name, id: referenceIDs[name] ?? r["id"] as? String ?? "", zap: r["zap"] as? [String] ?? [])
    }
    let version = args.firstIndex(of: "--version").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "?"
    let url = parityURL.deletingLastPathComponent().appendingPathComponent("tested-apps-fixture.json")
    let old = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TestedFixture.self, from: $0) }
    let tf = TestedFixture(referenceVersion: version, apps: apps, reference: readReference(args[2]), referenceMistakes: old?.referenceMistakes ?? [:])
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try? enc.encode(tf).write(to: url, options: .atomic)
    let problems = tf.problems(found: tf.found())
    for p in problems { print("✗ \(p)") }
    print(problems.isEmpty ? "Tested apps check passed: \(apps.count) apps." : "Tested apps check failed: \(problems.count) problem(s).")
    exit(problems.isEmpty ? 0 : 1)
case "parity":
    // sapu2-cli parity record <reference.txt> [--version v]   re-record this Mac (keeps the hand review), then check
    // sapu2-cli parity check                             check the saved recording
    // sapu2-cli parity todo                              print what still needs a decision, as JSON
    // sapu2-cli parity normalize                         rewrite the recording in its standard layout after a hand edit
    let sub = args.dropFirst().first ?? "check"
    var fx = loadParity()
    if sub == "record", args.count > 2 {
        // Never record over a hand review that failed to load.
        if fx == nil, FileManager.default.fileExists(atPath: parityURL.path) { err("Can't read \(parityURL.path); not overwriting its review."); exit(2) }
        let apps = Uninstaller.installedApps()
        let (disk, _) = ParityFixture.record(apps: apps)
        let version = args.firstIndex(of: "--version").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "?"
        let df = ISO8601DateFormatter(); df.formatOptions = [.withFullDate]
        fx = ParityFixture(made: df.string(from: Date()), referenceVersion: version,
                           apps: apps.map { .init(name: $0.name, id: $0.bundleID, path: $0.path) }, disk: disk,
                           reference: readReference(args[2]), referenceMistakes: fx?.referenceMistakes ?? [:], reviewed: fx?.reviewed ?? [:])
        saveParity(fx!)
    }
    // sapu2-cli parity record … --forget <word>   and   sapu2-cli parity forget <word>
    // leave the reference tool's own app and files out of the recording.
    let forgets = args.indices.filter { args[$0] == "--forget" || (sub == "forget" && $0 == 1) }.compactMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    if !forgets.isEmpty, fx != nil {
        for w in forgets { fx!.forget(w) }
        saveParity(fx!)
    }
    guard let fx else { err("No recording yet. Run scripts/release-check.sh"); exit(2) }
    // After a hand edit of the review, rewrite the file in the encoder's own layout so its diff stays small.
    if sub == "normalize" { saveParity(fx); exit(0) }
    let found = Uninstaller.leftoversForAll(fx.installedApps, fs: fx.replay())
    if sub == "todo" {
        var todo: [String: [String: [String]]] = [:]
        for a in fx.apps {
            let mine = (found[a.name] ?? []).map(ParityFixture.tilde)
            let unreviewed = mine.filter { fx.reviewed[a.name]?[$0] == nil }
            let missed = (fx.reference[a.name] ?? []).filter { p in fx.referenceMistakes[a.name]?[p] == nil &&
                !mine.contains { p.lowercased() == $0.lowercased() || p.lowercased().hasPrefix($0.lowercased() + "/") } }
            if !unreviewed.isEmpty || !missed.isEmpty { todo[a.name] = ["unreviewed": unreviewed, "referenceOnly": missed] }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try! enc.encode(todo), encoding: .utf8)!)
        exit(0)
    }
    let problems = fx.problems(found: found)
    for p in problems { print("✗ \(p)") }
    print(problems.isEmpty ? "Release check passed: \(fx.apps.count) apps, reference \(fx.referenceVersion), recorded \(fx.made)." : "Release check failed: \(problems.count) problem(s).")
    exit(problems.isEmpty ? 0 : 1)
case "coverage":
    // sapu2-cli coverage <cask.json> <app-names.txt>
    // For each listed app Homebrew knows, rebuild its documented leftovers ("zap" list) as a simulated
    // file system and check how many of them the uninstaller finds by its own rules.
    let exportValue = args.firstIndex(of: "--export").map { $0 + 1 }
    let rest = args.indices.dropFirst().filter { !args[$0].hasPrefix("--") && $0 != exportValue }.map { args[$0].expandingTilde }
    guard rest.count == 2 || (rest.count == 1 && args.contains("--real")), let data = FileManager.default.contents(atPath: rest[0]),
          let casks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let names = rest.count == 2 ? try? String(contentsOfFile: rest[1], encoding: .utf8) : "" else { print("usage: sapu2-cli coverage <cask.json> <names.txt>"); exit(2) }
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
    if args.contains("--real") {
        // Installed apps only: documented leftovers that exist on this Mac, against what Sapu2 finds on disk.
        var apps = 0, total = 0, hit = 0, bytesAll: Int64 = 0, bytesHit: Int64 = 0
        let installed = Uninstaller.installedApps()
        for app in installed {
            let key = app.path.lastComponent.replacingOccurrences(of: ".app", with: "").lowercased()
            guard let cask = byApp[key] ?? (app.caskToken.flatMap { byName[$0.lowercased()] }) else { continue }
            let existing = Set(cask.zap.filter { $0.hasPrefix("~/") }.flatMap { ScanEngine.glob($0.expandingTilde) })
                .filter { $0.hasPrefix(home + "/") && !Uninstaller.isNamesake($0) }
            guard !existing.isEmpty else { continue }
            apps += 1
            let found = Uninstaller.leftovers(for: app, apps: installed).map { $0.lowercased() }
            for z in existing.sorted() {
                let size = DiskSizer.size(z).bytes, l = z.lowercased()
                total += 1; bytesAll += size
                if found.contains(where: { l == $0 || l.hasPrefix($0 + "/") }) { hit += 1; bytesHit += size; continue }
                if args.contains("--misses") { print("MISS\t\(app.name)\t\(app.bundleID ?? "-")\t\(Format.bytes(size))\t\(z.tildePath)") }
            }
        }
        print("Installed apps with documented leftovers on this Mac: \(apps).")
        print("Leftovers present: \(total) (\(Format.bytes(bytesAll))). Found by Sapu2: \(hit) (\(total > 0 ? 100 * hit / total : 0)%), \(Format.bytes(bytesHit)) (\(bytesAll > 0 ? Int(100 * bytesHit / bytesAll) : 0)% of the space).")
        exit(0)
    }
    // --export <dir>: also write the leftovers as a fake home folder (<dir>/home), the apps (<dir>/apps.tsv) and what
    // Sapu2 finds (<dir>/sapu.txt), so another tool can be run on exactly the same files.
    let exportDir = args.firstIndex(of: "--export").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1].expandingTilde : nil }
    var exportApps = "", exportList: [(InstalledApp, [String])] = []
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
                if leaf.range(of: idPattern, options: .regularExpression) != nil, !leaf.split(separator: ".").contains("x") { counts[leaf, default: 0] += 1 }
            }
            id = counts.max { $0.value == $1.value ? $0.key.count > $1.key.count : $0.value < $1.value }?.key
        }
        let app = InstalledApp(path: "/Applications/\(cask.app).app", name: cask.app, bundleID: id, version: nil, executable: nil, fromAppStore: false, caskToken: cask.token)
        let foundCased = Uninstaller.leftovers(for: app, fs: .simulated(zap))
        let found = foundCased.map { $0.lowercased() }
        if let dir = exportDir {
            let fakeHome = dir + "/home"
            for z in zap where z.hasPrefix(home + "/") {
                let target = fakeHome + z.dropFirst(home.count)
                let isFile = [".plist", ".binarycookies", ".sfl2", ".sfl3", ".sfl4", ".json", ".db", ".log", ".txt", ".sqlite"].contains { z.lowercased().hasSuffix($0) }
                if isFile {
                    try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: target) { FileManager.default.createFile(atPath: target, contents: Data()) }
                } else {
                    try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                }
            }
            exportApps += "\(cask.app)\t\(id ?? "")\t\t/Applications/\(cask.app).app\n"
            exportList.append((app, zap))
        }
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
    if let dir = exportDir {
        // Every app installed side by side on one Mac: each sees all the others' files and IDs.
        let merged = Uninstaller.FileView.simulated(exportList.flatMap(\.1))
        let ids = exportList.map { $0.0.bundleID?.lowercased() ?? "" }
        let allIDs = Set(ids.filter { !$0.isEmpty })
        var out = ""
        for (i, (app, _)) in exportList.enumerated() {
            let names = Set(exportList.map { $0.0.name.lowercased() }).subtracting([app.name.lowercased()])
            let found = Uninstaller.leftovers(for: app, fs: merged, otherIDs: allIDs.subtracting([ids[i]]), otherNames: names)
            out += "### \(app.name)\n" + found.map { $0.tildePath + "\n" }.joined()
        }
        try? exportApps.write(toFile: dir + "/apps.tsv", atomically: true, encoding: .utf8)
        let zapJSON = exportList.map { ["name": $0.0.name, "id": $0.0.bundleID ?? "", "zap": $0.1.map(\.tildePath)] as [String: Any] }
        try? JSONSerialization.data(withJSONObject: zapJSON, options: [.sortedKeys]).write(to: URL(fileURLWithPath: dir + "/zap.json"))
        try? out.write(toFile: dir + "/sapu.txt", atomically: true, encoding: .utf8)
    }
    print("Apps on the list: \(tested). Known to Homebrew with documented leftovers: \(matched).")
    print("Documented leftover paths in your home folder: \(totalPaths). Found by Sapu2's rules: \(foundPaths) (\(totalPaths > 0 ? 100 * foundPaths / totalPaths : 0)%).")
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
case "updates":
    let ups = await AppUpdates.check(Uninstaller.installedApps())
    if ups.isEmpty { print("Every app is up to date (Homebrew, app feeds and App Store checked).") }
    for u in ups { print("\(u.app.name)  \(u.installed) → \(u.latest)  [\(u.sourceName)]\n    \(u.howTo)") }
case "trash":
    let t = TrashBin.summary()
    print("Trash: \(t.items) item(s), \(Format.bytes(t.bytes)); \(t.fromSapu) put there by Sapu2 (Put back still works for those). Emptying is done in the app, after you confirm.")
case "explain":
    // sapu2-cli explain <path>: what it is, what it means for your projects, and the right way to free it.
    guard args.count > 1 else { print("usage: sapu2-cli explain <path>"); exit(2) }
    let snap = Store.load() ?? Snapshot()
    let path = (args[1] as NSString).expandingTildeInPath
    let f = snap.findings.first { $0.path == path }
        ?? Finding(path: path, title: path.lastComponent, category: .system, safety: .yours, bytes: DiskSizer.size(path).bytes, reason: "", usedFor: "", action: .none, layer: .quick)
    print("\(f.title) · \(Format.bytes(f.bytes)) · \(f.safety.label)")
    if let e = Explainer.explain(f) {
        print("\nWhat it is: \(e.plain)\nIf you remove it (\(e.impact.label)): \(e.impactText)\nBest way: \(e.bestWay)")
        for c in e.commands { print("  $ \(c)") }
        print("Comes back: \(e.comesBack)")
    } else { print("\nNo explanation rule matches this path yet.") }
    print("\nOn your Mac:")
    for x in YourContext.facts(for: f, projects: snap.projects, running: SystemProbe.runningProcessNames()) { print("  • \(x.text)") }
case "maintenance", "optimize":
    let tasks = Maintenance.check()
    if args.count > 1, var t = tasks.first(where: { $0.id == args[1] }) {
        // Extra arguments narrow the fix to those paths only.
        if args.count > 2 { t.paths = t.paths.filter { args.dropFirst(2).contains($0) } }
        let r = Maintenance.run(t)
        print("\(r.ok ? "✓" : "✗") \(t.title): \(r.message)")
        exit(r.ok ? 0 : 1)
    }
    for g in MaintenanceTask.Group.allCases {
        let mine = tasks.filter { $0.group == g }
        guard !mine.isEmpty else { continue }
        print("\n\(g.rawValue)")
        for t in mine {
            let icon = ["ok": "✓", "attention": "!", "info": "·"][t.status.rawValue]!
            print("\(icon) \(t.title)  [\(t.id)]\n    \(t.detail)")
            if case .terminal(let c) = t.fix { print("    $ \(c)") }
            if case .admin(let c) = t.fix { print("    # (asks for your password) \(c)") }
        }
    }
default:
    print("usage: sapu2-cli scan [quick|projects|full|all] | report | clean [--bin sweep|choice|yours] [--json] [--yes] | log [--path|--clear] | versions [--offline] | apps [name…] | du [path] [--top n] | startup | devprocs [hours] | external [--clean] | optimize [task-id] | updates | trash | selftest")
}
