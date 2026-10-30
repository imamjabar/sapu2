import Foundation

/// Facts about one item on this Mac, from your own projects: which of them use Docker, which project a
/// node_modules belongs to and how to reinstall it, which projects load Hugging Face models. The explanation says
/// what a thing is in general; these say what it means for you. Reads only small files at project roots.
public enum YourContext {
    public struct Fact: Sendable, Hashable {
        public let symbol: String
        public let text: String
        public init(_ symbol: String, _ text: String) { self.symbol = symbol; self.text = text }
    }

    /// Call off the main thread: it reads a few small files per project.
    public static func facts(for f: Finding, projects: [Project], running: Set<String>, now: Date = Date()) -> [Fact] {
        let p = f.path.lowercased()
        var out: [Fact] = []

        if ["/.colima", "/.lima", "/.orbstack", "com.docker.docker", "group.dev.orbstack"].contains(where: p.contains) {
            out += containers(projects, running: running, engine: p.contains("colima") ? "Colima" : p.contains("orbstack") ? "OrbStack" : p.contains("lima") ? "Lima" : "Docker Desktop")
        } else if f.category == .projects, let project = owner(of: f.path, in: projects) {
            out += artifact(f, project, now: now)
        } else if p.contains("/.cache/huggingface") || p.contains("/.cache/torch") {
            out += mentions(["transformers", "datasets", "diffusers", "sentence-transformers", "huggingface", "torch"], what: "Hugging Face or PyTorch", projects)
            out += listing(f.path + "/hub", prefix: "models--", label: "Models stored here")
        } else if p.contains("/.ollama") {
            out += mentions(["ollama"], what: "Ollama", projects)
            out += listing(f.path + "/models/manifests/registry.ollama.ai/library", prefix: "", label: "Models stored here")
        } else if ["anaconda3", "miniconda3", "miniforge3", "/.conda"].contains(where: p.contains) {
            out += listing(f.path + "/envs", prefix: "", label: "Environments")
            out += mentions(["environment.yml", "conda"], what: "conda", projects, files: ["environment.yml", "environment.yaml"])
        } else if f.category == .devCaches {
            out += packageManagers(p, projects)
        }

        if let app = f.owner, f.category == .appCaches || f.lockedReason?.contains("running") == true {
            let open = running.contains { $0.localizedCaseInsensitiveContains(app) }
            out.append(open ? Fact("app.badge.fill", "\(app) is open now. Quit it and scan again to clean this.")
                            : Fact("app.dashed", "\(app) isn't running, so this can be cleaned now."))
        }
        if f.category == .downloads, let opened = lastOpened(f.path) {
            out.append(Fact("eye", "You last opened it \(Format.age(opened, now: now))."))
        }
        if let d = f.lastModified, f.category != .projects {
            out.append(Fact("clock", "Last changed \(Format.age(d, now: now))."))
        }
        return out
    }

    // MARK: Pieces

    static func owner(of path: String, in projects: [Project]) -> Project? {
        projects.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    static func containers(_ projects: [Project], running: Set<String>, engine: String) -> [Fact] {
        let markers = ["Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", ".devcontainer"]
        let users = projects.filter { pr in markers.contains { DiskSizer.exists(pr.path + "/" + $0) } }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        var out: [Fact] = []
        if users.isEmpty {
            out.append(Fact("shippingbox", "None of your \(projects.count) projects has a Dockerfile or compose file, so nothing you work on seems to need \(engine) right now."))
        } else {
            let names = users.prefix(4).map(\.name).joined(separator: ", ") + (users.count > 4 ? " and \(users.count - 4) more" : "")
            out.append(Fact("shippingbox.fill", "\(users.count) of your projects use containers (Dockerfile or compose file): \(names)."))
            if let recent = users.first, let d = recent.lastActivity {
                out.append(Fact("clock", "The most recent, \(recent.name), was edited \(Format.age(d))."))
            }
        }
        let names = ["colima", "limactl", "com.docker.backend", "Docker Desktop", "OrbStack"]
        let on = running.contains { r in names.contains { r.localizedCaseInsensitiveContains($0) } }
        out.append(Fact(on ? "play.circle.fill" : "pause.circle", on ? "\(engine) is running now." : "\(engine) isn't running right now."))
        return out
    }

    static func artifact(_ f: Finding, _ pr: Project, now: Date) -> [Fact] {
        var out: [Fact] = []
        let edited = pr.lastActivity.map { Format.age($0, now: now) } ?? "a while ago"
        let state = pr.status == .active ? "you're working on it" : pr.status == .recent ? "touched recently" : "idle"
        out.append(Fact("folder.fill", "Belongs to \(pr.name), last edited \(edited) (\(state))."))
        if let g = pr.git {
            out.append(Fact("arrow.triangle.branch", (g.branch.map { "On branch \($0)" } ?? "Git repository")
                + (g.dirtyFiles > 0 ? ", \(g.dirtyFiles) uncommitted file\(g.dirtyFiles == 1 ? "" : "s"). Your source code is never part of this item." : ", all work committed.")))
        }
        if let (file, cmd) = reinstall(pr.path, f.path.lastComponent) {
            out.append(Fact("arrow.clockwise", "To get it back: run `\(cmd)` in \(pr.name). \(file) pins the exact versions, so you get the same ones."))
        } else if ["node_modules", ".venv", "venv", "vendor", "Pods"].contains(f.path.lastComponent) {
            out.append(Fact("exclamationmark.triangle", "No lockfile in \(pr.name), so a reinstall may pick newer versions than you have now."))
        }
        return out
    }

    /// The lockfile at a project's root and the command that rebuilds `folder` from it.
    static func reinstall(_ root: String, _ folder: String) -> (String, String)? {
        let table: [(String, String, [String])] = [
            ("pnpm-lock.yaml", "pnpm install", ["node_modules"]), ("bun.lockb", "bun install", ["node_modules"]), ("bun.lock", "bun install", ["node_modules"]),
            ("yarn.lock", "yarn install", ["node_modules"]), ("package-lock.json", "npm install", ["node_modules"]),
            ("uv.lock", "uv sync", [".venv", "venv"]), ("poetry.lock", "poetry install", [".venv", "venv"]),
            ("requirements.txt", "pip install -r requirements.txt", [".venv", "venv", "env"]),
            ("Cargo.lock", "cargo build", ["target"]), ("Podfile.lock", "pod install", ["Pods"]),
            ("composer.lock", "composer install", ["vendor"]), ("Gemfile.lock", "bundle install", ["vendor"]),
        ]
        for (file, cmd, folders) in table where folders.contains(folder) && DiskSizer.exists(root + "/" + file) { return (file, cmd) }
        // Build output: the project's own build script.
        if ["dist", "build", "out", ".next", ".nuxt", ".svelte-kit", ".turbo"].contains(folder), DiskSizer.exists(root + "/package.json") {
            return ("package.json", "npm run build")
        }
        return nil
    }

    /// Projects whose dependency files mention any of `words`.
    static func mentions(_ words: [String], what: String, _ projects: [Project], files extra: [String] = []) -> [Fact] {
        let files = ["requirements.txt", "pyproject.toml", "package.json", "environment.yml", "Pipfile"] + extra
        let users = projects.filter { pr in
            files.contains { name in
                guard let s = small(pr.path + "/" + name)?.lowercased() else { return false }
                return words.contains { s.contains($0) }
            }
        }
        if users.isEmpty { return [Fact("questionmark.folder", "None of your \(projects.count) projects lists \(what) in its dependencies.")] }
        let names = users.prefix(4).map(\.name).joined(separator: ", ") + (users.count > 4 ? " and \(users.count - 4) more" : "")
        return [Fact("folder.fill", "Used by \(users.count) of your projects: \(names).")]
    }

    static func packageManagers(_ p: String, _ projects: [Project]) -> [Fact] {
        let table: [(String, String, [String])] = [
            ("/.npm", "npm", ["package-lock.json"]), ("pnpm", "pnpm", ["pnpm-lock.yaml"]), ("yarn", "Yarn", ["yarn.lock"]),
            ("/.bun", "Bun", ["bun.lockb", "bun.lock"]), ("/pip", "pip", ["requirements.txt", "pyproject.toml"]), ("/uv", "uv", ["uv.lock", "pyproject.toml"]),
            ("/.cargo", "Cargo", ["Cargo.toml"]), ("/go", "Go", ["go.mod"]), ("/.gradle", "Gradle", ["build.gradle", "build.gradle.kts"]),
            ("/.m2", "Maven", ["pom.xml"]), ("cocoapods", "CocoaPods", ["Podfile"]), ("/.pub-cache", "Flutter", ["pubspec.yaml"]),
        ]
        guard let (_, tool, files) = table.first(where: { p.contains($0.0) }) else { return [] }
        let users = projects.filter { pr in files.contains { DiskSizer.exists(pr.path + "/" + $0) } }
        if users.isEmpty { return [Fact("questionmark.folder", "None of your \(projects.count) projects uses \(tool), so cleaning this costs you nothing.")] }
        let active = users.filter { $0.status == .active }.count
        return [Fact("folder.fill", "\(users.count) of your projects use \(tool)\(active > 0 ? ", \(active) active" : ""). Their next install downloads packages again instead of copying from here.")]
    }

    static func listing(_ dir: String, prefix: String, label: String) -> [Fact] {
        let names = DiskSizer.children(dir, includeHidden: false).map(\.lastComponent).filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).replacingOccurrences(of: "--", with: "/") }.sorted()
        guard !names.isEmpty else { return [] }
        return [Fact("list.bullet", "\(label) (\(names.count)): " + names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " …" : ""))]
    }

    static func lastOpened(_ path: String) -> Date? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    /// A text file under 256 KB, or nil.
    static func small(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) < 262_144 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
