import AppKit
import SapuCore
import SwiftUI

struct HealthView: View {
    @Environment(AppModel.self) var model
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .health, value: model.health.map { "\($0.score)" }, caption: model.health?.verdict) {
                Button { model.refreshHealth() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            if let h = model.health {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !h.advice.isEmpty {
                            Card(tint: h.score >= 85 ? .green : .orange) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("What to do").font(.headline)
                                    ForEach(h.advice, id: \.self) { a in
                                        Label(a, systemImage: "arrow.right.circle").labelStyle(.titleAndIcon).foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                            Gauge("Memory", value: Double(h.memoryUsed) / Double(max(h.memoryTotal, 1)),
                                  big: Format.bytes(h.memoryUsed), small: "of \(Format.bytes(h.memoryTotal)) · pressure \(h.pressure.rawValue)",
                                  warn: h.pressure != .normal)
                            Gauge("Swap", value: h.swapTotal > 0 ? Double(h.swapUsed) / Double(h.swapTotal) : 0,
                                  big: Format.bytes(h.swapUsed), small: h.swapTotal > 0 ? "of \(Format.bytes(h.swapTotal)) on disk" : "not in use",
                                  warn: h.swapTotal > 0 && Double(h.swapUsed) / Double(h.swapTotal) > 0.5)
                            Gauge("Processor", value: min(1, (h.load.first ?? 0) / Double(max(h.cores, 1))),
                                  big: String(format: "%.1f", h.load.first ?? 0), small: "load on \(h.cores) cores (1 min)",
                                  warn: (h.load.first ?? 0) > Double(h.cores))
                            if let v = h.volume {
                                Gauge("Disk", value: Double(v.total - v.available) / Double(max(v.total, 1)),
                                      big: Format.bytes(v.available), small: "free of \(Format.bytes(v.total))",
                                      warn: Double(v.available) / Double(max(v.total, 1)) < 0.15)
                            }
                            if let b = h.battery {
                                Gauge("Battery", value: Double(b.health ?? 100) / 100, big: "\(b.health.map { "\($0)%" } ?? "—")",
                                      small: "health · \(b.cycles.map { "\($0) cycles" } ?? "") · \(b.percent)%\(b.charging ? " charging" : "")",
                                      warn: (b.health ?? 100) < 80, invert: true)
                            }
                            Gauge("Temperature", value: h.thermal == "Normal" ? 0.2 : h.thermal == "Fair" ? 0.5 : 0.9, big: h.thermal,
                                  small: "up \(uptime(h.uptime))", warn: h.thermal == "Serious" || h.thermal == "Critical")
                        }
                        HStack(alignment: .top, spacing: 14) {
                            ProcessCard(title: "Using the most memory", rows: h.topMemory.map { ($0.name, Format.bytes($0.memory)) })
                            ProcessCard(title: "Using the most processor", rows: h.topCPU.map { ($0.name, "\(Int($0.cpu.rounded()))%") })
                        }
                        DevProcessCard()
                        Text("Helpers are counted with their app. Refreshes every 5 seconds while this page is open.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            } else {
                ProgressView("Reading memory, processor and battery…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.refreshHealth(); model.loadDevProcesses() }
        .onReceive(timer) { _ in model.refreshHealth() }
    }

    private func uptime(_ s: TimeInterval) -> String {
        let h = Int(s) / 3600
        return h >= 48 ? "\(h / 24) days" : h >= 1 ? "\(h) h" : "\(Int(s) / 60) min"
    }
}

struct Gauge: View {
    let title: String
    let value: Double
    let big: String
    let small: String
    var warn = false
    /// For battery: a high value is good.
    var invert = false

    init(_ title: String, value: Double, big: String, small: String, warn: Bool = false, invert: Bool = false) {
        self.title = title; self.value = value; self.big = big; self.small = small; self.warn = warn; self.invert = invert
    }

    private var color: Color { warn ? Depot.choice : invert ? Depot.go : Depot.yours }

    var body: some View {
        VStack(spacing: 12) {
            Ring(value: min(max(value, 0), 1), color: color, lineWidth: 11, size: 120, big: big)
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Depot.choice) }
                    Text(title).font(Depot.sign(15, .bold)).foregroundStyle(Depot.ink)
                }
                Text(small).font(.caption).foregroundStyle(Depot.ink2).multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .bay()
    }
}

struct ProcessCard: View {
    let title: String
    let rows: [(String, String)]
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack {
                        Text(r.0).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(r.1).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct MaintenanceView: View {
    @Environment(AppModel.self) var model
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TuneUpHero(confirming: $confirming)
                if model.tasks.isEmpty {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking login items, settings files and caches…").foregroundStyle(Depot.ink2) }
                        .frame(maxWidth: .infinity).padding(30)
                } else {
                    ForEach(MaintenanceTask.Group.allCases, id: \.self) { g in
                        let tasks = model.tasks.filter { $0.group == g }
                        if !tasks.isEmpty {
                            if g == .quickFix { QuickFixesCard(tasks: tasks) } else { TaskGroupSection(group: g, tasks: tasks.sorted { rank($0) < rank($1) }) }
                        }
                        if g == .launchSpeed { StartupSection() }
                    }
                    ExternalDrivesCard()
                    Text("Every file a fix removes goes to the Trash and is listed in Receipts. Databases and settings are copied to the Trash before they change.")
                        .font(.caption).foregroundStyle(Depot.ink3)
                }
            }
            .frame(maxWidth: 980)
            .padding(.horizontal, 24).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if model.tasks.isEmpty { model.checkMaintenance() }; model.loadStartup(); model.loadDrives() }
        .sheet(isPresented: $confirming) { TuneUpSheet() }
    }

    private func rank(_ t: MaintenanceTask) -> Int { t.status == .attention ? 0 : t.status == .info ? 1 : 2 }
}

/// The one-click tune-up: a dial of how tidy macOS is, and one button that runs only the harmless fixes.
struct TuneUpHero: View {
    @Environment(AppModel.self) var model
    @Binding var confirming: Bool

    var body: some View {
        let all = model.tasks.filter { $0.fix != .none }
        let fine = all.filter { $0.status == .ok }.count
        let ready = model.tuneUpTasks
        HStack(spacing: 28) {
            ZStack {
                if model.tuning != nil { DustFall(colors: [Depot.go, Depot.yours], speed: 1.6).frame(width: 150, height: 150).clipShape(Circle()) }
                Ring(value: all.isEmpty ? 0 : Double(fine) / Double(all.count), color: ready.isEmpty ? Depot.go : Depot.choice, lineWidth: 14, size: 150,
                     big: model.tasks.isEmpty ? "…" : ready.isEmpty ? "Tidy" : "\(ready.count)",
                     small: model.tasks.isEmpty ? "checking" : ready.isEmpty ? "nothing to do" : "ready to run")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Tune up").font(Depot.sign(30, .heavy)).foregroundStyle(Depot.ink)
                Text("One click runs every harmless fix that has something to do: thumbnails and the Open With list rebuilt, idle disk images ejected, old window states, broken lists and leftovers of removed apps moved to the Trash, old tweaks undone. No password, nothing restarted, nothing deleted for good.")
                    .font(.callout).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                // Both buttons always stay on screen and show their progress inside, so focus never jumps away (a button
                // that disappears while focused hands focus to a control far down the page, which scrolls there).
                HStack(spacing: 10) {
                    Button { if model.tuning == nil { confirming = true } } label: {
                        if let t = model.tuning {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Running: \(t)").lineLimit(1) }
                        } else {
                            Label(ready.isEmpty ? "All tidy" : "Tune up \(ready.count)", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(SignButtonStyle(large: false))
                    .disabled(ready.isEmpty && model.tuning == nil)
                    Button { model.checkMaintenance() } label: {
                        if model.checkingTasks {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.checkProgress.total == 0 ? "Checking…" : "Checking \(model.checkProgress.done) of \(model.checkProgress.total)…").monospacedDigit()
                            }
                        } else {
                            Label("Check again", systemImage: "arrow.clockwise")
                        }
                    }
                    .help(model.checkingTasks ? "Checking now; results update when it's done." : "Run every check again")
                }
                if !model.tasks.isEmpty {
                    let left = model.tasks.filter { TuneUpSheet.leftOut($0) != nil }.count
                    HStack(spacing: 14) {
                        Label("\(model.tasks.count) checks", systemImage: "checklist").foregroundStyle(Depot.ink2)
                        Label("\(model.tasks.filter { $0.status == .ok }.count) fine", systemImage: "checkmark.circle.fill").foregroundStyle(Depot.go)
                        Label("\(ready.count) in one click", systemImage: "wand.and.stars").foregroundStyle(ready.isEmpty ? Depot.ink3 : Depot.choice)
                        if left > 0 { Label("\(left) yours to choose below", systemImage: "hand.raised.fill").foregroundStyle(Depot.ink2) }
                    }
                    .font(.caption.weight(.semibold))
                }
                if model.tuning == nil, !model.tuneLog.isEmpty {
                    let bad = model.tuneLog.filter { !$0.ok }.count
                    Label(bad == 0 ? "Done: \(model.tuneLog.count) tune-up\(model.tuneLog.count == 1 ? "" : "s") ran. Anything moved is in the Trash and Receipts."
                                   : "\(model.tuneLog.count - bad) ran, \(bad) couldn't. See the messages below.",
                          systemImage: bad == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(bad == 0 ? Depot.go : Depot.choice)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .bay()
        .padding(.top, 8)
    }
}

/// What a tune-up will do, task by task, before it runs. Untick anything to skip it.
struct TuneUpSheet: View {
    /// Why a task with something to do stays out of the one click, or nil when it is in it (or has nothing to do).
    static func leftOut(_ t: MaintenanceTask) -> String? {
        guard t.status != .ok, !AppModel.smartTaskIDs.contains(t.id) else { return nil }
        switch t.fix {
        case .none: return nil
        case .admin: return "asks for your password"
        case .terminal: return "runs in Terminal"
        case .run:
            if t.id.hasPrefix("repair.") { return nil }  // Quick fixes are for when something is stuck, not upkeep.
            switch t.id {
            case "quarantine": return "clears your download history, so it's your call"
            case "brew", "brewoutdated": return "changes Homebrew packages your projects may use"
            default: return "your call"
            }
        }
    }

    @Environment(AppModel.self) var model
    @Environment(\.dismiss) private var dismiss
    @State private var skip = Set<String>()

    var body: some View {
        let list = model.tuneUpTasks
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").font(.system(size: 18, weight: .bold)).foregroundStyle(Depot.floor)
                    .frame(width: 36, height: 36).background(Circle().fill(Depot.go))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run \(list.count - skip.count) tune-up\(list.count - skip.count == 1 ? "" : "s")?").font(Depot.sign(20, .heavy)).foregroundStyle(Depot.ink)
                    Text("Safe by design: no password, nothing restarted, anything removed goes to the Trash.").font(.callout).foregroundStyle(Depot.ink2)
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { t in
                        let on = !skip.contains(t.id)
                        HStack(alignment: .top, spacing: 12) {
                            Tick(on: on, color: Depot.go) { if on { skip.insert(t.id) } else { skip.remove(t.id) } }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.title).font(.body.weight(.medium)).foregroundStyle(Depot.ink)
                                Text(t.detail).font(.caption).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                                let files = t.paths.filter { $0.hasPrefix("/") }
                                if !files.isEmpty {
                                    Text("Changes \(files.count) item\(files.count == 1 ? "" : "s"): " + files.prefix(3).map(\.tildePath).joined(separator: ", ") + (files.count > 3 ? " …" : ""))
                                        .font(.caption.monospaced()).foregroundStyle(Depot.ink3).lineLimit(2).truncationMode(.middle)
                                }
                            }
                            Spacer()
                            Text(t.fixLabel).font(.caption.weight(.semibold)).foregroundStyle(Depot.ink2)
                        }
                        .padding(12)
                        Hairline(inset: 42)
                    }
                }
                .bay()
            }
            .frame(maxHeight: 340)
            // Everything else Optimize checked, so one click never hides what it looked at.
            let fine = model.tasks.filter { $0.status == .ok }
            let left = model.tasks.compactMap { t in Self.leftOut(t).map { (t, $0) } }
            if !fine.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ALREADY FINE · \(fine.count)").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                    Text(fine.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !left.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOT IN ONE CLICK · \(left.count)").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                    ForEach(left, id: \.0.id) { t, why in
                        (Text(t.title).foregroundStyle(Depot.ink) + Text(" · " + why).foregroundStyle(Depot.ink2)).font(.caption)
                    }
                    Text("Run these from the list below when you want them.").font(.caption).foregroundStyle(Depot.ink3)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button { model.tuneUp(list.filter { !skip.contains($0.id) }); dismiss() } label: { Text("Run tune-up") }
                    .buttonStyle(SignButtonStyle(large: false))
                    .keyboardShortcut(.defaultAction)
                    .disabled(list.count == skip.count)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Depot.floorTop)
    }
}

/// One Optimize section: what it promises, the tasks that need something first, and the healthy ones folded away.
struct TaskGroupSection: View {
    let group: MaintenanceTask.Group
    let tasks: [MaintenanceTask]
    @State private var showOK = false

    var body: some View {
        let open = tasks.filter { $0.status != .ok }, ok = tasks.filter { $0.status == .ok }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: group.symbol).foregroundStyle(.secondary)
                Text(group.rawValue).font(.title3.weight(.semibold))
            }
            .padding(.top, 8)
            Text(group.promise).font(.callout).foregroundStyle(.secondary)
            if !open.isEmpty { GroupedRows(open) }
            if !ok.isEmpty {
                DisclosureGroup(isExpanded: $showOK) {
                    GroupedRows(ok).padding(.top, 6)
                } label: {
                    Label("\(ok.count) already fine", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                }
            }
        }
    }
}

/// The reference's quick repairs: one row each, one Restart button each.
struct QuickFixesCard: View {
    @Environment(AppModel.self) var model
    let tasks: [MaintenanceTask]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: MaintenanceTask.Group.quickFix.symbol).foregroundStyle(.secondary)
                    Text(MaintenanceTask.Group.quickFix.rawValue).font(.headline)
                }
                Text(MaintenanceTask.Group.quickFix.promise).font(.callout).foregroundStyle(.secondary)
                ForEach(tasks) { t in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.body.weight(.medium))
                            Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let r = model.taskResults[t.id] { Label(r, systemImage: "checkmark").font(.caption).foregroundStyle(.green) }
                        }
                        Spacer(minLength: 8)
                        // The button stays (spinner inside) so focus doesn't jump down the page while it runs.
                        Button { if model.runningTask == nil { model.runTask(t) } } label: {
                            if model.runningTask == t.id { ProgressView().controlSize(.small) } else { Text(t.fixLabel) }
                        }
                        .opacity(model.runningTask != nil && model.runningTask != t.id ? 0.45 : 1)
                    }
                }
            }
        }
    }
}

/// Tasks of one section as a single grouped list, rows split by hairlines.
struct GroupedRows: View {
    let tasks: [MaintenanceTask]
    init(_ tasks: [MaintenanceTask]) { self.tasks = tasks }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { i, t in
                if i > 0 { Divider().padding(.leading, 48) }
                TaskCard(task: t, grouped: true)
            }
        }
        .bay()
    }
}

struct TaskCard: View {
    @Environment(AppModel.self) var model
    let task: MaintenanceTask
    var grouped = false

    var body: some View {
        if grouped { content.padding(14) } else { Card(tint: task.status == .attention ? .orange : nil) { content } }
    }

    private var content: some View {
        Group {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.status == .ok ? "checkmark.circle.fill" : task.status == .attention ? "exclamationmark.circle.fill" : "wrench.adjustable")
                    .font(.body).foregroundStyle(task.status == .ok ? .green : task.status == .attention ? .orange : .secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.body.weight(.medium))
                    Text(task.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .admin(let cmd) = task.fix {
                        Label { Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } icon: { Image(systemName: "lock.fill") }
                            .font(.caption).foregroundStyle(.secondary)
                            .help("macOS asks for your administrator password for this one command.")
                    }
                    if case .terminal(let cmd) = task.fix {
                        HStack {
                            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            Button("Copy") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                            }.buttonStyle(.link)
                        }
                    }
                    let files = task.paths.filter { $0.hasPrefix("/") }
                    if !files.isEmpty {
                        DisclosureGroup("Show the \(files.count) item\(files.count == 1 ? "" : "s") it changes") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(files.prefix(40), id: \.self) { p in
                                    HStack {
                                        Text(p.tildePath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                        Spacer()
                                        Button { model.reveal(p) } label: { Image(systemName: "magnifyingglass.circle") }
                                            .buttonStyle(.borderless).help("Show in Finder")
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                    if let r = model.taskResults[task.id] {
                        Label(r, systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 8)
                switch task.fix {
                case .run, .admin:
                    // The button stays (spinner inside) so focus doesn't jump down the page while it runs.
                    Button {
                        if model.runningTask == nil { model.runTask(task) }
                    } label: {
                        if model.runningTask == task.id { ProgressView().controlSize(.small) }
                        else if case .admin = task.fix { Label(task.fixLabel + "…", systemImage: "lock") } else { Text(task.fixLabel) }
                    }
                    .opacity(model.runningTask != nil && model.runningTask != task.id ? 0.45 : 1)
                default: EmptyView()
                }
            }
        }
    }
}

/// Startup items: yours can be turned off and on (launchctl, or brew services for Homebrew), leftovers of removed
/// apps can be removed (Trash, with a receipt), system ones are shown only. Nothing is deleted to turn it off.
struct StartupSection: View {
    @Environment(AppModel.self) var model
    @State private var showSystem = false

    var body: some View {
        let user = model.startup.filter { $0.scope == .user }, system = model.startup.filter { $0.scope == .system }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Startup items").font(.headline)
                        Text("Background helpers that start at login. Turning one off keeps its file, so you can turn it on again.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Login Items Settings…") { NSWorkspace.shared.open(URL(string: Startup.loginItemsSettings)!) }
                        .help("Apps' own login items are switched in System Settings")
                }
                if user.isEmpty { Text("None in your Library.").font(.callout).foregroundStyle(.secondary) }
                ForEach(user) { StartupRow(item: $0) }
                if !system.isEmpty {
                    DisclosureGroup(isExpanded: $showSystem) {
                        ForEach(system) { StartupRow(item: $0) }
                    } label: {
                        Text("\(system.count) system item(s), shown only (outside your home folder, need an administrator)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct StartupRow: View {
    @Environment(AppModel.self) var model
    let item: StartupItem

    private var state: (String, Color) {
        if item.programMissing { return ("Leftover: its program is gone", .orange) }
        if item.scope == .system { return ("System, shown only", .secondary) }
        if item.disabled { return ("Off", .secondary) }
        return item.loaded ? ("On, running", .green) : ("On, starts when needed", .green)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.programMissing ? "exclamationmark.triangle.fill" : item.disabled ? "pause.circle" : "play.circle.fill")
                .foregroundStyle(state.1).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                let title = item.app ?? Startup.brewService(item).map { "\($0) · Homebrew service" } ?? item.label
                Text(title).lineLimit(1)
                Text(title == item.label ? state.0 : "\(state.0) · \(item.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let p = item.program { Text(p.tildePath).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                if let m = model.startupResults[item.id] { Text(m).font(.caption).foregroundStyle(.blue) }
            }
            Spacer(minLength: 8)
            if item.scope == .user {
                if model.startupBusy == item.id { ProgressView().controlSize(.small) } else {
                    if item.programMissing {
                        Button("Remove") { model.startup(item, .remove) }.help("Stop it and move its file to the Trash (Receipts can put it back)")
                    } else {
                        Toggle("", isOn: Binding(get: { !item.disabled }, set: { on in model.startup(item, on ? .turnOn : .turnOff) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .help(item.disabled ? "Off: it won't start at login. Switch on to allow it again."
                                                : "On. Switch off to stop it now and keep it off after restarts; the file stays.")
                    }
                }
            }
        }
        .disabled(model.startupBusy != nil && model.startupBusy != item.id)
        .padding(.vertical, 2)
    }
}

/// Developer tools still running long after what started them is gone. Sapu2 never stops one by itself.
struct DevProcessCard: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Card(tint: model.devProcesses.isEmpty ? nil : .orange) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Forgotten developer processes").font(.headline)
                    Spacer()
                    Button { model.loadDevProcesses() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Look again")
                }
                if model.devProcesses.isEmpty {
                    Text("None. No dev server, runtime or language server has been left running for 12+ hours without what started it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Still running after their terminal or editor closed. Quit asks the program to stop; unsaved work in it is lost.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(model.devProcesses) { p in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.name) · \(Format.bytes(p.memory))").font(.callout.weight(.medium))
                                Text(p.reason).font(.caption).foregroundStyle(.secondary)
                                Text(p.command).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                    .help(p.command)
                                if let m = model.devProcessResults[p.pid] { Text(m).font(.caption).foregroundStyle(.blue) }
                            }
                            Spacer()
                            Button("Quit") { model.quit(p) }.help("Ask process \(p.pid) to stop (never forced)")
                        }
                    }
                }
            }
        }
    }
}

/// Mac bookkeeping files on USB sticks and external drives, removed only when you ask, after a confirmation.
struct ExternalDrivesCard: View {
    @Environment(AppModel.self) var model
    @State private var confirm: ExternalDrives.Drive?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("External drives").font(.headline)
                    Spacer()
                    Button { model.loadDrives() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Look again")
                }
                Text("Finder leaves .DS_Store files on drives, and ._ files on drives formatted for Windows. They show up on other computers. Your files stay.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.drives.isEmpty { Text("No external drive connected.").font(.callout).foregroundStyle(.secondary) }
                ForEach(model.drives, id: \.drive.id) { d, j in
                    HStack(alignment: .top) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(d.name) · \(d.format)")
                            Text(j.count == 0 ? "Nothing to remove." : "\(j.dsStore.count) .DS_Store, \(j.appleDouble.count) ._ files · \(Format.bytes(j.bytes))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let m = model.driveResults[d.id] { Text(m).font(.caption).foregroundStyle(.blue) }
                        }
                        Spacer()
                        if model.driveBusy == d.id { ProgressView().controlSize(.small) }
                        else if j.count > 0 { Button("Clean…") { confirm = d } }
                    }
                }
            }
        }
        .confirmationDialog(confirm.map { "Remove Mac bookkeeping files from \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Remove") { if let d = confirm, let j = model.drives.first(where: { $0.drive.id == d.id })?.junk { model.cleanDrive(d, j) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(".DS_Store files go to the drive's Trash. ._ files are merged back into their files by macOS's dot_clean. Nothing else on the drive changes.")
        }
    }
}
