import Charts
import SapuCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var allInsights = false

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HomeHero()
                KindsGuide()

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Clean up", subtitle: "One card per kind of clutter. Open one to see why each item is there and whether it's safe.")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach([Pane.cleanable, .caches, .artifacts, .logs, .apps, .files]) { CategoryTile(pane: $0) }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Understand & protect")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach([Pane.projects, .security, .map]) { CategoryTile(pane: $0) }
                    }
                }

                if !s.insights.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(title: "Insights", subtitle: "What Sapu noticed on this Mac.")
                            Spacer()
                            if s.insights.count > 6 {
                                Button(allInsights ? "Show fewer" : "Show all \(s.insights.count)") { allInsights.toggle() }.buttonStyle(.link)
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                            ForEach(allInsights ? s.insights : Array(s.insights.prefix(6))) { InsightCard(insight: $0) }
                        }
                    }
                }

                let breakdown = Insights.breakdown(s).filter { $0.1 > 0 }
                if !breakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Where the space goes")
                        Card {
                            Chart(breakdown, id: \.0) { item in
                                BarMark(x: .value("Size", Double(item.1) / 1e9), y: .value("Category", item.0.rawValue))
                                    .foregroundStyle(by: .value("Category", item.0.rawValue))
                                    .cornerRadius(4)
                                    .annotation(position: .trailing) { Text(Format.bytes(item.1)).font(.caption.monospacedDigit()) }
                            }
                            .chartLegend(.hidden)
                            .chartXAxisLabel("GB")
                            .frame(height: CGFloat(breakdown.count) * 30 + 30)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Plain answers to "what is all this?": the four kinds of things Sapu finds, and what each label promises.
struct KindsGuide: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("kindsGuideHidden") private var hidden = false

    private let kinds: [(Pane, String, String, String)] = [
        (.caches, "Caches", "Copies apps and tools keep to go faster: package downloads, browser and IDE caches.", "Rebuilt by themselves"),
        (.artifacts, "Build folders", "What a project installs or compiles: node_modules, .venv, vendor, target, build.", "One command brings them back"),
        (.logs, "Logs", "Diaries apps write for troubleshooting. Running services keep their files.", "Emptied, not needed"),
        (.files, "Your files", "Downloads, documents, app data, virtual machines, models, agent worktrees.", "Never ticked for you"),
    ]

    var body: some View {
        if hidden {
            Button { withAnimation(.easeOut(duration: 0.2)) { hidden = false } } label: {
                Label("What's safe to delete?", systemImage: "questionmark.circle")
            }
            .buttonStyle(.link)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: "What's safe to delete?", subtitle: "Everything Sapu finds is one of four kinds. Projects you touched in the last \(model.activeDays) days are always locked.")
                    Spacer()
                    Button("Hide") { withAnimation(.easeOut(duration: 0.2)) { hidden = true } }.buttonStyle(.link)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(kinds, id: \.1) { k in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                IconTile(symbol: k.0.symbol, tint: k.0.tint, size: 24)
                                Text(k.1).font(.headline)
                            }
                            Text(k.2).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Label(k.3, systemImage: k.1 == "Your files" ? "hand.raised.fill" : "arrow.uturn.backward")
                                .font(.caption.weight(.semibold)).foregroundStyle(k.0.tint)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
                        .background(k.0.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(k.0.tint.opacity(0.16)))
                    }
                }
                HStack(spacing: 14) {
                    ForEach(Safety.allCases, id: \.self) { s in
                        HStack(spacing: 6) {
                            SafetyBadge(safety: s)
                            Text(s.promise).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension Safety {
    /// What the label promises, in a few words.
    var promise: String {
        switch self {
        case .safe: "ticked by Select Safe"
        case .check: "read why first"
        case .yours: "only if you tick it"
        case .protected: "never touched"
        }
    }
}

/// Big disk gauge with the one button most people need.
struct HomeHero: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        let ready = s.findings.filter { Pane.cleanable.includes($0) && model.isSelectable($0) }
        let readyBytes = ready.reduce(0) { $0 + $1.bytes }
        HStack(alignment: .center, spacing: 28) {
            DiskRing(volume: s.volume).frame(width: 170, height: 170)
            VStack(alignment: .leading, spacing: 12) {
                if let v = s.volume {
                    Text("\(Format.bytes(v.free)) free")
                        .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: v.free)
                    Text(status(v)).font(.title3).foregroundStyle(.secondary)
                }
                if let layer = model.scanning {
                    ScanProgressInline(layer: layer)
                } else {
                    HStack(spacing: 12) {
                        Button { model.scan([.quick, .projects]) } label: {
                            Label(s.layerDates.isEmpty ? "Start Smart Scan" : "Smart Scan", systemImage: "sparkle.magnifyingglass")
                                .font(.headline).padding(.horizontal, 18).padding(.vertical, 9)
                        }
                        .buttonStyle(GradientButtonStyle(tint: .indigo))
                        .help("Quick + Projects layers. Light on your Mac; about a minute.")
                        if readyBytes > 0 {
                            Button { model.section = .cleanable } label: {
                                Label("Review \(Format.bytes(readyBytes)) to clean", systemImage: "sparkles")
                                    .font(.headline).padding(.horizontal, 14).padding(.vertical, 9)
                            }
                            .buttonStyle(GradientButtonStyle(tint: .green))
                        }
                    }
                    HStack(spacing: 8) { ForEach(ScanLayer.allCases, id: \.self) { LayerChip(layer: $0) } }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [.indigo.opacity(0.22), .purple.opacity(0.10), .blue.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.indigo.opacity(0.18)))
    }

    private func status(_ v: VolumeInfo) -> String {
        let pct = Int(Double(v.used) / Double(max(v.total, 1)) * 100)
        let mood = pct >= 90 ? "Almost full." : pct >= 80 ? "Getting tight." : "Healthy."
        return "\(pct)% of \(Format.bytes(v.total)) used · \(mood)"
    }
}

struct DiskRing: View {
    let volume: VolumeInfo?
    var body: some View {
        let frac = volume.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0
        let tint: Color = frac > 0.9 ? .red : frac > 0.8 ? .orange : .indigo
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: 18)
            Circle().trim(from: 0, to: frac)
                .stroke(AngularGradient(colors: [tint.opacity(0.6), tint], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(frac * 100))%").font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                Text("used").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(9)
    }
}

/// One clickable card per section on Home.
struct CategoryTile: View {
    @EnvironmentObject var model: AppModel
    let pane: Pane
    @State private var hover = false

    var body: some View {
        Button { model.section = pane } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(symbol: pane.symbol, tint: pane.tint, size: 36)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                Text(pane.title).font(.headline)
                Text(headline).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(headlineColor)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: headline)
                VStack(alignment: .leading, spacing: 3) {
                    if detail.isEmpty {
                        Text(pane.blurb).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        ForEach(detail, id: \.self) { line in
                            Text(line).foregroundStyle(pane.tint.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [pane.tint.opacity(hover ? 0.16 : 0.10), pane.tint.opacity(0.03)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(pane.tint.opacity(hover ? 0.4 : 0.18)))
            .scaleEffect(hover ? 1.01 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(pane.blurb)
    }

    /// The two biggest real items behind the number, so each card shows content, not a description.
    private var detail: [String] {
        let s = model.snapshot
        switch pane {
        case .projects:
            return s.projects.filter { $0.status == .active }.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                .prefix(2).map { "\($0.name) · \(Format.age($0.lastActivity))" }
        case .security:
            let leaks = model.securityIssues.filter { $0.level == .danger }.prefix(2).map { "\($0.projectName) · \($0.title)" }
            return Array((leaks + model.versions.filter { $0.level == .eol }.map { "\($0.product) \($0.version) · \($0.source)" }).prefix(2))
        default:
            return s.findings.filter { pane.includes($0) && $0.action != .none }.sorted { $0.bytes > $1.bytes }
                .prefix(2).map { "\($0.title) · \(Format.bytes($0.bytes))" }
        }
    }

    private var headline: String {
        let s = model.snapshot
        switch pane {
        case .projects:
            let active = s.projects.filter { $0.status == .active }.count
            return s.projects.isEmpty ? "Not scanned" : "\(s.projects.count) · \(active) active"
        case .security:
            let eol = model.versions.filter { $0.level == .eol }.count
            let out = model.versions.filter { $0.level == .outdated }.count
            let leaks = model.securityIssues.filter { $0.level != .info }.count
            if model.versions.isEmpty && model.securityChecked == nil { return "Not checked" }
            return eol + out + leaks == 0 ? "All good" : "\(eol + out + leaks) to fix"
        default:
            let items = s.findings.filter { pane.includes($0) && $0.action != .none }
            if items.isEmpty {
                let need: ScanLayer = [.apps, .files, .map].contains(pane) ? .full : (pane == .artifacts ? .projects : .quick)
                return s.layerDates[need.rawValue] == nil ? "Not scanned" : "Clean"
            }
            return Format.bytes(items.reduce(0) { $0 + $1.bytes })
        }
    }

    private var headlineColor: Color {
        if pane == .security, model.versions.contains(where: { $0.level == .eol }) || model.securityIssues.contains(where: { $0.level == .danger }) { return .red }
        return .primary
    }
}

struct GradientButtonStyle: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: tint.opacity(0.35), radius: 6, y: 3)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Live progress inside the Home hero while a scan runs.
struct ScanProgressInline: View {
    @EnvironmentObject var model: AppModel
    let layer: ScanLayer
    var body: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Scanning: \(layer.name)").font(.headline)
                Spacer()
                Button("Cancel") { model.cancelScan() }.controlSize(.small)
            }
            ProgressView(value: p?.fraction ?? 0).tint(.indigo)
            Text(p.map { "\(Int($0.fraction * 100))% · " + ($0.eta.map { "about \(Format.duration($0)) left" } ?? "estimating…") } ?? "Starting…")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
    }
}

struct InsightCard: View {
    @EnvironmentObject var model: AppModel
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: insight.level.symbol).foregroundStyle(insight.level.color).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.callout.weight(.semibold))
                Text(insight.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let p = insight.relatedPath {
                    Button("Show") {
                        if model.snapshot.findings.contains(where: { $0.path == p }) { model.focused = p } else { model.reveal(p) }
                    }
                    .controlSize(.small).buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(insight.level.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(insight.level.color.opacity(0.2)))
    }
}
