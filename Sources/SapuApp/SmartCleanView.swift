/*
 THESIS: Sapu2 is a sorting depot. Every item a scan finds is sorted into one of four labelled bins (Sweep, Your call,
 Your files, Stays) and you can open any bin before anything moves. Refuses the cleaner default of one gauge and a
 one-shot Clean that hides the list.
 OWN-WORLD: dark slate depot floor (#12161C), raised bays (#1A2029) with hairlines, four bin colours that only ever mean
 a bin (green #3DD68C, amber #FFB547, cobalt #5B9BFF, graphite #8B95A5), rounded heavy signage type for numbers and
 headings, capsule controls, a pill rail for places.
 STORY: see the floor and the bins, press Sort & sweep, watch specks fall into the bins, open a bin, untick anything,
 press Sweep; the green bin empties into the Trash and a receipt says how to put it back.
 FIRST VIEWPORT: pill rail on top; big free-space number; four bins side by side on a floor line, filled from the last
 scan; one green capsule button under them; "Also worth a look" cards below.
 FORM: sorting depot, item 7 of 7 on the grounded list, seed key 6705d134.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
*/
import SapuCore
import SwiftUI

struct SmartCleanView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Group {
            switch model.smartStep {
            case .start: SmartStart()
            case .scanning:
                SmartWorking(title: "Sorting your Mac", detail: model.progress.map { "\($0.layer.name) · \($0.currentPath.tildePath)" } ?? model.smartStatus,
                             fraction: model.progress?.fraction, cancel: model.cancelSmartClean)
            case .review: SmartReview()
            case .cleaning: SmartWorking(title: "Sweeping", detail: model.smartStatus, fraction: nil, cancel: nil, speed: 2.2)
            case .done: SmartDone()
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: model.smartStep)
    }
}

// MARK: Start

struct SmartStart: View {
    @Environment(AppModel.self) var model

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                FreeSpace().padding(.top, 28)
                BinRow(height: 118)
                VStack(spacing: 12) {
                    Button { model.startSmartClean() } label: { Label("Sort & sweep", systemImage: "sparkles") }
                        .buttonStyle(SignButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.scanning != nil)
                    Text("Sapu2 sorts everything it finds into these four bins. Nothing moves until you've looked inside; swept items go to the Trash and History puts them back.")
                        .font(.callout).foregroundStyle(Depot.ink2).multilineTextAlignment(.center)
                }
                DevStack()
                Suggestions()
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 32).padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The disk as one tally that adds up: what each bin holds, the rest of what's used, and free space, with one
/// sentence that says what a sweep gives back.
struct FreeSpace: View {
    @Environment(AppModel.self) var model

    var body: some View {
        if let v = model.snapshot.volume {
            let go = sum(.go), choice = sum(.choice), yours = sum(.yours)
            let rest = max(0, v.used - go - choice - yours)
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.bytes(v.available)).font(Depot.sign(54, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                    Text("free of \(Format.bytes(v.total))").font(Depot.sign(20, .semibold)).foregroundStyle(Depot.ink2)
                }
                Tally(total: v.total, parts: [
                    (Bin.go.name, go, Bin.go.color),
                    (Bin.choice.name, choice, Bin.choice.color),
                    (Bin.yours.name, yours, Bin.yours.color),
                    ("macOS, apps and everything else", rest, Depot.ink3),
                    ("Free", v.available, Depot.bayHigh),
                ])
                .frame(maxWidth: 720)
                Group {
                    if go > 0 {
                        Text("A sweep gives back **\(Format.bytes(go))** now, so you'd have **\(Format.bytes(v.available + go)) free**.")
                        + Text(choice > 0 ? " Your call can add up to \(Format.bytes(choice)) more." : "")
                    } else if model.snapshot.layerDates.isEmpty {
                        Text("Press Sort & sweep to see what can go.")
                    } else {
                        Text("Nothing safe to sweep right now.")
                    }
                }
                .font(.callout).foregroundStyle(Depot.ink2).multilineTextAlignment(.center)
            }
        }
    }

    private func sum(_ b: Bin) -> Int64 { model.items(in: b).reduce(Int64(0)) { $0 + $1.bytes } }
}

/// One bar for the whole disk, split into named parts, with a legend that reads left to right like the bar.
struct Tally: View {
    let total: Int64
    let parts: [(String, Int64, Color)]

    var body: some View {
        let t = Double(max(total, 1))
        let shown = parts.filter { $0.1 > 0 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.2.gradient).frame(width: max(3, (g.size.width - CGFloat(shown.count - 1) * 2) * Double(p.1) / t))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 16)
            HStack(spacing: 14) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 10, height: 10)
                        Text(p.0).foregroundStyle(Depot.ink2)
                        Text(Format.bytes(p.1)).foregroundStyle(Depot.ink).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What Sapu2 found in the developer's own stack, tile by tile. This is the part generic cleaners don't see.
struct DevStack: View {
    @Environment(AppModel.self) var model

    private struct Tile: Identifiable { let id: String, symbol: String, title: String, detail: String, bytes: Int64, safe: Int64, pane: Pane, category: SapuCore.Category }

    private var tiles: [Tile] {
        let all = Bin.allCases.flatMap { model.items(in: $0) }
        func tile(_ id: String, _ symbol: String, _ title: String, _ detail: String, _ cats: [SapuCore.Category], _ pane: Pane) -> Tile {
            let f = all.filter { cats.contains($0.category) }
            return Tile(id: id, symbol: symbol, title: title, detail: detail, bytes: f.reduce(0) { $0 + $1.bytes },
                        safe: model.smartSafe.filter { cats.contains($0.category) }.reduce(0) { $0 + $1.bytes }, pane: pane, category: cats[0])
        }
        return [
            tile("build", "hammer.fill", "Build folders", "node_modules, .venv, target, build, Pods", [.projects], .artifacts),
            tile("pkg", "shippingbox.fill", "Package caches", "npm, pnpm, Yarn, pip, uv, Cargo, Go, Gradle, Homebrew", [.devCaches], .caches),
            tile("xcode", "hammer.circle.fill", "Xcode & Simulators", "DerivedData, old simulators, device support", [.xcode], .caches),
            tile("docker", "cube.transparent.fill", "Docker & VMs", "Images and disks, explained, never deleted", [.containers], .caches),
            tile("ml", "brain.head.profile", "ML models & envs", "Hugging Face, Ollama, conda, torch caches", [.ml], .caches),
        ].filter { $0.bytes > 0 }
    }

    var body: some View {
        let list = tiles
        let active = Bin.allCases.flatMap { model.items(in: $0) }.filter { $0.lockedReason?.hasPrefix("Active project") == true }.count
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Kicker(text: "Your dev stack")
                        Text("Sapu2 knows where developer tools hide gigabytes, and never touches your code.")
                            .font(Depot.sign(16, .bold)).foregroundStyle(Depot.ink)
                    }
                    Spacer()
                    if !model.snapshot.projects.isEmpty {
                        Label("\(model.snapshot.projects.count) projects found · \(active) active, protected", systemImage: "lock.shield.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Depot.go)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Depot.go.opacity(0.12)))
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(list) { t in
                        // Opens Cleanup showing only this kind of item.
                        Button { model.search = ""; model.section = t.pane; model.categoryFilter = t.category } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: t.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Depot.yours)
                                    Spacer()
                                    if t.safe > 0 { Text("\(Format.bytes(t.safe)) safe").font(.caption2.weight(.bold)).foregroundStyle(Depot.go) }
                                }
                                Text(Format.bytes(t.bytes)).font(Depot.sign(22, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                                Text(t.title).font(.callout.weight(.semibold)).foregroundStyle(Depot.ink)
                                Text(t.detail).font(.caption).foregroundStyle(Depot.ink2).lineLimit(2, reservesSpace: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bay()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The four bins on a floor line, filled from the last scan. In the review, tapping a bin opens it.
struct BinRow: View {
    @Environment(AppModel.self) var model
    var height: CGFloat = 110
    var selected: Bin? = nil
    var onPick: ((Bin) -> Void)? = nil

    var body: some View {
        let totals = Bin.allCases.map { b in model.items(in: b).reduce(Int64(0)) { $0 + $1.bytes } }
        let top = Double(max(totals.max() ?? 1, 1))
        HStack(alignment: .bottom, spacing: 26) {
            ForEach(Array(Bin.allCases.enumerated()), id: \.element) { i, b in
                let n = model.items(in: b).count
                Button { onPick?(b) } label: {
                    // Square-root scale, so a small Sweep bin still reads next to a huge Stays bin.
                    BinView(bin: b, level: totals[i] == 0 ? 0 : 0.1 + 0.8 * (Double(totals[i]) / top).squareRoot(),
                            label: b.name, value: n == 0 ? "empty" : "\(Format.bytes(totals[i])) · \(n)",
                            selected: selected == b, height: height)
                        .frame(width: height * 0.92)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(onPick != nil)
                .help(b.promise)
            }
        }
    }
}

/// Up to four next steps drawn from what Sapu2 already knows, as small depot cards.
struct Suggestions: View {
    @Environment(AppModel.self) var model

    struct Item: Identifiable {
        let id: String, symbol: String, color: Color, title: String, detail: String, action: () -> Void
    }

    var items: [Item] {
        var out: [Item] = []
        let attention = model.tasks.filter { $0.status == .attention }
        if !attention.isEmpty {
            out.append(Item(id: "opt", symbol: "wrench.and.screwdriver.fill", color: Depot.choice, title: attention.count == 1 ? "1 tune-up waiting" : "\(attention.count) tune-ups waiting",
                            detail: attention.prefix(2).map(\.title).joined(separator: ", "), action: { model.section = .maintenance }))
        }
        if !model.appUpdates.isEmpty {
            out.append(Item(id: "upd", symbol: "arrow.down.app.fill", color: Depot.yours, title: "\(model.appUpdates.count) app update\(model.appUpdates.count == 1 ? "" : "s")",
                            detail: model.appUpdates.prefix(3).map(\.app.name).joined(separator: ", "), action: { model.section = .updates }))
        } else if model.updatesChecked == nil {
            out.append(Item(id: "upd", symbol: "arrow.down.app.fill", color: Depot.yours, title: "Check app updates",
                            detail: "Homebrew, app updaters, App Store", action: { model.section = .updates; model.checkAppUpdates() }))
        }
        if let t = model.trashSummary, t.bytes > 100_000_000 {
            out.append(Item(id: "trash", symbol: "trash.fill", color: Depot.stays, title: "Trash holds \(Format.bytes(t.bytes))",
                            detail: "Space returns when you empty it", action: { model.section = .trash }))
        }
        let large = model.snapshot.findings.filter { $0.category == .downloads }.reduce(Int64(0)) { $0 + $1.bytes }
        if large > 1_000_000_000 {
            out.append(Item(id: "large", symbol: "doc.on.doc.fill", color: Depot.yours, title: "\(Format.bytes(large)) in big old files",
                            detail: "Never ticked for you", action: { model.section = .files }))
        }
        if let h = model.health, h.score < 65 {
            out.append(Item(id: "health", symbol: "heart.fill", color: Depot.alert, title: "Mac under pressure (\(h.score))",
                            detail: h.advice.first ?? "See what's using memory", action: { model.section = .health }))
        }
        return Array(out.prefix(4))
    }

    var body: some View {
        let list = items
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("ALSO WORTH A LOOK").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Depot.ink3)
                HStack(spacing: 12) {
                    ForEach(list) { s in
                        Button(action: s.action) {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: s.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(s.color).frame(height: 20)
                                Text(s.title).font(Depot.sign(14, .semibold)).foregroundStyle(Depot.ink).lineLimit(1)
                                Text(s.detail).font(.caption).foregroundStyle(Depot.ink2).lineLimit(2, reservesSpace: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .bay()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: Working

struct SmartWorking: View {
    let title: String
    let detail: String
    let fraction: Double?
    let cancel: (() -> Void)?
    var speed: Double = 1

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack(alignment: .bottom) {
                DustFall(speed: speed).frame(width: 480, height: 230)
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                HStack(alignment: .bottom, spacing: 26) {
                    ForEach(Bin.allCases) { b in BinView(bin: b, level: 0, height: 96).frame(width: 88) }
                }
            }
            VStack(spacing: 10) {
                Text(title).font(Depot.sign(26, .heavy)).foregroundStyle(Depot.ink)
                Group {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
                .tint(Depot.go).frame(width: 340)
                Text(detail).font(.callout).foregroundStyle(Depot.ink2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            }
            if cancel != nil { StallHint() }
            if let cancel { Button("Cancel", action: cancel).buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Review

struct SmartReview: View {
    @Environment(AppModel.self) var model
    @State private var bin: Bin = .go
    /// Open groups, keyed by bin and group.
    @State private var open = Set<String>()

    var body: some View {
        let jobs = model.smartTasks.filter { model.smartTaskPicked.contains($0.id) }
        let count = model.smartPicked.count
        VStack(spacing: 0) {
            ScrollView {
                // One flat lazy list: each group row and each opened item is its own entry, so opening a group of
                // 80 items builds only the ones on screen.
                LazyVStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Text("Sorted into four bins").font(Depot.sign(24, .heavy)).foregroundStyle(Depot.ink)
                        Text("Click a bin to look inside. Every item shows where it lives and what happens to it.")
                            .font(.callout).foregroundStyle(Depot.ink2)
                    }
                    .padding(.top, 20).padding(.bottom, 22)
                    BinRow(height: 92, selected: bin, onPick: { b in withAnimation(.easeOut(duration: 0.2)) { bin = b } })
                        .padding(.bottom, 22)
                    let items = model.items(in: bin)
                    let groups = model.memo("bin/\(bin.rawValue)") { BinPanel.groups(items, bin: bin) }
                    let rows = SweepRow.rows(groups, bin: bin, open: open)
                    BinPanel(bin: bin, last: rows.isEmpty)
                    ForEach(rows) { r in
                        SweepRowView(row: r, bin: bin, open: open.contains(r.id)) {
                            withAnimation(.easeOut(duration: 0.12)) { if open.contains(r.id) { open.remove(r.id) } else { open.insert(r.id) } }
                        }
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                Button("Back") { model.smartStep = .start }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(count) item\(count == 1 ? "" : "s") to the Trash\(jobs.isEmpty ? "" : " · \(jobs.count) tune-up\(jobs.count == 1 ? "" : "s")")")
                        .font(.callout.weight(.medium)).foregroundStyle(Depot.ink)
                    Text("Put back any time from History until you empty the Trash").font(.caption).foregroundStyle(Depot.ink2)
                }
                Button { model.confirmSmartClean() } label: { Text("Sweep \(Format.bytes(model.smartBytes))").monospacedDigit() }
                    .buttonStyle(SignButtonStyle(large: false))
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 && jobs.isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Depot.floorTop)
            .overlay(alignment: .top) { Rectangle().fill(Depot.line).frame(height: 1) }
        }
    }
}

/// What's inside one bin: its promise, a tick-all, and groups that open with one click anywhere on the row.
struct BinPanel: View {
    @Environment(AppModel.self) var model
    let bin: Bin
    /// No groups follow: round the bottom too.
    var last = false

    var body: some View {
        let items = model.items(in: bin)
        let tickable = bin != .stays
        let on = items.filter { model.smartPicked.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: bin.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Depot.floor)
                    .frame(width: 32, height: 32).background(Circle().fill(bin.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(bin.name).font(Depot.sign(18, .bold)).foregroundStyle(Depot.ink)
                    Text(bin.promise).font(.callout).foregroundStyle(Depot.ink2)
                }
                Spacer()
                if tickable && !items.isEmpty {
                    Button(on.count == items.count ? "Untick all" : "Tick all") {
                        let all = on.count != items.count
                        for f in items { if all { model.smartPicked.insert(f.id) } else { model.smartPicked.remove(f.id) } }
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Text(Format.bytes((tickable ? on : items).reduce(0) { $0 + $1.bytes }))
                    .font(Depot.sign(20, .heavy).monospacedDigit()).foregroundStyle(tickable && on.isEmpty ? Depot.ink3 : bin.color)
            }
            .padding(16)
            Rectangle().fill(Depot.line).frame(height: 1)
            if bin == .go && !model.smartTasks.isEmpty { TuneUps() }
            if items.isEmpty {
                Text(bin == .go ? "Nothing to sweep right now. Nice and tidy." : "Empty.")
                    .font(.callout).foregroundStyle(Depot.ink2).padding(24)
            }
        }
        .background(Depot.bay, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: last ? 16 : 0,
                                                        bottomTrailingRadius: last ? 16 : 0, topTrailingRadius: 16, style: .continuous))
    }

    struct Shelf { let key: String, title: String, symbol: String, note: String, items: [Finding] }

    static func groups(_ items: [Finding], bin: Bin) -> [Shelf] {
        if bin == .stays {
            let order = ["Projects you're working on", "In use right now", "Managed by its own app", "On your protect list", "Protected", "Other"]
            let d = Dictionary(grouping: items, by: Self.stayReason)
            return order.compactMap { r in d[r].map { Shelf(key: r, title: r, symbol: "lock", note: "", items: $0) } }
        }
        let d = Dictionary(grouping: items) { CleanGroup.of($0) }
        return CleanGroup.allCases.compactMap { g in d[g].map { Shelf(key: g.rawValue, title: g.rawValue, symbol: g.symbol, note: g.promise, items: $0) } }
            .sorted { $0.items.reduce(0) { $0 + $1.bytes } > $1.items.reduce(0) { $0 + $1.bytes } }
    }

    static func stayReason(_ f: Finding) -> String {
        if f.safety == .protected { return "Protected" }
        if let lock = f.lockedReason {
            if lock == ProtectList.message { return "On your protect list" }
            return lock.hasPrefix("Active project") ? "Projects you're working on" : "In use right now"
        }
        if f.action == .none { return "Managed by its own app" }
        return "Other"
    }
}

/// Harmless Optimize tasks that run with the sweep.
struct TuneUps: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TUNE-UPS THAT RUN TOO").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(model.smartTasks) { t in
                let on = model.smartTaskPicked.contains(t.id)
                HStack(spacing: 12) {
                    Tick(on: on, color: Depot.go) { if on { model.smartTaskPicked.remove(t.id) } else { model.smartTaskPicked.insert(t.id) } }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).foregroundStyle(Depot.ink)
                        Text(t.detail).font(.caption).foregroundStyle(Depot.ink2).lineLimit(1)
                    }
                    Spacer()
                    Text(t.fixLabel).font(.caption).foregroundStyle(Depot.ink3)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
            Rectangle().fill(Depot.line).frame(height: 1).padding(.top, 6)
        }
    }
}

/// A group inside a bin. The whole row opens it; the tick on the left ticks every item in it that can be ticked.
/// Inside, an app's or a project's items sit together under its name.
struct GroupBlock: View {
    @Environment(AppModel.self) var model
    let title: String
    let symbol: String
    let note: String
    let items: [Finding]
    let bin: Bin
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let tickable = items.filter { bin != .stays || model.unlocked.contains($0.id) }
        let lockable = items.filter(model.canUnlock)
        let on = tickable.filter { model.smartPicked.contains($0.id) }.count
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !tickable.isEmpty {
                    Tick(on: on == tickable.count, mixed: on > 0, color: bin == .stays ? Depot.choice : bin.color) {
                        let all = on != tickable.count
                        for f in tickable { if all { model.smartPicked.insert(f.id) } else { model.smartPicked.remove(f.id) } }
                    }
                } else if bin == .stays {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Depot.ink3).frame(width: 18)
                }
                Button { toggle() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(bin.color).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.body.weight(.semibold)).foregroundStyle(Depot.ink)
                            Text((!tickable.isEmpty && on != tickable.count ? "\(on) of \(items.count) ticked" : "\(items.count) item\(items.count == 1 ? "" : "s")")
                                 + (note.isEmpty ? "" : " · \(note)"))
                                .font(.caption).foregroundStyle(Depot.ink2).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Depot.ink)
                        Chevron(open: isOpen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(items.count) items")
                .accessibilityHint(isOpen ? "Collapse" : "Expand")
                if lockable.count > 1 { UnlockButton(items: lockable, label: "Unlock all") }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Rectangle().fill(Depot.line).frame(height: 1)
        }
    }

    /// Items of one app or project together, biggest first.
    static func ownerGroups(_ items: [Finding]) -> [(String, [Finding])] {
        let d = Dictionary(grouping: items) { ($0.owner ?? $0.title).lowercased() }
        return d.map { _, v in (v.compactMap(\.owner).first ?? v[0].title, v.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }
}

/// One entry of the flat Sweep review list.
struct SweepRow: Identifiable {
    enum Kind {
        case group(BinPanel.Shelf)
        case owner(String, [Finding])
        case item(Finding, nested: Bool)
        case more(Int)
    }
    let id: String
    let kind: Kind
    var last = false

    static func rows(_ groups: [BinPanel.Shelf], bin: Bin, open: Set<String>) -> [SweepRow] {
        var out: [SweepRow] = []
        for g in groups {
            let key = "\(bin.rawValue)/\(g.key)"
            out.append(SweepRow(id: key, kind: .group(g)))
            guard open.contains(key) else { continue }
            for (name, items) in GroupBlock.ownerGroups(Array(g.items.prefix(300))) {
                if items.count > 1 {
                    out.append(SweepRow(id: "\(key)/o/\(name)", kind: .owner(name, items)))
                    out += items.map { SweepRow(id: "\(key)/n/\($0.id)", kind: .item($0, nested: true)) }
                } else {
                    out.append(SweepRow(id: "\(key)/i/\(items[0].id)", kind: .item(items[0], nested: false)))
                }
            }
            if g.items.count > 300 { out.append(SweepRow(id: "\(key)/more", kind: .more(g.items.count - 300))) }
        }
        if !out.isEmpty { out[out.count - 1].last = true }
        return out
    }
}

struct SweepRowView: View {
    let row: SweepRow
    let bin: Bin
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let bottom: CGFloat = row.last ? 16 : 0
        Group {
            switch row.kind {
            case .group(let g):
                GroupBlock(title: g.title, symbol: g.symbol, note: g.note, items: g.items, bin: bin, isOpen: open, toggle: toggle)
            case .owner(let name, let items):
                OwnerHeader(name: name, items: items, bin: bin).background(Depot.floor.opacity(0.35))
            case .item(let f, let nested):
                ItemRow(finding: f, bin: bin, nested: nested, showPath: nested).background(Depot.floor.opacity(0.35))
            case .more(let n):
                Text("…and \(n) more. See them all in Cleanup.").font(.caption).foregroundStyle(Depot.ink2).padding(10)
                    .frame(maxWidth: .infinity).background(Depot.floor.opacity(0.35))
            }
        }
        .background(Depot.bay)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, style: .continuous))
    }
}

/// The name of an app or project whose items follow, indented beneath it.
struct OwnerHeader: View {
    @Environment(AppModel.self) var model
    let name: String
    let items: [Finding]
    let bin: Bin

    var body: some View {
        let lockable = items.filter(model.canUnlock)
        HStack(spacing: 10) {
            // One tick for the whole app or project; a mixed tick when only some of it is ticked.
            let tickable = items.filter { bin != .stays || model.unlocked.contains($0.id) }
            let picked = tickable.filter { model.smartPicked.contains($0.id) }.count
            if tickable.isEmpty {
                Image(systemName: items.first?.category == .projects ? "folder.fill" : "app.fill").font(.system(size: 12)).foregroundStyle(Depot.ink3).frame(width: 18)
            } else {
                Tick(on: picked == tickable.count, mixed: picked > 0 && picked < tickable.count, color: bin.color) {
                    let ids = tickable.map(\.id)
                    if picked == tickable.count { model.smartPicked.subtract(ids) } else { model.smartPicked.formUnion(ids) }
                }
                .frame(width: 18)
            }
            Text(name).font(.callout.weight(.semibold)).foregroundStyle(Depot.ink)
            Text("\(items.count)").font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Depot.ink2)
                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Depot.bayHigh))
            Spacer()
            if !lockable.isEmpty { UnlockButton(items: lockable, label: lockable.count == items.count ? "Unlock project" : "Unlock \(lockable.count)") }
            Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(Depot.ink2)
        }
        .padding(.leading, 46).padding(.trailing, 16).padding(.top, 10).padding(.bottom, 4)
    }
}

/// One item: tick (or lock), what it is, where it lives, what happens, Finder and details. Clicking the row ticks it.
struct ItemRow: View {
    @Environment(AppModel.self) var model
    let finding: Finding
    let bin: Bin
    var nested = false
    var showPath = false
    @State private var info = false

    var body: some View {
        let unlocked = model.unlocked.contains(finding.id)
        let tickable = bin != .stays || unlocked
        let on = model.smartPicked.contains(finding.id)
        HStack(spacing: 12) {
            if tickable {
                Tick(on: on, color: unlocked ? Depot.choice : bin.color) { flip(on) }
            } else if model.canUnlock(finding) {
                UnlockButton(items: [finding])
            } else {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Depot.ink3).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(nested ? finding.title.components(separatedBy: " › ").last ?? finding.title : finding.title).foregroundStyle(Depot.ink).lineLimit(1)
                    if unlocked { Text("unlocked").font(.caption2.weight(.bold)).foregroundStyle(Depot.choice) }
                }
                Text(showPath ? "\(finding.path.tildePath)  →  \(Self.outcome(finding))" : Explainer.explain(finding)?.plain ?? "\(finding.path.tildePath)  →  \(Self.outcome(finding))")
                    .font(.caption).foregroundStyle(Depot.ink2).lineLimit(1).truncationMode(showPath ? .middle : .tail)
                if !tickable, let why = model.isActiveLock(finding.lockedReason) ? "Active project, edited \(Format.age(finding.lastModified)). Click the lock to unlock it."
                                                    : finding.lockedReason ?? (finding.action == .none ? finding.rebuild : nil) {
                    Text(why).font(.caption).foregroundStyle(Depot.ink3).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(Format.bytes(finding.bytes)).monospacedDigit().foregroundStyle(Depot.ink)
            Button { model.reveal(finding.path) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).foregroundStyle(Depot.ink2).help("Show in Finder").accessibilityLabel("Show \(finding.title) in Finder")
            Button { info.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(Depot.ink2).help("What it is, what it means for you, and what happens")
                .accessibilityLabel("About \(finding.title)")
                .popover(isPresented: $info, arrowEdge: .trailing) { FindingDetail(finding: finding).frame(width: 420, height: 560) }
        }
        .padding(.leading, nested ? 66 : 46).padding(.trailing, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if tickable { flip(on) } else { info = true } }
        .contextMenu {
            Button("Show in Finder") { model.reveal(finding.path) }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(finding.path, forType: .string) }
            if unlocked { Button("Lock again") { model.relock(finding) } }
            Divider()
            Button("Never clean this") { model.setProtected(finding.path, true) }
        }
    }

    private func flip(_ on: Bool) { if on { model.smartPicked.remove(finding.id) } else { model.smartPicked.insert(finding.id) } }

    /// What Sapu2 does with it, in a few words.
    static func outcome(_ f: Finding) -> String {
        if f.lockedReason != nil || f.action == .none || f.safety == .protected { return "stays" }
        switch f.action {
        case .trash where f.category == .logs: return "old logs to Trash, active ones emptied"
        case .trash, .freezeThenTrash: return "Trash"
        case .command(let c): return "runs \(c)"
        case .truncateLogs: return "emptied in place"
        case .none: return "stays"
        }
    }
}

// MARK: Done

struct SmartDone: View {
    @Environment(AppModel.self) var model
    @State private var shown: Int64 = 0

    private var canUndo: Bool { model.smartResult?.receipt?.items.contains(where: Restorer.canPutBack) ?? false }

    var body: some View {
        let r = model.smartResult
        let moved = r?.receipt?.items.filter { $0.ok && $0.trashedTo != nil }.reduce(Int64(0)) { $0 + $1.bytes } ?? 0
        let cleaned = r?.receipt?.cleanedBytes ?? 0
        let failed = (r?.receipt?.items.filter { !$0.ok }.count ?? 0) + (r?.tasks.filter { !$0.ok }.count ?? 0)
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Burst().frame(width: 520, height: 260)
                    VStack(spacing: 6) {
                        Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 44, weight: .bold)).foregroundStyle(failed == 0 ? Depot.go : Depot.choice)
                        Text(cleaned > 0 ? "Swept \(Format.bytes(shown))" : "All done")
                            .font(Depot.sign(46, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                            .contentTransition(.numericText())
                        Text(moved > 0 ? "It's in the Trash for now. Empty the Trash to get the space back, or put anything back from History."
                                       : "Free space: \(Format.bytes(r?.freeBefore ?? 0)) → \(Format.bytes(r?.freeAfter ?? 0)).")
                            .font(.callout).foregroundStyle(Depot.ink2).multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                }
                .padding(.top, 10)
                HStack(spacing: 10) {
                    Button("Done") { model.smartStep = .start }.buttonStyle(SignButtonStyle(large: false)).keyboardShortcut(.defaultAction)
                    if canUndo { Button("Undo sweep") { model.undoSweep() }.buttonStyle(GhostButtonStyle()).keyboardShortcut("z", modifiers: .command) }
                    if moved > 0 { Button("Empty Trash…") { model.section = .trash }.buttonStyle(GhostButtonStyle()) }
                    Button("Receipt") { model.section = .receipts }.buttonStyle(GhostButtonStyle())
                }
                if let m = model.undoMessage {
                    Text(m).font(.callout).foregroundStyle(Depot.ink2).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                if let items = r?.receipt?.items, !items.isEmpty {
                    resultList("What happened", items.map { ($0.title, $0.ok, $0.message, $0.bytes) })
                }
                if let tasks = r?.tasks, !tasks.isEmpty {
                    resultList("Tune-ups", tasks.map { ($0.title, $0.ok, $0.message, Int64(0)) })
                }
            }
            .frame(maxWidth: 760)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.0)) { shown = cleaned } }
    }

    private func resultList(_ title: String, _ rows: [(String, Bool, String, Int64)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Depot.ink3)
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(Depot.line).frame(height: 1).padding(.leading, 44) }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.1 ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(row.1 ? Depot.go : Depot.choice)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.0).foregroundStyle(Depot.ink)
                            Text(row.2).font(.caption).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if row.3 > 0 { Text(Format.bytes(row.3)).monospacedDigit().foregroundStyle(Depot.ink2) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            .bay()
        }
    }
}

/// Appears when a scan has been quiet for a while. The usual cause is a macOS permission prompt ("Sapu2 would like to
/// access files in your Documents folder") waiting behind the window; the scan resumes as soon as it's answered.
struct StallHint: View {
    @Environment(AppModel.self) var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { t in
            if model.scanning != nil, t.date.timeIntervalSince(model.lastProgressAt) > 8 {
                Label("Still working. If macOS asked whether Sapu2 may read a folder (Desktop, Documents, Downloads), answer it; the dialog can hide behind this window.",
                      systemImage: "hand.raised.fill")
                    .font(.callout).foregroundStyle(Depot.choice).multilineTextAlignment(.leading)
                    .frame(maxWidth: 520).padding(12)
                    .background(Depot.choice.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
