import Darwin
import Foundation

public struct SizeResult: Sendable, Hashable {
    public var bytes: Int64 = 0
    public var files: Int = 0
    public var newest: TimeInterval = 0
    public var denied: Bool = false

    public init(bytes: Int64 = 0, files: Int = 0, newest: TimeInterval = 0, denied: Bool = false) {
        self.bytes = bytes; self.files = files; self.newest = newest; self.denied = denied
    }

    public var newestDate: Date? { newest > 0 ? Date(timeIntervalSince1970: newest) : nil }
}

/// Streams a directory tree with `fts(3)`: physical walk (never follows symlinks), one device
/// (never crosses into other volumes), constant memory. Sizes are allocated blocks, so sparse
/// files are not over-counted. Hardlinked files are counted once.
public enum DiskSizer {
    /// Directory names never entered: cloud-managed folders (reading them can trigger downloads)
    /// and macOS-protected stores.
    public static let neverEnter: Set<String> = [
        "Mobile Documents", "CloudStorage", ".Spotlight-V100", ".DocumentRevisions-V100", ".fseventsd",
    ]
    /// Folders never entered from the top of the disk. On APFS every firmlinked folder reports the same device, so
    /// /System/Volumes/Data would count the whole disk a second time; /Volumes holds other drives and a link back to /.
    public static let neverEnterPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/.vol", "/.nofollow", "/.resolve"]

    public static func size(_ path: String,
                            cancelled: () -> Bool = { false },
                            progress: ((Int64, Int) -> Void)? = nil,
                            largeFile: ((String, Int64, TimeInterval) -> Void)? = nil,
                            largeThreshold: Int64 = 1_000_000_000,
                            skipDir: ((String) -> Bool)? = nil,
                            onDir: ((String, SizeResult) -> Void)? = nil,
                            dirThreshold: Int64 = 0) -> SizeResult {
        var result = SizeResult()
        var lst = stat()
        guard lstat(path, &lst) == 0 else { result.denied = errno == EPERM || errno == EACCES; return result }
        if (lst.st_mode & S_IFMT) != S_IFDIR {
            result.bytes = Int64(lst.st_blocks) * 512
            result.files = 1
            result.newest = TimeInterval(lst.st_mtimespec.tv_sec)
            return result
        }

        if useBulk, let bulk = bulkSize(path, rootDev: lst.st_dev, cancelled: cancelled, progress: progress,
                                         largeFile: largeFile, largeThreshold: largeThreshold, skipDir: skipDir,
                                         onDir: onDir, dirThreshold: dirThreshold) {
            return bulk
        }
        return ftsSize(path, cancelled: cancelled, progress: progress, largeFile: largeFile, largeThreshold: largeThreshold, skipDir: skipDir,
                       onDir: onDir, dirThreshold: dirThreshold)
    }

    /// `getattrlistbulk` is the default; set false to compare against the fts walker.
    nonisolated(unsafe) public static var useBulk = true

    /// Reference walker: one lstat per file via fts(3).
    public static func ftsSize(_ path: String,
                               cancelled: () -> Bool = { false },
                               progress: ((Int64, Int) -> Void)? = nil,
                               largeFile: ((String, Int64, TimeInterval) -> Void)? = nil,
                               largeThreshold: Int64 = 1_000_000_000,
                               skipDir: ((String) -> Bool)? = nil,
                               onDir: ((String, SizeResult) -> Void)? = nil,
                               dirThreshold: Int64 = 0) -> SizeResult {
        var result = SizeResult()
        guard let cPath = strdup(path) else { return result }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return result }
        defer { fts_close(fts) }

        var seenLinks = Set<UInt64>()
        var visited = 0
        // Open folders, outermost first: the running totals when each was entered, and whether a skipped folder
        // inside it left its own total short (then it isn't reported).
        var open: [(level: Int, bytes: Int64, files: Int, newest: TimeInterval, denied: Int, short: Bool)] = []
        var unread = 0
        func close(_ ent: UnsafeMutablePointer<FTSENT>) {
            guard let top = open.last, top.level == Int(ent.pointee.fts_level) else { return }
            open.removeLast()
            if top.short { if !open.isEmpty { open[open.count - 1].short = true }; return }
            let bytes = result.bytes - top.bytes
            if let onDir, bytes >= dirThreshold {
                onDir(String(cString: ent.pointee.fts_path),
                      SizeResult(bytes: bytes, files: result.files - top.files, denied: unread > top.denied))
            }
        }
        while let ent = fts_read(fts) {
            visited += 1
            if visited & 2047 == 0 {
                if cancelled() { break }
                progress?(result.bytes, result.files)
            }
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                if ent.pointee.fts_level > 0, neverEnter.contains(name(ent)) || neverEnterPaths.contains(String(cString: ent.pointee.fts_path)) {
                    fts_set(fts, ent, FTS_SKIP)
                } else if ent.pointee.fts_level > 0, skipDir?(String(cString: ent.pointee.fts_path)) == true {
                    fts_set(fts, ent, FTS_SKIP)
                    if !open.isEmpty { open[open.count - 1].short = true }
                } else if ent.pointee.fts_level > 0, onDir != nil {
                    open.append((Int(ent.pointee.fts_level), result.bytes, result.files, 0, unread, false))
                }
            case FTS_DP:
                close(ent)
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 {
                    let key = st.st_ino ^ (UInt64(UInt32(bitPattern: st.st_dev)) << 40)
                    if !seenLinks.insert(key).inserted { continue }
                }
                let b = Int64(st.st_blocks) * 512
                result.bytes += b
                result.files += 1
                let m = TimeInterval(st.st_mtimespec.tv_sec)
                if m > result.newest { result.newest = m }
                if b >= largeThreshold, let largeFile { largeFile(String(cString: ent.pointee.fts_path), b, m) }
            case FTS_DNR, FTS_ERR:
                if ent.pointee.fts_level == 0 { result.denied = true }
                unread += 1
                close(ent)
            default:
                break
            }
        }
        return result
    }

    /// Fast walker: `getattrlistbulk(2)` returns name, type, size, mtime and inode for a whole batch of
    /// directory entries per syscall, instead of one lstat per file. Same rules as the fts walker:
    /// never follows symlinks, stays on one volume, counts hardlinks once, constant memory per level.
    /// Returns nil if the root can't be read this way, so the caller falls back to fts.
    static func bulkSize(_ root: String, rootDev: dev_t,
                         cancelled: () -> Bool,
                         progress: ((Int64, Int) -> Void)?,
                         largeFile: ((String, Int64, TimeInterval) -> Void)?,
                         largeThreshold: Int64,
                         skipDir: ((String) -> Bool)? = nil,
                         onDir: ((String, SizeResult) -> Void)? = nil,
                         dirThreshold: Int64 = 0) -> SizeResult? {
        var req = attrlist()
        req.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // Order in the buffer follows bit order: name, devid, objtype, modtime, fileid; then linkcount, allocsize.
        req.commonattr = 0x8000_0000 /* RETURNED_ATTRS */ | 0x1 /* NAME */ | 0x2 /* DEVID */ | 0x8 /* OBJTYPE */
            | 0x400 /* MODTIME */ | 0x0200_0000 /* FILEID */
        req.fileattr = 0x1 /* LINKCOUNT */ | 0x4 /* ALLOCSIZE */
        let options = UInt64(0x1 /* FSOPT_NOFOLLOW */ | 0x8 /* FSOPT_PACK_INVAL_ATTRS */)

        let bufSize = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        var result = SizeResult()
        var seenLinks = Set<UInt64>()
        var visited = 0
        var stopped = false
        var unread = 0

        /// Reads one folder (its descriptor is closed before going deeper, so open files stay at one), then its
        /// subfolders. Returns false when a skipped folder somewhere inside left this folder's own total short.
        func walk(_ dir: String, isRoot: Bool) -> Bool? {
            let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                if isRoot { return nil }
                unread += 1
                return true
            }
            var subdirs: [String] = []
            var complete = true
            reading: while true {
                let n = getattrlistbulk(fd, &req, buf, bufSize, options)
                if n <= 0 { break }
                var entry = UnsafeRawPointer(buf)
                for _ in 0..<n {
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    defer { entry = entry + length }
                    visited += 1
                    if visited & 4095 == 0 {
                        if cancelled() { stopped = true; break reading }
                        progress?(result.bytes, result.files)
                    }
                    let nameRef = entry + 24
                    let nameOff = Int(nameRef.loadUnaligned(as: Int32.self))
                    let nameLen = Int(nameRef.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                    let dev = entry.loadUnaligned(fromByteOffset: 32, as: Int32.self)
                    let type = entry.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
                    let mtime = TimeInterval(entry.loadUnaligned(fromByteOffset: 40, as: Int.self))
                    let fileID = entry.loadUnaligned(fromByteOffset: 56, as: UInt64.self)
                    let links = entry.loadUnaligned(fromByteOffset: 64, as: UInt32.self)
                    let alloc = entry.loadUnaligned(fromByteOffset: 68, as: Int64.self)

                    if type == 2 /* VDIR */ {
                        guard dev == rootDev, nameLen > 1 else { continue }
                        let name = String(cString: (nameRef + nameOff).assumingMemoryBound(to: CChar.self))
                        let sub = dir + "/" + name
                        if neverEnter.contains(name) || neverEnterPaths.contains(sub) { continue }
                        if skipDir?(sub) == true { complete = false; continue }
                        subdirs.append(sub)
                        continue
                    }
                    if links > 1 {
                        let key = fileID ^ (UInt64(UInt32(bitPattern: dev)) << 40)
                        if !seenLinks.insert(key).inserted { continue }
                    }
                    result.bytes += alloc
                    result.files += 1
                    if mtime > result.newest { result.newest = mtime }
                    if alloc >= largeThreshold, let largeFile {
                        let name = String(cString: (nameRef + nameOff).assumingMemoryBound(to: CChar.self))
                        largeFile(dir + "/" + name, alloc, mtime)
                    }
                }
            }
            close(fd)
            for sub in subdirs {
                if stopped { return complete }
                let before = (bytes: result.bytes, files: result.files, unread: unread)
                let whole = walk(sub, isRoot: false) ?? true
                if !whole { complete = false; continue }
                let bytes = result.bytes - before.bytes
                if !stopped, let onDir, bytes >= dirThreshold {
                    onDir(sub, SizeResult(bytes: bytes, files: result.files - before.files, denied: unread > before.unread))
                }
            }
            return complete
        }

        guard walk(root, isRoot: true) != nil else { return nil }
        return result
    }

    static func name(_ ent: UnsafeMutablePointer<FTSENT>) -> String {
        String(cString: ent.pointee.fts_path).lastComponent
    }

    /// Immediate children of a directory (no hidden `.`/`..`), never following symlinks.
    public static func children(_ path: String, includeHidden: Bool = true) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names
            .filter { includeHidden || !$0.hasPrefix(".") }
            .map { (path as NSString).appendingPathComponent($0) }
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static let noiseFiles: Set<String> = [".DS_Store", ".localized", "Icon\r", "Thumbs.db", ".swp"]

    /// Newest mtime among source files of a project, skipping heavy generated folders.
    /// Bounded: stops after `limit` entries so huge repos stay cheap.
    public static func newestSource(in root: String, skip: Set<String>, maxDepth: Int = 5, limit: Int = 25_000) -> Date? {
        guard let cPath = strdup(root) else { return nil }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }
        var newest: TimeInterval = 0
        var count = 0
        while let ent = fts_read(fts), count < limit {
            count += 1
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                let n = name(ent)
                if ent.pointee.fts_level > 0 && (skip.contains(n) || ent.pointee.fts_level >= maxDepth) {
                    fts_set(fts, ent, FTS_SKIP)
                }
            case FTS_F:
                // Finder and editors touch these without any real work happening.
                if noiseFiles.contains(name(ent)) { continue }
                if let st = ent.pointee.fts_statp?.pointee {
                    let m = TimeInterval(st.st_mtimespec.tv_sec)
                    if m > newest { newest = m }
                }
            default: break
            }
        }
        return newest > 0 ? Date(timeIntervalSince1970: newest) : nil
    }
}
