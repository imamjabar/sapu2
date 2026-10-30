import Foundation

public struct VersionFinding: Codable, Sendable, Identifiable, Hashable {
    public enum Level: String, Codable, Sendable { case ok, outdated, eol, unknown }
    public var id: String { "\(product)|\(version)|\(source)" }
    public var product: String
    public var version: String
    /// Where it was found, e.g. "Homebrew php@7.4" or "Campus Intelligence · composer.json".
    public var source: String
    public var level: Level
    public var message: String
    public var fix: String?
}

/// Runtime support status from endoflife.date (live, cached 24 h), with a small bundled
/// fallback for end-of-life dates when offline. Patch releases of a supported cycle are where
/// CVE fixes ship, so "behind the latest patch" is reported as a security warning.
public enum VersionAudit {
    public struct Cycle: Codable, Sendable {
        public var cycle: String
        public var eol: String?
        public var latest: String?
        public init(cycle: String, eol: String?, latest: String?) { self.cycle = cycle; self.eol = eol; self.latest = latest }
    }

    /// endoflife.date product ids.
    static let products = ["php", "nodejs", "python", "go", "ruby", "laravel"]

    static let display = ["php": "PHP", "nodejs": "Node.js", "python": "Python", "go": "Go", "ruby": "Ruby", "laravel": "Laravel"]

    /// Offline fallback: end-of-life dates only.
    static let bundled: [String: [Cycle]] = [
        "php": [("7.4", "2022-11-28"), ("8.0", "2023-11-26"), ("8.1", "2025-12-31"), ("8.2", "2026-12-31"), ("8.3", "2027-12-31"), ("8.4", "2028-12-31")].map { Cycle(cycle: $0.0, eol: $0.1, latest: nil) },
        "nodejs": [("14", "2023-04-30"), ("16", "2023-09-11"), ("18", "2025-04-30"), ("20", "2026-04-30"), ("22", "2027-04-30"), ("24", "2028-04-30")].map { Cycle(cycle: $0.0, eol: $0.1, latest: nil) },
        "python": [("3.7", "2023-06-27"), ("3.8", "2024-10-07"), ("3.9", "2025-10-31"), ("3.10", "2026-10-31"), ("3.11", "2027-10-31"), ("3.12", "2028-10-31"), ("3.13", "2029-10-31")].map { Cycle(cycle: $0.0, eol: $0.1, latest: nil) },
    ]

    // MARK: Data

    static var cacheURL: URL { Store.directory.appendingPathComponent("eol-cache.json") }

    struct Cache: Codable { var fetched: Date; var data: [String: [Cycle]] }

    /// Load cycles: cached if under 24 h old, otherwise fetch; bundled data if offline.
    public static func cycles(allowNetwork: Bool) async -> (data: [String: [Cycle]], live: Bool) {
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d),
           Date().timeIntervalSince(c.fetched) < 86_400 {
            return (c.data, true)
        }
        guard allowNetwork else { return (bundled, false) }
        var out: [String: [Cycle]] = [:]
        await withTaskGroup(of: (String, [Cycle]?).self) { group in
            for p in products {
                group.addTask {
                    var req = URLRequest(url: URL(string: "https://endoflife.date/api/\(p).json")!)
                    req.timeoutInterval = 8
                    guard let (data, _) = try? await URLSession.shared.data(for: req) else { return (p, nil) }
                    return (p, parseCycles(data))
                }
            }
            for await (p, c) in group { if let c { out[p] = c } }
        }
        if out.isEmpty { return (bundled, false) }
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Cache(fetched: Date(), data: out)).write(to: cacheURL)
        return (out, true)
    }

    /// endoflife.date returns `eol` as a date string or a bool.
    static func parseCycles(_ data: Data) -> [Cycle]? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let cycle = o["cycle"].map({ "\($0)" }) else { return nil }
            var eol: String?
            if let s = o["eol"] as? String { eol = s } else if let b = o["eol"] as? Bool, b { eol = "1970-01-01" }
            return Cycle(cycle: cycle, eol: eol, latest: o["latest"].map { "\($0)" })
        }
    }

    // MARK: Evaluate

    public static func evaluate(product: String, version: String, source: String,
                                cycles: [String: [Cycle]], now: Date = Date()) -> VersionFinding {
        let name = display[product] ?? product
        var f = VersionFinding(product: name, version: version, source: source, level: .unknown,
                               message: "No support data for \(name) \(version).", fix: nil)
        guard let list = cycles[product], !list.isEmpty else { return f }
        let match = list.filter { version == $0.cycle || version.hasPrefix($0.cycle + ".") }.max { $0.cycle.count < $1.cycle.count }
        let newest = list.filter { !isEOL($0, now) }.max { compare($0.cycle, $1.cycle) < 0 }
        guard let cycle = match else {
            if let oldest = list.min(by: { compare($0.cycle, $1.cycle) < 0 }), compare(version, oldest.cycle) < 0 {
                f.level = .eol
                f.message = "\(name) \(version) is older than every release line still tracked. It gets no security (CVE) fixes."
                if let n = newest { f.fix = "Upgrade to \(name) \(n.latest ?? n.cycle)" }
            } else {
                f.message = "\(name) \(version) is newer than Sapu2's offline data. Use Check online for its support status."
            }
            return f
        }
        if isEOL(cycle, now) {
            f.level = .eol
            let since = cycle.eol.flatMap { $0 == "1970-01-01" ? nil : $0 }
            f.message = "\(name) \(cycle.cycle) is end-of-life\(since.map { " since \($0)" } ?? ""). It gets no security (CVE) fixes."
            if let n = newest { f.fix = "Upgrade to \(name) \(n.latest ?? n.cycle)" }
        } else if let latest = cycle.latest, isFullVersion(version), compare(version, latest) < 0 {
            f.level = .outdated
            f.message = "\(name) \(version) is behind the latest \(cycle.cycle).x patch (\(latest)). Patch releases carry the security fixes."
            f.fix = "Update to \(name) \(latest) or newer"
        } else {
            f.level = .ok
            f.message = "\(name) \(version) is supported\(cycle.eol.map { " until \($0)" } ?? "")."
        }
        return f
    }

    static func isEOL(_ c: Cycle, _ now: Date) -> Bool {
        guard let e = c.eol else { return false }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let d = fmt.date(from: e) else { return false }
        return d < now
    }

    static func isFullVersion(_ v: String) -> Bool { v.split(separator: ".").count >= 3 }

    /// Numeric dotted-version compare ("8.2.10" > "8.2.9").
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let y = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// First "1.2" or "1.2.3" in a string.
    public static func extractVersion(_ s: String) -> String? {
        guard let r = s.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }

    /// Lowest version a constraint like "^8.1", ">=18", "~3.10", "8.2.*" allows.
    public static func constraintFloor(_ s: String) -> String? {
        let first = s.split(separator: "|").first.map(String.init) ?? s
        if let v = extractVersion(first) { return v }
        if let r = first.range(of: #"\d+"#, options: .regularExpression) { return String(first[r]) }
        return nil
    }

    /// A declared constraint only matters when every version it allows is end-of-life.
    /// `>=18` or `^8.1` (any 8.x ≥ 8.1) still allow supported releases; `18`, `^18`, `~3.9.0` do not.
    public static func evaluateConstraint(product: String, constraint: String, projects: [String], cycles: [String: [Cycle]], now: Date = Date()) -> VersionFinding? {
        guard let list = cycles[product], !list.isEmpty else { return nil }
        let alternatives = constraint.replacingOccurrences(of: "||", with: "|").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        var floors: [String] = []
        for alt in alternatives {
            if alt.hasPrefix(">") || alt == "*" || alt.isEmpty { return nil }
            guard let floor = constraintFloor(alt) else { return nil }
            floors.append(floor)
            let parts = floor.split(separator: ".").map(String.init)
            let allowed: [Cycle]
            if (alt.hasPrefix("^") || (alt.hasPrefix("~") && parts.count == 2)) && parts.count >= 2 {
                // ^X.Y / ~X.Y: any X.* release at or above X.Y.
                allowed = list.filter { $0.cycle.split(separator: ".").first.map(String.init) == parts[0] && compare($0.cycle, cycleKey(floor, list)) >= 0 }
            } else {
                let key = cycleKey(floor, list)
                allowed = list.filter { $0.cycle == key }
            }
            if allowed.isEmpty || allowed.contains(where: { !isEOL($0, now) }) { return nil }
        }
        let name = display[product] ?? product
        var f = evaluate(product: product, version: floors.first ?? constraint, source: "", cycles: cycles, now: now)
        f.level = .eol
        let who = projects.prefix(3).joined(separator: ", ") + (projects.count > 3 ? " +\(projects.count - 3)" : "")
        f.version = constraint
        f.source = who + " · requires"
        let verb = product == "laravel" ? (projects.count == 1 ? "uses" : "use") : (projects.count == 1 ? "only allows" : "only allow")
        f.message = "\(projects.count == 1 ? "This project" : "\(projects.count) projects") \(verb) \(name) \(constraint)\(product == "laravel" ? " (composer.lock)" : ""), which is end-of-life: no security (CVE) fixes."
        if product == "laravel" { f.source = who + " · uses" }
        f.fix = f.fix.map { "Raise the requirement, then " + $0.prefix(1).lowercased() + $0.dropFirst() }
        return f
    }

    /// The release-line key a version belongs to ("8.2.10" → "8.2" for PHP, "18.2" → "18" for Node).
    static func cycleKey(_ version: String, _ list: [Cycle]) -> String {
        list.filter { version == $0.cycle || version.hasPrefix($0.cycle + ".") }.max { $0.cycle.count < $1.cycle.count }?.cycle ?? version
    }

    // MARK: Installed runtimes

    public static func installedRuntimes() -> [(product: String, version: String, source: String)] {
        var out: [(String, String, String)] = []
        func probe(_ product: String, _ exe: String, _ args: [String], _ source: String) {
            let r = Shell.run([exe] + args, timeout: 5)
            if r.status == 0, let v = extractVersion(r.out + r.err) { out.append((product, v, source)) }
        }
        if let php = Shell.which("php") { probe("php", php, ["-v"], "php on PATH") }
        // opt/php@X links into the Cellar ("../Cellar/php@8.1/8.1.33"); old aliases may point at another formula.
        var kegs = Set<String>()
        for dir in DiskSizer.children("/opt/homebrew/opt").sorted() where dir.lastComponent.hasPrefix("php") {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dir),
                  kegs.insert(target).inserted, let v = extractVersion(target.lastComponent) else { continue }
            let formula = target.parentPath.lastComponent
            out.append(("php", v, "Homebrew \(formula)"))
        }
        for dir in DiskSizer.children("/Applications/MAMP/bin/php") {
            if let v = extractVersion(dir.lastComponent) { out.append(("php", v, "MAMP \(dir.lastComponent)")) }
        }
        if let node = Shell.which("node") { probe("nodejs", node, ["-v"], "node on PATH") }
        for dir in DiskSizer.children("~/.nvm/versions/node".expandingTilde) {
            if let v = extractVersion(dir.lastComponent) { out.append(("nodejs", v, "nvm \(dir.lastComponent)")) }
        }
        if let py = Shell.which("python3") { probe("python", py, ["--version"], "python3 on PATH (\(py.tildePath))") }
        for base in ["~/miniconda3", "~/anaconda3", "~/miniforge3"].map(\.expandingTilde) {
            for env in DiskSizer.children(base + "/envs") where DiskSizer.exists(env + "/bin/python") {
                probe("python", env + "/bin/python", ["--version"], "conda env \(env.lastComponent)")
            }
        }
        if let go = Shell.which("go") { probe("go", go, ["version"], "go on PATH") }
        if let ruby = Shell.which("ruby"), ruby != "/usr/bin/ruby" { probe("ruby", ruby, ["-v"], "ruby on PATH") }
        // Same runtime reachable two ways (PATH and its Homebrew keg): keep the more specific source.
        var seen = Set<String>()
        let specific = out.filter { !$0.2.contains("on PATH") }.map { "\($0.0)|\($0.1)" }
        return out.filter { !($0.2.contains("on PATH") && specific.contains("\($0.0)|\($0.1)")) }
            .filter { seen.insert("\($0.0)|\($0.1)|\($0.2)").inserted }
    }

    // MARK: Project declarations

    public static func declaredVersions(in project: String) -> [String: String] {
        var out: [String: String] = [:]
        func json(_ file: String) -> [String: Any]? {
            guard let d = FileManager.default.contents(atPath: project + "/" + file) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        func text(_ file: String) -> String? {
            guard let d = FileManager.default.contents(atPath: project + "/" + file), d.count < 200_000 else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        if let c = json("composer.json"), let req = c["require"] as? [String: Any] {
            if let php = req["php"] as? String { out["php"] = php }
        }
        if let lock = json("composer.lock"), let pkgs = lock["packages"] as? [[String: Any]],
           let fw = pkgs.first(where: { ($0["name"] as? String) == "laravel/framework" }), let v = fw["version"] as? String {
            out["laravel"] = v.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        }
        if let p = json("package.json"), let engines = p["engines"] as? [String: Any], let node = engines["node"] as? String {
            out["nodejs"] = node
        }
        for f in [".nvmrc", ".node-version"] {
            if let t = text(f)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out["nodejs"] = t }
        }
        if let t = text(".python-version")?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out["python"] = t }
        else if let t = text("pyproject.toml"), let r = t.range(of: #"requires-python\s*=\s*"[^"]+""#, options: .regularExpression) {
            out["python"] = String(t[r]).components(separatedBy: "\"")[1]
        }
        if let t = text("go.mod"), let r = t.range(of: #"(?m)^go \d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            out["go"] = String(t[r].dropFirst(3))
        }
        return out
    }

    /// Check installed runtimes and every project's declared versions.
    public static func audit(projects: [Project], allowNetwork: Bool) async -> (findings: [VersionFinding], live: Bool) {
        let (cycles, live) = await cycles(allowNetwork: allowNetwork)
        var out = installedRuntimes().map { evaluate(product: $0.product, version: $0.version, source: $0.source, cycles: cycles) }
        // One finding per product + constraint, listing the projects that declare it.
        var groups: [String: (product: String, constraint: String, projects: [String])] = [:]
        for p in projects {
            for (product, constraint) in p.declared {
                let key = product + "|" + constraint
                groups[key, default: (product, constraint, [])].projects.append(p.name)
            }
        }
        for g in groups.values.sorted(by: { $0.projects.count > $1.projects.count }) {
            guard let f = evaluateConstraint(product: g.product, constraint: g.constraint, projects: g.projects, cycles: cycles) else { continue }
            out.append(f)
        }
        let order: [VersionFinding.Level] = [.eol, .outdated, .unknown, .ok]
        out.sort { (order.firstIndex(of: $0.level)!, $0.product) < (order.firstIndex(of: $1.level)!, $1.product) }
        return (out, live)
    }
}
