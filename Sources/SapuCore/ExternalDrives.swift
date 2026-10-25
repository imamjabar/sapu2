import Darwin
import Foundation

/// macOS bookkeeping files left on USB sticks, SD cards and external drives: `.DS_Store` (Finder view settings) and,
/// on drives formatted for Windows (exFAT, FAT, NTFS), `._name` companions holding a file's Mac metadata. They show up
/// on other computers and in git. System folders (.Spotlight-V100, .Trashes, .fseventsd) are never touched.
public enum ExternalDrives {
    public struct Drive: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let name: String
        public let format: String
        /// exFAT/FAT/NTFS: `._` files exist only here.
        public let foreignFormat: Bool

        public init(path: String, name: String, format: String, foreignFormat: Bool) {
            self.path = path; self.name = name; self.format = format; self.foreignFormat = foreignFormat
        }
    }

    public struct Junk: Sendable, Hashable {
        public var dsStore: [String] = []
        public var appleDouble: [String] = []
        public var bytes: Int64 = 0
        public var count: Int { dsStore.count + appleDouble.count }
    }

    static let skipped: Set<String> = [".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100", ".Trash"]

    /// Writable external volumes (not the startup disk, not read-only images).
    public static func drives() -> [Drive] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsRootFileSystem != true, v.volumeIsReadOnly != true,
                  u.path.hasPrefix("/Volumes/") else { return nil }
            let format = v.volumeLocalizedFormatDescription ?? ""
            let foreign = ["exfat", "ms-dos", "fat", "ntfs", "windows"].contains { format.lowercased().contains($0) }
            return Drive(path: u.path, name: v.volumeName ?? u.lastPathComponent, format: format, foreignFormat: foreign)
        }
    }

    /// Finds the junk, up to `maxDepth` folders down. A `._name` file counts only when `name` is next to it.
    public static func scan(_ drive: Drive, maxDepth: Int = 12, cancelled: () -> Bool = { false }) -> Junk {
        var junk = Junk()
        func walk(_ dir: String, _ depth: Int) {
            guard depth <= maxDepth, !cancelled() else { return }
            let names = rawNames(dir)
            let set = Set(names)
            for n in names {
                let p = dir + "/" + n
                if skipped.contains(n) || DiskSizer.isSymlink(p) { continue }
                if DiskSizer.isDirectory(p) { walk(p, depth + 1); continue }
                if n == ".DS_Store" {
                    junk.dsStore.append(p); junk.bytes += DiskSizer.size(p).bytes
                } else if drive.foreignFormat, n.hasPrefix("._"), set.contains(String(n.dropFirst(2))) {
                    junk.appleDouble.append(p); junk.bytes += DiskSizer.size(p).bytes
                }
            }
        }
        walk(drive.path, 0)
        return junk
    }

    /// Every name in a folder, read with readdir: Foundation hides `._` files on exFAT/FAT drives.
    static func rawNames(_ dir: String) -> [String] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    /// `.DS_Store` files go to the drive's Trash; `._` files are merged back by macOS's own `dot_clean`, which then removes them.
    public static func clean(_ drive: Drive, _ junk: Junk) -> (ok: Bool, message: String) {
        var trashed = 0, failed = 0
        for p in junk.dsStore where p.hasPrefix(drive.path + "/") {
            if (try? FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)) != nil { trashed += 1 } else { failed += 1 }
        }
        var merged = 0
        if drive.foreignFormat, !junk.appleDouble.isEmpty {
            let r = Shell.run(["/usr/sbin/dot_clean", "-m", drive.path], timeout: 600)
            if r.status == 0 { merged = junk.appleDouble.filter { !DiskSizer.exists($0) }.count } else { failed += 1 }
        }
        let free = SystemProbe.volume().free
        Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: drive.path, title: "Mac bookkeeping files on \(drive.name)", bytes: junk.bytes,
                                                              action: "External drive", ok: failed == 0,
                                                              message: "\(trashed) .DS_Store file(s) to the drive's Trash, \(merged) ._ file(s) merged by dot_clean." + (failed > 0 ? " \(failed) failed." : ""),
                                                              trashedTo: nil)], freeBefore: free, freeAfter: free))
        return (failed == 0, "\(trashed) .DS_Store moved to \(drive.name)'s Trash, \(merged) ._ file(s) merged back." + (failed > 0 ? " \(failed) couldn't be removed." : ""))
    }
}
