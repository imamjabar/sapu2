import Foundation

/// The read-only folder browser behind the Disk map: one folder's children, sized and biggest first.
/// Links are shown but never followed. Credential stores, private mail and messages, photo libraries and
/// cloud folders are measured from outside but never listed: their names alone can be private.
public enum DiskExplorer {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        /// A folder you can open. Packages (apps, libraries, bundles) are measured as one item.
        public let isFolder: Bool
        public let isLink: Bool
        /// Why this folder isn't opened (it is still measured).
        public let sealed: String?
        /// A display name for rows that aren't a plain folder (macOS's own volumes, space it won't let anyone read).
        public var label: String? = nil
        /// What the row is, shown under its name.
        public var note: String? = nil
        public var name: String { label ?? (path == "/" ? "Macintosh HD" : path.lastComponent) }

        public init(path: String, isFolder: Bool, isLink: Bool, sealed: String?, label: String? = nil, note: String? = nil) {
            self.path = path; self.isFolder = isFolder; self.isLink = isLink; self.sealed = sealed; self.label = label; self.note = note
        }
    }

    /// Folders that open as one item in Finder too.
    static let packages: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "bundle", "framework",
                                        "xcarchive", "logicx", "band", "fcpbundle", "imovielibrary", "rtfd", "pages", "numbers", "key",
                                        "sparsebundle", "vmwarevm", "pvm", "utm", "plugin", "appex", "xpc", "kext", "dSYM"]

    public static func entries(in dir: String) -> [Entry] {
        DiskSizer.children(dir).filter { !DiskSizer.neverEnterPaths.contains($0) && !$0.lastComponent.hasPrefix(".") || dir != "/" }.map { p in
            let link = DiskSizer.isSymlink(p)
            let dir = !link && DiskSizer.isDirectory(p)
            let package = packages.contains((p as NSString).pathExtension)
            return Entry(path: p, isFolder: dir && !package, isLink: link, sealed: dir ? sealed(p) : nil)
        }
    }

    /// Why Sapu2 won't list this folder's contents, or nil.
    public static func sealed(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let l = path.lowercased(), name = path.lastComponent.lowercased()
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let keys = ["library/keychains", ".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker/contexts"]
        if keys.contains(rel.lowercased()) || [".ssh", ".gnupg", "keychains"].contains(name) { return "Keys and sign-ins. Sapu2 never looks inside." }
        if ["library/mail", "library/messages", "library/containers/com.apple.mail", "library/accounts", "library/cookies"].contains(rel.lowercased()) {
            return "Your mail, messages or accounts. Sapu2 never looks inside."
        }
        if ["1password", "bitwarden", "dashlane", "keeper", "enpass", "keepassxc", "lastpass", "proton pass"].contains(where: { l.contains($0) }) {
            return "Password manager data. Sapu2 never looks inside."
        }
        if DiskSizer.neverEnter.contains(path.lastComponent) || rel.lowercased() == "library/mobile documents" {
            return "Cloud files. Opening them can start downloads; manage them in Finder."
        }
        if name.hasSuffix(".photoslibrary") { return "Your photo library. Manage it in Photos." }
        return nil
    }

    /// Why this item can't be moved to the Trash from the map, or nil. Checked again right before moving.
    public static func trashRefusal(_ path: String, projects: [Project], home: String = NSHomeDirectory()) -> String? {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return "Outside your home folder." }
        if p == home + "/.Trash" || p.hasPrefix(home + "/.Trash/") { return "Already in the Trash." }
        if ProtectList.entry(covering: p, in: ProtectList.load()) != nil { return ProtectList.message }
        var q = p
        while q.count > home.count {
            if let s = sealed(q, home: home) { return q == p ? s : "Inside a private folder. " + s }
            q = q.parentPath
        }
        if let pr = projects.first(where: { $0.status == .active && (p == $0.path || p.hasPrefix($0.path + "/") || $0.path.hasPrefix(p + "/")) }) {
            return "Part of \(pr.path.lastComponent), a project you're working on."
        }
        let f = Finding(path: p, title: p.lastComponent, category: .home, safety: .check, reason: "", usedFor: "", action: .trash, layer: .full)
        if let r = SafetyGuard.refusal(for: f, allowActiveProjects: false) { return r }
        if let c = Credentials.find(in: p, limit: 1).first { return "Holds sign-ins or keys (\(c.lastComponent))." }
        return nil
    }

    /// Moves one item to the Trash and writes a receipt, so Receipts can put it back.
    public static func moveToTrash(_ path: String, bytes: Int64, projects: [Project]) -> (ok: Bool, message: String) {
        if let why = trashRefusal(path, projects: projects) { return (false, why) }
        let before = SystemProbe.volume().free
        let (ok, msg, to) = Cleaner.trash(path)
        Cleaner.save(CleanReceipt(date: Date(), items: [.init(path: path, title: path.lastComponent, bytes: bytes, action: "Move to Trash (Disk map)",
                                                              ok: ok, message: msg, trashedTo: to)],
                                  freeBefore: before, freeAfter: SystemProbe.volume().free))
        return (ok, ok ? "Moved to the Trash. Receipts can put it back." : msg)
    }

    public struct LargeFile: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let bytes: Int64
        public let modified: Date?

        public init(path: String, bytes: Int64, modified: Date?) {
            self.path = path; self.bytes = bytes; self.modified = modified
        }
    }

    /// True when the file sits inside a folder Sapu2 never lists (keys, mail, password managers, cloud files).
    /// A walk that measures a whole folder still passes through those; their files are left out of any list.
    public static func isPrivate(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        var q = path.parentPath
        while q.count > home.count, q.hasPrefix(home + "/") {
            if sealed(q, home: home) != nil { return true }
            q = q.parentPath
        }
        return false
    }

    /// Single files of at least `minBytes` anywhere under `root`, biggest first. Private folders are left out.
    public static func largestFiles(under root: String, minBytes: Int64 = 200_000_000, limit: Int = 200,
                                    cancelled: @escaping @Sendable () -> Bool = { false }) -> [LargeFile] {
        let found = Locked([LargeFile]())
        searchLargeFiles(under: root, minBytes: minBytes, cancelled: cancelled, onFile: { f in found.mutate { $0.append(f) } })
        return found.value.sorted { $0.bytes > $1.bytes }.prefix(limit).map { $0 }
    }

    /// Home folders macOS guards with a permission dialog (or that hold other apps' data) unless Full Disk Access is on.
    static let promptProne: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library"]

    /// One folder of the search: where it stands, so people can watch it move.
    public enum SearchState: Sendable, Equatable { case waiting, searching, done }

    /// Single files of `minBytes` or more under `root`, reported as they're found. Each top-level folder is searched on
    /// its own (`workers` at a time, `order` first), and private folders (keys, mail, password managers, cloud files)
    /// are skipped as the walk reaches them, never entered. `onFolder` hears each folder's state and file count.
    public static func searchLargeFiles(under root: String, minBytes: Int64 = 200_000_000, workers: Int = 3, order: [String] = [],
                                        cancelled: @escaping @Sendable () -> Bool = { false },
                                        onFile: @escaping @Sendable (LargeFile) -> Void,
                                        onFolder: @escaping @Sendable (_ folder: String, _ state: SearchState, _ files: Int) -> Void = { _, _, _ in }) {
        let skip: @Sendable (String) -> Bool = { sealed($0, home: root) != nil }
        var dirs: [String] = []
        for p in DiskSizer.children(root) where !DiskSizer.isSymlink(p) {
            if DiskSizer.isDirectory(p) {
                if !skip(p) { dirs.append(p) }
            } else {
                let r = DiskSizer.size(p)
                if r.bytes >= minBytes { onFile(LargeFile(path: p, bytes: r.bytes, modified: r.newestDate)) }
            }
        }
        // Folders macOS may ask permission for go last: while its dialog waits, every other folder still finishes.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ d: String) -> (Int, Int, String) { (promptProne.contains(d.lastComponent) ? 1 : 0, rank[d] ?? .max, d) }
        dirs.sort { key($0) < key($1) }
        for d in dirs { onFolder(d, .waiting, 0) }
        let q = OperationQueue()
        q.maxConcurrentOperationCount = workers
        q.qualityOfService = .utility
        for d in dirs {
            q.addOperation {
                guard !cancelled() else { return }
                onFolder(d, .searching, 0)
                let r = DiskSizer.size(d, cancelled: cancelled, progress: { _, files in onFolder(d, .searching, files) },
                                       largeFile: { p, b, t in onFile(LargeFile(path: p, bytes: b, modified: t > 0 ? Date(timeIntervalSince1970: t) : nil)) },
                                       largeThreshold: minBytes, skipDir: skip)
                onFolder(d, .done, r.files)
            }
        }
        q.waitUntilAllOperationsAreFinished()
    }

    /// The finding Sapu2 already has for this exact path, or the cleanable bytes of findings inside it.
    public static func cleanable(under path: String, in findings: [Finding]) -> Int64 {
        let prefix = path + "/"
        return findings.filter { ($0.path == path || $0.path.hasPrefix(prefix)) && $0.isCleanable && $0.safety <= .check }
            .reduce(0) { $0 + $1.bytes }
    }
}

extension DiskExplorer {
    /// macOS's own volumes beside the one you browse: the sealed system, update space, Recovery and memory swap.
    /// Read from `diskutil` for the startup disk's container; nothing is opened.
    public static func systemVolumes() -> [(entry: Entry, bytes: Int64)] {
        guard let info = Shell.run(["diskutil", "info", "-plist", "/"], timeout: 10).out.data(using: .utf8),
              let i = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let container = i["APFSContainerReference"] as? String,
              let list = Shell.run(["diskutil", "apfs", "list", "-plist"], timeout: 10).out.data(using: .utf8),
              let l = try? PropertyListSerialization.propertyList(from: list, format: nil) as? [String: Any],
              let c = (l["Containers"] as? [[String: Any]])?.first(where: { $0["ContainerReference"] as? String == container }),
              let volumes = c["Volumes"] as? [[String: Any]] else { return [] }
        let names: [String: (String, String)] = [
            "Preboot": ("macOS startup & update files", "Preboot volume. macOS manages it; it grows during updates."),
            "Recovery": ("Recovery", "macOS Recovery, used to repair or reinstall macOS."),
            "VM": ("Memory swap", "Swap and sleep image. Shrinks when apps quit or after a restart."),
            "Update": ("Update staging", "Space macOS uses while installing an update."),
        ]
        return volumes.compactMap { v in
            guard let role = (v["Roles"] as? [String])?.first, let (label, note) = names[role],
                  let bytes = (v["CapacityInUse"] as? NSNumber)?.int64Value, bytes > 0 else { return nil }
            return (Entry(path: "volume:" + role, isFolder: false, isLink: false, sealed: note, label: label, note: note), bytes)
        }
    }
}
