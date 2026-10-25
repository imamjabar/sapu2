import Foundation

/// A check with an optional fix. Fixes Sapu can do as you go through the Trash or a user-level
/// macOS tool; anything needing an administrator password is shown as a command for you to run.
public struct MaintenanceTask: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable { case ok, attention, info }
    public enum Fix: Codable, Sendable, Hashable {
        /// Sapu can do it now.
        case run
        /// Needs an administrator: the command to paste into Terminal.
        case terminal(String)
        case none
    }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    /// Files the fix acts on (shown so you can see exactly what changes).
    public var paths: [String] = []
    public var fix: Fix
    public var fixLabel: String = "Fix"
}

public enum Maintenance {
    static let home = NSHomeDirectory()

    public static func check() -> [MaintenanceTask] {
        [brokenLaunchAgents(), brokenPreferences(), quickLook(), dsStore(), launchServices(), dns(), snapshots(), brewAutoremove(),
         downloadHistory(), brewOutdated()].compactMap { $0 }
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
            return (false, "Nothing to run.")
        }
    }

    // MARK: Checks

    /// Launch agents whose program no longer exists. launchd keeps trying (and logging) at every login.
    static func brokenLaunchAgents() -> MaintenanceTask {
        let dir = home + "/Library/LaunchAgents"
        var broken: [String] = []
        for plist in DiskSizer.children(dir, includeHidden: false) where plist.hasSuffix(".plist") && !plist.lastComponent.hasPrefix("com.apple.") {
            guard let program = Uninstaller.agentProgram(plist), program.hasPrefix("/") else { continue }
            if !FileManager.default.fileExists(atPath: program) { broken.append(plist) }
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
        MaintenanceTask(id: "quicklook", title: "Refresh Quick Look thumbnails", status: .info,
                        detail: "Fixes wrong or blank previews in Finder and the spacebar preview. Thumbnails are redrawn on demand.",
                        fix: .run, fixLabel: "Refresh")
    }

    static func dsStore() -> MaintenanceTask {
        let net = Shell.run(["defaults", "read", "com.apple.desktopservices", "DSDontWriteNetworkStores"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let usb = Shell.run(["defaults", "read", "com.apple.desktopservices", "DSDontWriteUSBStores"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let on = net == "1" && usb == "1"
        return MaintenanceTask(id: "dsstore", title: "Stop .DS_Store files on shared drives", status: on ? .ok : .info,
                               detail: on ? "Finder doesn't leave .DS_Store files on network shares and USB drives."
                                          : "Finder leaves a hidden .DS_Store in every folder you open on network shares and USB drives, which shows up on Windows and in git.",
                               fix: on ? .none : .run, fixLabel: "Turn off")
    }

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static func launchServices() -> MaintenanceTask {
        MaintenanceTask(id: "lsregister", title: "Rebuild the \"Open With\" list", status: .info,
                        detail: "Removes duplicates and apps you deleted from the Open With menu and file-type choices. Takes a minute.",
                        fix: .run, fixLabel: "Rebuild")
    }

    static func dns() -> MaintenanceTask {
        MaintenanceTask(id: "dns", title: "Flush the DNS cache", status: .info,
                        detail: "Helps when one website won't load after a DNS or VPN change. Needs your administrator password, so run it in Terminal.",
                        fix: .terminal("sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"))
    }

    static func snapshots() -> MaintenanceTask? {
        let n = SystemProbe.localSnapshots()
        guard n > 0 else { return nil }
        return MaintenanceTask(id: "snapshots", title: "Time Machine local snapshots", status: n > 3 ? .attention : .info,
                               detail: "\(n) local snapshot(s) hold deleted files until macOS needs the space. Finder counts them as purgeable. Thinning them frees that space now.",
                               fix: .terminal("tmutil thinlocalsnapshots / 999999999999 4"))
    }

    static let quarantineDB = home + "/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

    /// macOS records every file you download, with the web address it came from. It is never trimmed.
    static func downloadHistory() -> MaintenanceTask? {
        guard FileManager.default.fileExists(atPath: quarantineDB) else { return nil }
        let n = Int(Shell.run(["sqlite3", "-readonly", quarantineDB, "select count(*) from LSQuarantineEvent"], timeout: 10).out
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return MaintenanceTask(id: "quarantine", title: "Download history", status: .info,
                               detail: n == 0 ? "macOS's list of downloaded files is empty."
                                              : "macOS keeps a list of all \(n) files you downloaded and the web address of each. Clearing it is for privacy; the \"downloaded from the internet\" check on your files stays. A copy goes to the Trash first.",
                               paths: [quarantineDB], fix: n == 0 ? .none : .run, fixLabel: "Clear history")
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
                               fix: names.isEmpty ? .none : .terminal("brew upgrade"))
    }

    static var brew: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) }
    static func brewAutoremove() -> MaintenanceTask? {
        guard let brew else { return nil }
        let r = Shell.run([brew, "autoremove", "--dry-run"], timeout: 60)
        let lines = r.out.split(separator: "\n").filter { !$0.hasPrefix("==>") }.map(String.init)
        return MaintenanceTask(id: "brew", title: "Unused Homebrew dependencies", status: lines.isEmpty ? .ok : .attention,
                               detail: lines.isEmpty ? "Every Homebrew dependency is still used by something you installed."
                                                     : "\(lines.count) package(s) were installed as dependencies of something you since removed: \(lines.prefix(8).joined(separator: ", "))\(lines.count > 8 ? "…" : "").",
                               fix: lines.isEmpty ? .none : .run, fixLabel: "brew autoremove")
    }
}
