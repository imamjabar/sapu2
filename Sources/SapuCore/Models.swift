import Foundation

/// How careful the user should be before cleaning an item.
public enum Safety: String, Codable, Sendable, CaseIterable, Comparable {
    /// Regenerates automatically (caches, build output with a lockfile).
    case safe
    /// Usually fine, but read the reason first (slow re-download, no lockfile, recent project).
    case check
    /// User data: documents, downloads, databases, backups. Never pre-selected.
    case yours
    /// Shown for transparency only. Sapu never cleans it.
    case protected

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .check: "Check first"
        case .yours: "Your files"
        case .protected: "Protected"
        }
    }

    private var rank: Int { Safety.allCases.firstIndex(of: self)! }
    public static func < (a: Safety, b: Safety) -> Bool { a.rank < b.rank }
}

public enum Category: String, Codable, Sendable, CaseIterable {
    case projects = "Project build artifacts"
    case devCaches = "Developer caches"
    case xcode = "Xcode & Simulators"
    case logs = "Logs"
    case ml = "ML models & environments"
    case containers = "Docker & VMs"
    case appCaches = "App caches"
    case appData = "App data"
    case apps = "Applications"
    case downloads = "Downloads & old files"
    case trash = "Trash"
    case home = "Home folders"
    case system = "System & other"

    public var symbol: String {
        switch self {
        case .projects: "hammer"
        case .devCaches: "shippingbox"
        case .xcode: "iphone"
        case .logs: "doc.text"
        case .ml: "brain"
        case .containers: "cube.transparent"
        case .appCaches: "square.stack.3d.up"
        case .appData: "folder.badge.gearshape"
        case .apps: "app.dashed"
        case .downloads: "arrow.down.circle"
        case .trash: "trash"
        case .home: "house"
        case .system: "gearshape.2"
        }
    }
}

/// What "clean" means for an item. Everything that deletes goes through the Trash first.
public enum CleanAction: Codable, Sendable, Hashable {
    /// Move to the Trash (restorable).
    case trash
    /// Save `pip freeze` next to the project, then move the virtualenv to the Trash.
    case freezeThenTrash
    /// Run the tool's own clean command, e.g. `npm cache clean --force`.
    case command(String)
    /// Empty log files in place (the writing process keeps its file handle).
    case truncateLogs
    /// Nothing Sapu will do; information only.
    case none

    public var label: String {
        switch self {
        case .trash: "Move to Trash"
        case .freezeThenTrash: "Save pip freeze, then Trash"
        case .command(let c): "Run: \(c)"
        case .truncateLogs: "Empty log files"
        case .none: "Info only"
        }
    }
}

public struct Finding: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var category: Category
    public var safety: Safety
    public var bytes: Int64
    public var files: Int
    public var lastModified: Date?
    /// Why this takes space.
    public var reason: String
    /// What it is used for.
    public var usedFor: String
    /// Project or app that owns it.
    public var owner: String?
    /// How it comes back if needed.
    public var rebuild: String?
    public var action: CleanAction
    /// Set when the item must not be selected right now (active project, app running).
    public var lockedReason: String?
    public var layer: ScanLayer

    public init(path: String, title: String, category: Category, safety: Safety, bytes: Int64 = 0, files: Int = 0,
                lastModified: Date? = nil, reason: String, usedFor: String, owner: String? = nil, rebuild: String? = nil,
                action: CleanAction, lockedReason: String? = nil, layer: ScanLayer) {
        self.path = path; self.title = title; self.category = category; self.safety = safety
        self.bytes = bytes; self.files = files; self.lastModified = lastModified; self.reason = reason
        self.usedFor = usedFor; self.owner = owner; self.rebuild = rebuild; self.action = action
        self.lockedReason = lockedReason; self.layer = layer
    }

    public var isCleanable: Bool {
        lockedReason == nil && safety != .protected && action != .none
    }
}

public enum ScanLayer: Int, Codable, Sendable, CaseIterable, Comparable {
    case quick = 1, projects = 2, full = 3

    public var name: String {
        switch self {
        case .quick: "Quick: known caches & logs"
        case .projects: "Projects & build artifacts"
        case .full: "Full map: everything else"
        }
    }
    public var short: String {
        switch self {
        case .quick: "Quick"
        case .projects: "Projects"
        case .full: "Full map"
        }
    }
    public static func < (a: ScanLayer, b: ScanLayer) -> Bool { a.rawValue < b.rawValue }
}

public enum ProjectStatus: String, Codable, Sendable {
    /// Touched in the last `activeDays`, or has uncommitted work. Artifacts are locked.
    case active
    /// Touched in the last `staleDays`.
    case recent
    case stale

    public var label: String {
        switch self {
        case .active: "Active"
        case .recent: "Recent"
        case .stale: "Idle"
        }
    }
}

public struct GitState: Codable, Sendable, Hashable {
    public var dirtyFiles: Int
    public var ahead: Int
    public var hasUpstream: Bool
    public var branch: String?
}

public struct Project: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kinds: [String]
    public var lastActivity: Date?
    public var git: GitState?
    public var status: ProjectStatus
    public var artifactBytes: Int64
    /// Declared runtime versions, e.g. ["php": "^8.1", "node": "18"].
    public var declared: [String: String]
}

public struct Insight: Codable, Sendable, Identifiable, Hashable {
    public enum Level: String, Codable, Sendable { case info, tip, warning, danger }
    public var id: String
    public var level: Level
    public var title: String
    public var detail: String
    public var bytes: Int64?
    public var relatedPath: String?
}

public struct VolumeInfo: Codable, Sendable, Hashable {
    public var total: Int64
    public var free: Int64
    /// Free space including purgeable (what Finder shows).
    public var available: Int64
    public var swapBytes: Int64
    public var localSnapshots: Int

    public var used: Int64 { total - free }
}

public struct Snapshot: Codable, Sendable {
    public var findings: [Finding] = []
    public var projects: [Project] = []
    public var insights: [Insight] = []
    public var volume: VolumeInfo?
    public var layerDates: [Int: Date] = [:]
    public var layerDurations: [Int: TimeInterval] = [:]
    public init() {}

    public func findings(in layer: ScanLayer) -> [Finding] { findings.filter { $0.layer == layer } }

    /// Replace one layer's findings, keeping the others.
    public mutating func replace(layer: ScanLayer, with new: [Finding]) {
        findings.removeAll { $0.layer == layer }
        findings.append(contentsOf: new)
    }
}

public enum Format {
    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    public static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case 1: return "1 day ago"
        case ..<60: return "\(days) days ago"
        case ..<730: return "\(days / 30) months ago"
        default: return "\(days / 365) years ago"
        }
    }

    public static func duration(_ s: TimeInterval) -> String {
        if s < 1 { return "<1 s" }
        if s < 60 { return "\(Int(s.rounded())) s" }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }
}

public extension String {
    var tildePath: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
    var lastComponent: String { (self as NSString).lastPathComponent }
    var parentPath: String { (self as NSString).deletingLastPathComponent }
}
