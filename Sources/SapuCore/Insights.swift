import Foundation

public enum Insights {
    static let gb: Int64 = 1_000_000_000

    public static func build(_ s: Snapshot, versions: [VersionFinding] = []) -> [Insight] {
        var out: [Insight] = []
        let f = s.findings

        if let v = s.volume, v.total > 0 {
            let pct = Double(v.used) / Double(v.total)
            if pct > 0.85 {
                out.append(Insight(id: "disk.full", level: pct > 0.92 ? .danger : .warning,
                                   title: "Disk \(Int(pct * 100))% full",
                                   detail: "macOS slows down and updates fail below ~10% free. \(Format.bytes(v.available)) free now.", bytes: nil, relatedPath: nil))
            }
            if v.swapBytes > 2 * gb {
                out.append(Insight(id: "swap", level: .info, title: "\(Format.bytes(v.swapBytes)) of swap counts as System Data",
                                   detail: "Memory pressure spills to disk. Quitting heavy apps or restarting frees it. It is not something to delete.",
                                   bytes: v.swapBytes, relatedPath: nil))
            }
            if v.localSnapshots > 0 {
                out.append(Insight(id: "snapshots", level: .info, title: "\(v.localSnapshots) Time Machine local snapshot(s)",
                                   detail: "Shown as purgeable space. macOS deletes them automatically when space runs low.", bytes: nil, relatedPath: nil))
            }
        }

        let safe = f.filter { $0.safety == .safe && $0.isCleanable }
        let safeBytes = safe.reduce(0) { $0 + $1.bytes }
        if safeBytes > 100_000_000 {
            out.append(Insight(id: "safe.total", level: .tip, title: "\(Format.bytes(safeBytes)) is safe to clean now",
                               detail: "\(safe.count) caches, logs and idle build folders that rebuild themselves.", bytes: safeBytes, relatedPath: nil))
        }

        // Logs that grew big: explain the usual cause.
        let duplicates = SystemProbe.duplicateBrewServices()
        for log in f.filter({ $0.category == .logs && $0.bytes > gb / 2 }) {
            var detail = "\(log.owner ?? "A service") writes here. Logs this big usually mean something is failing in a loop."
            if log.path.contains("homebrew/var/log") || log.path.contains("php") {
                if !duplicates.isEmpty {
                    detail = "Duplicate Homebrew services (\(duplicates.joined(separator: ", "))) are installed both as root daemons (Laravel Valet) and user agents. They fight for the same port (php-fpm: 127.0.0.1:9000); the loser restarts forever and logs \"Address already in use\". Fix: keep one, e.g. `sudo brew services stop php` or `brew services stop php`."
                }
            }
            let fresh = log.lastModified.map { Date().timeIntervalSince($0) < 3600 } ?? false
            out.append(Insight(id: "log." + log.path, level: .warning,
                               title: "\(log.title) is \(Format.bytes(log.bytes))\(fresh ? " and still growing" : "")",
                               detail: detail, bytes: log.bytes, relatedPath: log.path))
        }

        if let t = f.first(where: { $0.category == .trash }), t.bytes > gb {
            out.append(Insight(id: "trash", level: .tip, title: "Trash holds \(Format.bytes(t.bytes))",
                               detail: "Space comes back only after you empty it. Check nothing you cleaned is still needed first.",
                               bytes: t.bytes, relatedPath: t.path))
        }

        let active = s.projects.filter { $0.status == .active }
        if !active.isEmpty {
            let names = active.prefix(4).map(\.name).joined(separator: ", ")
            out.append(Insight(id: "projects.active", level: .info, title: "\(active.count) active project(s) are locked",
                               detail: "\(names)\(active.count > 4 ? "…" : ""). Their node_modules, venvs and build folders stay so you can keep developing fast.",
                               bytes: nil, relatedPath: nil))
        }
        let idle = f.filter { $0.category == .projects && $0.lockedReason == nil }
        let idleBytes = idle.reduce(0) { $0 + $1.bytes }
        if idleBytes > gb {
            let n = Set(idle.compactMap(\.owner)).count
            out.append(Insight(id: "projects.idle", level: .tip, title: "\(n) idle projects hold \(Format.bytes(idleBytes)) of build folders",
                               detail: "Dependencies and build output reinstall from lockfiles in minutes when you come back.", bytes: idleBytes, relatedPath: nil))
        }
        let unpushed = s.projects.filter { ($0.git?.ahead ?? 0) > 0 || ($0.git != nil && $0.git?.hasUpstream == false) }
        if !unpushed.isEmpty {
            out.append(Insight(id: "git.unpushed", level: .warning, title: "\(unpushed.count) repo(s) have commits not on a remote",
                               detail: unpushed.prefix(5).map(\.name).joined(separator: ", ") + ". Push before moving or deleting these projects.",
                               bytes: nil, relatedPath: nil))
        }

        if let d = f.first(where: { $0.category == .containers && $0.bytes > 10 * gb }) {
            out.append(Insight(id: "docker", level: .tip, title: "\(d.title) uses \(Format.bytes(d.bytes))",
                               detail: "The VM disk only grows. `docker system prune` removes stopped containers, unused images and build cache (not volumes).",
                               bytes: d.bytes, relatedPath: d.path))
        }
        let oldApps = f.filter { $0.category == .apps && $0.safety == .check }
        if !oldApps.isEmpty {
            let b = oldApps.reduce(0) { $0 + $1.bytes }
            out.append(Insight(id: "apps.unused", level: .tip, title: "\(oldApps.count) apps not opened in 6+ months (\(Format.bytes(b)))",
                               detail: oldApps.sorted { $0.bytes > $1.bytes }.prefix(5).map(\.title).joined(separator: ", "), bytes: b, relatedPath: nil))
        }
        let downloads = f.filter { $0.category == .downloads && $0.path.contains("/Downloads/") }
        let dlBytes = downloads.reduce(0) { $0 + $1.bytes }
        if dlBytes > gb {
            out.append(Insight(id: "downloads.old", level: .tip, title: "\(Format.bytes(dlBytes)) of old Downloads",
                               detail: "\(downloads.count) items untouched for 6+ months. Move what you need to cloud storage, then clean.",
                               bytes: dlBytes, relatedPath: "~/Downloads".expandingTilde))
        }

        let eol = versions.filter { $0.level == .eol }
        if !eol.isEmpty {
            out.append(Insight(id: "versions.eol", level: .danger, title: "\(eol.count) runtime(s) without security updates",
                               detail: eol.prefix(4).map { "\($0.product) \($0.version) (\($0.source))" }.joined(separator: "; "), bytes: nil, relatedPath: nil))
        }
        let outdated = versions.filter { $0.level == .outdated }
        if !outdated.isEmpty {
            out.append(Insight(id: "versions.patch", level: .warning, title: "\(outdated.count) runtime(s) missing security patches",
                               detail: outdated.prefix(4).map { "\($0.product) \($0.version) → \($0.fix?.replacingOccurrences(of: "Update to ", with: "") ?? "latest")" }.joined(separator: "; "),
                               bytes: nil, relatedPath: nil))
        }

        let order: [Insight.Level] = [.danger, .warning, .tip, .info]
        return out.sorted { order.firstIndex(of: $0.level)! < order.firstIndex(of: $1.level)! }
    }

    /// Breakdown of used space for the overview. "System & other" is what no scan could see.
    public static func breakdown(_ s: Snapshot) -> [(Category, Int64)] {
        var by: [Category: Int64] = [:]
        // Full-map home folders overlap with projects/caches; count only cleanable categories plus apps/app data.
        for f in s.findings where f.category != .home && f.category != .downloads || f.path.contains("/Downloads/") {
            if f.path == "/opt/homebrew" { continue }
            by[f.category, default: 0] += f.bytes
        }
        return by.sorted { $0.value > $1.value }
    }

    /// How much of used space the scans explain.
    public static func coverage(_ s: Snapshot) -> (accounted: Int64, used: Int64)? {
        guard let v = s.volume, s.layerDates[ScanLayer.full.rawValue] != nil else { return nil }
        let home = s.findings.filter { $0.category == .home }.reduce(0) { $0 + $1.bytes }
        let library = s.findings.filter { $0.layer == .full && $0.category == .appData }.reduce(0) { $0 + $1.bytes }
        let caches = s.findings.filter { $0.category == .appCaches || $0.path.hasPrefix(NSHomeDirectory() + "/Library/Caches") }.reduce(0) { $0 + $1.bytes }
        let apps = s.findings.filter { $0.category == .apps }.reduce(0) { $0 + $1.bytes }
        let brew = s.findings.first { $0.path == "/opt/homebrew" }?.bytes ?? 0
        let trash = s.findings.first { $0.category == .trash }?.bytes ?? 0
        return (home + library + caches + apps + brew + trash + v.swapBytes, v.used)
    }
}
