import AppKit
import Foundation

/// An app installed in /Applications or ~/Applications.
public struct InstalledApp: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var bundleID: String?
    public var version: String?
    public var executable: String?
    public var fromAppStore: Bool
    /// Homebrew cask token when Homebrew installed it.
    public var caskToken: String?

    public init(path: String, name: String, bundleID: String?, version: String? = nil, executable: String? = nil,
                fromAppStore: Bool = false, caskToken: String? = nil) {
        self.path = path; self.name = name; self.bundleID = bundleID; self.version = version
        self.executable = executable; self.fromAppStore = fromAppStore; self.caskToken = caskToken
    }
}

/// One thing an uninstall removes.
public struct UninstallItem: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// The app bundle itself.
        case app
        /// Caches and logs: rebuilt by the app, always safe to remove with it.
        case cache
        /// Settings, saved state, containers, support files: your data for this app.
        case data
        /// A background agent that starts the app or its helper at login.
        case agent
    }
    public var id: String { path }
    public var path: String
    public var kind: Kind
    public var bytes: Int64
    /// Selected unless the user changes it. Personal data is kept unless asked.
    public var selected: Bool
    /// Never preselected even when removing personal data (browser profiles, shared app groups, game libraries).
    public var holdBack: Bool
    public var note: String
}

public struct UninstallPlan: Codable, Sendable, Identifiable {
    public var id: String { app.path }
    public var app: InstalledApp
    public var items: [UninstallItem]
    /// Why the app can't be removed here (system app, security agent, running).
    public var blocked: String?
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var selectedBytes: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.bytes } }
}

/// Finds an app's leftovers by bundle ID and name, the way macOS apps actually store data:
/// bundle-ID folders across ~/Library, name variants ("Maestro Studio", "MaestroStudio", "maestro-studio"),
/// vendor folders ("Avid/Sibelius"), app-group and extension containers, embedded helper IDs and
/// launch agents whose program lives inside the app. Shared roots and namesake command-line tools are never claimed.
public enum Uninstaller {
    static let home = NSHomeDirectory()
    static let lib = home + "/Library"

    // MARK: Inventory

    public static func installedApps() -> [InstalledApp] {
        var bundles: [String] = []
        for root in ["/Applications", home + "/Applications"] {
            for p in DiskSizer.children(root) where !DiskSizer.isSymlink(p) {
                if p.hasSuffix(".app") { bundles.append(p) }
                // Vendor folders such as /Applications/Utilities or /Applications/Adobe Photoshop 2025.
                else if DiskSizer.isDirectory(p) {
                    bundles += DiskSizer.children(p).filter { $0.hasSuffix(".app") && !DiskSizer.isSymlink($0) }
                }
            }
        }
        let casks = caskApps()
        return bundles.compactMap { path in
            let b = Bundle(path: path)
            let info = b?.infoDictionary
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return InstalledApp(path: path, name: name, bundleID: b?.bundleIdentifier,
                                version: info?["CFBundleShortVersionString"] as? String,
                                executable: info?["CFBundleExecutable"] as? String,
                                fromAppStore: DiskSizer.exists(path + "/Contents/_MASReceipt/receipt"),
                                caskToken: casks[(path as NSString).lastPathComponent])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Foo.app" → cask token, from Homebrew's own records of installed casks.
    static func caskApps() -> [String: String] {
        var out: [String: String] = [:]
        for room in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            for token in DiskSizer.children(room) {
                for version in DiskSizer.children(token) {
                    for item in DiskSizer.children(version) where item.hasSuffix(".app") {
                        out[item.lastComponent] = token.lastComponent
                    }
                }
                // Newer Homebrew records artifacts in .metadata; fall back to the token's display name.
                let meta = token + "/.metadata"
                if DiskSizer.isDirectory(meta), let json = try? String(contentsOfFile: newestFile(meta, named: "\(token.lastComponent).json") ?? "", encoding: .utf8) {
                    let re = try? NSRegularExpression(pattern: "\"([^\"/]+\\.app)\"")
                    for m in re?.matches(in: json, range: NSRange(json.startIndex..., in: json)) ?? [] {
                        if let r = Range(m.range(at: 1), in: json) { out[String(json[r])] = token.lastComponent }
                    }
                }
            }
        }
        return out
    }

    static func newestFile(_ dir: String, named: String) -> String? {
        let e = FileManager.default.enumerator(atPath: dir)
        var best: (String, Date)?
        while let rel = e?.nextObject() as? String {
            guard rel.hasSuffix("/" + named) || rel == named, let m = DiskSizer.mtime(dir + "/" + rel) else { continue }
            if best == nil || m > best!.1 { best = (dir + "/" + rel, m) }
        }
        return best?.0
    }

    // MARK: Protection

    /// Apps macOS needs, and security agents that must be removed with their vendor's own uninstaller.
    public static func blockReason(_ app: InstalledApp, running: Set<String>) -> String? {
        let id = app.bundleID ?? ""
        if app.path.hasPrefix("/System/") { return "Part of macOS." }
        if id.hasPrefix("com.apple."), !appleRemovable.contains(where: { id.hasPrefix($0) }) {
            return "Built into macOS. Remove it in System Settings if it can be removed."
        }
        let lower = (id + " " + app.name).lowercased()
        if let vendor = officialUninstaller.first(where: { v in v.matches.contains { lower.contains($0) } }) {
            return "\(vendor.vendor) protects itself. Use \(vendor.vendor)'s own uninstaller or ask your IT team."
        }
        if id == Bundle.main.bundleIdentifier { return "That's Sapu." }
        let names = [app.name, app.executable].compactMap { $0 }
        if names.contains(where: running.contains) { return "\(app.name) is running. Quit it first." }
        return nil
    }

    /// Apple apps you installed yourself (Xcode, iWork, GarageBand…).
    static let appleRemovable = ["com.apple.dt.", "com.apple.FinalCut", "com.apple.Motion", "com.apple.Compressor", "com.apple.logic",
                                 "com.apple.garageband", "com.apple.iMovie", "com.apple.iWork.", "com.apple.MainStage",
                                 "com.apple.Playgrounds", "com.apple.server."]

    static let officialUninstaller: [(vendor: String, matches: [String])] = [
        ("ESET", ["com.eset.", "eset endpoint", "eset management"]), ("Jamf", ["com.jamf", "jamf connect", "jamf protect", "self service"]),
        ("CrowdStrike", ["com.crowdstrike.", "falcon"]), ("SentinelOne", ["com.sentinelone.", "com.sentinel-labs.", "sentinelone"]),
        ("GlobalProtect", ["com.paloaltonetworks.", "globalprotect"]), ("Cisco", ["com.cisco.anyconnect", "com.cisco.secureclient", "cisco secure client"]),
        ("Microsoft Defender", ["com.microsoft.wdav", "microsoft defender"]), ("Sophos", ["com.sophos."]),
    ]

    /// Folders that hold more than one app or tool. Never claimed by an uninstall.
    static let sharedRoots: Set<String> = [
        home + "/.cache", home + "/.config", home + "/.local", home + "/.local/share", home + "/.local/bin", home + "/.local/state",
        lib + "/Unity", lib + "/Application Support/Epic", lib + "/Application Support/Steam",
    ]
    /// Command-line tools that share a name with a desktop app (Claude Code vs Claude, Codex CLI vs Codex…).
    static let namesakeCLIs: Set<String> = ["claude", "opencode", "codex", "gemini", "cursor", "ollama", "docker", "code"]
    /// Words too common to match folders by.
    static let commonNames: Set<String> = ["music", "notes", "photos", "finder", "safari", "preview", "calendar", "contacts", "messages",
                                           "reminders", "clock", "weather", "books", "news", "files", "store", "system", "helper",
                                           "agent", "update", "sync", "backup", "cloud", "manager", "monitor", "server", "client",
                                           "launcher", "driver", "plugin", "utility", "code", "studio", "desktop", "app"]

    // MARK: Plan

    public static func plan(for app: InstalledApp, running: Set<String>) -> UninstallPlan {
        var items = [UninstallItem(path: app.path, kind: .app, bytes: DiskSizer.size(app.path).bytes, selected: true, holdBack: false,
                                   note: app.caskToken.map { "Removed with brew uninstall --cask \($0)." } ?? "Moved to the Trash.")]
        for path in leftovers(for: app) {
            let kind = classify(path)
            let hold = holdBack(path)
            let size = DiskSizer.size(path).bytes
            items.append(UninstallItem(path: path, kind: kind, bytes: size, selected: !hold && (kind == .cache || kind == .agent),
                                       holdBack: hold, note: note(for: path, kind: kind, hold: hold)))
        }
        return UninstallPlan(app: app, items: items, blocked: blockReason(app, running: running))
    }

    public static func classify(_ p: String) -> UninstallItem.Kind {
        if p.hasPrefix(lib + "/LaunchAgents/") { return .agent }
        // A few apps keep real data under Caches (Spotify offline songs, Raycast clipboard images).
        let cacheData = ["com.spotify.client", "com.raycast.macos", "MullvadBrowser"]
        if p.hasPrefix(lib + "/Caches/"), !cacheData.contains(where: { p.hasPrefix(lib + "/Caches/" + $0) }) { return .cache }
        if p.hasPrefix(lib + "/Logs/") || p.hasPrefix(lib + "/HTTPStorages/") || p.hasPrefix(lib + "/Application Support/CrashReporter/")
            || p.hasPrefix(home + "/.cache/") || p.hasPrefix(lib + "/Saved Application State/")
            || p.hasPrefix(lib + "/Logs/DiagnosticReports/") { return .cache }
        return .data
    }

    public static func holdBack(_ p: String) -> Bool {
        let l = p.lowercased(), support = (lib + "/Application Support/").lowercased()
        if l.hasPrefix((lib + "/Group Containers/").lowercased()) { return true }
        let profiles = ["google/chrome", "bravesoftware", "microsoft edge", "com.operasoftware.opera", "chromium", "vivaldi", "arc",
                        "firefox", "zen", "crossover", "openemu"]
        if profiles.contains(where: { l == support + $0 || l.hasPrefix(support + $0 + "/") || l.hasPrefix(support + $0 + " ") }) { return true }
        // Home dot folders can hold projects, keys or settings shared with command-line tools.
        if p.parentPath == home, p.lastComponent.hasPrefix(".") { return true }
        return l.hasPrefix((lib + "/Containers/com.isaacmarovitz.whisky").lowercased())
    }

    static func note(for p: String, kind: UninstallItem.Kind, hold: Bool) -> String {
        if hold { return p.contains("/Group Containers/") ? "Shared between this app and its helpers or sibling apps. Kept unless you choose it."
                                                           : "Profiles, libraries or saved games. Kept unless you choose it." }
        switch kind {
        case .app: return "The app."
        case .cache: return "Cache, logs or saved window state. Not needed once the app is gone."
        case .agent: return "Starts a helper in the background. Unloaded, then moved to the Trash."
        case .data: return "Settings and data for this app. Kept unless you choose to remove it."
        }
    }

    // MARK: Leftover discovery

    /// The file system the finder reads. Swapped for a simulated one when testing against known leftover lists.
    public struct FileView: Sendable {
        public var exists: @Sendable (String) -> Bool
        public var isDirectory: @Sendable (String) -> Bool
        public var isSymlink: @Sendable (String) -> Bool
        public var children: @Sendable (String) -> [String]
        public var enumerate: @Sendable (String) -> FileManager.DirectoryEnumerator?
        public var agentProgram: @Sendable (String) -> String?

        public static let disk = FileView(exists: { DiskSizer.exists($0) }, isDirectory: { DiskSizer.isDirectory($0) },
                                          isSymlink: { DiskSizer.isSymlink($0) }, children: { DiskSizer.children($0) },
                                          enumerate: { FileManager.default.enumerator(atPath: $0) },
                                          agentProgram: { Uninstaller.agentProgram($0) })

        /// A file system holding exactly these paths (and their parent folders), matched without regard to case.
        public static func simulated(_ paths: [String]) -> FileView {
            var all = Set<String>(), kids: [String: Set<String>] = [:]
            for p in paths {
                var q = p
                while q.count > 1 {
                    all.insert(q.lowercased()); kids[q.parentPath.lowercased(), default: []].insert(q)
                    q = q.parentPath
                }
            }
            let a = all, k = kids
            return FileView(exists: { a.contains($0.lowercased()) }, isDirectory: { k[$0.lowercased()] != nil || !$0.contains(".") },
                            isSymlink: { _ in false }, children: { Array(k[$0.lowercased()] ?? []).sorted() },
                            enumerate: { _ in nil }, agentProgram: { _ in nil })
        }
    }

    public static func leftovers(for app: InstalledApp) -> [String] { leftovers(for: app, fs: .disk) }

    /// Visible entries only: dotfiles inside Library folders are never an app's leftovers.
    static func fsKids(_ fs: FileView, _ dir: String) -> [String] { fs.children(dir).filter { !$0.lastComponent.hasPrefix(".") } }

    public static func leftovers(for app: InstalledApp, fs: FileView) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ p: String) {
            // APFS ignores case, so ~/.config/Foo and ~/.config/foo are one folder; keep its real spelling.
            let s = realCase((p as NSString).standardizingPath, fs)
            guard seen.insert(s.lowercased()).inserted else { return }
            guard s != home, !sharedRoots.contains(s), s.parentPath != home || s.lastComponent.hasPrefix("."),
                  !isLibraryRoot(s), !isNamesakeCLI(s), !s.contains("/Application Support/Steam"),
                  fs.exists(s), !fs.isSymlink(s), !found.contains(s) else { return }
            found.append(s)
        }

        let name = app.name
        let id = app.bundleID.flatMap { isReverseDNS($0) ? $0 : nil }
        let variants = nameVariants(name)

        // Name-based places. Names shorter than 3 letters or too generic would match other apps' folders.
        if name.count >= 3, !commonNames.contains(name.lowercased()) {
            for n in variants.cased {
                for p in ["\(lib)/Application Support/\(n)", "\(lib)/Caches/\(n)", "\(lib)/Logs/\(n)", "\(lib)/Preferences/\(n).plist",
                          "\(lib)/Preferences/\(n)", "\(lib)/Saved Application State/\(n).savedState"] { add(p) }
            }
            for n in variants.lower {
                for p in ["\(home)/.config/\(n)", "\(home)/.cache/\(n)", "\(home)/.local/share/\(n)"] { add(p) }
            }
            // Electron apps name their data folder after package.json ("obs-studio", "kimi-desktop") and
            // keep the auto-updater's downloads in "<name>-updater".
            for n in variants.slug {
                for p in ["\(lib)/Application Support/\(n)", "\(lib)/Application Support/\(n)-desktop", "\(lib)/Caches/\(n)",
                          "\(lib)/Caches/\(n)-updater", "\(lib)/Caches/\(n)-desktop-updater", "\(lib)/Logs/\(n)", "\(lib)/Logs/\(n)-desktop"] { add(p) }
            }
            // ~/.warp, ~/.zcode: app-owned dot folders. Only for distinctive names, kept unless you choose them.
            if name.count >= 4 {
                for n in variants.slug where !namesakeCLIs.contains(n) && !commonNames.contains(n) { add("\(home)/.\(n)") }
            }
            // Crash reports macOS wrote for the app (Name-2026-01-01-…ips, Name_2026…crash).
            let reportNames = Set(variants.cased + [app.executable].compactMap { $0 })
            for f in fsKids(fs, "\(lib)/Logs/DiagnosticReports") where reportNames.contains(where: { n in
                let l = f.lastComponent; return l.hasPrefix(n + "-") || l.hasPrefix(n + "_") || l.hasPrefix(n + ".")
            }) { add(f) }
            for (dir, ext) in pluginFolders { add("\(lib)/\(dir)/\(name).\(ext)") }
            // Crash reporter state named Name_<uuid>.plist.
            for f in fsKids(fs, "\(lib)/Application Support/CrashReporter")
            where variants.cased.contains(where: { f.lastComponent.hasPrefix($0 + "_") && f.hasSuffix(".plist") }) { add(f) }
        }

        if let id {
            for p in ["\(lib)/Application Support/\(id)", "\(lib)/Caches/\(id)", "\(lib)/Logs/\(id)", "\(lib)/Saved Application State/\(id).savedState",
                      "\(lib)/Containers/\(id)", "\(lib)/WebKit/\(id)", "\(lib)/WebKit/com.apple.WebKit.WebContent/\(id)",
                      "\(lib)/HTTPStorages/\(id)", "\(lib)/HTTPStorages/\(id).binarycookies", "\(lib)/Application Scripts/\(id)",
                      "\(lib)/Autosave Information/\(id)", "\(lib)/SyncedPreferences/\(id).plist", "\(lib)/Preferences/\(id).plist",
                      "\(lib)/Preferences/\(id)", "\(lib)/Caches/com.apple.nsurlsessiond/Downloads/\(id)",
                      "\(lib)/Caches/com.plausiblelabs.crashreporter.data/\(id)", "\(lib)/Caches/\(id).ShipIt",
                      "\(lib)/Cookies/\(id).binarycookies", "\(lib)/Caches/CloudKit/\(id)"] { add(p) }
            // Earlier major versions under the same ID family: com.omnigroup.OmniFocus4 also left com.omnigroup.OmniFocus3.
            let family = id.replacingOccurrences(of: "[0-9]+$", with: "", options: .regularExpression)
            if family != id, family.split(separator: ".").count >= 3, family.last != "." {
                for root in ["\(lib)/Application Support", "\(lib)/Caches", "\(lib)/Containers", "\(lib)/HTTPStorages", "\(lib)/Preferences",
                             "\(lib)/Saved Application State", "\(lib)/Application Scripts", "\(lib)/WebKit"] {
                    for d in fsKids(fs, root) {
                        var leaf = d.lastComponent
                        for ext in [".plist", ".savedState", ".binarycookies"] where leaf.hasSuffix(ext) { leaf = String(leaf.dropLast(ext.count)) }
                        if leaf.lowercased() == family.lowercased() || leaf.lowercased().range(of: "^" + NSRegularExpression.escapedPattern(for: family.lowercased()) + "[0-9]+$", options: .regularExpression) != nil { add(d) }
                    }
                }
            }
            // Per-machine preferences: <id>.<host-uuid>.plist.
            for f in fsKids(fs, "\(lib)/Preferences/ByHost") where startsWithID(f.lastComponent, id) { add(f) }
            // App groups (TEAMID.<id>, group.<id>) and extensions (<id>.ShareExtension).
            for root in ["\(lib)/Group Containers", "\(lib)/Containers", "\(lib)/Application Scripts", "\(lib)/Application Support/FileProvider"] {
                for d in fsKids(fs, root) where hasIDBoundary(d.lastComponent, id) { add(d) }
            }
            let recents = "\(lib)/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            for f in fsKids(fs, recents) where ["sfl2", "sfl3", "sfl4"].contains((f as NSString).pathExtension)
                && f.lastComponent.dropLast(5).lowercased() == id.lowercased() { add(f) }

            // A bundle-ID leaf that extends the display name names the data folder more exactly
            // (AyuGram → one.ayugram.AyuGramDesktop → "AyuGram Desktop").
            let leaf = String(id.split(separator: ".").last ?? "")
            let flat = name.replacingOccurrences(of: " ", with: "")
            if leaf.count >= 8, leaf != name, leaf.lowercased().hasPrefix(flat.lowercased()), flat.count >= 3,
               leaf.dropFirst(flat.count).first.map({ $0.isUppercase || $0.isNumber }) == true {
                let rest = String(leaf.dropFirst(flat.count))
                for v in [leaf, name + " " + splitCamel(rest)] {
                    for p in ["\(lib)/Application Support/\(v)", "\(lib)/Caches/\(v)", "\(lib)/Logs/\(v)",
                              "\(lib)/Preferences/\(v).plist", "\(lib)/Saved Application State/\(v).savedState"] { add(p) }
                }
            }

            // Vendor folder: com.avid.Sibelius → Application Support/Avid/Sibelius.
            let parts = id.split(separator: ".").map(String.init)
            if parts.count >= 3, name.count >= 4, !commonNames.contains(name.lowercased()) {
                let vendor = parts[parts.count - 2].lowercased(), product = parts[parts.count - 1].lowercased()
                let wanted = Set(variants.lower + [product])
                for root in ["\(lib)/Application Support", "\(lib)/Caches", "\(lib)/Logs"] {
                    for v in fsKids(fs, root) where v.lastComponent.lowercased() == vendor && fs.isDirectory(v) {
                        // Exact names only: "Google/Chrome" is Chrome's, "Google/Chrome for Testing" belongs to Playwright.
                        for c in fsKids(fs, v) where channelMatch(c.lastComponent.lowercased(), wanted) { add(c) }
                    }
                }
            }

            // Helpers inside the app (extensions, XPC services, login items) keep data under their own IDs.
            for sub in embeddedIDs(app.path, primary: id, fs: fs) {
                for p in ["\(lib)/Application Scripts/\(sub)", "\(lib)/Application Support/FileProvider/\(sub)", "\(lib)/Caches/\(sub)",
                          "\(lib)/Containers/\(sub)", "\(lib)/HTTPStorages/\(sub)", "\(lib)/HTTPStorages/\(sub).binarycookies",
                          "\(lib)/Preferences/\(sub).plist", "\(lib)/WebKit/\(sub)"] { add(p) }
                for f in fsKids(fs, "\(lib)/Preferences/ByHost") where f.lastComponent.hasPrefix(sub + ".") { add(f) }
            }
        }

        // Launch agents: named after the app, or running a program inside it.
        for plist in fsKids(fs, "\(lib)/LaunchAgents") where plist.hasSuffix(".plist") {
            let file = plist.lastComponent
            if file.hasPrefix("com.apple.") { continue }
            if let id, file == id + ".plist" || file.hasPrefix(id + ".") { add(plist); continue }
            if let program = fs.agentProgram(plist), program.hasPrefix(app.path + "/") { add(plist) }
        }

        for p in productSpecific(app, id: id, fs: fs) { add(p) }
        return found
    }

    /// The name as stored on disk ("~/.cache/Antigravity" → "~/.cache/antigravity").
    static func realCase(_ p: String, _ fs: FileView) -> String {
        let parent = p.parentPath, leaf = p.lastComponent.lowercased()
        return fsKids(fs, parent).first { $0.lastComponent.lowercased() == leaf } ?? p
    }

    static let pluginFolders: [(String, String)] = [
        ("Services", "workflow"), ("QuickLook", "qlgenerator"), ("Internet Plug-Ins", "plugin"), ("Audio/Plug-Ins/Components", "component"),
        ("Audio/Plug-Ins/VST", "vst"), ("Audio/Plug-Ins/VST3", "vst3"), ("PreferencePanes", "prefPane"), ("Input Methods", "app"),
        ("Screen Savers", "saver"), ("Spotlight", "mdimporter"), ("ColorPickers", "colorPicker"), ("Workflows", "workflow"),
        ("Contextual Menu Items", "plugin"), ("Frameworks", "framework"),
    ]

    /// Apps whose data lives under names nothing else would find.
    static func productSpecific(_ app: InstalledApp, id: String?, fs: FileView) -> [String] {
        let id = id ?? "", n = app.name
        var out: [String] = []
        if id.range(of: "microsoft.*vscode", options: [.regularExpression, .caseInsensitive]) != nil {
            let insiders = id.lowercased().contains("insiders")
            out += insiders ? ["\(home)/.vscode-insiders", "\(lib)/Application Support/Code - Insiders", "\(lib)/Caches/com.microsoft.VSCodeInsiders"]
                            : ["\(home)/.vscode", "\(lib)/Application Support/Code", "\(lib)/Caches/com.microsoft.VSCode"]
            out += ["\(lib)/Caches/com.microsoft.VSCode.ShipIt", "\(lib)/Caches/com.microsoft.VSCodeInsiders.ShipIt"]
        }
        if id == "com.todesktop.230313mzl4w4u92" || n == "Cursor" { out += ["\(home)/.cursor", "\(lib)/Application Support/Cursor"] }
        if n.hasPrefix("Docker") { out += ["\(home)/.docker/buildx", "\(home)/.docker/scan"] }
        if n.range(of: "Android Studio", options: .caseInsensitive) != nil {
            out += ["\(home)/.android/cache", "\(home)/.android/build-cache", "\(home)/.android/breakpad"]
            out += fsKids(fs, "\(lib)/Application Support/Google").filter { versioned($0.lastComponent, "AndroidStudio") }
        }
        if id.hasPrefix("com.apple.dt.Xcode") {
            out += ["DerivedData", "iOS DeviceSupport", "macOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport"]
                .map { "\(lib)/Developer/Xcode/\($0)" } + ["\(lib)/Developer/CoreSimulator/Caches"]
        }
        if id.hasPrefix("com.jetbrains.") || ["IntelliJ", "PyCharm", "WebStorm", "GoLand", "RubyMine", "PhpStorm", "CLion", "DataGrip", "Rider"].contains(where: n.hasPrefix) {
            let product = n.replacingOccurrences(of: " ", with: "")
            for base in ["\(lib)/Application Support/JetBrains", "\(lib)/Caches/JetBrains", "\(lib)/Logs/JetBrains"] {
                out += fsKids(fs, base).filter { versioned($0.lastComponent, product) || versioned($0.lastComponent, n) }
            }
        }
        if n.lowercased().hasPrefix("godot") { out.append("\(lib)/Application Support/Godot") }
        if id == "com.anthropic.claudefordesktop" { out += ["\(lib)/Application Support/Claude-3p", "\(lib)/Logs/Claude-3p"] }
        if id == "net.ankiweb.anki" { out.append("\(lib)/Application Support/AnkiProgramFiles") }
        if id == "com.raycast.macos" {
            for root in ["\(lib)/Application Support", "\(lib)/Application Scripts", "\(lib)/Containers", "\(lib)/Caches"] {
                out += fsKids(fs, root).filter {
                    let l = $0.lastComponent.lowercased(); return l.contains("raycast") && !l.contains("raycast-x")
                }
            }
        }
        if id == "com.valvesoftware.steam" { out += ["\(lib)/Application Support/Steam/appcache", "\(lib)/Application Support/Steam/htmlcache", "\(lib)/Application Support/Steam/logs"] }
        if n == "Postgres" || id == "com.postgresapp.Postgres2" { out.append("\(lib)/Application Support/Postgres") }
        return out
    }

    // MARK: Matching helpers

    static func nameVariants(_ name: String) -> (cased: [String], lower: [String], slug: [String]) {
        var cased = [name]
        if name.contains(" ") {
            cased += [name.replacingOccurrences(of: " ", with: ""), name.replacingOccurrences(of: " ", with: "_"), name.replacingOccurrences(of: " ", with: "-")]
        }
        // "Zed Nightly" → "Zed", "Firefox Developer Edition" → "Firefox".
        for suffix in [" Nightly", " Beta", " Alpha", " Dev", " Canary", " Preview", " Insiders", " Stable", " Developer Edition", " Technology Preview", " CE"]
        where name.hasSuffix(suffix) && name.count - suffix.count > 2 { cased.append(String(name.dropLast(suffix.count))) }
        let lower = Array(Set(cased.map { $0.lowercased() }))
        // "OBS Studio" → "obs-studio", "obsstudio"; "Cherry Studio" → "cherry-studio", "cherrystudio".
        let slug = Array(Set(cased.flatMap { c -> [String] in
            let l = c.lowercased(); return [l.replacingOccurrences(of: " ", with: "-"), l.replacingOccurrences(of: " ", with: "")]
        })).filter { $0.count >= 3 }
        return (Array(NSOrderedSet(array: cased)) as! [String], lower, slug)
    }

    static func variantMatch(_ candidate: String, _ wanted: Set<String>) -> Bool {
        wanted.contains { w in candidate == w || candidate.hasPrefix(w + " ") || candidate.hasPrefix(w + "-") || candidate.hasPrefix(w + "_") || candidate.hasPrefix(w + ".") }
    }

    /// The name itself or a release channel of it ("chrome", "chrome beta", "chrome canary").
    static func channelMatch(_ candidate: String, _ wanted: Set<String>) -> Bool {
        let channels = ["beta", "dev", "canary", "nightly", "preview", "insiders"]
        return wanted.contains { w in candidate == w || channels.contains { candidate == "\(w) \($0)" || candidate == "\(w)-\($0)" } }
    }

    /// IDE folders: "PyCharm2025.2", "AndroidStudio2024.3". A bare prefix would also claim sibling products.
    static func versioned(_ leaf: String, _ product: String) -> Bool {
        guard !product.isEmpty, leaf.hasPrefix(product) else { return false }
        let rest = leaf.dropFirst(product.count)
        return rest.isEmpty || String(rest).range(of: "^[0-9]{4}(\\.[0-9]+)+$", options: .regularExpression) != nil
    }

    static func splitCamel(_ s: String) -> String {
        var out = ""
        for (i, c) in s.enumerated() {
            if i > 0, c.isUppercase, let prev = out.last, prev.isLowercase || prev.isNumber { out.append(" ") }
            out.append(c)
        }
        return out
    }

    static func isReverseDNS(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][-A-Za-z0-9]*(\\.[A-Za-z0-9][-A-Za-z0-9]*)+$", options: .regularExpression) != nil
    }
    /// Bundle IDs compare without case: folders often lower-case them (com.TechSmith.Snagit → 7TQL462TU8.com.techsmith.snagit).
    static func startsWithID(_ name: String, _ id: String) -> Bool {
        let n = name.lowercased(), i = id.lowercased(); return n == i || n.hasPrefix(i + ".")
    }
    static func hasIDBoundary(_ name: String, _ id: String) -> Bool {
        let n = name.lowercased(), i = id.lowercased()
        return startsWithID(n, i) || n.hasSuffix("." + i) || n.contains("." + i + ".")
    }

    static func isLibraryRoot(_ p: String) -> Bool {
        let roots = ["Application Support", "Caches", "Logs", "Preferences", "Preferences/ByHost", "Containers", "WebKit", "HTTPStorages",
                     "Application Scripts", "Autosave Information", "Group Containers", "LaunchAgents", "Saved Application State"]
        return p == lib || roots.contains { p == lib + "/" + $0 }
    }

    static func isNamesakeCLI(_ p: String) -> Bool {
        let leaf = p.lastComponent.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard namesakeCLIs.contains(leaf) else { return false }
        return [home, home + "/.config", home + "/.local/share", home + "/.cache"].contains(p.parentPath)
    }

    /// Bundle IDs of extensions, XPC services and login items inside the app (at most 128 bundles read).
    static func embeddedIDs(_ app: String, primary: String, fs: FileView) -> [String] {
        var ids = Set<String>()
        let contents = app + "/Contents"
        guard let e = fs.enumerate(contents) else { return [] }
        var read = 0
        while let rel = e.nextObject() as? String, read < 128 {
            guard rel.hasSuffix("/Contents/Info.plist") else {
                if e.level > 8 { e.skipDescendants() }
                continue
            }
            let root = contents + "/" + String(rel.dropLast("/Contents/Info.plist".count))
            let ext = (root as NSString).pathExtension.lowercased()
            guard ext == "appex" || ext == "xpc" || (ext == "app" && root.contains("/Contents/Library/LoginItems/")) else { continue }
            read += 1
            guard let sub = Bundle(path: root)?.bundleIdentifier, isReverseDNS(sub), sub != primary,
                  !sub.hasPrefix("org.sparkle-project.") else { continue }
            ids.insert(sub)
        }
        return ids.sorted()
    }

    static func agentProgram(_ plist: String) -> String? {
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        if let p = d["Program"] as? String { return p }
        return (d["ProgramArguments"] as? [String])?.first
    }

    // MARK: Removal

    /// Removes the app and the selected items. Everything goes to the Trash; Homebrew apps go through
    /// `brew uninstall --cask`; launch agents are unloaded first. Returns a receipt like a cleanup does.
    public static func uninstall(_ plan: UninstallPlan, running: Set<String>) async -> CleanReceipt {
        let before = SystemProbe.volume().free
        var items: [CleanReceipt.Item] = []
        if let why = blockReason(plan.app, running: running) {
            items.append(.init(path: plan.app.path, title: plan.app.name, bytes: 0, action: "Uninstall", ok: false, message: "Skipped: \(why)", trashedTo: nil))
            return CleanReceipt(date: Date(), items: items, freeBefore: before, freeAfter: before)
        }
        for item in plan.items where item.selected {
            var r = CleanReceipt.Item(path: item.path, title: item.kind == .app ? plan.app.name : item.path.tildePath, bytes: item.bytes,
                                      action: item.kind == .app ? "Uninstall app" : "Move to Trash", ok: false, message: "", trashedTo: nil)
            if item.kind == .app {
                if let token = plan.app.caskToken, let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
                    let out = Shell.run([brew, "uninstall", "--cask", token], timeout: 600)
                    r.ok = out.status == 0
                    r.message = r.ok ? "brew uninstall --cask \(token)" : "brew uninstall failed: \((out.err + out.out).suffix(200))"
                } else {
                    (r.ok, r.message, r.trashedTo) = await recycle(item.path)
                }
            } else {
                let f = Finding(path: item.path, title: r.title, category: .apps, safety: .check, reason: "", usedFor: "", action: .trash, layer: .full)
                if let why = SafetyGuard.refusal(for: f, allowActiveProjects: false) {
                    r.message = "Skipped: \(why)"
                } else {
                    if item.kind == .agent { _ = Shell.run(["launchctl", "bootout", "gui/\(getuid())", item.path], timeout: 10) }
                    (r.ok, r.message, r.trashedTo) = Cleaner.trash(item.path)
                }
            }
            items.append(r)
        }
        let receipt = CleanReceipt(date: Date(), items: items, freeBefore: before, freeAfter: SystemProbe.volume().free)
        Cleaner.save(receipt)
        return receipt
    }

    /// Finder's own Trash, so apps owned by another user (App Store installs) ask for your password instead of failing.
    @MainActor static func recycleOnMain(_ url: URL) async -> (Bool, String, String?) {
        await withCheckedContinuation { cont in
            NSWorkspace.shared.recycle([url]) { moved, error in
                if let error { cont.resume(returning: (false, "Could not move to Trash: \(error.localizedDescription)", nil)) }
                else { cont.resume(returning: (true, "Moved to Trash.", moved[url]?.path)) }
            }
        }
    }

    static func recycle(_ path: String) async -> (Bool, String, String?) {
        await recycleOnMain(URL(fileURLWithPath: path))
    }
}
