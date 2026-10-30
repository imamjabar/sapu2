import Foundation

/// What a sweep would do, worked out from a saved scan without touching anything.
/// The command line and its tests use this; the app builds the same four bins in AppModel.derive().
public enum SweepPlan {
    public enum Bin: String, Codable, Sendable, CaseIterable {
        case sweep, choice, yours, stays
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var title: String
        public var bytes: Int64
        public var bin: Bin
        public var group: String
        public var action: String
        public var owner: String?
        public var rebuild: String?
        /// Why the last-resort guard would skip this item right now; nil when it would go ahead.
        public var refusal: String?
    }

    public struct Plan: Codable, Sendable {
        public var items: [Entry]
        public var sweepBytes: Int64
        public var perBin: [String: Int64]
    }

    /// Splits a scan into the four bins. Totals of the full map (Home folders, Applications, App data) are left out,
    /// because they contain the items listed elsewhere and would count the same bytes twice.
    public static func build(from snap: Snapshot, allowActiveProjects: Bool = false, home: String = NSHomeDirectory()) -> Plan {
        var entries: [Entry] = []
        for f in snap.findings where f.category != .trash && f.bytes > 0 && (f.layer != .full || f.category == .downloads) {
            let locked = f.lockedReason.map { !(allowActiveProjects && $0.hasPrefix("Active project")) } ?? false
            let candidate = f.action != .none && f.safety != .protected && !locked
            let bin: Bin
            switch (candidate, f.safety) {
            case (true, .safe): bin = .sweep
            case (true, .check): bin = .choice
            case (true, .yours): bin = .yours
            default: bin = .stays
            }
            let refusal = bin == .stays ? nil : SafetyGuard.refusal(for: f, allowActiveProjects: allowActiveProjects)
            entries.append(Entry(path: f.path, title: f.title, bytes: f.bytes, bin: bin, group: CleanGroup.of(f, home: home).rawValue,
                                 action: f.action.label, owner: f.owner, rebuild: f.rebuild, refusal: refusal))
        }
        entries.sort { $0.bytes > $1.bytes }
        var perBin: [String: Int64] = [:]
        for e in entries { perBin[e.bin.rawValue, default: 0] += e.bytes }
        let sweep = entries.filter { $0.bin == .sweep && $0.refusal == nil }.reduce(Int64(0)) { $0 + $1.bytes }
        return Plan(items: entries, sweepBytes: sweep, perBin: perBin)
    }
}
