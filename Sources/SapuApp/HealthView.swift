import AppKit
import SapuCore
import SwiftUI

struct HealthView: View {
    @EnvironmentObject var model: AppModel
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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                Text(big).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                ProgressView(value: min(max(value, 0), 1)).tint(warn ? .orange : invert ? .green : .accentColor)
                Text(small).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
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
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .maintenance,
                       value: model.tasks.isEmpty ? nil : "\(model.tasks.filter { $0.status == .attention }.count)",
                       caption: "need attention") {
                Button { model.checkMaintenance() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    .disabled(model.checkingTasks)
            }
            if model.tasks.isEmpty {
                ProgressView("Checking login items, settings files and caches…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        StartupSection()
                        ForEach(model.tasks.sorted { rank($0) < rank($1) }) { t in TaskCard(task: t) }
                        Text("Every file a fix removes goes to the Trash and is listed in Receipts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { if model.tasks.isEmpty { model.checkMaintenance() }; model.loadStartup() }
    }

    private func rank(_ t: MaintenanceTask) -> Int { t.status == .attention ? 0 : t.status == .info ? 1 : 2 }
}

struct TaskCard: View {
    @EnvironmentObject var model: AppModel
    let task: MaintenanceTask

    var body: some View {
        Card(tint: task.status == .attention ? .orange : nil) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.status == .ok ? "checkmark.circle.fill" : task.status == .attention ? "exclamationmark.circle.fill" : "wrench.adjustable")
                    .font(.title3).foregroundStyle(task.status == .ok ? .green : task.status == .attention ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).font(.headline)
                    Text(task.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if case .terminal(let cmd) = task.fix {
                        HStack {
                            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            Button("Copy") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                            }.buttonStyle(.link)
                        }
                    }
                    if let r = model.taskResults[task.id] {
                        Label(r, systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 8)
                if case .run = task.fix {
                    if model.runningTask == task.id { ProgressView().controlSize(.small) } else {
                        Button(task.fixLabel) { model.runTask(task) }.disabled(model.runningTask != nil)
                    }
                }
            }
        }
    }
}

/// Startup items: yours can be turned off and on (launchctl, or brew services for Homebrew), leftovers of removed
/// apps can be removed (Trash, with a receipt), system ones are shown only. Nothing is deleted to turn it off.
struct StartupSection: View {
    @EnvironmentObject var model: AppModel
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
    @EnvironmentObject var model: AppModel
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
                    } else if item.disabled {
                        Button("Turn on") { model.startup(item, .turnOn) }
                    } else {
                        Button("Turn off") { model.startup(item, .turnOff) }.help("Stop it now and keep it off after restarts. The file stays.")
                    }
                }
            }
        }
        .disabled(model.startupBusy != nil && model.startupBusy != item.id)
        .padding(.vertical, 2)
    }
}

/// Developer tools still running long after what started them is gone. Sapu never stops one by itself.
struct DevProcessCard: View {
    @EnvironmentObject var model: AppModel

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
