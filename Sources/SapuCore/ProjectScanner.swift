import Darwin
import Foundation

/// A generated folder inside a project that can be rebuilt from the project's manifest.
struct ArtifactKind: Sendable {
    var names: [String]
    var ecosystem: String
    /// Any of these next to the folder makes it this kind.
    var markers: [String]
    var lockfiles: [String]
    /// Required inside the folder (e.g. `pyvenv.cfg` for virtualenvs).
    var inside: String? = nil
    var defaultSafety: Safety = .safe
    var usedFor: String
    var rebuild: String
    var action: CleanAction = .trash
}

public struct ProjectScanResult: Sendable {
    public var projects: [Project]
    public var findings: [Finding]
}

public final class ProjectScanner: @unchecked Sendable {
    public var activeDays = 14
    public var staleDays = 60
    public var maxDepth = 8

    static let kinds: [ArtifactKind] = [
        ArtifactKind(names: ["node_modules"], ecosystem: "Node", markers: ["package.json"],
                     lockfiles: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"],
                     usedFor: "Installed npm dependencies for this project.", rebuild: "npm install (or pnpm/yarn/bun install)"),
        ArtifactKind(names: [".venv", "venv", "env", "virtualenv"], ecosystem: "Python",
                     markers: [], lockfiles: ["uv.lock", "poetry.lock", "Pipfile.lock", "requirements.txt", "pyproject.toml"],
                     inside: "pyvenv.cfg", usedFor: "Python virtual environment with this project's packages.",
                     rebuild: "uv sync / pip install -r requirements.txt", action: .freezeThenTrash),
        ArtifactKind(names: ["vendor"], ecosystem: "PHP", markers: ["composer.json"], lockfiles: ["composer.lock"],
                     usedFor: "Composer dependencies (Laravel framework and packages).", rebuild: "composer install"),
        ArtifactKind(names: ["target"], ecosystem: "Rust", markers: ["Cargo.toml"], lockfiles: ["Cargo.lock"],
                     usedFor: "Rust compiler output for every profile and toolchain.", rebuild: "cargo build"),
        ArtifactKind(names: ["target"], ecosystem: "Java", markers: ["pom.xml"], lockfiles: ["pom.xml"],
                     usedFor: "Maven build output.", rebuild: "mvn package"),
        ArtifactKind(names: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".expo", ".astro", ".vercel"],
                     ecosystem: "Node", markers: ["package.json"], lockfiles: ["package.json"],
                     usedFor: "Framework build cache / dev-server output.", rebuild: "Recreated by the next dev or build run."),
        ArtifactKind(names: ["dist", "out"], ecosystem: "Node", markers: ["package.json"], lockfiles: ["package.json"],
                     defaultSafety: .check, usedFor: "Built output. Sometimes it is the thing you deploy.", rebuild: "npm run build"),
        ArtifactKind(names: ["build", ".gradle"], ecosystem: "Android/Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                     lockfiles: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                     usedFor: "Gradle build output and project cache.", rebuild: "./gradlew build"),
        ArtifactKind(names: ["build", ".dart_tool"], ecosystem: "Flutter", markers: ["pubspec.yaml"], lockfiles: ["pubspec.lock"],
                     usedFor: "Flutter build output and tool cache.", rebuild: "flutter pub get && flutter build"),
        ArtifactKind(names: ["Pods"], ecosystem: "CocoaPods", markers: ["Podfile"], lockfiles: ["Podfile.lock"],
                     usedFor: "Installed CocoaPods.", rebuild: "pod install"),
        ArtifactKind(names: [".build"], ecosystem: "Swift", markers: ["Package.swift"], lockfiles: ["Package.swift"],
                     usedFor: "SwiftPM build output.", rebuild: "swift build"),
        ArtifactKind(names: [".godot"], ecosystem: "Godot", markers: ["project.godot"], lockfiles: ["project.godot"],
                     usedFor: "Godot import cache.", rebuild: "Re-imported when you open the project."),
        ArtifactKind(names: [".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox"], ecosystem: "Python",
                     markers: [], lockfiles: [], usedFor: "Test/lint tool cache.", rebuild: "Recreated on the next run."),
    ]

    static let artifactNames: Set<String> = Set(kinds.flatMap(\.names))

    static let markers: Set<String> = [
        "package.json", "composer.json", "pyproject.toml", "requirements.txt", "setup.py", "go.mod", "Cargo.toml",
        "Gemfile", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "Podfile", "project.godot",
        "Package.swift", "artisan", "manage.py", "environment.yml",
    ]

    /// Top-level home folders that hold tools, caches or media, not projects.
    static let skipTopLevel: Set<String> = [
        "Library", "Applications", "Music", "Pictures", "Movies", "Public", ".Trash",
        "anaconda3", "miniconda3", "miniforge3", "opt", "go",
    ]

    /// Folders never worth descending into.
    static let skipAnywhere: Set<String> = [".git", ".hg", ".svn", "__pycache__", ".idea", ".vscode", ".DS_Store", "site-packages"]
    static let bundleSuffixes = [".app", ".photoslibrary", ".fcpbundle", ".musiclibrary", ".logicx", ".imovielibrary", ".xcarchive", ".framework", ".bundle"]

    public init() {}

    public func scan(roots: [String] = [NSHomeDirectory()],
                     cancelled: @escaping () -> Bool,
                     onDiscover: (String) -> Void,
                     onArtifactsFound: (Int) -> Void,
                     sizeArtifact: (String) -> SizeResult) -> ProjectScanResult {
        var markerDirs = Set<String>()
        var gitRoots = Set<String>()
        var candidates: [String] = []

        for root in roots { walk(root, markerDirs: &markerDirs, gitRoots: &gitRoots, candidates: &candidates, cancelled: cancelled, onDiscover: onDiscover) }

        // Resolve artifact candidates to kinds.
        var artifacts: [(path: String, kind: ArtifactKind)] = []
        for c in candidates {
            if let k = kind(for: c) { artifacts.append((c, k)) }
        }
        onArtifactsFound(artifacts.count)

        // Group marker dirs into projects: the enclosing git repo if there is one.
        func projectRoot(for dir: String) -> String {
            var p = dir
            var best = dir
            while p.count > 1 && p != NSHomeDirectory() {
                if gitRoots.contains(p) { best = p }
                p = p.parentPath
            }
            return best
        }
        var projectPaths = Set(markerDirs.map(projectRoot))
        projectPaths.formUnion(gitRoots)
        projectPaths.remove(NSHomeDirectory())

        var byProject: [String: [(path: String, kind: ArtifactKind)]] = [:]
        for a in artifacts {
            let owner = projectRoot(for: a.path.parentPath)
            byProject[owner, default: []].append(a)
            projectPaths.insert(owner)
        }

        var projects: [Project] = []
        var findings: [Finding] = []
        let now = Date()
        for path in projectPaths.sorted() {
            if cancelled() { break }
            let arts = byProject[path] ?? []
            let activity = lastActivity(path)
            let git = gitRoots.contains(path) && !arts.isEmpty ? gitState(path) : nil
            let days = activity.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 9_999
            // Uncommitted work keeps a project at least "recent" (never auto-safe).
            var status: ProjectStatus = days < activeDays ? .active : (days < staleDays ? .recent : .stale)
            if status == .stale, (git?.dirtyFiles ?? 0) > 0 { status = .recent }
            var project = Project(path: path, name: path.lastComponent, kinds: [], lastActivity: activity, git: git,
                                  status: status, artifactBytes: 0, declared: VersionAudit.declaredVersions(in: path))
            var kinds = Set<String>()
            for a in arts {
                if cancelled() { break }
                let size = sizeArtifact(a.path)
                kinds.insert(a.kind.ecosystem)
                project.artifactBytes += size.bytes
                guard size.bytes >= 1_000_000 else { continue }
                findings.append(finding(for: a, size: size, project: project, days: days, gitTracked: isTracked(a.path, in: path, git: git)))
            }
            project.kinds = kinds.sorted()
            if project.kinds.isEmpty { project.kinds = detectKinds(path) }
            projects.append(project)
        }
        // Laravel logs live inside projects but are not artifacts.
        for p in projects where DiskSizer.exists(p.path + "/artisan") {
            let logs = p.path + "/storage/logs"
            let size = DiskSizer.size(logs)
            if size.bytes >= 20_000_000 {
                findings.append(Finding(path: logs, title: "Laravel logs", category: .logs, safety: .safe, bytes: size.bytes,
                                        files: size.files, lastModified: size.newestDate,
                                        reason: "laravel.log grows with every exception and debug message; Laravel never rotates it by default.",
                                        usedFor: "Debugging \(p.name).", owner: p.name, rebuild: "Not needed. Files are emptied in place.",
                                        action: .truncateLogs, layer: .projects))
            }
        }
        return ProjectScanResult(projects: projects.sorted { $0.artifactBytes > $1.artifactBytes }, findings: findings)
    }

    // MARK: Discovery walk

    private func walk(_ root: String, markerDirs: inout Set<String>, gitRoots: inout Set<String>,
                      candidates: inout [String], cancelled: () -> Bool, onDiscover: (String) -> Void) {
        guard let cPath = strdup(root) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // FTS_NOSTAT: directory type comes from readdir, so files cost no stat call.
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
        defer { fts_close(fts) }
        let isHome = root == NSHomeDirectory()
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 1023 == 0 && cancelled() { return }
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            let path = String(cString: ent.pointee.fts_path)
            let name = path.lastComponent
            if info == FTS_D {
                if level == 0 { continue }
                if isHome && level == 1 && (Self.skipTopLevel.contains(name) || (name.hasPrefix(".") && !Self.artifactNames.contains(name))) {
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if name == ".git" { gitRoots.insert(path.parentPath); fts_set(fts, ent, FTS_SKIP); continue }
                if Self.artifactNames.contains(name), kind(for: path) != nil {
                    candidates.append(path); fts_set(fts, ent, FTS_SKIP); continue
                }
                if Self.skipAnywhere.contains(name) || DiskSizer.neverEnter.contains(name)
                    || Self.bundleSuffixes.contains(where: name.hasSuffix) || level >= maxDepth {
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if level <= 3 { onDiscover(path) }
            } else if level > 0 && Self.markers.contains(name) {
                markerDirs.insert(path.parentPath)
            } else if level > 0 && name.hasSuffix(".xcodeproj") {
                markerDirs.insert(path.parentPath)
            }
        }
    }

    func kind(for path: String) -> ArtifactKind? {
        let name = path.lastComponent
        let parent = path.parentPath
        for k in Self.kinds where k.names.contains(name) {
            if let inside = k.inside {
                if DiskSizer.exists(path + "/" + inside) { return k }
                continue
            }
            if k.markers.isEmpty || k.markers.contains(where: { DiskSizer.exists(parent + "/" + $0) }) { return k }
        }
        return nil
    }

    private func detectKinds(_ path: String) -> [String] {
        var out: [String] = []
        if DiskSizer.exists(path + "/package.json") { out.append("Node") }
        if DiskSizer.exists(path + "/composer.json") { out.append("PHP") }
        if ["pyproject.toml", "requirements.txt", "setup.py"].contains(where: { DiskSizer.exists(path + "/" + $0) }) { out.append("Python") }
        if DiskSizer.exists(path + "/go.mod") { out.append("Go") }
        if DiskSizer.exists(path + "/Cargo.toml") { out.append("Rust") }
        return out
    }

    // MARK: Activity & git

    /// Newest of: source file edits and the git HEAD log (commits, checkouts).
    /// `.git/index` is not used: any `git status` (even ours) rewrites it.
    func lastActivity(_ path: String) -> Date? {
        let skip = Self.artifactNames.union(Self.skipAnywhere).union(["build", "dist", "out", "target", "vendor", "logs"])
        let dates = [
            DiskSizer.newestSource(in: path, skip: skip),
            DiskSizer.mtime(path + "/.git/logs/HEAD"),
        ].compactMap { $0 }
        return dates.max()
    }

    func gitState(_ path: String) -> GitState? {
        let r = Shell.run(["git", "--no-optional-locks", "-C", path, "status", "--porcelain=v1", "-b", "--untracked-files=no"], timeout: 8)
        guard r.status == 0 else { return nil }
        let lines = r.out.split(separator: "\n")
        var state = GitState(dirtyFiles: 0, ahead: 0, hasUpstream: false, branch: nil)
        if let head = lines.first, head.hasPrefix("## ") {
            let h = head.dropFirst(3)
            state.hasUpstream = h.contains("...")
            state.branch = String(h.split(separator: ".").first ?? h.prefix(40))
            if let r = h.range(of: "ahead ") {
                state.ahead = Int(h[r.upperBound...].prefix { $0.isNumber }) ?? 0
            }
        }
        state.dirtyFiles = lines.dropFirst().count
        return state
    }

    func isTracked(_ artifact: String, in root: String, git: GitState?) -> Bool {
        guard git != nil else { return false }
        let rel = String(artifact.dropFirst(root.count + 1))
        let r = Shell.run(["git", "--no-optional-locks", "-C", root, "ls-files", "--error-unmatch", "--", rel + "/"], timeout: 5)
        return r.status == 0 && !r.out.isEmpty
    }

    // MARK: Findings

    private func finding(for a: (path: String, kind: ArtifactKind), size: SizeResult, project: Project, days: Int, gitTracked: Bool) -> Finding {
        let parent = a.path.parentPath
        let lock = a.kind.lockfiles.first { DiskSizer.exists(parent + "/" + $0) || DiskSizer.exists(project.path + "/" + $0) }
        var safety = a.kind.defaultSafety
        var notes: [String] = []
        var action = a.kind.action

        switch project.status {
        case .active: notes.append("You worked on \(project.name) \(days == 0 ? "today" : "\(days) days ago").")
        case .recent: safety = max(safety, .check); notes.append("Last touched \(days) days ago.")
        case .stale: notes.append("Idle for \(days >= 9_999 ? "a long time" : "\(days) days").")
        }
        if lock == nil && !a.kind.lockfiles.isEmpty {
            safety = max(safety, .check)
            notes.append("No lockfile, so a reinstall may pick different versions.")
        } else if a.kind.action == .freezeThenTrash {
            action = .trash
        }
        if gitTracked {
            safety = max(safety, .check)
            notes.append("This folder is committed to git; removing it shows up as a change.")
        }
        let locked: String? = project.status == .active
            ? "Active project. Kept so you can keep developing fast. Turn on \"Allow active projects\" to clean it anyway."
            : nil
        let label = a.path.dropFirst(project.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Finding(path: a.path, title: "\(project.name) › \(label.isEmpty ? a.path.lastComponent : label)",
                       category: .projects, safety: safety, bytes: size.bytes, files: size.files, lastModified: project.lastActivity,
                       reason: "\(a.kind.ecosystem) \(a.path.lastComponent): \(size.files.formatted()) files. " + notes.joined(separator: " "),
                       usedFor: a.kind.usedFor, owner: project.name, rebuild: a.kind.rebuild, action: action,
                       lockedReason: locked, layer: .projects)
    }
}
