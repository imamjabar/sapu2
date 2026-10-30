import Foundation

/// Your Trash, and emptying it. Emptying is the one thing Sapu2 does that can't be undone, so it is never part of
/// Smart Clean, never preselected, and only runs after you confirm in a dialog that says Put back stops working.
public enum TrashBin {
    public struct Summary: Sendable, Hashable {
        public var items: Int
        public var bytes: Int64
        /// Items Sapu2 itself put there (they have a receipt and could still be put back until now).
        public var fromSapu: Int
        public var oldest: Date?
        /// False when macOS hides the Trash from Sapu2 (it needs Full Disk Access to look inside).
        public var readable = true
    }

    public static func folder(home: String = NSHomeDirectory()) -> String { home + "/.Trash" }

    public static func summary(home: String = NSHomeDirectory(), receipts: [CleanReceipt] = Store.receipts()) -> Summary {
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder(home: home))) != nil else {
            return Summary(items: 0, bytes: 0, fromSapu: 0, oldest: nil, readable: false)
        }
        let kids = DiskSizer.children(folder(home: home)).filter { $0.lastComponent != ".DS_Store" }
        let ours = Set(receipts.flatMap { $0.items.compactMap { $0.restored == true ? nil : $0.trashedTo } })
        return Summary(items: kids.count,
                       bytes: kids.reduce(Int64(0)) { $0 + DiskSizer.size($1).bytes },
                       fromSapu: kids.filter(ours.contains).count,
                       oldest: kids.compactMap(DiskSizer.mtime).min())
    }

    /// Removes everything directly inside ~/.Trash for good. Links are removed as links; nothing outside the Trash is touched.
    public static func empty(home: String = NSHomeDirectory(), save: Bool = true) -> (ok: Bool, message: String, freed: Int64) {
        let trash = folder(home: home)
        let real = (trash as NSString).resolvingSymlinksInPath
        guard real == (trash as NSString).standardizingPath, DiskSizer.isDirectory(trash),
              (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil else { return (false, "Your Trash folder isn't where Sapu2 expects it; nothing was removed.", 0) }
        let before = SystemProbe.volume().free
        var removed = 0, failed = 0, bytes: Int64 = 0
        for p in DiskSizer.children(trash) {
            guard p.parentPath == trash else { continue }
            let b = DiskSizer.size(p).bytes
            if (try? FileManager.default.removeItem(atPath: p)) != nil { removed += 1; bytes += b } else { failed += 1 }
        }
        if save {
            Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: trash, title: "Emptied the Trash", bytes: bytes, action: "Empty Trash", ok: failed == 0,
                                                                  message: "\(removed) item(s) removed for good." + (failed > 0 ? " \(failed) couldn't be removed (in use or locked)." : ""),
                                                                  trashedTo: nil)],
                                      freeBefore: before, freeAfter: SystemProbe.volume().free))
        }
        return (failed == 0, "Emptied: \(removed) item(s), \(Format.bytes(bytes)) freed." + (failed > 0 ? " \(failed) couldn't be removed." : ""), bytes)
    }
}
