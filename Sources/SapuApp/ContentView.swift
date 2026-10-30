import SapuCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            PlaceRail()
                .padding(.top, 12).padding(.bottom, 10)
            let area = Area.of(model.section)
            if area.panes.count > 1 || model.section.showsInspector { SubBar(area: area) }
            if !model.hasFullDiskAccess && model.section != .overview { FullDiskAccessBanner() }
            if (model.update != nil && !model.updateDismissed) || model.updateStatus != nil { UpdateBanner() }
            if model.section.showsInspector || model.section == .projects || (model.scanning != nil && model.section != .overview) {
                ScanBar()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !model.checked.isEmpty && model.section != .overview { SelectionBar() }
        }
        .background(LinearGradient(colors: [Depot.floorTop, Depot.floor], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .inspector(isPresented: inspectorShown) {
            Group {
                if let f = model.focusedFinding { FindingDetail(finding: f) } else { InspectorPlaceholder() }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .sheet(isPresented: Bindable(model).reviewing) { ReviewSheet() }
        .sheet(isPresented: Bindable(model).showAccessSetup) { AccessSetupView() }
        .preferredColorScheme(.dark)
        .tint(Depot.go)
        // Every plain push button in the app becomes a depot capsule.
        .buttonStyle(GhostButtonStyle())
    }

    /// The details column appears when an item is selected, and only where items exist.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { model.focused != nil && model.section.showsInspector },
                set: { if !$0 { model.focused = nil } })
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .overview: SmartCleanView()
        case .projects: ProjectsView()
        case .security: SecurityView()
        case .uninstall: UninstallView()
        case .health: HealthView()
        case .maintenance: MaintenanceView()
        case .receipts: ReceiptsView()
        case .protected: ProtectListView()
        case .map: DiskMapView(ex: model.explorer)
        case .updates: UpdatesView()
        case .trash: TrashView()
        default: FindingsList(section: model.section)
        }
    }
}

/// The six places as one floating pill rail, like signs over the depot bays.
struct PlaceRail: View {
    @Environment(AppModel.self) var model
    @Namespace private var pill

    var body: some View {
        let current = Area.of(model.section)
        HStack(spacing: 2) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30).padding(.horizontal, 6)
                .accessibilityHidden(true)
            ForEach(Area.allCases) { a in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.open(a) } } label: {
                    HStack(spacing: 6) {
                        Text(a == .smartClean ? "Sweep" : a.rawValue)
                        badge(a)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(current == a ? Depot.floor : Depot.ink2)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background {
                        if current == a { Capsule().fill(Depot.ink).matchedGeometryEffect(id: "pill", in: pill) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == a ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Depot.bay))
        .overlay(Capsule().strokeBorder(Depot.line))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    /// One quiet number per place: what can go, what needs you.
    @ViewBuilder private func badge(_ a: Area) -> some View {
        switch a {
        case .apps:
            if !model.appUpdates.isEmpty { Pill(text: "\(model.appUpdates.count)", color: Depot.yours) }
        case .optimize:
            // Same count the Tune up button shows, plus anything else that needs attention.
            let n = Set(model.tasks.filter { $0.status == .attention && $0.fix != .none }.map(\.id) + model.tuneUpTasks.map(\.id)).count
            if n > 0 { Pill(text: "\(n)", color: Depot.choice) }
        case .explore:
            let n = model.versions.filter { $0.level == .eol || $0.level == .outdated }.count + model.securityIssues.filter { $0.level != .info }.count
            if n > 0 { Pill(text: "\(n)", color: Depot.alert) }
        default: EmptyView()
        }
    }
}

/// Second row: the place's tabs as chips, plus filter and scan where there are items to filter.
struct SubBar: View {
    @Environment(AppModel.self) var model
    let area: Area

    var body: some View {
        HStack(spacing: 6) {
            if area.panes.count > 1 {
                ForEach(area.panes) { p in
                    Button { model.section = p } label: {
                        Text(p.tab)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.section == p ? Depot.ink : Depot.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(model.section == p ? Depot.bayHigh : .clear))
                            .overlay(Capsule().strokeBorder(model.section == p ? Depot.line : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if model.section.showsInspector {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Depot.ink3)
                    TextField("Filter by name or path", text: Bindable(model).search).textFieldStyle(.plain).frame(width: 190)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Depot.ink3)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Depot.bay))
                .overlay(Capsule().strokeBorder(Depot.line))
            }
            if model.section != .overview {
                Menu {
                    ForEach(ScanLayer.allCases, id: \.self) { layer in Button(layer.name) { model.scan([layer]) } }
                    Divider()
                    Button("Everything (all layers)") { model.scan(ScanLayer.allCases) }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    model.scan([.quick])
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.scanning != nil)
                .help("Quick scan (⌘R). The menu has projects and the full map.")
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(color))
    }
}

/// Small disk meter pinned to the bottom of the sidebar.
struct DiskFooter: View {
    @Environment(AppModel.self) var model
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
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Without Full Disk Access a few app folders can't be measured, so totals may be a little low.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("How to allow…") { model.showAccessSetup = true; model.watchFullDiskAccess() }.buttonStyle(.link)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.quaternary.opacity(0.35))
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

/// A quiet note when a newer release is on GitHub, or the result of a manual check.
struct UpdateBanner: View {
    @Environment(AppModel.self) var model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
            if let r = model.update, !model.updateDismissed {
                Text(model.updateStatus ?? "Sapu2 \(r.version) is available (you have \(Updater.current)).").font(.callout)
                Spacer()
                Button("Release notes") { NSWorkspace.shared.open(r.page) }.buttonStyle(.link)
                Button("Download") { model.downloadUpdate() }
                Button { model.updateDismissed = true; model.updateStatus = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            } else if let s = model.updateStatus {
                Text(s).font(.callout)
                Spacer()
                Button { model.updateStatus = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.blue.opacity(0.08))
    }
}
