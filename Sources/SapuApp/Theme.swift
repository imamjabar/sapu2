import SapuCore
import SwiftUI

/// Each section has its own colour, icon tile and one-line purpose, so the sections never blend together.
extension Pane {
    var tint: Color {
        switch self {
        case .overview: .indigo
        case .cleanable: .green
        case .caches: .blue
        case .artifacts: .orange
        case .logs: .brown
        case .apps: .indigo
        case .files: .pink
        case .projects: .teal
        case .map: .mint
        case .uninstall: .purple
        case .health: .pink
        case .maintenance: .cyan
        case .security: .red
        case .receipts: .gray
        }
    }

    var title: String { self == .overview ? "Home" : rawValue }

    var blurb: String {
        switch self {
        case .overview: "Your disk at a glance, and what to do next."
        case .cleanable: "Everything that rebuilds itself or re-downloads. Safe to clean."
        case .caches: "Package-manager, IDE, browser and app caches. Apps refill them as needed."
        case .artifacts: "node_modules, virtualenvs, vendor, target and build output, grouped by project."
        case .logs: "Log files that grew large. Emptied in place so running services keep working."
        case .apps: "Installed apps, when you last used them, and data left behind by apps you removed."
        case .files: "Big single files and Downloads untouched for 6+ months. Never pre-selected."
        case .projects: "Every repo on this Mac. Projects you're working on are locked."
        case .map: "Every folder in your home, biggest first. Open any folder to see what fills it. Measured only."
        case .uninstall: "Remove an app with everything it left in your Library. Caches go; your data stays unless you choose."
        case .health: "Memory, swap, processor, disk, battery and heat, and what is using them."
        case .maintenance: "Small fixes macOS doesn't do by itself: broken login items, damaged settings, stale caches."
        case .security: "Runtimes and project versions checked for end-of-life and missing CVE fixes."
        case .receipts: "Every cleanup, and where each item went so you can put it back."
        }
    }

    /// Sidebar groups. Each group is one job: clean, free space, understand, protect.
    static let groups: [(String, [Pane])] = [
        ("Clean up", [.cleanable, .caches, .artifacts, .logs]),
        ("Free up space", [.apps, .uninstall, .files]),
        ("Understand", [.projects, .map]),
        ("Keep it healthy", [.health, .maintenance, .security]),
        ("History", [.receipts]),
    ]

    /// Panes whose rows open the details inspector.
    var showsInspector: Bool { ![.projects, .security, .receipts, .uninstall, .health, .maintenance].contains(self) }
}

/// Rounded, gradient-filled icon square, the visual anchor of every section.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

/// Header band at the top of every section: icon, name, purpose, headline number, actions.
struct PaneHeader<Trailing: View>: View {
    let pane: Pane
    var subtitle: String? = nil
    var value: String? = nil
    var caption: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: pane.symbol, tint: pane.tint, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle ?? pane.blurb).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let value {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                }
            }
            trailing()
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(
            LinearGradient(colors: [pane.tint.opacity(0.16), pane.tint.opacity(0.03)], startPoint: .leading, endPoint: .trailing)
        )
        .overlay(alignment: .bottom) { Divider() }
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.07)) } ?? AnyShapeStyle(.background.secondary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.22))
            )
    }
}

/// Section title used inside scrolling pages.
struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
    }
}
