import Foundation

/// A check with an optional fix. Fixes Sapu2 can do as you go through the Trash or a user-level
/// macOS tool; a few need your administrator password, asked by macOS for that one command.
public struct MaintenanceTask: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable { case ok, attention, info }
    public enum Fix: Codable, Sendable, Hashable {
        /// Sapu2 can do it now.
        case run
        /// Sapu2 runs this exact command after macOS asks for your administrator password.
        case admin(String)
        /// The command to paste into Terminal.
        case terminal(String)
        case none
    }
    /// The sections of the Optimize view, in the reference cleaner's order.
    public enum Group: String, Codable, Sendable, CaseIterable {
        case quickFix = "Quick fixes"
        case launchSpeed = "Launch speed"
        case databases = "System databases"
        case network = "Network & search"
        case system = "System maintenance"
        case developer = "Developer tools"

        public var promise: String {
            switch self {
            case .quickFix: "Restart one part of macOS that stopped responding. macOS starts it again at once; nothing is deleted."
            case .launchSpeed: "Rebuild lists and caches macOS uses to open apps and draw previews."
            case .databases: "Trim records macOS keeps forever. A backup copy goes to the Trash first."
            case .network: "DNS, Spotlight and network-drive settings."
            case .system: "Leftovers of removed apps and damaged settings files. Everything removed goes to the Trash."
            case .developer: "Homebrew housekeeping."
            }
        }
        public var symbol: String {
            switch self {
            case .quickFix: "bolt.horizontal.circle"
            case .launchSpeed: "hare"
            case .databases: "cylinder.split.1x2"
            case .network: "network"
            case .system: "gearshape.2"
            case .developer: "hammer"
            }
        }
    }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// Files the fix acts on (shown so you can see exactly what changes).
    public var paths: [String] = []
    public var fix: Fix
    public var fixLabel: String = "Fix"
    public var group: Group = .system
}

public enum Maintenance {
    public static let home = NSHomeDirectory()

    /// Every check, in display order. They run side by side (the Homebrew ones take a second or two each), and
    /// `progress` hears how many are done so the view can count up instead of looking stuck.
    public static func check(progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) -> [MaintenanceTask] {
        let checks: [@Sendable () -> [MaintenanceTask]] = [
            { repairTasks() },
            { [quickLook()] }, { [launchServices()] }, { [diskImages()].compactMap { $0 } }, { [savedStates()].compactMap { $0 } },
            { [downloadHistory()].compactMap { $0 } }, { [notificationRecords()].compactMap { $0 } },
            { [dns()] }, { [spotlightRules()].compactMap { $0 } }, { [dsStore()] },
            { [brokenLaunchAgents()] }, { [brokenPreferences()] }, { [sharedFileLists()].compactMap { $0 } },
            { [commandLinks()].compactMap { $0 } }, { [legacyOverrides()] }, { [snapshots()].compactMap { $0 } },
            { [periodicMaintenance()].compactMap { $0 } }, { [homePermissions()].compactMap { $0 } }, { [memoryPurge()].compactMap { $0 } },
            { [brewAutoremove()].compactMap { $0 } }, { [brewOutdated()].compactMap { $0 } },
        ]
        let results = Locked([[MaintenanceTask]](repeating: [], count: checks.count))
        let done = Locked(0)
        DispatchQueue.concurrentPerform(iterations: checks.count) { i in
            let r = checks[i]()
            results.mutate { $0[i] = r }
            var n = 0
            done.mutate { $0 += 1; n = $0 }
            progress?(n, checks.count)
        }
        return results.value.flatMap { $0 }
    }

    /// Runs one task's fix. Removals go to the Trash and are written to a receipt.
    public static func run(_ task: MaintenanceTask) -> (ok: Bool, message: String) {
        switch task.id {
        case "agents", "prefs":
            var moved = 0
            var items: [CleanReceipt.Item] = []
            for p in task.paths {
                if task.id == "agents" { _ = Shell.run(["launchctl", "bootout", "gui/\(getuid())", p], timeout: 10) }
                let (ok, msg, to) = Cleaner.trash(p)
                if ok { moved += 1 }
                items.append(.init(path: p, title: p.lastComponent, bytes: 0, action: task.fixLabel, ok: ok, message: msg, trashedTo: to))
            }
            let free = SystemProbe.volume().free
            Cleaner.save(CleanReceipt(date: Date(), items: items, freeBefore: free, freeAfter: free))
            return (moved == task.paths.count, "Moved \(moved) of \(task.paths.count) to the Trash.")
        case "quicklook":
            let r = Shell.run(["qlmanage", "-r", "cache"], timeout: 30)
            _ = Shell.run(["qlmanage", "-r"], timeout: 30)
            return (r.status == 0, r.status == 0 ? "Thumbnails will be redrawn as Finder needs them." : "qlmanage failed.")
        case "dsstore":
            let a = Shell.run(["defaults", "write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"], timeout: 5)
            let b = Shell.run(["defaults", "write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"], timeout: 5)
            return (a.status == 0 && b.status == 0, "Finder stops writing .DS_Store files on network and USB drives (after you log out and in).")
        case "lsregister":
            let r = Shell.run([lsregister, "-kill", "-r", "-domain", "local", "-domain", "user"], timeout: 300)
            return (r.status == 0, r.status == 0 ? "Rebuilt. \"Open With\" lists only installed apps again." : "lsregister failed.")
        case "brew":
            let r = Shell.run([brew ?? "brew", "autoremove"], timeout: 600)
            return (r.status == 0, r.status == 0 ? "Removed unused Homebrew dependencies." : "brew autoremove failed: \(r.err.suffix(200))")
        case "quarantine":
            return clearDownloadHistory()
        default:
            return runOptimize(task)
        }
    }

    // MARK: Checks

    /// Launch agents whose program no longer exists. launchd keeps trying (and logging) at every login.
    static func brokenLaunchAgents() -> MaintenanceTask {
        let dir = home + "/Library/LaunchAgents"
        var broken: [String] = []
        for plist in DiskSizer.children(dir, includeHidden: false) where plist.hasSuffix(".plist") && !plist.lastComponent.hasPrefix("com.apple.") {
            guard let program = Uninstaller.agentProgram(plist), program.hasPrefix("/") else { continue }
            if !FileManager.default.fileExists(atPath: program), volumeMounted(program) { broken.append(plist) }
        }
        let names = broken.map { $0.lastComponent.replacingOccurrences(of: ".plist", with: "") }
        return MaintenanceTask(id: "agents", title: "Background items for removed apps", status: broken.isEmpty ? .ok : .attention,
                               detail: broken.isEmpty ? "Every login item in ~/Library/LaunchAgents points to a program that exists."
                                                      : "\(broken.count) item(s) start a program that is gone: \(names.joined(separator: ", ")). macOS retries them at every login.",
                               paths: broken, fix: broken.isEmpty ? .none : .run, fixLabel: "Unload and move to Trash")
    }

    /// Preference files that no longer parse. The app then starts with defaults or crashes.
    static func brokenPreferences() -> MaintenanceTask {
        let dir = home + "/Library/Preferences"
        var broken: [String] = []
        for p in DiskSizer.children(dir, includeHidden: false) where p.hasSuffix(".plist") && !p.lastComponent.hasPrefix("com.apple.") {
            guard let data = FileManager.default.contents(atPath: p), !data.isEmpty else { continue }
            if (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil { broken.append(p) }
        }
        return MaintenanceTask(id: "prefs", title: "Damaged settings files", status: broken.isEmpty ? .ok : .attention,
                               detail: broken.isEmpty ? "All app settings files in ~/Library/Preferences can be read."
                                                      : "\(broken.count) settings file(s) can't be read: \(broken.map(\.lastComponent).joined(separator: ", ")). The app recreates them with defaults.",
                               paths: broken, fix: broken.isEmpty ? .none : .run, fixLabel: "Move to Trash")
    }

    static func quickLook() -> MaintenanceTask {
        MaintenanceTask(id: "quicklook", title: "Refresh Quick Look thumbnails and icons", status: .info,
                        detail: "Fixes wrong or blank previews and icons in Finder and the spacebar preview. They're redrawn as Finder needs them.",
                        fix: .run, fixLabel: "Refresh", group: .launchSpeed)
    }

    static func dsStore() -> MaintenanceTask {
        let net = Shell.run(["defaults", "read", "com.apple.desktopservices", "DSDontWriteNetworkStores"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let usb = Shell.run(["defaults", "read", "com.apple.desktopservices", "DSDontWriteUSBStores"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let on = net == "1" && usb == "1"
        return MaintenanceTask(id: "dsstore", title: "Stop .DS_Store files on shared drives", status: on ? .ok : .info,
                               detail: on ? "Finder doesn't leave .DS_Store files on network shares and USB drives."
                                          : "Finder leaves a hidden .DS_Store in every folder you open on network shares and USB drives, which shows up on Windows and in git.",
                               fix: on ? .none : .run, fixLabel: "Turn off", group: .network)
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static func launchServices() -> MaintenanceTask {
        MaintenanceTask(id: "lsregister", title: "Rebuild the \"Open With\" list", status: .info,
                        detail: "Removes duplicates and apps you deleted from the Open With menu and file-type choices. Takes a minute.",
                        fix: .run, fixLabel: "Rebuild", group: .launchSpeed)
    }

    /// macOS's own DNS reset. Skipped while a VPN is connected: the VPN owns DNS then and reconnects on its own.
    static func dns() -> MaintenanceTask {
        let vpn = Shell.run(["scutil", "--nc", "list"], timeout: 5).out.contains("(Connected)")
        return MaintenanceTask(id: "dns", title: "Flush the DNS cache", status: .info,
                               detail: vpn ? "A VPN is connected and manages DNS right now. Disconnect it first if one website won't load."
                                           : "Helps when one website won't load after a DNS or VPN change. macOS asks for your administrator password for this one command.",
                               fix: vpn ? .none : .admin(adminCommands["dns"]!), fixLabel: "Flush", group: .network)
    }

    static func snapshots() -> MaintenanceTask? {
        let n = SystemProbe.localSnapshots()
        guard n > 0 else { return nil }
        return MaintenanceTask(id: "snapshots", title: "Time Machine local snapshots", status: n > 3 ? .attention : .info,
                               detail: "\(n) local snapshot(s) hold deleted files until macOS needs the space. Finder counts them as purgeable. Thinning them frees that space now.",
                               fix: .terminal("tmutil thinlocalsnapshots / 999999999999 4"), group: .system)
    }

    static let quarantineDB = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

    /// macOS records every file you download, with the web address it came from. It is never trimmed.
    static func downloadHistory() -> MaintenanceTask? {
        guard FileManager.default.fileExists(atPath: quarantineDB) else { return nil }
        let n = Int(Shell.run(["sqlite3", "-readonly", quarantineDB, "select count(*) from LSQuarantineEvent"], timeout: 10).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return MaintenanceTask(id: "quarantine", title: "Download history", status: n == 0 ? .ok : .info,
                               detail: n == 0 ? "macOS's list of downloaded files is empty."
                                              : "macOS keeps a list of all \(n) files you downloaded and the web address of each. Clearing it is for privacy; the \"downloaded from the internet\" check on your files stays. A copy goes to the Trash first.",
                               paths: [quarantineDB], fix: n == 0 ? .none : .run, fixLabel: "Clear history", group: .databases)
    }

    /// Copies the database to the Trash (listed in Receipts), then empties it.
    static func clearDownloadHistory() -> (ok: Bool, message: String) {
        let stamp = Date().ISO8601Format(.iso8601.year().month().day())
        let copy = NSTemporaryDirectory() + "QuarantineEventsV2 backup \(stamp)"
        try? FileManager.default.removeItem(atPath: copy)
        guard (try? FileManager.default.copyItem(atPath: quarantineDB, toPath: copy)) != nil else { return (false, "Couldn't make a backup copy; nothing was cleared.") }
        let (moved, msg, to) = Cleaner.trash(copy)
        guard moved else { return (false, "Couldn't put the backup in the Trash (\(msg)); nothing was cleared.") }
        let r = Shell.run(["sqlite3", quarantineDB, "delete from LSQuarantineEvent; vacuum;"], timeout: 30)
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: quarantineDB, title: "Download history (backup copy)", bytes: 0, action: "Clear history",
                                                              ok: r.status == 0, message: r.status == 0 ? "Cleared. The backup copy is in the Trash." : "sqlite3 failed: \(r.err.suffix(200))",
                                                              trashedTo: to)], freeBefore: free, freeAfter: free))
        return r.status == 0 ? (true, "Cleared. A backup copy is in the Trash.") : (false, "Couldn't clear it: \(r.err.suffix(200))")
    }

    /// Homebrew packages with a newer version (read from Homebrew's own records, nothing downloaded or changed).
    static func brewOutdated() -> MaintenanceTask? {
        guard let brew else { return nil }
        let r = Shell.run(["/usr/bin/env", "HOMEBREW_NO_AUTO_UPDATE=1", brew, "outdated", "--quiet"], timeout: 60)
        let names = r.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return MaintenanceTask(id: "brewoutdated", title: "Homebrew updates", status: names.isEmpty ? .ok : .info,
                               detail: names.isEmpty ? "Every Homebrew package is up to date (as of Homebrew's last update check)."
                                                     : "\(names.count) package(s) have a newer version: \(names.prefix(10).joined(separator: ", "))\(names.count > 10 ? "…" : ""). Updating can change versions your projects use, so it's yours to run.",
                               fix: names.isEmpty ? .none : .terminal("brew upgrade"), group: .developer)
    }

    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) }
    static func brewAutoremove() -> MaintenanceTask? {
        guard let brew else { return nil }
        let r = Shell.run([brew, "autoremove", "--dry-run"], timeout: 60)
        let lines = r.out.split(separator: "\n").filter { !$0.hasPrefix("==>") }.map(String.init)
        return MaintenanceTask(id: "brew", title: "Unused Homebrew dependencies", status: lines.isEmpty ? .ok : .attention,
                               detail: lines.isEmpty ? "Every Homebrew dependency is still used by something you installed."
                                                     : "\(lines.count) package(s) were installed as dependencies of something you since removed: \(lines.prefix(8).joined(separator: ", "))\(lines.count > 8 ? "…" : "").",
                               fix: lines.isEmpty ? .none : .run, fixLabel: "brew autoremove", group: .developer)
    }
}
