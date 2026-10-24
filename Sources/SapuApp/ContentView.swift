import SapuCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 265)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                if model.section != .overview || model.scanning != nil {
                    ScanBar()
                    Divider()
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.checked.isEmpty { SelectionBar() }
            }
            .background(.background)
            .inspector(isPresented: inspectorShown) {
                Group {
                    if let f = model.focusedFinding { FindingDetail(finding: f) } else { InspectorPlaceholder() }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(ScanLayer.allCases, id: \.self) { layer in
                        Button(layer.name) { model.scan([layer]) }
                    }
                    Divider()
                    Button("Everything (all layers)") { model.scan(ScanLayer.allCases) }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    model.scan([.quick])
                }
                .disabled(model.scanning != nil)
                .help("Quick scan (⌘R). Use the menu for projects or the full map.")
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name, path or project")
        .sheet(isPresented: $model.reviewing) { ReviewSheet() }
        .sheet(isPresented: $model.showAccessSetup) { AccessSetupView() }
    }

    /// The details column appears when an item is selected, and only where items exist.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { model.focused != nil && model.section.showsInspector },
                set: { if !$0 { model.focused = nil } })
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: OverviewView()
        case .projects: ProjectsView()
        case .security: SecurityView()
        case .receipts: ReceiptsView()
        default: FindingsList(section: model.section)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.section) {
            row(.overview).padding(.vertical, 4)
            ForEach(Pane.groups, id: \.0) { group in
                SwiftUI.Section(group.0) {
                    ForEach(group.1) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { DiskFooter().padding(12) }
    }

    private func row(_ s: Pane) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: s.symbol, tint: s.tint, size: 24)
            Text(s.title).lineLimit(1)
            Spacer(minLength: 4)
            badge(s)
        }
        .padding(.vertical, 2)
        .tag(s)
    }

    @ViewBuilder private func badge(_ s: Pane) -> some View {
        switch s {
        case .overview, .receipts, .map: EmptyView()
        case .projects:
            if !model.snapshot.projects.isEmpty {
                Text("\(model.snapshot.projects.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .security:
            let n = model.versions.filter { $0.level == .eol || $0.level == .outdated }.count
            if n > 0 {
                Text("\(n)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }
        default:
            let b = model.snapshot.findings.filter { s.includes($0) && $0.action != .none }.reduce(0) { $0 + $1.bytes }
            if b > 0 { Text(Format.bytes(b)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }
}

/// Small disk meter pinned to the bottom of the sidebar.
struct DiskFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let v = model.snapshot.volume {
            let frac = Double(v.used) / Double(max(v.total, 1))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text("Macintosh HD").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(frac * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressView(value: frac).tint(frac > 0.9 ? .red : frac > 0.8 ? .orange : .accentColor)
                Text("\(Format.bytes(v.free)) free of \(Format.bytes(v.total))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct FullDiskAccessBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("Without Full Disk Access some app containers can't be measured, so totals may be low.")
                .font(.callout)
            Spacer()
            Button("Set up…") { model.showAccessSetup = true; model.watchFullDiskAccess() }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }
}

struct InspectorPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "cursorarrow.click.2").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Select an item to see why it takes space, who owns it and how it comes back.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
