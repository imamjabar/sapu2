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
        public var name: String { path.lastComponent }
    }

    /// Folders that open as one item in Finder too.
    static let packages: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "bundle", "framework",
                                        "xcarchive", "logicx", "band", "fcpbundle", "imovielibrary", "rtfd", "pages", "numbers", "key",
                                        "sparsebundle", "vmwarevm", "pvm", "utm", "plugin", "appex", "xpc", "kext", "dSYM"]

    public static func entries(in dir: String) -> [Entry] {
        DiskSizer.children(dir).map { p in
            let link = DiskSizer.isSymlink(p)
            let dir = !link && DiskSizer.isDirectory(p)
            let package = packages.contains((p as NSString).pathExtension)
            return Entry(path: p, isFolder: dir && !package, isLink: link, sealed: dir ? sealed(p) : nil)
        }
    }

    /// Why Sapu won't list this folder's contents, or nil.
    public static func sealed(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let l = path.lowercased(), name = path.lastComponent.lowercased()
        let rel = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        let keys = ["library/keychains", ".ssh", ".gnupg", ".aws", ".config/gcloud", ".kube", ".docker/contexts"]
        if keys.contains(rel.lowercased()) || [".ssh", ".gnupg", "keychains"].contains(name) { return "Keys and sign-ins. Sapu never looks inside." }
        if ["library/mail", "library/messages", "library/containers/com.apple.mail", "library/accounts", "library/cookies"].contains(rel.lowercased()) {
            return "Your mail, messages or accounts. Sapu never looks inside."
        }
        if ["1password", "bitwarden", "dashlane", "keeper", "enpass", "keepassxc", "lastpass", "proton pass"].contains(where: { l.contains($0) }) {
            return "Password manager data. Sapu never looks inside."
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
    }

    /// Single files of at least `minBytes` anywhere under `root`, biggest first. Private folders are left out.
    public static func largestFiles(under root: String, minBytes: Int64 = 200_000_000, limit: Int = 200,
                                    cancelled: () -> Bool = { false }) -> [LargeFile] {
        var found: [LargeFile] = []
        _ = DiskSizer.size(root, cancelled: cancelled, largeFile: { p, b, t in
            found.append(LargeFile(path: p, bytes: b, modified: t > 0 ? Date(timeIntervalSince1970: t) : nil))
        }, largeThreshold: minBytes)
        return found.filter { f in
            var q = f.path.parentPath
            while q.count > root.count { if sealed(q, home: root) != nil { return false }; q = q.parentPath }
            return true
        }
        .sorted { $0.bytes > $1.bytes }.prefix(limit).map { $0 }
    }

    /// The finding Sapu already has for this exact path, or the cleanable bytes of findings inside it.
    public static func cleanable(under path: String, in findings: [Finding]) -> Int64 {
        let prefix = path + "/"
        return findings.filter { ($0.path == path || $0.path.hasPrefix(prefix)) && $0.isCleanable && $0.safety <= .check }
            .reduce(0) { $0 + $1.bytes }
    }
}
