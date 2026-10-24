import AppKit
import Darwin
import Foundation

public enum SystemProbe {
    public static func volume() -> VolumeInfo {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: keys)
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let free = Int64(v?.volumeAvailableCapacity ?? 0)
        let avail = v?.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeInfo(total: total, free: free, available: avail, swapBytes: swapUsed(), localSnapshots: localSnapshots())
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

    public static func lastUsed(app path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
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
