import Foundation

/// Sign-ins and keys inside an app's folders: cookie jars, saved passwords, OAuth and account files,
/// private keys, keychains. Sapu never removes a folder that holds them; it offers the cache folders
/// inside instead, which is where the space goes.
public enum Credentials {
    /// Folders that only ever hold rebuildable data. Not searched for credentials, and offered as bloat.
    static let cacheFolders: Set<String> = ["cache", "code cache", "gpucache", "dawncache", "dawngraphitecache", "dawnwebgpucache",
                                            "grshadercache", "shadercache", "graphitedawncache", "cachestorage", "scriptcache",
                                            "cacheddata", "cachedextensionvsixs", "cachedprofilesdata", "caches", "tmp"]
    /// Not searched: other people's code (certificate bundles in node_modules or a venv aren't your keys).
    static let skipped: Set<String> = ["node_modules", "site-packages", "extensions", ".git"]
    /// Bundles carry the vendor's own files (public update keys, CA bundles), never your sign-ins.
    static func isBundle(_ name: String) -> Bool {
        [".app", ".framework", ".bundle", ".appex", ".xpc", ".plugin", ".qlgenerator"].contains { name.lowercased().hasSuffix($0) }
    }

    /// Folders that are credential stores by name: every file inside counts.
    static func isStore(_ folder: String) -> Bool {
        let n = folder.lowercased()
        return ["keychains", "keychain", "oneauth", "credentials", "msal", "identitycache", "tokens", "token cache"].contains(n)
            || n.hasSuffix("credentialcache")
    }

    /// True when a file's name marks it as a sign-in or a key.
    public static func isCredential(name: String, inKeychains: Bool = false) -> Bool {
        let n = name.lowercased()
        if inKeychains { return true }
        if n.hasSuffix(".binarycookies") || n == "cookies" || n == "cookies.json" || n == "login data" || n == "login data for account"
            || n == "web data" || n == ".netrc" || n.hasPrefix("id_rsa") || n.hasPrefix("id_ed25519") || n.hasPrefix("id_ecdsa") { return true }
        if n.hasPrefix(".env") || [".pem", ".key", ".p12", ".pfx", ".keystore", ".jks", ".kdbx", ".ppk"].contains(where: n.hasSuffix) { return true }
        // Words alone mark a store only when the file isn't a log, document or source file about the subject.
        let ext = (n as NSString).pathExtension
        if ["log", "md", "txt", "html", "htm", "js", "mjs", "ts", "py", "rb", "go", "rs", "swift", "java", "php", "yaml", "yml", "strings",
            "nib", "svg", "png", "jpg", "pdf", "help", "cshelpindex", "map", "css", "h", "m", "dart", "R", "r", "ui", "storyboardc"].contains(ext) { return false }
        if ["credential", "oauth", "password", "passwd", "secret", "apikey", "api_key", "api-key", "keychain"].contains(where: n.contains) { return true }
        if n.contains("auth"), !n.contains("author") { return true }
        if n.contains("account") { return true }
        if n.contains("token"), !n.contains("trust token"), !n.contains("list"), !n.hasPrefix("changetoken") { return true }
        return false
    }

    /// Up to `limit` credential files inside `path` (relative names), or the file itself. When the folder is too
    /// large to read through and `failSafe` is set, it counts as holding them.
    public static func find(in path: String, limit: Int = 3, failSafe: Bool = true, maxEntries: Int = 60_000) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isBundle(path.lastComponent) else { return [] }
        if !isDir.boolValue { return isCredential(name: path.lastComponent) ? [path.lastComponent] : [] }
        var found: [String] = [], seen = 0
        let e = FileManager.default.enumerator(atPath: path)
        while let rel = e?.nextObject() as? String {
            seen += 1
            if seen > maxEntries { return failSafe ? found + ["(too many files to check)"] : found }
            let name = rel.lastComponent, lower = name.lowercased()
            let type = e?.fileAttributes?[.type] as? FileAttributeType
            // Links (a container's Keychains link to your real keychain) move as links; what they point to stays.
            if type == .typeSymbolicLink { continue }
            if type == .typeDirectory {
                if cacheFolders.contains(lower) || skipped.contains(lower) || isBundle(lower) { e?.skipDescendants() }
                continue
            }
            // Sockets and pipes (iTerm2's "secrets" socket) carry nothing at rest.
            guard type == .typeRegular else { continue }
            // A file inside a folder named like a credential store (Keychains, OneAuth, azurecredentialcache) counts too.
            let inStore = rel.split(separator: "/").dropLast().contains { isStore(String($0)) }
            if isCredential(name: name, inKeychains: inStore) {
                found.append(rel)
                if found.count >= limit { break }
            }
        }
        return found
    }

    /// Cache folders inside a folder that holds credentials: Chromium and Electron profile caches, a container's
    /// Library/Caches. Searched three levels down (Default/Cache, Partitions/x/Cache).
    public static func bloat(in path: String) -> [String] {
        var out: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            for kid in DiskSizer.children(dir) where DiskSizer.isDirectory(kid) && !DiskSizer.isSymlink(kid) {
                let l = kid.lastComponent.lowercased()
                if cacheFolders.contains(l) { out.append(kid); continue }
                if depth < 3, !skipped.contains(l) { walk(kid, depth + 1) }
            }
        }
        walk(path, 0)
        return out
    }
}
