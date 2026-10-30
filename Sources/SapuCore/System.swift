import AppKit
import Darwin
import Foundation

public enum SystemProbe {
    public static func volume() -> VolumeInfo {
        var v = capacity()
        v.swapBytes = swapUsed()
        v.localSnapshots = localSnapshots()
        return v
    }

    /// Disk size and free space only: one cheap call, safe to repeat while measuring.
    public static func capacity() -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = Int64(v?.volumeAvailableCapacity ?? 0)
        let avail = v?.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeInfo(total: total, free: free, available: max(avail, free), swapBytes: 0, localSnapshots: 0)
    }

    public static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    public static func localSnapshots() -> Int {
        let r = Shell.run(["tmutil", "listlocalsnapshots", "/"], timeout: 5)
        return r.out.split(separator: "\n").filter { $0.contains("com.apple") }.count
    }

    /// Executable names of everything running, to avoid touching files of open apps.
    public static func runningProcessNames() -> Set<String> {
        let r = Shell.run(["ps", "-axo", "comm="], timeout: 5)
        var names = Set(r.out.split(separator: "\n").map { String($0).lastComponent.trimmingCharacters(in: .whitespaces) })
        for app in NSWorkspace.shared.runningApplications {
            if let n = app.executableURL?.lastPathComponent { names.insert(n) }
            if let n = app.localizedName { names.insert(n) }
        }
        return names
    }

    /// "com.tinyspeck.slackmacgap" → ("Slack", "Slack") via LaunchServices.
    public static func app(forBundleID id: String) -> (name: String, executable: String?)? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let exe = Bundle(url: url)?.executableURL?.lastPathComponent
        return (url.deletingPathExtension().lastPathComponent, exe)
    }

    /// When an app was last used. Spotlight's "last opened" is often missing (Microsoft Office,
    /// apps launched from the Dock or by Login Items), so the newest of these counts:
    /// Spotlight, the app's own preferences (sandboxed or not), its saved window state, and the files
    /// it writes in its own Application Support folder (Chrome, Electron apps and many others keep
    /// their prefs there and never touch the plist or saved state).
    public static func lastUsed(app path: String) -> Date? {
        var dates: [Date] = []
        if let item = MDItemCreate(nil, path as CFString), let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            dates.append(d)
        }
        guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier else { return dates.max() }
        let lib = NSHomeDirectory() + "/Library"
        for p in ["\(lib)/Preferences/\(id).plist",
                  "\(lib)/Containers/\(id)/Data/Library/Preferences/\(id).plist",
                  "\(lib)/Saved Application State/\(id).savedState",
                  "\(lib)/Containers/\(id)/Data/Library/Saved Application State/\(id).savedState"] {
            if let m = DiskSizer.mtime(p) { dates.append(m) }
        }
        for dir in supportDirs(id: id, name: (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                               bundleName: bundle.infoDictionary?["CFBundleName"] as? String, lib: lib) {
            if let m = newestShallow(dir) { dates.append(m) }
        }
        return dates.max()
    }

    /// The app's own data folders: by bundle ID, by name, and vendor/product ("Google Chrome" → "Google/Chrome").
    static func supportDirs(id: String, name: String, bundleName: String?, lib: String) -> [String] {
        let support = lib + "/Application Support"
        var names = [id, name]
        if let bundleName { names.append(bundleName) }
        let words = name.split(separator: " ", maxSplits: 1).map(String.init)
        if words.count == 2 { names.append(words[0] + "/" + words[1]) }
        var dirs = Set(names.map { support + "/" + $0 })
        dirs.insert("\(lib)/Containers/\(id)/Data/Library/Application Support")
        return dirs.filter(DiskSizer.isDirectory).sorted()
    }

    /// Newest mtime of a folder and its direct children. One directory read, no recursion.
    static func newestShallow(_ dir: String) -> Date? {
        var newest = DiskSizer.mtime(dir)
        for child in DiskSizer.children(dir).prefix(300) {
            if let m = DiskSizer.mtime(child), m > (newest ?? .distantPast) { newest = m }
        }
        return newest
    }

    /// Full Disk Access is needed to size Mail, Safari, Messages and some containers.
    /// Opens a TCC-protected file for reading (one open/close, no data read). `access()` ignores TCC, so a
    /// real open is the only honest test. A denied open also makes macOS list the app under Full Disk Access.
    public static var hasFullDiskAccess: Bool {
        let probes = [
            "~/Library/Application Support/com.apple.TCC/TCC.db",
            "~/Library/Safari/Bookmarks.plist",
            "~/Library/Containers/com.apple.stocks/Data/Library/Preferences/com.apple.stocks.plist",
        ].map(\.expandingTilde)
        var sawDenied = false
        for p in probes {
            let fd = open(p, O_RDONLY | O_NOFOLLOW)
            if fd >= 0 { close(fd); return true }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        // None of the protected files exist: nothing for Full Disk Access to unlock.
        return !sawDenied
    }

    /// Homebrew service plists installed both as root daemons and user agents for the same family.
    public static func duplicateBrewServices() -> [String] {
        func names(_ dir: String) -> Set<String> {
            Set(DiskSizer.children(dir).map(\.lastComponent).filter { $0.hasPrefix("homebrew.mxcl.") }
                .map { $0.replacingOccurrences(of: "homebrew.mxcl.", with: "").replacingOccurrences(of: ".plist", with: "") })
        }
        let root = names("/Library/LaunchDaemons")
        let user = names("~/Library/LaunchAgents".expandingTilde)
        func family(_ s: String) -> String { String(s.split(separator: "@").first ?? Substring(s)) }
        var dup: [String] = []
        for f in Set(root.map(family)).intersection(user.map(family)) { dup.append(f) }
        // Several php versions as root daemons also fight for the same FPM port.
        if root.filter({ family($0) == "php" }).count > 1 && !dup.contains("php") { dup.append("php") }
        return dup.sorted()
    }
}
