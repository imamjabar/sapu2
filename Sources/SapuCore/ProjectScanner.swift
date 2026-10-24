import Darwin
import Foundation

/// A generated folder inside a project that can be rebuilt from the project's manifest.
struct ArtifactKind: Sendable {
    var names: [String]
    var ecosystem: String
    /// Any of these next to the folder makes it this kind.
    var markers: [String]
    /// Any file with one of these suffixes next to the folder also makes it this kind (e.g. `.spec`).
    var markerSuffixes: [String] = []
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
    /// What discovery found in each folder two levels below home, for reuse on the next scan.
    public var discovery: [String: DiscoveryUnit] = [:]
}

/// Discovery results for one folder (e.g. ~/Machine Learning/NextCRM), cached between scans.
public struct DiscoveryUnit: Codable, Sendable {
    public var markerDirs: [String] = []
    public var gitRoots: [String] = []
    public var readmeDirs: [String] = []
    public var candidates: [String] = []
}

public final class ProjectScanner: @unchecked Sendable {
    public var activeDays = 30
    public var staleDays = 90
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
        ArtifactKind(names: ["build"], ecosystem: "PyInstaller", markers: [], markerSuffixes: [".spec"], lockfiles: [],
                     usedFor: "PyInstaller work folder: analysed imports and partial bundles from the last build.",
                     rebuild: "pyinstaller <name>.spec"),
        ArtifactKind(names: ["dist"], ecosystem: "PyInstaller", markers: [], markerSuffixes: [".spec"], lockfiles: [],
                     defaultSafety: .check, usedFor: "The packaged app PyInstaller built. Keep it if this is the copy you share.",
                     rebuild: "pyinstaller <name>.spec"),
        ArtifactKind(names: ["target", "dbt_packages"], ecosystem: "dbt", markers: ["dbt_project.yml"], lockfiles: [],
                     usedFor: "Compiled SQL, run results and installed dbt packages.", rebuild: "dbt deps && dbt compile"),
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

    /// A renamed copy of node_modules (node_modules-old, node_modules.bak…). Nothing loads it.
    static let renamedNodeModules = ArtifactKind(
        names: [], ecosystem: "Node", markers: [], lockfiles: [], defaultSafety: .check,
        usedFor: "A renamed copy of node_modules, usually a backup made before reinstalling. Node never loads it.",
        rebuild: "npm install recreates node_modules from package.json.")

    /// Dependency trees are one item: never list folders inside them separately.
    static func isDependencyTree(_ name: String) -> Bool { name.hasPrefix("node_modules") }

    static let markers: Set<String> = [
        "package.json", "composer.json", "pyproject.toml", "requirements.txt", "setup.py", "go.mod", "Cargo.toml",
        "Gemfile", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "Podfile", "project.godot",
        "Package.swift", "artisan", "manage.py", "environment.yml",
        // Workspace roots: a monorepo or multi-service app is one project, not one per package.
        "pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json", "rush.json", "go.work",
        "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml", ".projectile",
    ]

    /// Folders that hold projects rather than being one (checked by name at any depth).
    static let containerNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Projects", "projects", "Sites", "Developer", "dev", "Dev", "code", "Code",
        "src", "repos", "Repos", "GitHub", "github", "git", "workspace", "Workspace", "work", "Work",
    ]

    /// Top-level home folders that hold tools, caches or media, not projects.
    static let skipTopLevel: Set<String> = [
        "Library", "Applications", "Music", "Pictures", "Movies", "Public", ".Trash",
        "anaconda3", "miniconda3", "miniforge3", "opt", "go",
    ]

    /// Folders never worth descending into.
    static let skipAnywhere: Set<String> = [".git", ".hg", ".svn", "__pycache__", ".idea", ".vscode", ".DS_Store", "site-packages"]
    static let bundleSuffixes = [".app", ".photoslibrary", ".fcpbundle", ".musiclibrary", ".logicx", ".imovielibrary", ".xcarchive", ".framework", ".bundle"]

    /// Bump when artifact or project rules change, so cached discovery is not reused.
    public static let rulesVersion = 2

    public init() {}

    public func scan(roots: [String] = [NSHomeDirectory()],
                     cancelled: @escaping () -> Bool,
                     onDiscover: (String) -> Void,
                     onArtifactsFound: (Int) -> Void,
                     sizeArtifact: (String) -> SizeResult,
                     changes: ChangeSet? = nil,
                     discoveryCache: [String: DiscoveryUnit] = [:],
                     previousProjects: [Project] = []) -> ProjectScanResult {
        let previousByPath = Dictionary(previousProjects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var markerDirs = Set<String>()
        var gitRoots = Set<String>()
        var readmeDirs = Set<String>()
        var candidates: [String] = []

        var units: [String: DiscoveryUnit] = [:]
        for root in roots {
            walk(root, markerDirs: &markerDirs, gitRoots: &gitRoots, readmeDirs: &readmeDirs, candidates: &candidates,
                 units: &units, changes: changes, cache: discoveryCache, cancelled: cancelled, onDiscover: onDiscover)
        }

        // Resolve artifact candidates to kinds.
        var artifacts: [(path: String, kind: ArtifactKind)] = []
        for c in candidates {
            if let k = kind(for: c) { artifacts.append((c, k)) }
        }
        onArtifactsFound(artifacts.count)

        // What counts as one project (the rule IDEs and Projectile use):
        //  1. A git repository is one project, including everything nested in it (packages, examples,
        //     vendored clones). The outermost repository wins.
        //  2. Without git, a component joins the outermost ancestor that is itself a project: it has a
        //     manifest, a workspace file (pnpm-workspace, go.work, docker-compose…), or a README with
        //     two or more components under it.
        //  3. Climbing stops at containers: the scan root's direct children (~/Sites, ~/Documents…)
        //     and folders named like Projects, Downloads or GitHub are never merged into one project.
        //  4. A folder right under an area of your home (~/Machine Learning/Campus Intelligence) that holds
        //     its own loose files (notes, docs, data) and two or more components is a workspace: one
        //     project. A folder with nothing but subfolders stays a plain container.
        for dir in readmeDirs where markerDirs.filter({ $0.parentPath == dir }).count >= 2 { markerDirs.insert(dir) }
        let home = NSHomeDirectory()
        if roots.contains(home) {
            var perUnit: [String: Int] = [:]
            for m in markerDirs where m.hasPrefix(home + "/") {
                let parts = m.dropFirst(home.count + 1).split(separator: "/")
                guard parts.count > 2 else { continue }
                perUnit[home + "/" + parts.prefix(2).joined(separator: "/"), default: 0] += 1
            }
            for (unit, count) in perUnit where count >= 2 && !Self.containerNames.contains(unit.lastComponent)
                && !Self.containerNames.contains(unit.parentPath.lastComponent) && !markerDirs.contains(unit) {
                let loose = DiskSizer.children(unit, includeHidden: false).contains { !DiskSizer.isDirectory($0) && !DiskSizer.isSymlink($0) }
                if loose { markerDirs.insert(unit) }
            }
        }
        func isContainer(_ p: String) -> Bool {
            if roots.contains(p) || Self.containerNames.contains(p.lastComponent) { return true }
            return roots.contains(p.parentPath)
        }
        func projectRoot(for dir: String) -> String {
            var p = dir
            var best = dir
            var git: String?
            while p.count > 1 && !roots.contains(p) && p != NSHomeDirectory() {
                if gitRoots.contains(p), !Self.containerNames.contains(p.lastComponent) { git = p } else if p != dir, markerDirs.contains(p), !isContainer(p) { best = p }
                p = p.parentPath
            }
            return git ?? best
        }
        var projectPaths = Set(markerDirs.map(projectRoot))
        projectPaths.formUnion(gitRoots.map(projectRoot))
        projectPaths.remove(NSHomeDirectory())
        for r in roots { projectPaths.remove(r) }

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
            // Nothing inside changed since last scan: activity, git state and declared versions are the same.
            let unchanged = changes.map { !$0.isDirty(path) } ?? false
            let old = unchanged ? previousByPath[path] : nil
            let activity = old != nil ? old!.lastActivity : lastActivity(path)
            let git = old != nil ? old!.git : (gitRoots.contains(path) && !arts.isEmpty ? gitState(path) : nil)
            let days = activity.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 9_999
            // Uncommitted work keeps a project at least "recent" (never auto-safe).
            var status: ProjectStatus = days < activeDays ? .active : (days < staleDays ? .recent : .stale)
            if status == .stale, (git?.dirtyFiles ?? 0) > 0 { status = .recent }
            var project = Project(path: path, name: path.lastComponent, kinds: [], lastActivity: activity, git: git,
                                  status: status, artifactBytes: 0, declared: old?.declared ?? VersionAudit.declaredVersions(in: path))
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
        return ProjectScanResult(projects: projects.sorted { $0.artifactBytes > $1.artifactBytes }, findings: findings,
                                 discovery: cancelled() ? [:] : units)
    }

    // MARK: Discovery walk

    /// One fts pass over the tree, with no stat per file. Under home, each folder two levels down
    /// (~/Area/Project) is a cache unit: if the change journal says nothing in it changed since the
    /// last scan, its previous results are reused and the folder isn't read at all.
    private func walk(_ root: String, markerDirs: inout Set<String>, gitRoots: inout Set<String>, readmeDirs: inout Set<String>,
                      candidates: inout [String], units: inout [String: DiscoveryUnit],
                      changes: ChangeSet?, cache: [String: DiscoveryUnit],
                      cancelled: () -> Bool, onDiscover: (String) -> Void) {
        guard let cPath = strdup(root) else { return }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        // FTS_NOSTAT: directory type comes from readdir, so files cost no stat call.
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR | FTS_NOSTAT, nil) else { return }
        defer { fts_close(fts) }
        let isHome = root == NSHomeDirectory()
        var unit: (path: String, found: DiscoveryUnit)?
        func note(_ update: (inout DiscoveryUnit) -> Void) {
            if unit != nil { update(&unit!.found) }
        }
        var n = 0
        while let ent = fts_read(fts) {
            n += 1
            if n & 1023 == 0 && cancelled() { return }
            let info = Int32(ent.pointee.fts_info)
            let level = Int(ent.pointee.fts_level)
            if info == FTS_DP {
                if isHome, level == 2, let u = unit, u.path == String(cString: ent.pointee.fts_path) { units[u.path] = u.found; unit = nil }
                continue
            }
            let path = String(cString: ent.pointee.fts_path)
            let name = path.lastComponent
            if info == FTS_D {
                if level == 0 { continue }
                if isHome && level == 1 && (Self.skipTopLevel.contains(name) || (name.hasPrefix(".") && !Self.artifactNames.contains(name))) {
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if name == ".git" {
                    gitRoots.insert(path.parentPath); note { $0.gitRoots.append(path.parentPath) }
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if Self.artifactNames.contains(name) || Self.isDependencyTree(name), kind(for: path) != nil {
                    candidates.append(path); note { $0.candidates.append(path) }
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if Self.isDependencyTree(name) { fts_set(fts, ent, FTS_SKIP); continue }
                if Self.skipAnywhere.contains(name) || DiskSizer.neverEnter.contains(name)
                    || Self.bundleSuffixes.contains(where: name.hasSuffix) || level >= maxDepth {
                    fts_set(fts, ent, FTS_SKIP); continue
                }
                if isHome && level == 2 {
                    if let changes, !changes.isDirty(path), let cached = cache[path] {
                        markerDirs.formUnion(cached.markerDirs)
                        gitRoots.formUnion(cached.gitRoots)
                        readmeDirs.formUnion(cached.readmeDirs)
                        candidates += cached.candidates
                        units[path] = cached
                        fts_set(fts, ent, FTS_SKIP); continue
                    }
                    unit = (path, DiscoveryUnit())
                }
                if level <= 3 { onDiscover(path) }
            } else if level > 0 && (Self.markers.contains(name) || name.hasSuffix(".xcodeproj")
                                    || name.hasSuffix(".code-workspace") || name.hasSuffix(".sln")) {
                markerDirs.insert(path.parentPath); note { $0.markerDirs.append(path.parentPath) }
            } else if level > 1 && name.hasPrefix("README") {
                readmeDirs.insert(path.parentPath); note { $0.readmeDirs.append(path.parentPath) }
            }
        }
    }

    func kind(for path: String) -> ArtifactKind? {
        let name = path.lastComponent
        let parent = path.parentPath
        if name != "node_modules" && Self.isDependencyTree(name) {
            // Only a real npm tree: it has packages with a package.json or npm's own metadata.
            let looksLikeTree = DiskSizer.exists(path + "/.package-lock.json") || DiskSizer.exists(path + "/.bin")
                || DiskSizer.children(path, includeHidden: false).prefix(20).contains { DiskSizer.exists($0 + "/package.json") }
            return looksLikeTree ? Self.renamedNodeModules : nil
        }
        var siblings: [String]?
        for k in Self.kinds where k.names.contains(name) {
            if let inside = k.inside {
                if DiskSizer.exists(path + "/" + inside) { return k }
                continue
            }
            if !k.markerSuffixes.isEmpty {
                if siblings == nil { siblings = DiskSizer.children(parent, includeHidden: false).map(\.lastComponent) }
                if siblings!.contains(where: { s in k.markerSuffixes.contains { s.hasSuffix($0) } }) { return k }
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
        case .recent:
            safety = max(safety, .check)
            notes.append("Last touched \(days) days ago.")
            if days >= staleDays, let dirty = project.git?.dirtyFiles, dirty > 0 {
                notes.append("Kept as recent because \(project.name) has \(dirty) uncommitted file\(dirty == 1 ? "" : "s").")
            }
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
