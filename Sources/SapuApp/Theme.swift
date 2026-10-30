import SapuCore
import SwiftUI

/// Each section has its own colour, icon tile and one-line purpose, so the sections never blend together.
/// The six places in the sidebar. Each holds one or more panes, shown as tabs in the toolbar.
enum Area: String, CaseIterable, Identifiable, Hashable {
    case smartClean = "Smart Clean"
    case cleanup = "Cleanup"
    case apps = "Apps"
    case optimize = "Optimize"
    case explore = "Explore"
    case history = "History"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .smartClean: "sparkles"
        case .cleanup: "trash.circle"
        case .apps: "square.grid.2x2"
        case .optimize: "speedometer"
        case .explore: "chart.bar.doc.horizontal"
        case .history: "clock.arrow.circlepath"
        }
    }

    var panes: [Pane] {
        switch self {
        case .smartClean: [.overview]
        case .cleanup: [.cleanable, .caches, .artifacts, .logs, .files]
        case .apps: [.uninstall, .updates, .apps]
        case .optimize: [.maintenance, .health]
        case .explore: [.map, .projects, .security]
        case .history: [.receipts, .trash, .protected]
        }
    }

    static func of(_ p: Pane) -> Area { allCases.first { $0.panes.contains(p) } ?? .smartClean }
}

extension Pane {
    /// One accent for the whole app; meaning comes from the safety colours, not from section colours.
    var tint: Color { Depot.ink }

    /// Short name used on the tabs.
    var tab: String {
        switch self {
        case .cleanable: "Recommended"
        case .caches: "Caches"
        case .artifacts: "Build folders"
        case .logs: "Logs"
        case .files: "Large & old files"
        case .uninstall: "Uninstall"
        case .updates: "Updates"
        case .apps: "Leftovers"
        case .maintenance: "Optimize"
        case .health: "Health"
        case .map: "Disk map"
        case .projects: "Projects"
        case .security: "Security"
        case .receipts: "Receipts"
        case .trash: "Trash"
        case .protected: "Protect list"
        default: rawValue
        }
    }

    var title: String { self == .overview ? "Smart Clean" : tab }

    var blurb: String {
        switch self {
        case .overview: "Scan, review exactly what happens, then confirm."
        case .cleanable: "Everything that rebuilds itself or downloads again. Safe items can go; Check-first items tell you why to look."
        case .caches: "Package-manager, editor, browser and app caches. Apps refill them as needed."
        case .artifacts: "node_modules, virtual environments, vendor, target and build output, grouped by project."
        case .logs: "Log files that grew large. Old ones go to the Trash; ones still being written are emptied in place."
        case .apps: "Data left behind by apps you already removed."
        case .files: "Big single files and downloads untouched for 6+ months. Never ticked for you."
        case .projects: "Every repository on this Mac. Projects you're working on are locked."
        case .map: "Everything on your startup disk, biggest first. Open any folder to see what fills it."
        case .uninstall: "Remove apps with everything they left in your Library. Caches go; your data stays unless you choose."
        case .health: "Memory, swap, processor, disk, battery and heat, and what is using them."
        case .maintenance: "Quick fixes for stuck parts of macOS, and housekeeping macOS doesn't do by itself."
        case .security: "Runtimes and project versions checked for end-of-life and known security fixes."
        case .receipts: "Every cleanup, where each item went, and Put back."
        case .protected: "Folders and files Sapu2 must never clean, whatever a scan finds."
        case .updates: "Newer versions of your apps, from Homebrew, each app's own updater, and the App Store."
        case .trash: "What's in your Trash. Items there can still be put back until you empty it."
        }
    }

    /// Panes whose rows open the details inspector.
    var showsInspector: Bool { [.cleanable, .caches, .artifacts, .logs, .files, .apps].contains(self) }
}

/// A quiet symbol square: accent-tinted, used sparingly where an icon anchors a row.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.48, weight: .medium)).foregroundStyle(tint))
            .frame(width: size, height: size)
    }
}

/// Plain header at the top of a pane: what it is, the one number that matters, its actions.
struct PaneHeader<Trailing: View>: View {
    let pane: Pane
    var subtitle: String? = nil
    var value: String? = nil
    var caption: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(Depot.sign(24, .heavy)).foregroundStyle(Depot.ink)
                Text(subtitle ?? pane.blurb).font(.callout).foregroundStyle(Depot.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let value {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value).font(Depot.sign(24, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                    if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                }
            }
            trailing()
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(pane: Pane, subtitle: String? = nil, value: String? = nil, caption: String? = nil) {
        self.init(pane: pane, subtitle: subtitle, value: value, caption: caption) { EmptyView() }
    }
}

/// Card surface used across Home and Security.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.09)) } ?? AnyShapeStyle(Depot.bay))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.3) } ?? Depot.line)
            )
    }
}

/// Section title used inside scrolling pages.
struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Depot.sign(18, .bold)).foregroundStyle(Depot.ink)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
