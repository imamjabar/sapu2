import CoreServices
import Foundation

/// What changed on disk since the last scan, from the FSEvents history macOS keeps per volume
/// (the same journal Time Machine and Spotlight use). Lets a rescan skip every folder that
/// did not change, even if Sapu2 was not running in between.
public struct ChangeSet: Sendable {
    /// Every changed directory plus all of its ancestors, so "did anything under X change?" is one lookup.
    var touched: Set<String> = []
    /// Directories macOS says must be rescanned in full (events were coalesced).
    var rescanRoots: [String] = []

    /// True when `path` or anything below it may have changed.
    public func isDirty(_ path: String) -> Bool {
        if touched.contains(path) { return true }
        return rescanRoots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
    }
}

public enum ChangeJournal {
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// Identifies the journal itself; it changes if macOS resets the FSEvents database.
    public static func journalID(for path: String = "/") -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private final class Collector {
        var set = ChangeSet()
        var unusable = false
        let done = DispatchSemaphore(value: 0)
        var finished = false
    }

    /// Directories under `roots` changed since `eventID`. Nil means the history can't be trusted
    /// (dropped events, reset journal, timeout), and the caller should measure everything.
    public static func changes(since eventID: UInt64, roots: [String], timeout: TimeInterval = 20) -> ChangeSet? {
        let collector = Collector()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let c = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            guard !c.finished else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<count {
                let f = Int(flags[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 {
                    c.finished = true; c.done.signal(); return
                }
                if f & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    c.unusable = true
                }
                guard i < list.count else { continue }
                var p = list[i]
                if p.hasPrefix("/System/Volumes/Data/") { p.removeFirst("/System/Volumes/Data".count) }
                while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                if f & kFSEventStreamEventFlagMustScanSubDirs != 0 { c.set.rescanRoots.append(p) }
                var q = p
                while q.count > 1, c.set.touched.insert(q).inserted { q = q.parentPath }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray, eventID, 0, flags) else { return nil }
        let queue = DispatchQueue(label: "sapu.journal", qos: .utility)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        let ok = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return queue.sync { ok && !collector.unusable ? collector.set : nil }
    }
}
