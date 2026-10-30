import SapuCore
import SwiftUI

/// Cleanup: one bay per cleaning group. Rows share one set of columns (tick, opener, name, size), so an app with
/// several items reads as one row whose items open inside it, never as a sibling of the row above.
struct FindingsList: View {
    @Environment(AppModel.self) var model
    let section: Pane
    /// Apps and projects that are open, keyed by shelf and owner.
    @State private var open = Set<String>()

    var body: some View {
        let items = model.findings(for: section)
        let maxBytes = items.first?.bytes ?? 1
        VStack(spacing: 0) {
            if items.isEmpty {
                empty
            } else {
                ScrollView {
                    // One flat lazy list: every header, row and opened item is its own entry, so only what is on
                    // screen is built, and opening an app inserts its items without laying out the rest again.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        hero(items).padding(.bottom, 18)
                        // Grouped once per change of results, not on every redraw.
                        let bays = model.memo("shelves/\(section.rawValue)") { shelves(items) }
                        ForEach(Self.rows(bays, open: open)) { r in
                            CleanRowView(row: r, maxBytes: maxBytes, open: open.contains(r.id)) {
                                withAnimation(.easeOut(duration: 0.12)) { if open.contains(r.id) { open.remove(r.id) } else { open.insert(r.id) } }
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 28).padding(.top, 4)
                }
            }
        }
    }

    /// Title, what's here split by safety as one ribbon, and Select Safe.
    private func hero(_ items: [Finding]) -> some View {
        let cleanable = items.filter { $0.action != .none }
        let total = cleanable.reduce(Int64(0)) { $0 + $1.bytes }
        let safe = items.filter { $0.safety == .safe && model.isSelectable($0) }
        let safeBytes = safe.reduce(Int64(0)) { $0 + $1.bytes }
        func sum(_ s: Safety) -> Int64 { cleanable.filter { $0.safety == s }.reduce(0) { $0 + $1.bytes } }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.categoryFilter?.rawValue ?? section.title).font(Depot.sign(28, .heavy)).foregroundStyle(Depot.ink)
                    if model.categoryFilter != nil {
                        Button { model.categoryFilter = nil } label: { Label("Showing only this kind · Show all \(section.tab.lowercased())", systemImage: "xmark.circle.fill") }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Depot.yours)
                    }
                    Text(model.categoryFilter == nil ? section.blurb : "Everything Sapu2 found of this kind, and what it can do with each.").font(.callout).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 0) {
                    // The headline is what's here; the caption says how much of it Sapu2 can clean.
                    let found = items.reduce(Int64(0)) { $0 + $1.bytes }
                    Text(Format.bytes(found)).font(Depot.sign(30, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                    let now = items.filter(model.isSelectable).reduce(Int64(0)) { $0 + $1.bytes }
                    let locked = items.filter { model.canUnlock($0) }.reduce(Int64(0)) { $0 + $1.bytes }
                    Text("\(items.count) item\(items.count == 1 ? "" : "s") · " + (total == 0 ? "managed by their own apps" : (now == safeBytes ? "all \(Format.bytes(now)) safe" : "\(Format.bytes(now)) you can tick, \(Format.bytes(safeBytes)) of it safe"))
                         + (locked > 0 ? " · \(Format.bytes(locked)) locked (active projects)" : ""))
                        .font(.caption).foregroundStyle(Depot.ink2)
                }
                if !safe.isEmpty {
                    Button { model.selectSafe(in: section) } label: { Label("Tick safe · \(Format.bytes(safeBytes))", systemImage: "checkmark") }
                        .buttonStyle(SignButtonStyle(large: false))
                }
            }
            Ribbon(parts: [
                .init(id: "s", name: "Safe", bytes: sum(.safe), color: Depot.go),
                .init(id: "c", name: "Check first", bytes: sum(.check), color: Depot.choice),
                .init(id: "y", name: "Yours", bytes: sum(.yours), color: Depot.yours),
                .init(id: "p", name: "Protected", bytes: sum(.protected), color: Depot.stays),
            ])
        }
        .padding(.top, 8)
    }

    struct Shelf {
        let key: String, title: String, symbol: String, note: String, items: [Finding]
        /// Items of one app or project together, biggest first; nil when the shelf lists items one by one.
        var owners: [Owner]? = nil
        var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    struct Owner: Identifiable {
        let id: String
        let name: String
        let items: [Finding]
        let total: Int64
        /// The most careful verdict among its items, so a group never looks safer than its riskiest part.
        let worst: Safety
    }

    static func owners(_ items: [Finding]) -> [Owner] {
        // "Notion" and "notion" are one app; the lowercased key is also the row's identity, so it's unique.
        Dictionary(grouping: items) { ($0.owner ?? $0.title).lowercased() }
            .map { key, v in
                let sorted = v.sorted { $0.bytes > $1.bytes }
                return Owner(id: key, name: v.compactMap(\.owner).first { $0.first?.isUppercase == true } ?? v[0].owner ?? v[0].title,
                             items: sorted, total: v.reduce(0) { $0 + $1.bytes }, worst: v.map(\.safety).max() ?? .safe)
            }
            .sorted { $0.total > $1.total }
    }

    private func shelves(_ items: [Finding]) -> [Shelf] {
        let cleanable = items.filter { $0.action != .none }
        var out: [Shelf]
        if [.cleanable, .caches, .logs].contains(section) {
            let d = Dictionary(grouping: cleanable) { CleanGroup.of($0) }
            out = CleanGroup.allCases.compactMap { g in d[g].map { Shelf(key: g.rawValue, title: g.rawValue, symbol: g.symbol, note: g.promise, items: $0) } }
        } else {
            let d = Dictionary(grouping: cleanable, by: \.category)
            out = d.map { Shelf(key: $0.key.rawValue, title: $0.key.rawValue, symbol: $0.key.symbol, note: "", items: $0.value) }
                .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }
        }
        if [.cleanable, .caches, .logs, .artifacts].contains(section) {
            out = out.map { var s = $0; s.owners = Self.owners(s.items); return s }
        }
        let separate = items.filter { $0.action == .none }
        if !separate.isEmpty {
            out.append(Shelf(key: "own", title: "Manage in their own app", symbol: "arrow.up.forward.app",
                             note: "Virtual machine disks and model libraries. Only their app removes them correctly, so Sapu2 explains them and leaves them.",
                             items: separate))
        }
        return out
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

/// One entry of the flat Cleanup list.
struct CleanRow: Identifiable {
    enum Kind {
        case header(FindingsList.Shelf)
        case owner(FindingsList.Owner)
        case item(Finding, nested: Bool, showPath: Bool, rail: Color)
        case gap
    }
    let id: String
    let kind: Kind
    /// Last entry of its bay: rounds the bottom corners and drops the divider.
    var last = false
}

extension FindingsList {
    static func rows(_ shelves: [Shelf], open: Set<String>) -> [CleanRow] {
        var out: [CleanRow] = []
        for (i, shelf) in shelves.enumerated() {
            if i > 0 { out.append(CleanRow(id: "gap/\(shelf.key)", kind: .gap)) }
            out.append(CleanRow(id: "h/\(shelf.key)", kind: .header(shelf)))
            if let owners = shelf.owners {
                for o in owners {
                    if o.items.count == 1 {
                        out.append(CleanRow(id: "i/\(o.items[0].id)", kind: .item(o.items[0], nested: false, showPath: false, rail: .clear)))
                        continue
                    }
                    let key = "o/\(shelf.key)/\(o.id)"
                    out.append(CleanRow(id: key, kind: .owner(o)))
                    if open.contains(key) {
                        // When every item would repeat the same sentence, each one shows where it lives instead.
                        let same = Set(o.items.map { Explainer.explain($0)?.plain ?? $0.reason }).count == 1
                        out += o.items.map { CleanRow(id: "n/\(key)/\($0.id)", kind: .item($0, nested: true, showPath: same, rail: o.worst.color)) }
                    }
                }
            } else {
                out += shelf.items.map { CleanRow(id: "i/\($0.id)", kind: .item($0, nested: false, showPath: false, rail: .clear)) }
            }
            out[out.count - 1].last = true
        }
        return out
    }
}

/// Draws one entry on its slice of the bay: the header rounds the top, the last entry rounds the bottom.
struct CleanRowView: View {
    let row: CleanRow
    let maxBytes: Int64
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        switch row.kind {
        case .gap:
            Color.clear.frame(height: 18)
        case .header(let shelf):
            VStack(spacing: 0) { ShelfHeader(shelf: shelf); Hairline() }
                .background(Depot.bay, in: shape(top: 16))
        case .owner(let o):
            slice { OwnerRow(owner: o.name, items: o.items, maxBytes: maxBytes, open: open, toggle: toggle) }
        case .item(let f, let nested, let showPath, let rail):
            slice(nested: nested) {
                FindingRow(finding: f, maxBytes: maxBytes, nested: nested, showPath: showPath)
                    .background(nested ? Depot.floor.opacity(0.55) : .clear)
                    .overlay(alignment: .leading) { if nested { Rectangle().fill(rail.opacity(0.6)).frame(width: 2).padding(.leading, 56) } }
            }
        }
    }

    private func shape(top: CGFloat = 0) -> UnevenRoundedRectangle {
        let bottom: CGFloat = row.last ? 16 : 0
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }

    private func slice<C: View>(nested: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            content()
            if !row.last && !nested { Hairline(inset: 16) }
        }
        .background(Depot.bay)
        .clipShape(shape())
    }
}

/// A shelf's title row. Its own view, so ticking redraws only this and the rows, not the grouping.
struct ShelfHeader: View {
    @Environment(AppModel.self) var model
    let shelf: FindingsList.Shelf

    var body: some View {
        let selectable = shelf.items.filter { model.isSelectable($0) }
        let picked = selectable.filter { model.checked.contains($0.id) }.count
        HStack(spacing: 12) {
            Tick(on: !selectable.isEmpty && picked == selectable.count, mixed: picked > 0, color: Depot.go, enabled: !selectable.isEmpty) {
                let on = picked != selectable.count
                for f in selectable { if on { model.checked.insert(f.id) } else { model.checked.remove(f.id) } }
            }
            Image(systemName: shelf.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Depot.ink2).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title).font(Depot.sign(16, .bold)).foregroundStyle(Depot.ink)
                if !shelf.note.isEmpty { Text(shelf.note).font(.caption).foregroundStyle(Depot.ink2).lineLimit(2) }
            }
            Spacer()
            Text(Format.bytes(shelf.total)).font(Depot.sign(17, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }
}

/// One item. Columns: tick · opener slot · name and why · size bar · size and verdict. Click the row for details.
struct FindingRow: View {
    @Environment(AppModel.self) var model
    let finding: Finding
    let maxBytes: Int64
    var nested = false
    var showPath = false

    var body: some View {
        let selectable = model.isSelectable(finding)
        let focused = model.focused == finding.id
        HStack(spacing: 12) {
            Group {
                if model.canUnlock(finding) {
                    UnlockButton(items: [finding])
                } else {
                    Tick(on: model.checked.contains(finding.id), color: model.unlocked.contains(finding.id) ? Depot.choice : finding.safety.color, enabled: selectable) { model.toggle(finding) }
                        .opacity(finding.action == .none ? 0 : 1)
                }
            }
            .frame(width: 18)
            // Same width as an app row's chevron, so names line up whether or not a row opens.
            Group {
                if nested { Circle().fill(finding.safety.color).frame(width: 6, height: 6) } else { Color.clear }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if model.unlocked.contains(finding.id) { Text("unlocked").font(.caption2.weight(.bold)).foregroundStyle(Depot.choice) }
                    Text(finding.title).font(.body.weight(nested ? .regular : .medium)).foregroundStyle(Depot.ink).lineLimit(1)
                    if let owner = finding.owner, !finding.title.contains(owner), !nested {
                        Text(owner).font(.caption).foregroundStyle(Depot.ink2).lineLimit(1)
                    }
                }
                Text(model.unlocked.contains(finding.id) ? (Explainer.explain(finding)?.impactText ?? finding.reason)
                                                         : model.isActiveLock(finding.lockedReason) ? "Active project, edited \(Format.age(finding.lastModified)). Click the lock to unlock it."
                                                         : finding.lockedReason ?? (showPath ? finding.path.tildePath : Explainer.explain(finding)?.plain ?? finding.reason))
                    .font(.caption).foregroundStyle(Depot.ink2).lineLimit(1).truncationMode(showPath ? .middle : .tail)
            }
            Spacer(minLength: 8)
            RelativeBar(value: finding.bytes, max: maxBytes, color: finding.safety.color).frame(width: 90)
            VStack(alignment: .trailing, spacing: 3) {
                SizeText(bytes: finding.bytes)
                Text(Format.age(finding.lastModified)).font(.caption).foregroundStyle(Depot.ink3)
            }
            .frame(minWidth: 84, alignment: .trailing)
            SafetyBadge(safety: finding.safety).frame(width: 104, alignment: .trailing)
        }
        .padding(.leading, nested ? 34 : 16).padding(.trailing, 16).padding(.vertical, 9)
        .background(focused ? Depot.bayHigh : .clear)
        .opacity(finding.lockedReason != nil && !selectable ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.focused = focused ? nil : finding.id }
        .contextMenu {
            Button("Show in Finder") { model.reveal(finding.path) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(finding.path, forType: .string) }
            if model.unlocked.contains(finding.id) { Button("Lock again") { model.relock(finding) } }
            Divider()
            if model.isProtected(finding.path) {
                Button("Allow cleaning again") { model.setProtected(ProtectList.entry(covering: finding.path, in: model.protectList) ?? finding.path, false) }
            } else {
                Button("Never clean this") { model.setProtected(finding.path, true) }
            }
        }
    }
}

/// One app with several items (VS Code › Cache, Code Cache, WebStorage). Click anywhere to open it; the tick
/// selects every item of that app that can be selected.
struct OwnerRow: View {
    @Environment(AppModel.self) var model
    let owner: String
    let items: [Finding]
    let maxBytes: Int64
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let selectable = items.filter { model.isSelectable($0) }
        let picked = selectable.filter { model.checked.contains($0.id) }
        let lockable = items.filter(model.canUnlock)
        HStack(spacing: 12) {
            Group {
                if selectable.isEmpty && !lockable.isEmpty {
                    UnlockButton(items: lockable)
                } else {
                    Tick(on: !selectable.isEmpty && picked.count == selectable.count, mixed: !picked.isEmpty, color: worst.color, enabled: !selectable.isEmpty) {
                        let on = picked.count != selectable.count
                        for f in selectable { if on { model.checked.insert(f.id) } else { model.checked.remove(f.id) } }
                    }
                }
            }
            .frame(width: 18)
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Chevron(open: open)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(owner).font(.body.weight(.medium)).foregroundStyle(Depot.ink).lineLimit(1)
                            Text("\(items.count)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Depot.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Depot.bayHigh))
                        }
                        Text(summary).font(.caption).foregroundStyle(Depot.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    RelativeBar(value: total, max: maxBytes, color: worst.color).frame(width: 90)
                    VStack(alignment: .trailing, spacing: 3) {
                        SizeText(bytes: total)
                        Text(open ? "hide items" : "show items").font(.caption).foregroundStyle(Depot.ink3)
                    }
                    .frame(minWidth: 84, alignment: .trailing)
                    SafetyBadge(safety: worst).frame(width: 104, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Collapse" : "Expand")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// The most careful verdict among its items, so a group never looks safer than its riskiest part.
    private var worst: Safety { items.map(\.safety).max() ?? .safe }
    private var summary: String {
        let safe = items.filter { $0.safety == .safe }.count
        return safe == items.count ? "All safe: " + items.map(\.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3).joined(separator: ", ")
                                   : "\(safe) of \(items.count) safe, the rest need a look"
    }
}

struct FindingDetail: View {
    @Environment(AppModel.self) var model
    let finding: Finding
    @State private var facts: [YourContext.Fact]? = nil

    var body: some View {
        let e = Explainer.explain(finding)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(finding.category.rawValue, systemImage: finding.category.symbol).font(.caption).foregroundStyle(Depot.ink2)
                    Text(finding.title).font(Depot.sign(18, .bold)).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(Format.bytes(finding.bytes)).font(Depot.sign(28, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                        Spacer()
                        SafetyBadge(safety: finding.safety)
                    }
                    Text("\(finding.files.formatted()) files · changed \(Format.age(finding.lastModified))").font(.caption).foregroundStyle(Depot.ink2)
                }
                if let lock = finding.lockedReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: model.unlocked.contains(finding.id) ? "lock.open.fill" : "lock.fill").foregroundStyle(Depot.choice)
                        Text(model.unlocked.contains(finding.id) ? "Unlocked for this session. It locks again when you quit Sapu2."
                             : model.isActiveLock(lock) ? "Active project: you edited it \(Format.age(finding.lastModified)), so it stays and your next build is fast. Unlock it to clean it anyway." : lock)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if model.canUnlock(finding) { UnlockButton(items: [finding], label: "Unlock") }
                    }
                    .font(.callout).padding(10)
                    .background(Depot.choice.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                block("What it is", e?.plain ?? finding.usedFor, "text.book.closed")
                facts.map { list in
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(text: "On your Mac")
                        if list.isEmpty { Text("Nothing more to add about this one.").font(.callout).foregroundStyle(Depot.ink2) }
                        ForEach(list, id: \.self) { f in
                            Label { Text(.init(f.text)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: f.symbol).foregroundStyle(Depot.yours) }
                                .font(.callout).foregroundStyle(Depot.ink)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Depot.yours.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if facts == nil { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at your projects…").font(.caption).foregroundStyle(Depot.ink2) } }
                if let e {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(text: "If you remove it")
                        ImpactMeter(impact: e.impact)
                        Text(e.impactText).font(.callout).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(text: "Best way to free this space")
                        Text(e.bestWay).font(.callout).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true)
                        ForEach(e.commands, id: \.self) { CommandChip(command: $0) }
                    }
                    block("Comes back?", e.comesBack, "arrow.uturn.backward")
                } else {
                    block("Why it takes space", finding.reason, "questionmark.circle")
                    if let r = finding.rebuild { block("If you clean it", r, "arrow.uturn.backward") }
                }
                block("Our suggestion", Self.suggestion(finding), "lightbulb")
                block("Sapu2 will", finding.category == .logs && finding.action == .trash
                      ? "Move log files untouched for a week to the Trash (restorable), empty large logs still being written in place, and keep recent small ones."
                      : finding.action.label + (finding.action == .trash || finding.action == .freezeThenTrash ? " (restorable until you empty the Trash)." : "."), "hand.raised")
                VStack(alignment: .leading, spacing: 6) {
                    Kicker(text: "Location")
                    Text(finding.path.tildePath).font(.caption.monospaced()).foregroundStyle(Depot.ink2).textSelection(.enabled)
                    HStack {
                        Button { model.reveal(finding.path) } label: { Label("Show in Finder", systemImage: "folder") }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(finding.path, forType: .string) } label: {
                            Label("Copy path", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Toggle("Never clean this (protect list)", isOn: Binding(get: { model.isProtected(finding.path) }, set: { model.setProtected(finding.path, $0) }))
                        .toggleStyle(.checkbox).font(.caption)
                }
            }
            .padding(16)
        }
        .background(Depot.floorTop)
        .task(id: finding.id) {
            facts = nil
            let f = finding, projects = model.snapshot.projects
            facts = await Task.detached(priority: .userInitiated) {
                YourContext.facts(for: f, projects: projects, running: SystemProbe.runningProcessNames())
            }.value
        }
    }

    /// One sentence on what to do with it, from its safety level and lock.
    static func suggestion(_ f: Finding) -> String {
        if let lock = f.lockedReason { return "Leave it for now. \(lock)" }
        if f.action == .none { return "Leave it to its own app. Sapu2 explains it but never removes it." }
        switch f.safety {
        case .safe: return "Clean it. It's rebuilt or downloaded again when needed, and it goes to the Trash first, so you can put it back."
        case .check: return "Clean it if you can wait for it to rebuild or download again\(f.rebuild.map { " (\($0.prefix(1).lowercased() + $0.dropFirst()))" } ?? ""). Quit its app first."
        case .yours: return "Look at it in Finder first. It's your data, so Sapu2 never ticks it for you."
        case .protected: return "Leave it. Sapu2 never touches protected items."
        }
    }

    private func block(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: title)
            Text(text).font(.callout).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Four steps from no impact to may lose data, filled to this item's level.
struct ImpactMeter: View {
    let impact: Explainer.Impact
    private var color: Color { [Depot.go, Depot.go, Depot.choice, Depot.alert][impact.rawValue] }
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4) { i in Capsule().fill(i <= impact.rawValue ? color : Depot.bayHigh).frame(width: 18, height: 6) }
            }
            Text(impact.label).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
    }
}

/// A command to type, with Copy.
struct CommandChip: View {
    let command: String
    @State private var copied = false
    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(.caption.monospaced()).foregroundStyle(Depot.ink).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 4)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string); copied = true
            }
            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Depot.yours)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Depot.floor, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Depot.line))
    }
}
