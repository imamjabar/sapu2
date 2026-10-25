import SapuCore
import SwiftUI

/// Pick an app on the left; the right side shows exactly what goes with it before anything moves.
struct UninstallView: View {
    @EnvironmentObject var model: AppModel
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
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)
            Divider()
            if model.loadingApps {
                ProgressView("Reading Applications…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { app in
                            HStack(spacing: 4) {
                                Toggle("", isOn: Binding(get: { model.batch.contains(app.id) }, set: { _ in model.toggleBatch(app) }))
                                    .toggleStyle(.checkbox).labelsHidden().help("Tick several apps to remove them together")
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
                Image(systemName: "hand.point.left").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Choose an app").font(.title3.weight(.semibold))
                Text("Sapu lists the app and every file it keeps in your Library: caches, settings, containers, background helpers. Nothing moves until you press Uninstall, and everything goes to the Trash.")
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
                Text(app.caskToken != nil ? "Homebrew" : app.fromAppStore ? "App Store" : (app.version.map { "Version \($0)" } ?? " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}

struct PlanView: View {
    @EnvironmentObject var model: AppModel
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: plan.app.path)).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.app.name).font(.title2.weight(.bold))
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
                .buttonStyle(GradientButtonStyle(tint: .purple))
                .disabled(plan.blocked != nil || model.uninstalling || !plan.sized)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
        }
    }
}

struct PlanRow: View {
    @EnvironmentObject var model: AppModel
    let item: UninstallItem
    let appName: String
    var sized = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { item.selected }, set: { _ in model.togglePlanItem(item.id) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(item.kind == .app || item.locked != nil)
                .overlay { if item.locked != nil { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).offset(x: 14) } }
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
    @EnvironmentObject var model: AppModel

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
                        .buttonStyle(GradientButtonStyle(tint: .purple))
                        .disabled(ok.isEmpty || model.uninstalling || model.planningBatch)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}
