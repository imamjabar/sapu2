import Foundation

/// A launch agent or daemon that starts something at login or in the background.
public struct StartupItem: Codable, Sendable, Identifiable, Hashable {
    public enum Scope: String, Codable, Sendable {
        /// ~/Library/LaunchAgents: yours, Sapu2 can turn it off and on.
        case user
        /// /Library/LaunchAgents and /Library/LaunchDaemons: shown only (outside your home, needs an administrator).
        case system
    }
    public var id: String { plist }
    public var plist: String
    public var label: String
    public var program: String?
    public var scope: Scope
    /// Running or waiting in launchd now.
    public var loaded: Bool
    /// Turned off with `launchctl disable`, so it stays off after a restart.
    public var disabled: Bool
    /// The program it starts no longer exists: a leftover of a removed app.
    public var programMissing: Bool
    /// The app it belongs to, when its program lives inside one.
    public var app: String?

    public init(plist: String, label: String, program: String?, scope: Scope, loaded: Bool, disabled: Bool, programMissing: Bool, app: String?) {
        self.plist = plist; self.label = label; self.program = program; self.scope = scope; self.loaded = loaded
        self.disabled = disabled; self.programMissing = programMissing; self.app = app
    }
}

/// Startup items, turned off and on the way macOS does it (launchctl), never by deleting them.
/// Only leftovers whose program is gone can be removed, and those go to the Trash with a receipt.
public enum Startup {
    static let home = NSHomeDirectory()
    static var domain: String { "gui/\(getuid())" }

    public static func list() -> [StartupItem] {
        let loaded = loadedLabels(Shell.run(["launchctl", "list"], timeout: 10).out)
        let disabled = disabledLabels(Shell.run(["launchctl", "print-disabled", domain], timeout: 10).out)
        var out: [StartupItem] = []
        for (dir, scope) in [(home + "/Library/LaunchAgents", StartupItem.Scope.user),
                             ("/Library/LaunchAgents", .system), ("/Library/LaunchDaemons", .system)] {
            for plist in DiskSizer.children(dir, includeHidden: false) where plist.hasSuffix(".plist") && !DiskSizer.isSymlink(plist) {
                guard let item = item(plist, scope: scope, loaded: loaded, disabled: disabled) else { continue }
                out.append(item)
            }
        }
        return out.sorted { ($0.scope == .user ? 0 : 1, $0.label.lowercased()) < ($1.scope == .user ? 0 : 1, $1.label.lowercased()) }
    }

    static func item(_ plist: String, scope: StartupItem.Scope, loaded: Set<String>, disabled: Set<String>) -> StartupItem? {
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let label = dict["Label"] as? String ?? plist.lastComponent.replacingOccurrences(of: ".plist", with: "")
        // Apple's own agents are part of macOS.
        if label.hasPrefix("com.apple.") { return nil }
        let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
        let missing = program.map { $0.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0) } ?? false
        let app = program.flatMap { p -> String? in
            guard let r = p.range(of: ".app/") else { return nil }
            return (String(p[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return StartupItem(plist: plist, label: label, program: program, scope: scope, loaded: loaded.contains(label),
                           disabled: disabled.contains(label), programMissing: missing, app: app)
    }

    /// Labels in `launchctl list` output ("PID\tStatus\tLabel").
    public static func loadedLabels(_ out: String) -> Set<String> {
        Set(out.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            return cols.count >= 3 ? String(cols[2]) : nil
        })
    }

    /// Labels `launchctl print-disabled` reports as disabled (`"label" => disabled` or `=> true`).
    public static func disabledLabels(_ out: String) -> Set<String> {
        var s = Set<String>()
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("\""), let end = t.dropFirst().firstIndex(of: "\"") else { continue }
            let label = String(t[t.index(after: t.startIndex)..<end])
            let value = t[t.index(after: end)...].lowercased()
            if value.contains("disabled") || value.contains("true") { s.insert(label) }
        }
        return s
    }

    /// The Homebrew formula behind a `brew services` item (homebrew.mxcl.php@8.1 → php@8.1).
    public static func brewService(_ i: StartupItem) -> String? {
        i.label.hasPrefix("homebrew.mxcl.") ? String(i.label.dropFirst("homebrew.mxcl.".count)) : nil
    }

    /// Stops it now and keeps it off after restarts. The file stays where it is (Homebrew services use `brew services`).
    public static func turnOff(_ i: StartupItem) -> (ok: Bool, message: String) {
        guard i.scope == .user else { return (false, "System items need an administrator. Turn it off in the app that installed it.") }
        if let f = brewService(i), let brew = Maintenance.brew {
            let r = Shell.run([brew, "services", "stop", f], timeout: 60)
            return r.status == 0 ? (true, "Stopped with brew services. Start it again with: brew services start \(f)")
                                 : (false, "brew services stop \(f) failed: \(r.err.suffix(200))")
        }
        _ = Shell.run(["launchctl", "bootout", domain, i.plist], timeout: 15)   // fails harmlessly when not running
        let r = Shell.run(["launchctl", "disable", "\(domain)/\(i.label)"], timeout: 10)
        return r.status == 0 ? (true, "Turned off. It won't start at login; Turn on brings it back.")
                             : (false, "launchctl disable failed: \(r.err.suffix(200))")
    }

    /// Allows it again and starts it.
    public static func turnOn(_ i: StartupItem) -> (ok: Bool, message: String) {
        guard i.scope == .user else { return (false, "System items need an administrator.") }
        if let f = brewService(i), let brew = Maintenance.brew {
            let r = Shell.run([brew, "services", "start", f], timeout: 60)
            return r.status == 0 ? (true, "Started with brew services.") : (false, "brew services start \(f) failed: \(r.err.suffix(200))")
        }
        let r = Shell.run(["launchctl", "enable", "\(domain)/\(i.label)"], timeout: 10)
        guard r.status == 0 else { return (false, "launchctl enable failed: \(r.err.suffix(200))") }
        let b = Shell.run(["launchctl", "bootstrap", domain, i.plist], timeout: 15)
        // 5 / 37: already loaded. The item is allowed again either way.
        return (true, b.status == 0 || b.status == 5 || b.status == 37 ? "Turned on." : "Turned on; it starts at your next login.")
    }

    /// Leftovers only: an item whose program is gone is stopped and moved to the Trash, with a receipt.
    public static func removeLeftover(_ i: StartupItem) -> (ok: Bool, message: String) {
        guard i.scope == .user, i.programMissing, i.plist.hasPrefix(home + "/Library/LaunchAgents/") else {
            return (false, "Only leftovers of removed apps can be removed. Turn this one off instead.")
        }
        _ = Shell.run(["launchctl", "bootout", domain, i.plist], timeout: 15)
        let (ok, msg, to) = Cleaner.trash(i.plist)
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: i.plist, title: "Startup item \(i.label)", bytes: 0, action: "Remove leftover",
                                                              ok: ok, message: msg, trashedTo: to)], freeBefore: free, freeAfter: free))
        return (ok, ok ? "Moved to the Trash. Receipts can put it back." : msg)
    }

    /// System Settings › General › Login Items & Extensions, where apps' own login items are switched.
    public static let loginItemsSettings = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
}
