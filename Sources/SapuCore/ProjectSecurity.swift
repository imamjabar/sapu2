import Foundation

public struct SecurityIssue: Codable, Sendable, Identifiable, Hashable {
    public enum Level: String, Codable, Sendable, Comparable {
        case danger, warning, info
        var rank: Int { self == .danger ? 0 : self == .warning ? 1 : 2 }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }
    public var id: String { "\(projectPath)|\(kind)|\(file ?? "")|\(line ?? 0)" }
    public var projectPath: String
    public var projectName: String
    public var level: Level
    /// "env", "key", "secret", "remote", "lockfile".
    public var kind: String
    public var title: String
    public var detail: String
    /// Path relative to the project.
    public var file: String?
    public var line: Int?
    public var fix: String
}

/// Offline checks of a project for the mistakes that leak access: committed `.env` files and private keys,
/// API tokens written into code, tokens inside git remote URLs, and dependencies installed without a lockfile.
/// Reads only files git tracks (what a push publishes), with size and count limits so big repos stay cheap.
/// Secrets are never shown in full or written anywhere.
public enum ProjectSecurity {
    static let maxFileBytes = 512 * 1024
    static let maxFiles = 4000
    static let maxTotalBytes = 40 * 1024 * 1024
    static let maxIssues = 40

    /// Template env files that are meant to be committed.
    static let envTemplates = ["example", "sample", "template", "dist", "defaults", "default", "schema", "tpl"]

    /// `.env`, `.env.local`, `prod.env`; not `.env.example` or other templates.
    static func isEnvFile(_ name: String) -> Bool {
        let n = name.lowercased()
        guard n == ".env" || n.hasPrefix(".env.") || (n.hasSuffix(".env") && n.count > 4) else { return false }
        let words = n.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
        return !words.contains { envTemplates.contains(String($0)) }
    }

    static let keyNames: Set<String> = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    static let keyStoreSuffixes = [".p12", ".pfx", ".jks", ".keystore", ".ppk"]

    /// Token formats with a recognisable prefix, so matches are real credentials, not words.
    static let patternSource: [(String, [String], String, SecurityIssue.Level)] = [
        ("AWS access key", ["AKIA", "ASIA"], #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, SecurityIssue.Level.danger),
        ("GitHub token", ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"], #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#, .danger),
        ("GitHub token", ["github_pat_"], #"\bgithub_pat_[A-Za-z0-9_]{50,}\b"#, .danger),
        ("Anthropic API key", ["sk-ant-"], #"\bsk-ant-[A-Za-z0-9_\-]{30,}"#, .danger),
        ("OpenAI API key", ["T3BlbkFJ", "sk-proj-"], #"\bsk-(proj-|svcacct-)?[A-Za-z0-9]{20,}T3BlbkFJ[A-Za-z0-9]{20,}|\bsk-proj-[A-Za-z0-9_\-]{40,}"#, .danger),
        ("Slack token", ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"], #"\bxox[baprs]-[0-9A-Za-z\-]{10,}"#, .danger),
        ("Stripe live key", ["sk_live_", "rk_live_"], #"\b(sk|rk)_live_[0-9A-Za-z]{20,}"#, .danger),
        ("Google API key", ["AIza"], #"\bAIza[0-9A-Za-z_\-]{35}\b"#, .warning),
        ("Private key", ["PRIVATE KEY"], #"-----BEGIN (RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY( BLOCK)?-----"#, .danger),
        ("npm token", ["_authToken"], #"_authToken\s*=\s*(?!\$\{)[A-Za-z0-9_\-]{20,}"#, .danger),
        ("Database password in a URL", ["postgres", "mysql", "mariadb", "mongodb", "redis", "amqp"], #"\b(postgres|postgresql|mysql|mariadb|mongodb(\+srv)?|redis|rediss|amqp)://[^:\s/@'"]+:(?!\$\{|<|\*|password|pass@|xxx|changeme|secret@|root@)[^@\s/'"]{4,}@"#, .warning),
    ]
    static let patterns: [(name: String, prefixes: [String], regex: NSRegularExpression, level: SecurityIssue.Level)] =
        patternSource.map { ($0.0, $0.1, try! NSRegularExpression(pattern: $0.2), $0.3) }

    /// Files never read for tokens: binaries, minified bundles, lockfiles and fixtures full of fake keys.
    static let skippedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "pdf", "zip", "gz", "tgz", "xz", "7z", "jar",
                                                 "woff", "woff2", "ttf", "otf", "eot", "mp3", "mp4", "mov", "wav", "so", "dylib", "a", "o",
                                                 "class", "pyc", "parquet", "sqlite", "db", "xlsx", "docx", "pptx", "lock", "map", "svg", "ipynb"]
    static let skippedNames: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "composer.lock", "poetry.lock", "uv.lock",
                                            "Cargo.lock", "go.sum", "Gemfile.lock", "bun.lockb"]

    public static func check(projectPath: String, name: String, git: (([String], String) -> Shell.Result)? = nil) -> [SecurityIssue] {
        let run = git ?? { args, cwd in Shell.run(["git"] + args, cwd: cwd, timeout: 15) }
        var out: [SecurityIssue] = []
        func add(_ level: SecurityIssue.Level, _ kind: String, _ title: String, _ detail: String, _ file: String? = nil, _ line: Int? = nil, fix: String) {
            guard out.count < maxIssues else { return }
            out.append(SecurityIssue(projectPath: projectPath, projectName: name, level: level, kind: kind, title: title, detail: detail,
                                     file: file, line: line, fix: fix))
        }

        let isGit = DiskSizer.exists(projectPath + "/.git")
        let lsFiles = isGit ? run(["ls-files", "-z"], projectPath) : nil
        let tracked: [String] = lsFiles.flatMap { $0.status == 0 ? $0.out.split(separator: "\0").map(String.init) : nil } ?? []
        let trackedSet = Set(tracked)

        // Committed .env files and keys: anyone with the repo has them, and git history keeps them after deletion.
        for f in tracked {
            let n = f.lastComponent
            if isEnvFile(n) {
                add(.danger, "env", "\(f) is committed", "Environment files usually hold passwords and API keys. Anyone who can read this repository has them, and they stay in git history.",
                    f, fix: "git rm --cached \(f), add it to .gitignore, then change every key it held.")
            } else if keyNames.contains(n) || keyStoreSuffixes.contains(where: n.lowercased().hasSuffix) {
                add(.danger, "key", "Private key \(f) is committed", "A private key or key store is in the repository.", f,
                    fix: "Remove it with git rm --cached, replace the key, and keep keys outside the repo.")
            }
        }

        // .env files present but not ignored: the next `git add .` publishes them.
        if isGit {
            let candidates = envFilesOnDisk(projectPath).filter { !trackedSet.contains($0) }
            for f in candidates {
                let r = run(["check-ignore", "-q", f], projectPath)
                if r.status == 1 {
                    add(.warning, "env", "\(f) isn't ignored by git", "It isn't committed yet, but `git add .` would commit it.", f,
                        fix: "Add \(f.lastComponent) to .gitignore.")
                }
            }
            // Tokens inside remote URLs are stored in plain text in .git/config and shown by `git remote -v`.
            let remotes = run(["remote", "-v"], projectPath).out
            for line in Set(remotes.split(separator: "\n").compactMap { $0.split(separator: "\t").dropFirst().first.map { String($0.split(separator: " ")[0]) } }) {
                if let u = URLComponents(string: line), ["http", "https"].contains(u.scheme ?? ""), u.password != nil || (u.user ?? "").count >= 20 {
                    add(.danger, "remote", "A git remote URL holds a password or token", "\(u.host ?? "remote") · stored in plain text in .git/config.",
                        ".git/config", fix: "git remote set-url origin https://\(u.host ?? "host")\(u.path) and sign in with a credential helper or SSH.")
                }
            }
        } else {
            for f in envFilesOnDisk(projectPath) where !DiskSizer.exists(projectPath + "/.gitignore") {
                add(.info, "env", "\(f) has no .gitignore beside it", "This folder isn't a git repository yet. When it becomes one, ignore env files before the first commit.", f,
                    fix: "Create a .gitignore with .env* in it.")
                break
            }
        }

        // Tokens written into tracked files.
        var read = 0, bytes = 0
        for f in tracked where read < maxFiles && bytes < maxTotalBytes && out.count < maxIssues {
            let n = f.lastComponent, ext = (n as NSString).pathExtension.lowercased()
            if skippedExtensions.contains(ext) || skippedNames.contains(n) || n.hasSuffix(".min.js") || isEnvFile(n) { continue }
            let lower = f.lowercased()
            if lower.contains("node_modules/") || lower.contains("vendor/") || lower.contains("test") && lower.contains("fixture") { continue }
            let full = projectPath + "/" + f
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full), (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? Int, size > 0, size <= maxFileBytes,
                  let data = FileManager.default.contents(atPath: full), !data.prefix(1024).contains(0) else { continue }
            read += 1; bytes += size
            let ns = NSString(data: data, encoding: NSUTF8StringEncoding) ?? (String(decoding: data, as: UTF8.self) as NSString)
            let text = ns as String
            for p in patterns where p.prefixes.contains(where: { ns.range(of: $0).location != NSNotFound }) {
                guard let m = p.regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                let value = ns.substring(with: m.range)
                if looksLikePlaceholder(value) { continue }
                let line = ns.substring(to: m.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                // Test suites carry throwaway credentials for local databases; worth a look, not an alarm.
                let inTests = ["test/", "tests/", "spec/", "__tests__/", "_test.", ".test.", ".spec.", "fixtures/"].contains { lower.contains($0) }
                add(inTests ? .info : p.level, "secret", "\(p.name) in \(f)",
                    "Line \(line): \(mask(value)). " + (inTests ? "It's in a test file, so it may be a throwaway local credential." : "Anyone who can read the repository can use it."), f, line,
                    fix: "Revoke it with the provider, move it to an ignored .env file or the keychain, and read it from the environment.")
            }
        }

        // Installs without a lockfile pull whatever version is newest that day, including a compromised one.
        let has = { (f: String) in DiskSizer.exists(projectPath + "/" + f) }
        if has("package.json"), !["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"].contains(where: has),
           !(isGit && !tracked.contains("package.json")) {
            add(.warning, "lockfile", "No lockfile for package.json", "Every install resolves versions again, so a newly published malicious release can slip in, and builds differ between machines.",
                "package.json", fix: "Run npm install (or pnpm/yarn/bun install) and commit the lockfile it writes.")
        }
        return out.sorted { ($0.level, $0.file ?? "") < ($1.level, $1.file ?? "") }
    }

    /// `.env` files in the project's top three levels, outside dependency folders.
    static func envFilesOnDisk(_ root: String) -> [String] {
        var out: [String] = []
        func walk(_ dir: String, _ depth: Int) {
            for kid in DiskSizer.children(dir, includeHidden: true) where !DiskSizer.isSymlink(kid) {
                let n = kid.lastComponent
                if DiskSizer.isDirectory(kid) {
                    if depth < 2, !n.hasPrefix("."), !["node_modules", "vendor", "venv", "dist", "build", "target", "Pods"].contains(n) { walk(kid, depth + 1) }
                } else if isEnvFile(n) {
                    out.append(String(kid.dropFirst(root.count + 1)))
                }
            }
        }
        walk(root, 0)
        return out.sorted()
    }

    static func looksLikePlaceholder(_ v: String) -> Bool {
        let l = v.lowercased()
        return ["xxxx", "example", "your_", "your-", "dummy", "placeholder", "redacted", "<", "1234567890", "abcdef"].contains { l.contains($0) }
    }

    /// "sk-ant-api03-AbC…" → first 8 characters and the length, never the secret.
    public static func mask(_ v: String) -> String {
        "\(v.prefix(8))… (\(v.count) characters)"
    }
}

/// On-demand dependency vulnerability audit using each ecosystem's own tool, against the lockfile.
public enum DependencyAudit {
    public static func run(projectPath: String) -> String {
        var parts: [String] = []
        let has = { (f: String) in DiskSizer.exists(projectPath + "/" + f) }
        func npmStyle(_ tool: String, _ args: [String]) {
            let r = Shell.run([tool] + args, cwd: projectPath, timeout: 90)
            if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let meta = o["metadata"] as? [String: Any], let v = meta["vulnerabilities"] as? [String: Int] {
                parts.append("\(tool): " + ["critical", "high", "moderate", "low"].map { "\(v[$0] ?? 0) \($0)" }.joined(separator: ", "))
            } else { parts.append("\(tool) audit failed: \((r.err.isEmpty ? r.out : r.err).prefix(120))") }
        }
        if has("package-lock.json") { npmStyle("npm", ["audit", "--json"]) }
        if has("pnpm-lock.yaml"), Shell.which("pnpm") != nil { npmStyle("pnpm", ["audit", "--json"]) }
        if has("composer.lock") {
            let r = Shell.run(["composer", "audit", "--format=json", "--locked"], cwd: projectPath, timeout: 90)
            if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let adv = (o["advisories"] as? [String: Any]) ?? [:]
                let count = adv.values.reduce(0) { $0 + (($1 as? [Any])?.count ?? 0) }
                parts.append("composer: \(count) advisories in \(adv.count) packages")
            } else { parts.append("composer audit failed: \(r.err.prefix(120))") }
        }
        if has("Cargo.lock"), Shell.which("cargo-audit") != nil {
            let r = Shell.run(["cargo-audit", "audit", "--json"], cwd: projectPath, timeout: 90)
            if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let v = o["vulnerabilities"] as? [String: Any] {
                parts.append("cargo: \(v["count"] as? Int ?? 0) vulnerabilities")
            } else { parts.append("cargo audit failed: \(r.err.prefix(120))") }
        }
        if has("requirements.txt") || has("pyproject.toml"), Shell.which("pip-audit") != nil {
            let args = has("requirements.txt") ? ["pip-audit", "-r", "requirements.txt", "-f", "json", "--progress-spinner", "off"] : ["pip-audit", "-f", "json", "--progress-spinner", "off", "."]
            let r = Shell.run(args, cwd: projectPath, timeout: 120)
            if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let deps = o["dependencies"] as? [[String: Any]] {
                let n = deps.reduce(0) { $0 + (($1["vulns"] as? [Any])?.count ?? 0) }
                parts.append("pip-audit: \(n) vulnerabilities in \(deps.count) packages")
            } else { parts.append("pip-audit failed: \(r.err.prefix(120))") }
        }
        if Shell.which("osv-scanner") != nil {
            let r = Shell.run(["osv-scanner", "scan", "source", "-r", "--format", "json", "."], cwd: projectPath, timeout: 120)
            if let d = r.out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let results = o["results"] as? [[String: Any]] {
                let n = results.flatMap { ($0["packages"] as? [[String: Any]]) ?? [] }.reduce(0) { $0 + (($1["vulnerabilities"] as? [Any])?.count ?? 0) }
                parts.append("osv-scanner: \(n) known vulnerabilities")
            }
        }
        if parts.isEmpty {
            parts.append("Nothing to audit: needs a package-lock.json, pnpm-lock.yaml or composer.lock (or cargo-audit, pip-audit or osv-scanner installed).")
        }
        return parts.joined(separator: "\n")
    }
}
