import AppKit
import Darwin
import Foundation

/// The rest of the reference cleaner's Optimize tab, task for task, with Sapu2's rules on top: removals go to the
/// Trash with a receipt, databases are copied to the Trash before they change, and administrator commands are fixed
/// strings that macOS asks your password for, one at a time. Left out on purpose: compacting Mail and Messages
/// (never touched) and deleting login items through System Events (System Settings does that).
extension Maintenance {
    // MARK: Quick fixes

    struct Repair: Sendable {
        let id: String, title: String, detail: String, processes: [String]
    }

    /// Each restarts this user's copy of one macOS process with SIGTERM, as the reference does; launchd starts it again.
    static let repairs: [Repair] = [
        Repair(id: "repair.input", title: "Input switching",
               detail: "Fixes the input menu or keyboard-language switch when it stops responding.", processes: ["TextInputMenuAgent", "TextInputSwitcher"]),
        Repair(id: "repair.spotlight", title: "Spotlight",
               detail: "Fixes the Spotlight window when it won't open or shows nothing. The search index isn't touched.", processes: ["Spotlight"]),
        Repair(id: "repair.notifications", title: "Notification Center",
               detail: "Fixes notifications or widgets that stopped showing. Notifications you already have stay.", processes: ["NotificationCenter"]),
        Repair(id: "repair.clipboard", title: "Universal Clipboard and Handoff",
               detail: "Fixes copying on one device and pasting on another, and Handoff between your devices.", processes: ["useractivityd"]),
        Repair(id: "repair.dock", title: "Dock",
               detail: "Fixes a stuck Dock, Launchpad or Mission Control. Your Dock layout stays.", processes: ["Dock"]),
    ]

    static func repairTasks() -> [MaintenanceTask] {
        repairs.map { MaintenanceTask(id: $0.id, title: $0.title, status: .info, detail: $0.detail + " Restarts \($0.processes.joined(separator: " and ")).",
                                      fix: .run, fixLabel: "Restart", group: .quickFix) }
    }

    static func restart(_ names: [String]) -> (ok: Bool, message: String) {
        let pids = names.flatMap(pids(named:))
        guard !pids.isEmpty else { return (true, "It wasn't running; macOS starts it when it's needed.") }
        let done = pids.filter { kill($0, SIGTERM) == 0 }.count
        return done > 0 ? (true, "Restarted. macOS started it again.") : (false, "Couldn't restart it.")
    }

    /// This user's processes with exactly this name.
    static func pids(named name: String) -> [pid_t] {
        Shell.run(["pgrep", "-x", "-U", "\(getuid())", name], timeout: 5).out
            .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: Launch speed

    public struct MountedImage: Sendable, Hashable {
        public let image: String
        public let mount: String
        public init(image: String, mount: String) { self.image = image; self.mount = mount }
    }

    /// Disk images and where they are mounted, from `hdiutil info -plist`.
    public static func mountedImages(_ plist: Data) -> [MountedImage] {
        guard let d = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let images = d["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { i in
            ((i["system-entities"] as? [[String: Any]]) ?? []).compactMap { e in
                (e["mount-point"] as? String).map { MountedImage(image: i["image-path"] as? String ?? "", mount: $0) }
            }
        }
    }

    static let imageSuffixes = [".dmg", ".iso", ".img", ".cdr", ".sparseimage", ".sparsebundle"]

    /// A downloaded image you opened, mounted in /Volumes. macOS's own images (cryptexes, simulators) never qualify,
    /// nor the image Sapu2 itself runs from, nor one on your protect list.
    public static func ejectable(_ m: MountedImage, protectList: [String] = ProtectList.load(), running: String = Bundle.main.bundlePath) -> Bool {
        if ["/System/", "/Library/Apple/", "/private/var/run/com.apple.security.cryptexd/"].contains(where: m.image.hasPrefix) { return false }
        guard m.mount.hasPrefix("/Volumes/"), !m.mount.hasPrefix("/Library/Developer/CoreSimulator/") else { return false }
        guard imageSuffixes.contains(where: m.image.lowercased().hasSuffix) else { return false }
        if running == m.mount || running.hasPrefix(m.mount + "/") { return false }
        return ProtectList.entry(covering: m.image, in: protectList) == nil && ProtectList.entry(covering: m.mount, in: protectList) == nil
    }

    static func diskImages() -> MaintenanceTask? {
        let r = Shell.run(["hdiutil", "info", "-plist"], timeout: 8)
        let mounts = mountedImages(Data(r.out.utf8)).filter { ejectable($0) }
        guard !mounts.isEmpty else { return nil }
        let names = mounts.map { "\($0.mount.lastComponent) (\($0.image.tildePath))" }
        return MaintenanceTask(id: "diskimages", title: "Eject idle disk images", status: .info,
                               detail: "\(mounts.count) disk image(s) you opened are still mounted: \(names.joined(separator: ", ")). An image in use is left mounted.",
                               paths: mounts.map(\.mount), fix: .run, fixLabel: "Eject", group: .launchSpeed)
    }

    /// Never forces: `hdiutil detach` refuses an image something still has open.
    static func ejectImages(_ mounts: [String]) -> (ok: Bool, message: String) {
        let live = Set(mountedImages(Data(Shell.run(["hdiutil", "info", "-plist"], timeout: 8).out.utf8)).filter { ejectable($0) }.map(\.mount))
        let mine = mounts.filter(live.contains)
        let done = mine.filter { Shell.run(["hdiutil", "detach", $0], timeout: 15).status == 0 }.count
        let busy = mine.count - done
        return (busy == 0, "Ejected \(done) disk image(s)." + (busy > 0 ? " \(busy) still in use, left mounted." : ""))
    }

    public static let savedStateDir = home + "/Library/Saved Application State"

    /// Window states untouched for `days` days whose app is not running. The app opens with fresh windows.
    public static func oldSavedStates(in dir: String = savedStateDir, days: Int = 30, running: Set<String>, now: Date = Date()) -> [String] {
        DiskSizer.children(dir, includeHidden: false).filter { p in
            guard p.hasSuffix(".savedState"), DiskSizer.isDirectory(p), !DiskSizer.isSymlink(p),
                  let m = DiskSizer.mtime(p), now.timeIntervalSince(m) > Double(days) * 86_400 else { return false }
            return !running.contains(String(p.lastComponent.dropLast(".savedState".count)))
        }
    }

    static var runningBundleIDs: Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }

    static func savedStates() -> MaintenanceTask? {
        let old = oldSavedStates(running: runningBundleIDs)
        guard !old.isEmpty else {
            return MaintenanceTask(id: "savedstate", title: "Clear old saved window states", status: .ok,
                                   detail: "No app kept windows from more than 30 days ago.", fix: .none, group: .launchSpeed)
        }
        let bytes = old.reduce(Int64(0)) { $0 + DiskSizer.size($1).bytes }
        return MaintenanceTask(id: "savedstate", title: "Clear old saved window states", status: .info,
                               detail: "\(old.count) app(s) kept the windows you had open more than 30 days ago (\(Format.bytes(bytes))). Those apps open with fresh windows; documents aren't affected. Apps that are open now are skipped.",
                               paths: old, fix: .run, fixLabel: "Move to Trash", group: .launchSpeed)
    }

    // MARK: System databases

    /// The live Notification Center database: the usernoted group container on macOS 15 and later, the user temp folder before.
    static var notificationDB: String? {
        let darwinUser = Shell.run(["getconf", "DARWIN_USER_DIR"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return [home + "/Library/Group Containers/group.com.apple.usernoted/db2/db", darwinUser + "com.apple.notificationcenter/db2/db"]
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// Notification Center stores dates as seconds since 2001 (Core Data time), not since 1970. Comparing them with
    /// Unix time, as the reference does, would match every record; this keeps the last 30 days.
    public static let notificationPrune = "DELETE FROM record WHERE delivered_date < (strftime('%s','now','-30 days') - 978307200); VACUUM;"
    static let notificationLimit: Int64 = 50 * 1_048_576

    static func notificationRecords() -> MaintenanceTask? {
        guard let db = notificationDB else { return nil }
        let size = [db, db + "-wal"].reduce(Int64(0)) { $0 + DiskSizer.size($1).bytes }
        let big = size >= notificationLimit
        return MaintenanceTask(id: "notifications", title: "Clear old notification records", status: big ? .attention : .ok,
                               detail: big ? "Notification Center's history is \(Format.bytes(size)). Records older than 30 days are removed; recent ones stay. A backup copy goes to the Trash first."
                                           : "Notification Center's history is \(Format.bytes(size)), well under the 50 MB where it slows down.",
                               paths: [db], fix: big ? .run : .none, fixLabel: "Clear old records", group: .databases)
    }

    static func pruneNotifications(_ db: String) -> (ok: Bool, message: String) {
        let (copied, to) = backupToTrash([db, db + "-wal", db + "-shm"], name: "Notification Center backup")
        guard copied else { return (false, "Couldn't put a backup copy in the Trash; nothing was changed.") }
        let r = Shell.run(["sqlite3", db, notificationPrune], timeout: 60)
        _ = restart(["NotificationCenter"])
        record(db, "Notification records (backup copy)", r.status == 0, r.status == 0 ? "Records older than 30 days removed. The backup copy is in the Trash." : "sqlite3 failed: \(r.err.suffix(200))", to)
        return r.status == 0 ? (true, "Removed records older than 30 days. A backup copy is in the Trash.") : (false, "The database was busy; nothing was removed.")
    }

    // MARK: Network & search

    static let spotlightPlist = home + "/Library/Preferences/com.apple.spotlight.plist"

    /// Rules in System Settings › Spotlight left by apps you removed. Apple's and anything not shaped like an app ID stay.
    public static func spotlightOrphans(_ rules: [String], installed: (String) -> Bool) -> [String] {
        rules.filter { r in
            !r.hasPrefix("System.") && !r.hasPrefix("com.apple.")
                && r.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil
                && !installed(r)
        }
    }

    static func spotlightRuleList() -> [String]? {
        guard let d = FileManager.default.contents(atPath: spotlightPlist),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return nil }
        return p["EnabledPreferenceRules"] as? [String]
    }

    /// LaunchServices first, then Spotlight's own record of the bundle ID.
    static func appInstalled(_ id: String) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        let r = Shell.run(["mdfind", "kMDItemCFBundleIdentifier == '\(id)'"], timeout: 10)
        return r.status != 0 || !r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func spotlightRules() -> MaintenanceTask? {
        guard let rules = spotlightRuleList() else { return nil }
        let orphans = spotlightOrphans(rules, installed: appInstalled)
        return MaintenanceTask(id: "spotlightrules", title: "Clean orphaned Spotlight rules", status: orphans.isEmpty ? .ok : .info,
                               detail: orphans.isEmpty ? "Every app listed in Spotlight's settings is installed."
                                                       : "\(orphans.count) app(s) you removed still show as rows in System Settings › Spotlight: \(orphans.joined(separator: ", ")). A backup of the settings file goes to the Trash first.",
                               paths: orphans, fix: orphans.isEmpty ? .none : .run, fixLabel: "Remove rows", group: .network)
    }

    /// Writes through `defaults` (cfprefsd) so System Settings sees it, and only if nothing changed since the check.
    static func pruneSpotlightRules(_ orphans: [String]) -> (ok: Bool, message: String) {
        guard let rules = spotlightRuleList() else { return (false, "Couldn't read Spotlight's settings; nothing changed.") }
        let gone = Set(spotlightOrphans(rules, installed: appInstalled)).intersection(orphans)
        guard !gone.isEmpty else { return (true, "Nothing to remove any more.") }
        let (copied, to) = backupToTrash([spotlightPlist], name: "Spotlight settings backup")
        guard copied else { return (false, "Couldn't put a backup copy in the Trash; nothing was changed.") }
        let keep = rules.filter { !gone.contains($0) }
        let r = keep.isEmpty ? Shell.run(["defaults", "delete", "com.apple.spotlight", "EnabledPreferenceRules"], timeout: 5)
                             : Shell.run(["defaults", "write", "com.apple.spotlight", "EnabledPreferenceRules", "-array"] + keep, timeout: 5)
        record(spotlightPlist, "Spotlight settings (backup copy)", r.status == 0, r.status == 0 ? "Removed \(gone.count) row(s): \(gone.sorted().joined(separator: ", "))." : "defaults failed.", to)
        return r.status == 0 ? (true, "Removed \(gone.count) row(s). A backup is in the Trash.") : (false, "Couldn't change Spotlight's settings.")
    }

    // MARK: System maintenance

    /// A program on an external drive that is simply unplugged is not broken.
    public static func volumeMounted(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return true }
        let parts = path.split(separator: "/")
        return parts.count < 2 || DiskSizer.isDirectory("/Volumes/" + parts[1])
    }

    public static let sharedListDir = home + "/Library/Application Support/com.apple.sharedfilelist"

    /// Sidebar, recent-server and favourites lists macOS can no longer read. Recent documents are yours and stay.
    public static func brokenSharedLists(in dir: String = sharedListDir) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            let p = dir + "/" + rel
            guard [".sfl2", ".sfl3", ".sfl4"].contains(where: rel.hasSuffix), !rel.contains("ApplicationRecentDocuments"),
                  !DiskSizer.isSymlink(p), let d = FileManager.default.contents(atPath: p) else { continue }
            if (try? PropertyListSerialization.propertyList(from: d, format: nil)) == nil { out.append(p) }
        }
        return out.sorted()
    }

    static func sharedFileLists() -> MaintenanceTask? {
        guard DiskSizer.isDirectory(sharedListDir) else { return nil }
        let broken = brokenSharedLists()
        return MaintenanceTask(id: "sharedlists", title: "Remove broken recent and sidebar lists", status: broken.isEmpty ? .ok : .attention,
                               detail: broken.isEmpty ? "Finder's sidebar, favourites and recent-item lists can all be read."
                                                      : "\(broken.count) list(s) can't be read: \(broken.map(\.lastComponent).joined(separator: ", ")). macOS makes a new, empty one.",
                               paths: broken, fix: broken.isEmpty ? .none : .run, fixLabel: "Move to Trash", group: .system)
    }

    /// Folders where command-line tools put their command links.
    static var commandDirs: [String] {
        [home + "/.local/bin", home + "/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
    }

    /// Links whose target is gone (not merely on an unplugged drive). Simulator runtimes are macOS's own.
    public static func brokenLinks(in dirs: [String]) -> [String] {
        dirs.flatMap { dir in
            DiskSizer.children(dir).filter { p in
                guard DiskSizer.isSymlink(p), !FileManager.default.fileExists(atPath: p),
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { return false }
                let abs = target.hasPrefix("/") ? target : (dir as NSString).appendingPathComponent(target)
                return volumeMounted(abs) && !abs.hasPrefix("/Library/Developer/CoreSimulator/")
            }
        }
    }

    static func commandLinks() -> MaintenanceTask? {
        let broken = brokenLinks(in: commandDirs)
        guard !broken.isEmpty else {
            return MaintenanceTask(id: "commandlinks", title: "Commands left by removed apps", status: .ok,
                                   detail: "Every command in your command folders points to a program that exists.", fix: .none, group: .system)
        }
        let fixable = broken.filter { $0.hasPrefix(home + "/") || $0.hasPrefix("/opt/homebrew/") }
        let elsewhere = broken.count - fixable.count
        return MaintenanceTask(id: "commandlinks", title: "Commands left by removed apps", status: .attention,
                               detail: "\(broken.count) command(s) point to a program that is gone: \(broken.map(\.lastComponent).joined(separator: ", ")). Typing them gives \"no such file\"."
                                   + (elsewhere > 0 ? " \(elsewhere) of them are in /usr/local, which only an administrator can change, so Sapu2 lists them only. Reinstalling the app and using its own uninstaller removes them; or delete them in Finder (Go › Go to Folder › /usr/local/bin)." : ""),
                               paths: fixable, fix: fixable.isEmpty ? .none : .run, fixLabel: "Remove links", group: .system)
    }

    /// Links in your home go to the Trash (the link only, never a target); Homebrew's are pruned by Homebrew.
    static func removeLinks(_ paths: [String]) -> (ok: Bool, message: String) {
        let still = Set(brokenLinks(in: commandDirs))
        var items: [CleanReceipt.Item] = [], done = 0, failed = 0
        for p in paths where still.contains(p) && p.hasPrefix(home + "/") {
            let (ok, msg, to) = Cleaner.trash(p)
            ok ? (done += 1) : (failed += 1)
            items.append(.init(path: p, title: p.lastComponent, bytes: 0, action: "Remove broken command link", ok: ok, message: msg, trashedTo: to))
        }
        if paths.contains(where: { $0.hasPrefix("/opt/homebrew/") && still.contains($0) }), let brew {
            let r = Shell.run([brew, "cleanup", "--prune-prefix"], timeout: 120)
            r.status == 0 ? (done += 1) : (failed += 1)
            items.append(.init(path: "/opt/homebrew", title: "Homebrew's broken links", bytes: 0, action: "brew cleanup --prune-prefix", ok: r.status == 0,
                               message: r.status == 0 ? "Homebrew removed its broken links." : "brew failed: \(r.err.suffix(200))", trashedTo: nil))
        }
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: items, freeBefore: free, freeAfter: free))
        return (failed == 0, "Removed the broken commands." + (failed > 0 ? " \(failed) couldn't be removed." : ""))
    }

    public struct Override: Sendable, Hashable {
        public let domain: String, key: String, label: String
    }

    static func truthy(_ s: String) -> Bool {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes"
    }

    /// Old tweaks that turn off App Nap for every app or skip checking disk images you open.
    public static func overrides(read: (String, String) -> String = { Shell.run(["defaults", "read", $0, $1], timeout: 5).out }) -> [Override] {
        var out: [Override] = []
        if truthy(read("-g", "NSAppSleepDisabled")) { out.append(Override(domain: "-g", key: "NSAppSleepDisabled", label: "App Nap turned off for every app")) }
        for k in ["skip-verify", "skip-verify-locked", "skip-verify-remote"] where truthy(read("com.apple.frameworks.diskimages", k)) {
            out.append(Override(domain: "com.apple.frameworks.diskimages", key: k, label: "disk images opened without checking (\(k))"))
        }
        return out
    }

    static func legacyOverrides() -> MaintenanceTask {
        let found = overrides()
        return MaintenanceTask(id: "overrides", title: "Restore app sleep and disk image checks", status: found.isEmpty ? .ok : .attention,
                               detail: found.isEmpty ? "No old tweaks turn off App Nap or skip disk-image checks."
                                                     : "Found: \(found.map(\.label).joined(separator: "; ")). These old tweaks cost battery or skip a safety check. Removing them restores macOS's default.",
                               paths: found.map { "\($0.domain) \($0.key)" }, fix: found.isEmpty ? .none : .run, fixLabel: "Restore defaults", group: .system)
    }

    static func restoreOverrides() -> (ok: Bool, message: String) {
        var items: [CleanReceipt.Item] = [], failed = 0
        for o in overrides() {
            let r = Shell.run(["defaults", "delete", o.domain, o.key], timeout: 5)
            if r.status != 0 { failed += 1 }
            items.append(.init(path: "defaults \(o.domain) \(o.key)", title: o.label, bytes: 0, action: "Restore default", ok: r.status == 0,
                               message: r.status == 0 ? "Removed. To undo: defaults write \(o.domain) \(o.key) -bool true" : "defaults failed.", trashedTo: nil))
        }
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: items, freeBefore: free, freeAfter: free))
        return (failed == 0, failed == 0 ? "macOS's defaults are back. Apps pick it up when they next open." : "\(failed) couldn't be changed.")
    }

    // MARK: Administrator tasks

    /// The only commands Sapu2 ever runs as administrator. Full paths, fixed text: nothing from a scan goes in.
    public static let adminCommands: [String: String] = [
        "dns": "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder",
        "periodic": "/usr/sbin/periodic daily weekly monthly",
        "permissions": "/usr/sbin/diskutil resetUserPermissions / \(getuid())",
        "purge": "/usr/sbin/purge",
    ]

    static func periodicMaintenance() -> MaintenanceTask? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/periodic") else { return nil }
        let last = DiskSizer.mtime("/var/log/daily.out")
        let stale = last.map { Date().timeIntervalSince($0) > 7 * 86_400 } ?? true
        return MaintenanceTask(id: "periodic", title: "Run periodic system maintenance", status: .info,
                               detail: (last.map { "Last ran \(RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()))." } ?? "No record that it has run.")
                                   + " macOS's daily, weekly and monthly scripts rotate system logs and tidy temporary files; they're skipped when the Mac sleeps at night."
                                   + (stale ? "" : " Running it again now changes little."),
                               fix: .admin(adminCommands["periodic"]!), fixLabel: "Run", group: .system)
    }

    /// Shown only when your Library is not owned by you, the case the reference repairs. Apple's tool, your account only.
    static func homePermissions() -> MaintenanceTask? {
        let owner = (try? FileManager.default.attributesOfItem(atPath: home + "/Library")[.ownerAccountID] as? NSNumber)?.uint32Value
        guard let owner, owner != getuid() else { return nil }
        return MaintenanceTask(id: "permissions", title: "Repair your home folder permissions", status: .attention,
                               detail: "Your Library folder belongs to another account, so apps can fail to save settings. macOS's own tool resets ownership of your home folder to you.",
                               fix: .admin(adminCommands["permissions"]!), fixLabel: "Repair", group: .system)
    }

    /// Shown only while memory is tight. macOS frees this memory itself; this only does it now.
    static func memoryPurge() -> MaintenanceTask? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0, level >= 2 else { return nil }
        return MaintenanceTask(id: "purge", title: "Purge inactive memory", status: .info,
                               detail: "Memory is tight. This drops file caches macOS keeps in memory; apps may be slower for a moment as they reload. Quitting apps you don't use helps more.",
                               fix: .admin(adminCommands["purge"]!), fixLabel: "Purge", group: .system)
    }

    /// macOS shows its own password dialog for this one command.
    public static func runAdmin(_ id: String) -> (ok: Bool, message: String) {
        guard let cmd = adminCommands[id] else { return (false, "Not an administrator task.") }
        let script = "do shell script \"\(cmd)\" with administrator privileges with prompt \"Sapu2 needs your password to run: \(cmd)\""
        let r = Shell.run(["osascript", "-e", script], timeout: 900)
        if r.status == 0 { return (true, "Done.") }
        if r.err.contains("-128") { return (false, "Cancelled. Nothing changed.") }
        return (false, "Didn't finish: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
    }

    // MARK: Running

    static func runOptimize(_ task: MaintenanceTask) -> (ok: Bool, message: String) {
        if let repair = repairs.first(where: { $0.id == task.id }) { return restart(repair.processes) }
        if case .admin = task.fix { return runAdmin(task.id) }
        switch task.id {
        case "diskimages": return ejectImages(task.paths)
        case "savedstate":
            let still = Set(oldSavedStates(running: runningBundleIDs))
            return trashAll(task.paths.filter(still.contains), action: task.fixLabel)
        case "notifications":
            guard let db = notificationDB else { return (false, "Notification Center's database isn't readable.") }
            return pruneNotifications(db)
        case "spotlightrules": return pruneSpotlightRules(task.paths)
        case "sharedlists":
            let still = Set(brokenSharedLists())
            return trashAll(task.paths.filter(still.contains), action: task.fixLabel)
        case "commandlinks": return removeLinks(task.paths)
        case "overrides": return restoreOverrides()
        default: return (false, "Nothing to run.")
        }
    }

    public static func trashAll(_ paths: [String], action: String) -> (ok: Bool, message: String) {
        guard !paths.isEmpty else { return (true, "Nothing left to move.") }
        var items: [CleanReceipt.Item] = [], moved = 0
        let before = SystemProbe.volume().free
        for p in paths {
            let bytes = DiskSizer.size(p).bytes
            let (ok, msg, to) = Cleaner.trash(p)
            if ok { moved += 1 }
            items.append(.init(path: p, title: p.lastComponent, bytes: bytes, action: action, ok: ok, message: msg, trashedTo: to))
        }
        Cleaner.save(CleanReceipt(date: Date(), items: items, freeBefore: before, freeAfter: SystemProbe.volume().free))
        return (moved == paths.count, "Moved \(moved) of \(paths.count) to the Trash.")
    }

    /// Copies files into one dated folder and puts that folder in the Trash, so a change can be undone by hand.
    static func backupToTrash(_ files: [String], name: String) -> (ok: Bool, trashedTo: String?) {
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "-")
        let dir = NSTemporaryDirectory() + "\(name) \(stamp)"
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { return (false, nil) }
        for f in files where fm.fileExists(atPath: f) {
            guard (try? fm.copyItem(atPath: f, toPath: dir + "/" + f.lastComponent)) != nil else { return (false, nil) }
        }
        let (ok, _, to) = Cleaner.trash(dir)
        return (ok, to)
    }

    static func record(_ path: String, _ title: String, _ ok: Bool, _ message: String, _ trashedTo: String?) {
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: path, title: title, bytes: 0, action: "Optimize", ok: ok, message: message, trashedTo: trashedTo)],
                                  freeBefore: free, freeAfter: free))
    }
}
