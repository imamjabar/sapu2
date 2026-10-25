import SapuCore
import SwiftUI

struct FindingsList: View {
    @EnvironmentObject var model: AppModel
    let section: Pane

    var body: some View {
        let items = model.findings(for: section)
        let maxBytes = items.first?.bytes ?? 1
        VStack(spacing: 0) {
            header(items)
            if items.isEmpty {
                empty
            } else {
                List(selection: $model.focused) {
                    if [.cleanable, .caches, .logs].contains(section) {
                        // The eight cleaning groups; an app with several items is one row that opens.
                        ForEach(cleanGroups(items.filter { $0.action != .none }), id: \.0) { group in
                            SwiftUI.Section {
                                ForEach(owners(group.1), id: \.0) { owner in
                                    if owner.1.count > 1 {
                                        OwnerRow(owner: owner.0, items: owner.1, maxBytes: maxBytes)
                                    } else {
                                        FindingRow(finding: owner.1[0], maxBytes: maxBytes).tag(owner.1[0].id)
                                    }
                                }
                            } header: {
                                VStack(alignment: .leading, spacing: 2) {
                                    groupHeader(group.0.rawValue, group.0.symbol, group.1)
                                    Text(group.0.promise).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        ForEach(groups(items.filter { $0.action != .none }), id: \.0) { group in
                            SwiftUI.Section {
                                ForEach(group.1) { f in FindingRow(finding: f, maxBytes: maxBytes).tag(f.id) }
                            } header: {
                                groupHeader(group.0.rawValue, group.0.symbol, group.1)
                            }
                        }
                    }
                    let separate = items.filter { $0.action == .none }
                    if !separate.isEmpty {
                        SwiftUI.Section {
                            ForEach(separate) { f in FindingRow(finding: f, maxBytes: maxBytes).tag(f.id) }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                groupHeader("Manage in their own app", "arrow.up.forward.app", separate)
                                Text("Virtual machine disks and model libraries. Only their app removes them correctly, so Sapu explains them and leaves them.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func groupHeader(_ title: String, _ symbol: String, _ items: [Finding]) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(section.tint).font(.callout.weight(.semibold))
            Spacer()
            Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
        }
    }

    private func groups(_ items: [Finding]) -> [(SapuCore.Category, [Finding])] {
        let dict = Dictionary(grouping: items, by: \.category)
        return dict.map { ($0.key, $0.value) }.sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }

    private func cleanGroups(_ items: [Finding]) -> [(CleanGroup, [Finding])] {
        let dict = Dictionary(grouping: items) { CleanGroup.of($0) }
        return CleanGroup.allCases.compactMap { g in dict[g].map { (g, $0) } }
    }

    /// Items of one app together, biggest app first; an app's items biggest first.
    private func owners(_ items: [Finding]) -> [(String, [Finding])] {
        // "Notion" and "notion" are one app.
        let dict = Dictionary(grouping: items) { ($0.owner ?? $0.title).lowercased() }
        return dict.map { _, v in
            let name = v.compactMap(\.owner).first { $0.first?.isUppercase == true } ?? v[0].owner ?? v[0].title
            return (name, v.sorted { $0.bytes > $1.bytes })
        }
            .sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }

    private func header(_ items: [Finding]) -> some View {
        let total = items.filter { $0.action != .none }.reduce(0) { $0 + $1.bytes }
        let safe = items.filter { $0.safety == .safe && model.isSelectable($0) }
        return PaneHeader(pane: section, value: items.isEmpty ? nil : Format.bytes(total), caption: items.isEmpty ? nil : "\(items.count) items") {
            if !safe.isEmpty {
                Button { model.selectSafe(in: section) } label: {
                    Label("Select Safe · \(Format.bytes(safe.reduce(0) { $0 + $1.bytes }))", systemImage: "checkmark.seal.fill")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(GradientButtonStyle(tint: section.tint))
                .padding(.leading, 8)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        let needs: ScanLayer = [.apps, .files, .map].contains(section) ? .full : (section == .artifacts ? .projects : .quick)
        if model.snapshot.layerDates[needs.rawValue] == nil {
            EmptyState(symbol: "magnifyingglass", title: "Not scanned yet",
                       message: "This view needs the “\(needs.name)” layer.",
                       action: ("Scan \(needs.short)", { model.scan([needs]) }))
        } else {
            EmptyState(symbol: "checkmark.circle", title: "Nothing here", message: model.search.isEmpty ? "Clean already." : "No match for “\(model.search)”.")
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding
    let maxBytes: Int64

    var body: some View {
        let selectable = model.isSelectable(finding)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.checked.contains(finding.id) }, set: { _ in model.toggle(finding) }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!selectable)
                .opacity(finding.action == .none ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if finding.lockedReason != nil { Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption) }
                    Text(finding.title).font(.body.weight(.medium)).lineLimit(1)
                    if let owner = finding.owner, !finding.title.contains(owner) {
                        Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(finding.lockedReason ?? finding.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                RelativeBar(value: finding.bytes, max: maxBytes, color: finding.safety.color).frame(maxWidth: 260)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                SizeText(bytes: finding.bytes)
                HStack(spacing: 6) {
                    Text(Format.age(finding.lastModified)).font(.caption).foregroundStyle(.tertiary)
                    SafetyBadge(safety: finding.safety)
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(finding.lockedReason != nil && !selectable ? 0.6 : 1)
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(finding.path) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(finding.path, forType: .string) }
            Divider()
            if model.isProtected(finding.path) {
                Button("Allow cleaning again") { model.setProtected(ProtectList.entry(covering: finding.path, in: model.protectList) ?? finding.path, false) }
            } else {
                Button("Never clean this") { model.setProtected(finding.path, true) }
            }
        }
    }
}

struct FindingDetail: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(finding.category.rawValue, systemImage: finding.category.symbol).font(.caption).foregroundStyle(.secondary)
                    Text(finding.title).font(.title3.weight(.semibold))
                    HStack {
                        Text(Format.bytes(finding.bytes)).font(.title.monospacedDigit().weight(.bold))
                        Spacer()
                        SafetyBadge(safety: finding.safety)
                    }
                    Text("\(finding.files.formatted()) files · changed \(Format.age(finding.lastModified))").font(.caption).foregroundStyle(.secondary)
                }
                if let lock = finding.lockedReason {
                    Label(lock, systemImage: "lock.fill").font(.callout)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                block("Why it takes space", finding.reason, "questionmark.circle")
                block("What it is for", finding.usedFor, "wrench.and.screwdriver")
                if let owner = finding.owner { block("Belongs to", owner, "person.2") }
                if let r = finding.rebuild { block("If you clean it", r, "arrow.uturn.backward") }
                block("Sapu will", finding.category == .logs && finding.action == .trash
                      ? "Move log files untouched for a week to the Trash (restorable), empty large logs still being written in place, and keep recent small ones."
                      : finding.action.label + (finding.action == .trash || finding.action == .freezeThenTrash ? " (restorable until you empty the Trash)." : "."), "hand.raised")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(finding.path.tildePath).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Reveal in Finder") { model.reveal(finding.path) }.controlSize(.small)
                }
            }
            .padding(16)
        }
    }

    private func block(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// One app with several items (VS Code › Cache, Code Cache, WebStorage): opens to show each, and its checkbox
/// selects every item of that app that can be selected.
struct OwnerRow: View {
    @EnvironmentObject var model: AppModel
    let owner: String
    let items: [Finding]
    let maxBytes: Int64
    @State private var open = false

    var body: some View {
        let selectable = items.filter { model.isSelectable($0) }
        let picked = selectable.filter { model.checked.contains($0.id) }
        DisclosureGroup(isExpanded: $open) {
            ForEach(items) { FindingRow(finding: $0, maxBytes: maxBytes).tag($0.id) }
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { !selectable.isEmpty && picked.count == selectable.count }, set: { on in
                    for f in selectable { if on { model.checked.insert(f.id) } else { model.checked.remove(f.id) } }
                }))
                .toggleStyle(.checkbox).labelsHidden().disabled(selectable.isEmpty)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(owner).font(.body.weight(.medium)).lineLimit(1)
                        Text("\(items.count) items").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    RelativeBar(value: total, max: maxBytes, color: worst.color).frame(maxWidth: 260)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    SizeText(bytes: total)
                    SafetyBadge(safety: worst)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
        }
    }

    private var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// The most careful verdict among its items, so a group never looks safer than its riskiest part.
    private var worst: Safety { items.map(\.safety).max() ?? .safe }
    private var summary: String {
        let safe = items.filter { $0.safety == .safe }.count
        return safe == items.count ? "All safe: " + items.map(\.title).prefix(3).joined(separator: ", ")
                                   : "\(safe) of \(items.count) safe, the rest need a look"
    }
}
