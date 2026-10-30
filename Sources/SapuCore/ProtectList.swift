import Foundation

/// Folders and files you told Sapu2 never to clean. Everything at or under an entry stays: scans show it locked,
/// the disk map won't move it, an uninstall leaves it, and the final safety guard refuses it.
public enum ProtectList {
    public static let message = "On your protect list. Sapu2 never cleans it."
    static var url: URL { Store.directory.appendingPathComponent("protect-list.json") }

    public static func load() -> [String] {
        guard let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return list
    }

    public static func save(_ list: [String]) {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        let clean = Array(Set(list.map { ($0 as NSString).standardizingPath })).sorted()
        try? JSONEncoder().encode(clean).write(to: url, options: .atomic)
    }

    public static func add(_ path: String) { save(load() + [path]) }
    public static func remove(_ path: String) { save(load().filter { $0 != path }) }

    /// The entry that protects `path` (the path itself or a folder above it), if any.
    public static func entry(covering path: String, in list: [String]) -> String? {
        let p = (path as NSString).standardizingPath
        return list.first { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Locks a finding covered by the list; unlocks one the list no longer covers.
    public static func apply(_ f: Finding, list: [String]) -> Finding {
        var g = f
        if entry(covering: f.path, in: list) != nil { g.lockedReason = message }
        else if g.lockedReason == message { g.lockedReason = nil }
        return g
    }
}
