import Foundation

/// What AI coding agents, IDEs and chat apps leave behind, beyond plain caches: finished agent jobs, agent
/// worktrees, settings of IDE versions you upgraded from, old runtime releases. Plus large data that only its
/// own app should remove (VM disks, model libraries), listed so the space is explained, never cleaned.
/// Locations checked against what a reference cleaner cleans or reports; none of its code is used.
public enum DevExtras {
    public struct Candidate: Sendable, Hashable {
        public var path: String
        public var title: String
        public var category: Category
        public var safety: Safety
        public var reason: String
        public var usedFor: String
        public var owner: String
        public var rebuild: String
        public var action: CleanAction
        public var lockedReason: String?
        /// Processes that lock the item while they run.
        public var whileRunning: [String] = []
    }

    static let day: TimeInterval = 86_400

    /// Every candidate under `home`. `projects` are project roots from the last scan (for `.claude/worktrees`).
    /// `system` prefixes the few read-only locations outside the home folder (tests point it at a fake root).
    public static func candidates(home: String = NSHomeDirectory(), projects: [String] = [], now: Date = Date(),
                                  system: String = "", simRuntimes: () -> Data? = DevExtras.simctlRuntimes,
                                  gitClean: (String) -> Bool? = DevExtras.gitClean) -> [Candidate] {
        claudeJobs(home: home, now: now)
            + agentWorktrees(home: home, projects: projects, now: now, gitClean: gitClean)
            + jetbrainsOldVersions(home: home)
            + codexOldReleases(home: home)
            + chatAppCaches(home: home)
            + pnpmStores(home: home)
            + simulatorRuntimes(json: simRuntimes(), system: system)
            + instrumentsTraces(home: home, projects: projects, now: now)
            + manageSeparately(home: home, system: system)
    }

    // MARK: Claude Code jobs

    /// Background jobs keep scratch files (renders, downloads, scripts) in `~/.claude/jobs/<id>/tmp`. Once a job
    /// has finished and sat idle three days, the files are leftovers; the job's chat stays in Claude Code.
    static func claudeJobs(home: String, now: Date) -> [Candidate] {
        let root = home + "/.claude/jobs"
        let pins = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/pins.json")))) as? [String] ?? []
        var out: [Candidate] = []
        for dir in DiskSizer.children(root, includeHidden: false) where DiskSizer.isDirectory(dir) && !DiskSizer.isSymlink(dir) {
            let tmp = dir + "/tmp"
            guard DiskSizer.isDirectory(tmp), !DiskSizer.isSymlink(tmp), !pins.contains(dir.lastComponent),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/state.json")),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let status = (state["state"] as? String ?? "").lowercased()
            let ended = [state["lastTerminalAt"], state["updatedAt"]].compactMap { $0 as? String }.compactMap(parseDate).max()
            guard ["done", "failed", "error", "cancelled", "canceled", "stopped", "killed"].contains(status),
                  let ended, now.timeIntervalSince(ended) >= 3 * day else { continue }
            let name = (state["name"] as? String).map { "“\($0)”" } ?? dir.lastComponent
            out.append(Candidate(path: tmp, title: "Claude Code job files: \(name)", category: .devCaches, safety: .check,
                                 reason: "Scratch files a background Claude Code job made while it ran (renders, downloads, scripts). The job finished \(Format.age(ended, now: now)).",
                                 usedFor: "Nothing now; the job is \(status).", owner: "Claude Code",
                                 rebuild: "Not needed. The job's conversation stays in Claude Code; look inside first if the job produced files you wanted.",
                                 action: .trash))
        }
        return out
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Agent worktrees

    /// Full checkouts coding agents create: the Codex app under `~/.codex/worktrees/<id>/<repo>`, Claude Code
    /// under `<project>/.claude/worktrees/<name>`. Never preselected: a worktree may hold the agent's work.
    /// Ones with uncommitted changes, or touched in the last three days, are locked.
    static func agentWorktrees(home: String, projects: [String], now: Date, gitClean: (String) -> Bool?) -> [Candidate] {
        var trees: [(path: String, agent: String)] = []
        for id in DiskSizer.children(home + "/.codex/worktrees", includeHidden: false) where DiskSizer.isDirectory(id) && !DiskSizer.isSymlink(id) {
            if DiskSizer.exists(id + "/.git") { trees.append((id, "Codex")); continue }
            for repo in DiskSizer.children(id, includeHidden: false) where DiskSizer.exists(repo + "/.git") && !DiskSizer.isSymlink(repo) {
                trees.append((repo, "Codex"))
            }
        }
        for p in Set(projects) {
            for t in DiskSizer.children(p + "/.claude/worktrees", includeHidden: false) where DiskSizer.exists(t + "/.git") && !DiskSizer.isSymlink(t) {
                trees.append((t, "Claude Code"))
            }
        }
        return trees.map { t in
            let touched = newestTopLevel(t.path)
            let recent = touched.map { now.timeIntervalSince($0) < 3 * day } ?? false
            let clean = gitClean(t.path)
            let lock = clean == false ? "Has uncommitted changes. Commit or discard them in the worktree first."
                : clean == nil ? "Couldn't read its git status." : recent ? "Used in the last three days." : nil
            return Candidate(path: t.path, title: "\(t.agent) worktree: \(t.path.lastComponent)", category: .projects, safety: .yours,
                             reason: "A full checkout \(t.agent) made to work on a branch in parallel. It stays after the task ends.",
                             usedFor: "\(t.agent)'s work on a separate branch.", owner: t.agent,
                             rebuild: "Commits are kept: the branch lives in the main repository. Run `git worktree prune` there afterwards.",
                             action: .trash, lockedReason: lock)
        }
    }

    /// Newest modification among a folder's direct children (cheap; a worktree's activity shows at the top).
    static func newestTopLevel(_ path: String) -> Date? {
        ([path] + DiskSizer.children(path, includeHidden: true)).compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
    }

    /// true when `git status` shows nothing to commit, nil when git can't tell.
    public static func gitClean(_ path: String) -> Bool? {
        let r = Shell.run(["git", "-C", path, "status", "--porcelain", "--untracked-files=normal"], timeout: 10)
        guard r.status == 0, !r.timedOut else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: JetBrains

    /// Per-version settings folders (`GoLand2024.3` when `GoLand2025.2` exists). The newer version imported them.
    static func jetbrainsOldVersions(home: String) -> [Candidate] {
        let base = home + "/Library/Application Support/JetBrains"
        var byProduct: [String: [(path: String, key: Int, version: String)]] = [:]
        for dir in DiskSizer.children(base, includeHidden: false) where DiskSizer.isDirectory(dir) && !DiskSizer.isSymlink(dir) {
            guard let (product, version, key) = jetbrainsVersion(dir.lastComponent) else { continue }
            byProduct[product, default: []].append((dir, key, version))
        }
        var out: [Candidate] = []
        for (product, dirs) in byProduct {
            guard let newest = dirs.max(by: { $0.key < $1.key }) else { continue }
            for d in dirs where d.key < newest.key {
                out.append(Candidate(path: d.path, title: "\(product) \(d.version) settings", category: .devCaches, safety: .check,
                                     reason: "Settings, plugins and local history of \(product) \(d.version). You now use \(newest.version), which imported them when it first started.",
                                     usedFor: "Nothing, unless you go back to \(product) \(d.version).", owner: "JetBrains",
                                     rebuild: "Not needed. \(product) \(newest.version) keeps its own copy.", action: .trash,
                                     whileRunning: [product.lowercased(), "idea"]))
            }
        }
        return out
    }

    /// "GoLand2025.1" → ("GoLand", "2025.1", 202501). Unversioned folders and Toolbox return nil.
    static func jetbrainsVersion(_ name: String) -> (String, String, Int)? {
        guard let r = name.range(of: #"[0-9]{4}\.[0-9]+$"#, options: .regularExpression), r.lowerBound > name.startIndex else { return nil }
        let product = String(name[..<r.lowerBound]), version = String(name[r])
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2, product.first?.isLetter == true else { return nil }
        return (product, version, parts[0] * 100 + parts[1])
    }

    // MARK: Codex

    /// The Codex app's background server keeps every release it ever installed; only the newest is used.
    static func codexOldReleases(home: String) -> [Candidate] {
        let dir = home + "/.codex/packages/app-server-daemon/releases"
        guard !DiskSizer.exists(home + "/.codex/packages/app-server-daemon/install.lock.d") else { return [] }
        let releases = DiskSizer.children(dir, includeHidden: false).filter { DiskSizer.isDirectory($0) && !DiskSizer.isSymlink($0) }
        guard releases.count > 1 else { return [] }
        let dated = releases.map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date ?? .distantPast) }
        let newest = dated.max { $0.1 < $1.1 }!.0
        return dated.filter { $0.0 != newest }.map { r in
            Candidate(path: r.0, title: "Codex server release \(r.0.lastComponent)", category: .devCaches, safety: .safe,
                      reason: "An earlier release of the Codex app's background server. Codex runs the newest one, \(newest.lastComponent).",
                      usedFor: "Nothing after the update.", owner: "Codex", rebuild: "Not needed.", action: .trash,
                      whileRunning: ["Codex", "codex"])
        }
    }

    // MARK: Chat apps

    /// WeChat and Feishu/Lark keep a Chromium browser and mini-program runtime inside their sandbox.
    /// Only HTTP and service-worker caches go; IndexedDB, local storage and chats stay.
    static func chatAppCaches(home: String) -> [Candidate] {
        var out: [Candidate] = []
        func add(_ path: String, _ title: String, _ owner: String, _ exe: [String], log: Bool = false) {
            guard DiskSizer.isDirectory(path), !DiskSizer.isSymlink(path) else { return }
            out.append(Candidate(path: path, title: title, category: log ? .logs : .appCaches, safety: .safe,
                                 reason: log ? "Logs \(owner) writes and rarely deletes." : "Web pages, scripts and images \(owner)'s built-in browser and mini programs downloaded.",
                                 usedFor: log ? "Troubleshooting \(owner)." : "Opening links and mini programs faster.", owner: owner,
                                 rebuild: log ? "Not needed." : "\(owner) downloads them again when needed. Chats and sign-ins stay.",
                                 action: .trash, whileRunning: exe))
        }
        let wechat = home + "/Library/Containers/com.tencent.xinWeChat/Data"
        add(wechat + "/Documents/app_data/log", "WeChat logs", "WeChat", ["WeChat"], log: true)
        add(wechat + "/.wxapplet/WMPF", "WeChat mini program cache", "WeChat", ["WeChat"])
        for profile in DiskSizer.children(wechat + "/Documents/app_data/radium/web/profiles", includeHidden: false) where !DiskSizer.isSymlink(profile) {
            add(profile + "/Cache", "WeChat browser cache", "WeChat", ["WeChat"])
            add(profile + "/Service Worker/CacheStorage", "WeChat browser offline cache", "WeChat", ["WeChat"])
        }
        let feishu = home + "/Library/Containers/com.bytedance.macos.feishu/Data"
        add(feishu + "/Library/Caches", "Feishu cache", "Feishu", ["Feishu", "Lark"])
        add(home + "/Library/Caches/LarkShell", "Lark cache", "Lark", ["Lark", "Feishu"])
        for app in ["com.alibaba.DingTalkMac"] {
            add(home + "/Library/Containers/\(app)/Data/Library/Caches", "DingTalk cache", "DingTalk", ["DingTalk"])
        }
        return out
    }

    // MARK: pnpm

    /// pnpm keeps its store in a folder per layout version (`v3` for pnpm 7–9, `v10` for pnpm 10). After an
    /// upgrade the older folder is no longer read, unless a project still pins an older pnpm. The newest
    /// folder is pruned with pnpm itself.
    static func pnpmStores(home: String) -> [Candidate] {
        var out: [Candidate] = []
        for root in ["/Library/pnpm/store", "/.local/share/pnpm/store", "/.pnpm-store"].map({ home + $0 })
        where DiskSizer.isDirectory(root) && !DiskSizer.isSymlink(root) {
            let versions = DiskSizer.children(root, includeHidden: false)
                .compactMap { p -> (String, Int)? in
                    let n = p.lastComponent
                    guard n.hasPrefix("v"), let v = Int(n.dropFirst()), DiskSizer.isDirectory(p), !DiskSizer.isSymlink(p) else { return nil }
                    return (p, v)
                }
                .sorted { $0.1 < $1.1 }
            let current = versions.last
            out.append(Candidate(path: current?.0 ?? root, title: "pnpm store", category: .devCaches, safety: .check,
                                 reason: "Content-addressed store shared by all pnpm projects; projects hard-link into it.",
                                 usedFor: "pnpm installs.", owner: "pnpm",
                                 rebuild: "Prune only removes packages no project references.", action: .command("pnpm store prune")))
            for old in versions.dropLast() {
                out.append(Candidate(path: old.0, title: "Old pnpm store (\(old.0.lastComponent))", category: .devCaches, safety: .check,
                                     reason: "Packages saved by an earlier pnpm. pnpm now keeps them in \(current!.0.lastComponent), so this copy is no longer read.",
                                     usedFor: "Only projects that still pin an older pnpm (packageManager in package.json).", owner: "pnpm",
                                     rebuild: "Those projects download their packages again on the next pnpm install.", action: .trash,
                                     whileRunning: ["pnpm"]))
            }
        }
        return out
    }

    // MARK: Simulator runtimes

    /// `xcrun simctl runtime list -j`, or nil without Xcode (Command Line Tools have no simctl).
    public static func simctlRuntimes() -> Data? {
        let r = Shell.run(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 20)
        guard r.status == 0, r.out.hasPrefix("{") else { return nil }
        return Data(r.out.utf8)
    }

    /// iOS, watchOS, tvOS and visionOS simulator runtimes are disk images of 5–20 GB each, stored outside the
    /// home folder. The newest one per platform stays; older ones are removed with simctl, Apple's own tool.
    /// Without Xcode, leftover images are only shown.
    static func simulatorRuntimes(json: Data?, system: String) -> [Candidate] {
        guard let json, let all = (try? JSONSerialization.jsonObject(with: json)) as? [String: [String: Any]] else {
            let dir = system + "/Library/Developer/CoreSimulator"
            return ["/Images", "/Volumes"].map { dir + $0 }.filter { DiskSizer.isDirectory($0) && !DiskSizer.isSymlink($0) }.map { p in
                Candidate(path: p, title: "Simulator runtimes (\(p.lastComponent.lowercased()))", category: .xcode, safety: .yours,
                          reason: "Disk images of iOS and other simulator systems, stored outside your home folder.",
                          usedFor: "Running apps in the Simulator.", owner: "Xcode",
                          rebuild: "Remove them in Xcode › Settings › Components. Without Xcode installed, Apple's tool to remove them is missing, so Sapu only shows them.",
                          action: .none)
            }
        }
        struct Runtime { var id: String, platform: String, version: [Int], label: String, path: String, deletable: Bool }
        let runtimes: [Runtime] = all.values.compactMap { r in
            guard let id = r["identifier"] as? String, let path = (r["path"] as? String) ?? (r["mountPath"] as? String) else { return nil }
            let version = (r["version"] as? String) ?? ""
            let platform = (r["platformIdentifier"] as? String) ?? (r["runtimeIdentifier"] as? String) ?? ""
            let name = platform.split(separator: ".").last.map { $0.replacingOccurrences(of: "simulator", with: "") } ?? "simulator"
            let label = ["iphone": "iOS", "watch": "watchOS", "appletv": "tvOS", "xr": "visionOS"][name.lowercased()] ?? name
            return Runtime(id: id, platform: platform, version: version.split(separator: ".").compactMap { Int($0) },
                           label: "\(label) \(version)", path: system + path, deletable: (r["deletable"] as? Bool) ?? false)
        }
        var out: [Candidate] = []
        for (_, group) in Dictionary(grouping: runtimes, by: \.platform) {
            let sorted = group.sorted { $0.version.lexicographicallyPrecedes($1.version) }
            let newest = sorted.last!
            for r in sorted.dropLast() where r.deletable {
                out.append(Candidate(path: r.path, title: "Simulator runtime \(r.label)", category: .xcode, safety: .check,
                                     reason: "An older simulator system. \(newest.label) is the newest one installed and stays.",
                                     usedFor: "Testing apps on \(r.label) in the Simulator.", owner: "Xcode",
                                     rebuild: "Download it again in Xcode › Settings › Components if you need to test on it.",
                                     action: .command("xcrun simctl runtime delete \(r.id)"), whileRunning: ["Simulator"]))
            }
        }
        return out.sorted { $0.title < $1.title }
    }

    // MARK: Instruments

    /// Instruments and `xctrace record` save each recording as a `.trace` bundle, often hundreds of MB, wherever
    /// you were working. Looked for in project folders, plus Desktop and Documents when projects already live there
    /// (so the scan asks for no new folder access). Recordings from the last week are locked.
    static func instrumentsTraces(home: String, projects: [String], now: Date) -> [Candidate] {
        var roots = Set(projects)
        for d in ["Desktop", "Documents"] where projects.contains(where: { $0.hasPrefix(home + "/" + d + "/") }) { roots.insert(home + "/" + d) }
        let skip: Set<String> = ["node_modules", ".git", "Library", ".venv", "venv", "build", "DerivedData", "Pods", "target"]
        var found = Set<String>()
        func walk(_ dir: String, _ depth: Int) {
            for c in DiskSizer.children(dir, includeHidden: false) where DiskSizer.isDirectory(c) && !DiskSizer.isSymlink(c) {
                if c.hasSuffix(".trace") { found.insert(c); continue }
                if depth < 3, !skip.contains(c.lastComponent), !c.hasSuffix(".app"), !c.hasSuffix(".xcodeproj") { walk(c, depth + 1) }
            }
        }
        for r in roots where DiskSizer.isDirectory(r) { walk(r, 0) }
        return found.sorted().map { p in
            let date = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
            let recent = date.map { now.timeIntervalSince($0) < 7 * day } ?? true
            return Candidate(path: p, title: "Instruments recording \(p.lastComponent)", category: .xcode, safety: .check,
                             reason: "A performance recording from Instruments or xctrace\(date.map { ", saved \(Format.age($0, now: now))" } ?? "").",
                             usedFor: "Looking back at that profiling session.", owner: "Instruments",
                             rebuild: "Cannot be rebuilt; record again if you need it.", action: .trash,
                             lockedReason: recent ? "Recorded in the last week." : nil, whileRunning: ["Instruments"])
        }
    }

    // MARK: Manage separately

    /// Big data that only its own app can remove correctly (a VM disk, a model library). Explained, never cleaned.
    static func manageSeparately(home: String, system: String) -> [Candidate] {
        let items: [(String, String, Category, String, String, String)] = [
            ("/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", "OrbStack disk", .containers, "OrbStack",
             "One disk holding every OrbStack container, image, volume and Linux machine.",
             "In OrbStack: delete unused containers and images, or run `docker system prune` (keeps volumes)."),
            ("/OrbStack", "OrbStack files", .containers, "OrbStack", "OrbStack's view of your Linux machines and Docker volumes.",
             "Delete machines or volumes from OrbStack itself."),
            ("/Library/Application Support/Claude/vm_bundles", "Claude's virtual machine", .containers, "Claude",
             "The Linux virtual machine the Claude app uses to run code and work with files.",
             "Claude downloads it again when a task needs it. Remove it from Claude's settings, not by hand, while Claude is installed."),
            ("/.lmstudio/models", "LM Studio models", .ml, "LM Studio", "Local language models you downloaded in LM Studio.",
             "Delete models in LM Studio › My Models, so it knows they are gone."),
            ("/.cache/lm-studio/models", "LM Studio models (old location)", .ml, "LM Studio", "Models from an earlier LM Studio version, which kept them here.",
             "Open LM Studio › My Models to see whether it still uses this folder before removing anything."),
            ("/Library/Containers/com.liuliu.draw-things/Data/Documents/Models", "Draw Things models", .ml, "Draw Things",
             "Image models you downloaded in Draw Things.", "Delete models in Draw Things › Model › Manage."),
            ("/Documents/ComfyUI/models", "ComfyUI models", .ml, "ComfyUI", "Checkpoints, LoRAs and other models used by ComfyUI.",
             "Remove models you no longer use from ComfyUI's model manager or this folder."),
        ]
        var out: [Candidate] = items.compactMap { i in
            let p = home + i.0
            guard DiskSizer.isDirectory(p), !DiskSizer.isSymlink(p) else { return nil }
            return Candidate(path: p, title: i.1, category: i.2, safety: .yours, reason: i.4,
                             usedFor: "\(i.3). Manage it there.", owner: i.3, rebuild: i.5, action: .none)
        }
        // Aerial wallpapers and screen savers live outside the home folder and belong to macOS.
        let aerials = system + "/Library/Application Support/com.apple.idleassetsd/Customer"
        if DiskSizer.isDirectory(aerials), !DiskSizer.isSymlink(aerials) {
            out.append(Candidate(path: aerials, title: "Aerial wallpaper videos", category: .system, safety: .yours,
                                 reason: "Videos macOS downloaded for aerial wallpapers and screen savers. They sit outside your home folder and need admin rights to remove.",
                                 usedFor: "macOS. Manage it in System Settings.", owner: "macOS",
                                 rebuild: "Choose a still wallpaper and screen saver in System Settings so macOS stops downloading more; macOS downloads them again if you switch back.",
                                 action: .none))
        }
        return out
    }
}

extension ScanEngine {
    /// Quick-layer jobs for `DevExtras`. A candidate under a running app is locked.
    func devExtraJobs(running: Set<String>, previous: Snapshot?) -> [Job] {
        let projects = previous?.projects.map(\.path) ?? []
        let runningLower = Set(running.map { $0.lowercased() })
        return DevExtras.candidates(projects: projects).map { c in
            Job(path: c.path) { r in
                guard r.bytes >= Self.bloatFloor else { return nil }
                let open = c.whileRunning.first { runningLower.contains($0.lowercased()) }
                return Finding(path: c.path, title: c.title, category: c.category, safety: c.safety, bytes: r.bytes, files: r.files,
                               lastModified: r.newestDate, reason: c.reason, usedFor: c.usedFor, owner: c.owner, rebuild: c.rebuild,
                               action: c.action, lockedReason: c.lockedReason ?? open.map { "\($0) is running. Quit it first." }, layer: .quick)
            }
        }
    }
}
