import Foundation

/// The release check's memory of one Mac: every answer the leftover finder got from the disk, the reference tool's
/// leftovers for each app, and the hand review of every path. Replaying it re-runs the finder on that
/// Mac without the Mac, so a later change that claims a new path, loses one of the reference tool's, or lets two apps
/// claim the same path fails `sapu-cli selftest`.
public struct ParityFixture: Codable, Sendable {
    public struct App: Codable, Sendable {
        public var name: String; public var id: String?; public var path: String
        public init(name: String, id: String?, path: String) { self.name = name; self.id = id; self.path = path }
    }
    /// Disk answers, keyed by path with the home folder written as "~".
    public struct Disk: Codable, Sendable {
        public var exists: [String: Bool] = [:]
        public var dir: [String: Bool] = [:]
        public var link: [String: Bool] = [:]
        public var kids: [String: [String]] = [:]
        public var agent: [String: String] = [:]
        public var bundle: [String: String] = [:]
        public var target: [String: String] = [:]

        public init() {}
        // Recordings from before a field existed still load.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exists = try c.decodeIfPresent([String: Bool].self, forKey: .exists) ?? [:]
            dir = try c.decodeIfPresent([String: Bool].self, forKey: .dir) ?? [:]
            link = try c.decodeIfPresent([String: Bool].self, forKey: .link) ?? [:]
            kids = try c.decodeIfPresent([String: [String]].self, forKey: .kids) ?? [:]
            agent = try c.decodeIfPresent([String: String].self, forKey: .agent) ?? [:]
            bundle = try c.decodeIfPresent([String: String].self, forKey: .bundle) ?? [:]
            target = try c.decodeIfPresent([String: String].self, forKey: .target) ?? [:]
        }
    }
    public var made: String
    public var referenceVersion: String
    public var apps: [App]
    public var disk: Disk
    /// The reference tool's leftovers per app name.
    public var reference: [String: [String]]
    /// Paths the reference tool claims that Sapu deliberately leaves, with the reason. Keyed by app name, then path.
    public var referenceMistakes: [String: [String: String]]
    /// Every path Sapu claims, reviewed by hand once: app name → path → why it belongs to that app.
    public var reviewed: [String: [String: String]]

    public init(made: String, referenceVersion: String, apps: [App], disk: Disk, reference: [String: [String]],
                referenceMistakes: [String: [String: String]], reviewed: [String: [String: String]]) {
        self.made = made; self.referenceVersion = referenceVersion; self.apps = apps; self.disk = disk; self.reference = reference
        self.referenceMistakes = referenceMistakes; self.reviewed = reviewed
    }

    static let home = NSHomeDirectory()
    public static func tilde(_ p: String) -> String { p == home || p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p }
    public static func expand(_ p: String) -> String { p == "~" || p.hasPrefix("~/") ? home + p.dropFirst(1) : p }

    /// Runs the finder on the real disk for every app and keeps each answer it got.
    public static func record(apps: [InstalledApp]) -> (disk: Disk, found: [String: [String]]) {
        let log = Locked(Disk())
        let base = Uninstaller.FileView.disk
        // A folder's whole listing, with each entry's type, so a later finder that asks about a
        // sibling it never asked about today still gets the true answer.
        @Sendable func list(_ dir: String) -> [String] {
            if let hit = log.value.kids[tilde(dir)] { return hit.map(expand) }
            let kids = base.children(dir)
            let types = kids.map { ($0, base.isDirectory($0), base.isSymlink($0)) }
            log.mutate { d in
                d.kids[tilde(dir)] = kids.map(tilde)
                for (k, isDir, isLink) in types { d.exists[tilde(k)] = true; d.dir[tilde(k)] = isDir; d.link[tilde(k)] = isLink }
            }
            return kids
        }
        var fs = base
        fs.exists = { p in _ = list(p.parentPath); let r = base.exists(p); log.mutate { $0.exists[tilde(p)] = r }; return r }
        fs.isDirectory = { p in let r = base.isDirectory(p); log.mutate { $0.dir[tilde(p)] = r }; return r }
        fs.isSymlink = { p in let r = base.isSymlink(p); log.mutate { $0.link[tilde(p)] = r }; return r }
        fs.children = { p in list(p) }
        fs.agentProgram = { p in let r = base.agentProgram(p); if let r { log.mutate { $0.agent[tilde(p)] = tilde(r) } }; return r }
        fs.bundleID = { p in let r = base.bundleID(p); if let r { log.mutate { $0.bundle[tilde(p)] = r } }; return r }
        fs.linkTarget = { p in let r = base.linkTarget(p); if let r { log.mutate { $0.target[tilde(p)] = tilde(r) } }; return r }
        let found = Uninstaller.leftoversForAll(apps, fs: fs.memoized())
        return (log.value, found)
    }

    /// A file system that answers exactly as the recorded Mac did. Anything never asked is absent.
    /// The disk ignores case, so lookups do too.
    public func replay() -> Uninstaller.FileView {
        func low<V>(_ m: [String: V]) -> [String: V] { Dictionary(m.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a }) }
        let exists = low(disk.exists), dir = low(disk.dir), link = low(disk.link), kids = low(disk.kids)
        let agent = low(disk.agent), bundle = low(disk.bundle), target = low(disk.target)
        let t = { (p: String) in ParityFixture.tilde(p).lowercased() }, x = ParityFixture.expand
        return Uninstaller.FileView(exists: { exists[t($0)] ?? false }, isDirectory: { dir[t($0)] ?? false },
                                    isSymlink: { link[t($0)] ?? false }, children: { (kids[t($0)] ?? []).map(x) },
                                    agentProgram: { agent[t($0)].map(x) }, bundleID: { bundle[t($0)] },
                                    linkTarget: { target[t($0)].map(x) })
    }

    public var installedApps: [InstalledApp] {
        apps.map { InstalledApp(path: $0.path, name: $0.name, bundleID: $0.id) }
    }

    /// The release rules. Empty means pass.
    public func problems(found: [String: [String]]) -> [String] {
        var out: [String] = []
        func covered(_ p: String, by set: [String]) -> Bool {
            let l = p.lowercased()
            return set.contains { s in let m = s.lowercased(); return l == m || l.hasPrefix(m + "/") }
        }
        for a in apps {
            let mine = (found[a.name] ?? []).map(ParityFixture.tilde)
            // 1. Everything the reference finds, Sapu finds, or it is a written-down reference mistake.
            for p in reference[a.name] ?? [] where !covered(p, by: mine) && referenceMistakes[a.name]?[p] == nil {
                out.append("\(a.name): reference finds \(p), Sapu doesn't, and it isn't on the reference-mistakes list")
            }
            // 2. Nothing Sapu claims goes unreviewed.
            for p in mine where reviewed[a.name]?[p] == nil {
                out.append("\(a.name): Sapu claims \(p), which nobody has reviewed")
            }
        }
        // 3. No path, or folder inside it, belongs to two apps.
        let claims = apps.flatMap { a in (found[a.name] ?? []).map { (a.name, ParityFixture.tilde($0).lowercased()) } }
        for (a, p) in claims {
            for (b, q) in claims where a < b && (p == q || p.hasPrefix(q + "/") || q.hasPrefix(p + "/")) {
                out.append("\(p) is claimed by both \(a) and \(b)")
            }
        }
        return out
    }
}

extension Uninstaller {
    /// Leftovers for every app, each guarded by the other apps' IDs, all read through `fs`.
    public static func leftoversForAll(_ apps: [InstalledApp], fs: FileView) -> [String: [String]] {
        let owned = apps.map { a in ([a.bundleID].compactMap { $0 } + embeddedIDs(a.path, primary: a.bundleID ?? "", fs: fs)).map { $0.lowercased() } }
        var out: [String: [String]] = [:]
        for (i, a) in apps.enumerated() {
            let others = Set(owned.enumerated().filter { $0.offset != i }.flatMap(\.element))
            out[a.name] = leftovers(for: a, fs: fs, otherIDs: others, otherNames: Set(apps.filter { $0.path != a.path }.map { $0.name.lowercased() }))
        }
        return out
    }
}

/// The reference tool's tested apps (those on its compatibility list that Homebrew documents), all installed side by side in a
/// home folder holding exactly their documented leftovers, and what the reference finder claimed there. Replayed by
/// `sapu-cli selftest`: Sapu must find every reference path (bar written-down reference mistakes) and no path may go to two apps.
public struct TestedFixture: Codable, Sendable {
    public struct App: Codable, Sendable {
        public var name: String; public var id: String; public var zap: [String]
        public init(name: String, id: String, zap: [String]) { self.name = name; self.id = id; self.zap = zap }
    }
    public var referenceVersion: String
    public var apps: [App]
    public var reference: [String: [String]]
    public var referenceMistakes: [String: [String: String]]

    public init(referenceVersion: String, apps: [App], reference: [String: [String]], referenceMistakes: [String: [String: String]]) {
        self.referenceVersion = referenceVersion; self.apps = apps; self.reference = reference; self.referenceMistakes = referenceMistakes
    }

    public func found() -> [String: [String]] {
        let fs = Uninstaller.FileView.simulated(apps.flatMap { $0.zap.map(ParityFixture.expand) })
        let ids = apps.map { $0.id.lowercased() }, allIDs = Set(ids.filter { !$0.isEmpty })
        let names = apps.map { $0.name.lowercased() }
        var out: [String: [String]] = [:]
        for (i, a) in apps.enumerated() {
            let app = InstalledApp(path: "/Applications/\(a.name).app", name: a.name, bundleID: a.id.isEmpty ? nil : a.id)
            out[a.name] = Uninstaller.leftovers(for: app, fs: fs, otherIDs: allIDs.subtracting([ids[i]]),
                                                otherNames: Set(names).subtracting([names[i]])).map(ParityFixture.tilde)
        }
        return out
    }

    public func problems(found: [String: [String]]) -> [String] {
        var out: [String] = []
        for a in apps {
            let mine = (found[a.name] ?? []).map { $0.lowercased() }
            for p in reference[a.name] ?? [] where referenceMistakes[a.name]?[p] == nil {
                let l = p.lowercased()
                if !mine.contains(where: { l == $0 || l.hasPrefix($0 + "/") }) { out.append("\(a.name): reference finds \(p), Sapu doesn't") }
            }
        }
        var owner: [String: String] = [:]
        for a in apps { for p in found[a.name] ?? [] {
            let l = p.lowercased()
            if let b = owner[l], b != a.name { out.append("\(p) is claimed by both \(b) and \(a.name)") } else { owner[l] = a.name }
        } }
        // A folder inside another app's folder: walk up each path's parents.
        for (p, a) in owner {
            var q = p.parentPath
            while q.count > 1 {
                if let b = owner[q], b != a { out.append("\(p) (\(a)) is inside \(q) (\(b))") }
                q = q.parentPath
            }
        }
        return out
    }
}
