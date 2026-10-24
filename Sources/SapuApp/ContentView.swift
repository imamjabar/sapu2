import SapuCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasFullDiskAccess { FullDiskAccessBanner() }
                ScanBar()
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.checked.isEmpty { SelectionBar() }
            }
            .inspector(isPresented: $showInspector) {
                Group {
                    if let f = model.focusedFinding { FindingDetail(finding: f) } else { InspectorPlaceholder() }
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
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
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Filter by name, path or project")
        .sheet(isPresented: $model.reviewing) { ReviewSheet() }
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
            row(.overview)
            SwiftUI.Section("Clean") {
                ForEach([Pane.cleanable, .caches, .artifacts, .logs, .apps, .files]) { row($0) }
            }
            SwiftUI.Section("Understand") {
                ForEach([Pane.projects, .map, .security]) { row($0) }
            }
            SwiftUI.Section("History") { row(.receipts) }
        }
        .listStyle(.sidebar)
    }

    private func row(_ s: Pane) -> some View {
        Label {
            HStack {
                Text(s.rawValue)
                Spacer()
                if let badge = badge(s) {
                    Text(badge).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: s.symbol)
        }
        .tag(s)
    }

    private func badge(_ s: Pane) -> String? {
        switch s {
        case .overview, .receipts: return nil
        case .projects: return model.snapshot.projects.isEmpty ? nil : "\(model.snapshot.projects.count)"
        case .security:
            let n = model.versions.filter { $0.level == .eol || $0.level == .outdated }.count
            return n > 0 ? "\(n)" : nil
        default:
            let b = model.snapshot.findings.filter { s.includes($0) && $0.action != .none }.reduce(0) { $0 + $1.bytes }
            return b > 0 ? Format.bytes(b) : nil
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
            Button("Open Settings") { model.openFullDiskAccessSettings() }
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
