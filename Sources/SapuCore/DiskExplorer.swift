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
        if keys.contains(rel.lowercased()) { return "Keys and sign-ins. Sapu never looks inside." }
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

    /// The finding Sapu already has for this exact path, or the cleanable bytes of findings inside it.
    public static func cleanable(under path: String, in findings: [Finding]) -> Int64 {
        let prefix = path + "/"
        return findings.filter { ($0.path == path || $0.path.hasPrefix(prefix)) && $0.isCleanable && $0.safety <= .check }
            .reduce(0) { $0 + $1.bytes }
    }
}
