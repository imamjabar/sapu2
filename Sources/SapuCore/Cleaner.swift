import Darwin
import Foundation

public struct CleanReceipt: Codable, Sendable, Identifiable {
    public struct Item: Codable, Sendable, Hashable {
        public var path: String
        public var title: String
        public var bytes: Int64
        public var action: String
        public var ok: Bool
        public var message: String
        /// Where the item went in the Trash, for restoring.
        public var trashedTo: String?
    }
    public var id: String { date.ISO8601Format() }
    public var date: Date
    public var items: [Item]
    public var freeBefore: Int64
    public var freeAfter: Int64

    public var cleanedBytes: Int64 { items.filter(\.ok).reduce(0) { $0 + $1.bytes } }
}

/// Last line of defence. Every path is checked here right before it is touched, whatever the UI allowed.
public enum SafetyGuard {
    static let home = NSHomeDirectory()

    static let protectedFragments = [
        "/Library/Keychains", "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Mail", "/Library/Messages",
        "/Library/Application Support/MobileSync", "/Library/Photos", "/Library/Safari", "/Library/Cookies",
        "/Library/Accounts", "/Library/Calendars", "/Library/Group Containers/group.com.apple",
        "/.ssh", "/.gnupg", "/.aws", "/.config/gcloud", "/.kube", "/.docker/config.json",
        ".photoslibrary", "/Library/Application Support/1Password", "/Library/Application Support/Bitwarden",
    ]
    static let secretSuffixes = [".pem", ".key", ".p12", ".keystore", ".jks", ".kdbx"]
    static let homeTopLevel: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications"]
    static let allowedRoots = [home + "/", "/Applications/", "/opt/homebrew/var/log/"]

    /// nil when the path may be cleaned, otherwise the reason it may not.
    public static func refusal(for f: Finding, allowActiveProjects: Bool) -> String? {
        let p = (f.path as NSString).standardizingPath
        if f.safety == .protected { return "Protected item." }
        if f.action == .none { return "Information only." }
        if let lock = f.lockedReason, !(allowActiveProjects && lock.hasPrefix("Active project")) { return lock }
        guard allowedRoots.contains(where: p.hasPrefix) else { return "Outside the folders Sapu may change." }
        if protectedFragments.contains(where: p.contains) { return "Protected location." }
        let name = p.lastComponent
        if name.hasPrefix(".env") || secretSuffixes.contains(where: name.hasSuffix) { return "Looks like secrets." }
        if p == home || p.parentPath == home && homeTopLevel.contains(name) { return "Never removes a home folder itself." }
        if p == home + "/Library" || p.parentPath == home + "/Library" { return "Never removes a top-level Library folder." }
        if DiskSizer.isSymlink(p) { return "Symlink; Sapu never follows or removes links." }
        if !DiskSizer.exists(p) { return "Already gone." }
        return nil
    }
}

public enum Cleaner {
    public static func clean(_ findings: [Finding], allowActiveProjects: Bool,
                             progress: (Int, String) -> Void = { _, _ in }) -> CleanReceipt {
        let before = SystemProbe.volume().free
        var items: [CleanReceipt.Item] = []
        var ranCommands = Set<String>()
        for (i, f) in findings.enumerated() {
            progress(i, f.title)
            var item = CleanReceipt.Item(path: f.path, title: f.title, bytes: f.bytes, action: f.action.label, ok: false, message: "", trashedTo: nil)
            if let why = SafetyGuard.refusal(for: f, allowActiveProjects: allowActiveProjects) {
                item.message = "Skipped: \(why)"
                items.append(item); continue
            }
            switch f.action {
            case .trash:
                (item.ok, item.message, item.trashedTo) = trash(f.path)
            case .freezeThenTrash:
                let freeze = freezeVenv(f.path)
                (item.ok, item.message, item.trashedTo) = trash(f.path)
                item.message = freeze + " " + item.message
            case .command(let cmd):
                if ranCommands.contains(cmd) { item.ok = true; item.message = "Covered by the same command above."; break }
                ranCommands.insert(cmd)
                let r = Shell.run(Shell.split(cmd), cwd: NSHomeDirectory(), timeout: 900)
                item.ok = r.status == 0
                item.message = r.status == 0 ? "Ran \(cmd)" : "\(cmd) failed (\(r.status)): \((r.err + r.out).suffix(300))"
            case .truncateLogs:
                (item.ok, item.message) = truncateLogs(f.path)
            case .none:
                item.message = "Info only."
            }
            items.append(item)
        }
        let receipt = CleanReceipt(date: Date(), items: items, freeBefore: before, freeAfter: SystemProbe.volume().free)
        save(receipt)
        return receipt
    }

    static func trash(_ path: String) -> (Bool, String, String?) {
        var result: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            return (true, "Moved to Trash.", result?.path)
        } catch {
            return (false, "Could not move to Trash: \(error.localizedDescription)", nil)
        }
    }

    /// Save installed packages next to the project before a venv goes away.
    static func freezeVenv(_ venv: String) -> String {
        let py = venv + "/bin/python"
        guard FileManager.default.isExecutableFile(atPath: py) else { return "No python in venv; nothing frozen." }
        let r = Shell.run([py, "-m", "pip", "freeze"], timeout: 60)
        guard r.status == 0, !r.out.isEmpty else { return "pip freeze failed; venv still trashed (restorable)." }
        let day = Date().ISO8601Format(.iso8601.year().month().day())
        let out = venv.parentPath + "/requirements-freeze-\(day).txt"
        do {
            try r.out.write(toFile: out, atomically: true, encoding: .utf8)
            return "Saved \(out.lastComponent)."
        } catch { return "Could not write \(out.lastComponent)." }
    }

    /// Empty `*.log` files in place (a file, or files up to two levels inside a folder).
    public static func truncateLogs(_ path: String) -> (Bool, String) {
        var files: [String] = []
        if DiskSizer.isDirectory(path) {
            for c in DiskSizer.children(path) {
                if DiskSizer.isDirectory(c) { files += DiskSizer.children(c).filter(isLog) } else if isLog(c) { files.append(c) }
            }
        } else if isLog(path) || path.contains("/var/log/") || path.contains("/logs/") {
            files = [path]
        }
        files = files.filter { !DiskSizer.isSymlink($0) }
        guard !files.isEmpty else { return (false, "No log files found.") }
        var failed = 0
        for f in files where truncate(f, 0) != 0 { failed += 1 }
        return (failed == 0, failed == 0 ? "Emptied \(files.count) log file(s)." : "\(failed) of \(files.count) could not be emptied (permission).")
    }

    static func isLog(_ p: String) -> Bool {
        let n = p.lastComponent
        return n.hasSuffix(".log") || n.contains(".log.") || n.hasSuffix("_log") || n.hasSuffix(".err")
    }

    static func save(_ r: CleanReceipt) {
        let dir = Store.receiptsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = r.date.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(r).write(to: dir.appendingPathComponent("receipt-\(stamp).json"))
        var md = "# Sapu cleanup receipt — \(r.date.formatted())\n\n"
        md += "Free before: \(Format.bytes(r.freeBefore)) · after: \(Format.bytes(r.freeAfter))\n\n"
        md += "| Item | Size | Action | Result | Restore |\n|---|---|---|---|---|\n"
        for i in r.items {
            md += "| \(i.title) | \(Format.bytes(i.bytes)) | \(i.action) | \(i.ok ? "✅" : "⚠️") \(i.message) | \(i.trashedTo.map { "Put back from Trash: `\($0.tildePath)` → `\(i.path.tildePath)`" } ?? "—") |\n"
        }
        try? md.write(to: dir.appendingPathComponent("receipt-\(stamp).md"), atomically: true, encoding: .utf8)
    }
}
