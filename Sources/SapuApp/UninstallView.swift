import SapuCore
import SwiftUI

/// Pick an app on the left; the right side shows exactly what goes with it before anything moves.
struct UninstallView: View {
    @Environment(AppModel.self) var model
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .uninstall, value: model.installedApps.isEmpty ? nil : "\(model.installedApps.count)", caption: "apps installed")
            HSplitView {
                appList.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                planPane.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model.installedApps.isEmpty { model.loadApps() } }
    }

    private var shown: [InstalledApp] {
        let q = filter.lowercased()
        return model.installedApps.filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.bundleID ?? "").lowercased().contains(q) }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find an app", text: $filter).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Depot.bay))
            .overlay(Capsule().strokeBorder(Depot.line))
            .padding(10)
            if model.loadingApps {
                ProgressView("Reading Applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { app in
                            HStack(spacing: 4) {
                                Tick(on: model.batch.contains(app.id), color: Depot.alert) { model.toggleBatch(app) }
                                    .help("Tick several apps to remove them together")
                                AppRow(app: app, selected: model.selectedApp == app.id && model.batch.count < 2)
                                    .onTapGesture { model.batch.removeAll(); model.batchPlans = []; model.choose(app) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    @ViewBuilder private var planPane: some View {
        if model.batch.count > 1 {
            BatchPlanView()
        } else if model.planning {
            ProgressView("Looking for everything this app left behind…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let plan = model.plan {
            PlanView(plan: plan)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "hand.point.left.fill").font(.system(size: 30)).foregroundStyle(Depot.ink3)
                    .frame(width: 76, height: 76).background(Circle().fill(Depot.bay)).overlay(Circle().strokeBorder(Depot.line))
                Text("Choose an app").font(Depot.sign(20, .bold)).foregroundStyle(Depot.ink)
                Text("Sapu2 lists the app and every file it keeps in your Library: caches, settings, containers, background helpers. Nothing moves until you press Uninstall, and everything goes to the Trash.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.caskToken != nil ? "Homebrew" : app.fromAppStore ? "App Store" : (app.version.flatMap { $0.isEmpty ? nil : "Version \($0)" } ?? " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Depot.bayHigh : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Depot.line : .clear))
        .contentShape(Rectangle())
    }
}

struct PlanView: View {
    @Environment(AppModel.self) var model
    let plan: UninstallPlan

    private var groups: [(String, String, [UninstallItem])] {
        let items = plan.items
        return [
            ("The app", "Moved to the Trash" + (plan.app.caskToken != nil ? " by Homebrew" : "") + ".", items.filter { $0.kind == .app }),
            ("Caches, logs and helpers", "Only useful while the app is installed. Removed with it.", items.filter { ($0.kind == .cache || $0.kind == .agent) }),
            ("Your data for this app", "Settings, documents and accounts. Kept unless you tick them.", items.filter { $0.kind == .data && !$0.holdBack }),
            ("Kept for safety", "Sign-ins and keys always stay. Shared folders, profiles and libraries: tick one only if you are sure.", items.filter(\.holdBack)),
        ].filter { !$0.2.isEmpty }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { Circle().fill(c).frame(width: 8, height: 8); Text(t).font(.caption).foregroundStyle(Depot.ink2) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 22) {
                        Constellation(plan: plan).frame(width: 230, height: 230)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.app.name).font(Depot.sign(30, .heavy)).foregroundStyle(Depot.ink)
                            Text([plan.app.bundleID, plan.app.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(plan.sized ? Format.bytes(plan.totalBytes) : "Counting…").font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                                .contentTransition(.numericText())
                            Text("app and all its files").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 6)
                    HStack(spacing: 16) {
                        legend(Depot.go, "Goes with it")
                        legend(Depot.yours, "Your data, kept")
                        legend(Depot.stays, "Kept for safety")
                    }
                    if let why = plan.blocked {
                        Label(why, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                SectionTitle(title: g.0, subtitle: g.1)
                                Spacer()
                                if g.0 == "Your data for this app" {
                                    let allOn = g.2.allSatisfy(\.selected)
                                    Button(allOn ? "Keep all" : "Remove all") { model.setPersonalData(!allOn) }.buttonStyle(.link)
                                }
                            }
                            Card {
                                VStack(spacing: 0) {
                                    ForEach(Array(g.2.enumerated()), id: \.element.id) { i, item in
                                        if i > 0 { Divider().padding(.vertical, 6) }
                                        PlanRow(item: item, appName: plan.app.name, sized: plan.sized)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.sized ? "\(Format.bytes(plan.selectedBytes)) goes to the Trash" : "\(plan.items.filter(\.selected).count) items go to the Trash").font(.headline.monospacedDigit())
                    Text("\(plan.items.filter(\.selected).count) of \(plan.items.count) items. Put back from the Trash any time.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.uninstalling || !plan.sized { ProgressView().controlSize(.small) }
                Button {
                    model.uninstall()
                } label: {
                    Label("Uninstall \(plan.app.name)", systemImage: "trash")
                }
                .buttonStyle(SignButtonStyle(tint: Depot.alert, large: false))
                .disabled(plan.blocked != nil || model.uninstalling || !plan.sized)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Depot.floorTop)
        }
    }
}

struct PlanRow: View {
    @Environment(AppModel.self) var model
    let item: UninstallItem
    let appName: String
    var sized = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if item.locked != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(Depot.ink3).frame(width: 18, height: 18) }
                else { Tick(on: item.selected, color: Constellation.color(item), enabled: item.kind != .app) { model.togglePlanItem(item.id) } }
            }
            .help(item.locked ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .app ? appName + ".app" : label).lineLimit(1).truncationMode(.middle)
                Text(item.path.tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if item.kind == .agent || item.holdBack { Text(item.note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(sized ? Format.bytes(item.bytes) : "…").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { model.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
    }

    /// "Application Support › Orca" reads better than the full path.
    private var label: String {
        let lib = NSHomeDirectory() + "/Library/"
        if item.path.hasPrefix(lib) {
            let parts = item.path.dropFirst(lib.count).split(separator: "/")
            return parts.count > 1 ? "\(parts.first!) › \(parts.dropFirst().joined(separator: "/"))" : String(parts.first ?? "")
        }
        return item.path.tildePath
    }
}

/// Several apps ticked: one review, each app with its default plan. Click an app to change its choices.
struct BatchPlanView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let plans = model.batchPlans, ok = plans.filter { $0.blocked == nil }
        VStack(spacing: 0) {
            if model.planningBatch && plans.isEmpty {
                ProgressView("Looking for everything these apps left behind…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Remove \(model.batch.count) apps",
                                     subtitle: "Each app goes with its caches, logs and background helpers. Your data, sign-ins and protected items stay. Click an app to change its choices.")
                        ForEach(plans, id: \.app.id) { p in
                            Card(tint: p.blocked == nil ? nil : .orange) {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: p.app.path)).resizable().frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.app.name).font(.headline)
                                        if let why = p.blocked { Text("Skipped: \(why)").font(.caption).foregroundStyle(.orange) }
                                        else {
                                            let kept = p.items.filter { !$0.selected }.count
                                            Text("\(p.items.filter(\.selected).count) items go · \(kept) kept (your data, sign-ins)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(Format.bytes(p.selectedBytes)).font(.body.monospacedDigit().weight(.semibold))
                                    Button("Review") { if let a = model.installedApps.first(where: { $0.id == p.app.id }) { model.batch.removeAll(); model.batchPlans = []; model.choose(a) } }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Format.bytes(ok.reduce(0) { $0 + $1.selectedBytes })) goes to the Trash").font(.headline.monospacedDigit())
                        Text("\(ok.count) of \(plans.count) apps. Put back from the Trash or Receipts any time.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.uninstalling || model.planningBatch { ProgressView().controlSize(.small) }
                    Button { model.uninstallBatch() } label: { Label("Uninstall \(ok.count) apps", systemImage: "trash") }
                        .buttonStyle(SignButtonStyle(tint: Depot.alert, large: false))
                        .disabled(ok.isEmpty || model.uninstalling || model.planningBatch)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Depot.floorTop)
            }
        }
    }
}

/// The app at the centre and every file it keeps orbiting it, sized by space and coloured by what happens to it.
/// Shows at a glance how much an app scatters across your Library.
struct Constellation: View {
    let plan: UninstallPlan
    @State private var spread: CGFloat = 0.2

    static func color(_ i: UninstallItem) -> Color {
        if i.locked != nil || (i.holdBack && !i.selected) { return Depot.stays }
        return i.selected ? Depot.go : Depot.yours
    }

    var body: some View {
        let items = plan.items.filter { $0.kind != .app }.sorted { $0.bytes > $1.bytes }.prefix(36)
        let top = Double(max(items.first?.bytes ?? 1, 1))
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            ZStack {
                Circle().strokeBorder(Depot.line, style: StrokeStyle(lineWidth: 1, dash: [3, 5])).frame(width: g.size.width * 0.62)
                Circle().strokeBorder(Depot.line, style: StrokeStyle(lineWidth: 1, dash: [3, 5])).frame(width: g.size.width * 0.95)
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let ring = i % 2 == 0 ? 0.31 : 0.475
                    let a = Double(i) * 2.399963 // golden angle: no two dots line up
                    let r = g.size.width * ring * spread
                    let d = 7 + 18 * (Double(item.bytes) / top).squareRoot()
                    Circle().fill(Self.color(item).gradient)
                        .frame(width: d, height: d)
                        .shadow(color: Self.color(item).opacity(0.5), radius: 6)
                        .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                        .help("\(item.path.tildePath) · \(Format.bytes(item.bytes))")
                }
                Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path)).resizable().frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    .position(c)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) { spread = 1 } }
        .id(plan.app.id)
        .accessibilityLabel("\(plan.app.name) and \(plan.items.count - 1) files")
    }
}
