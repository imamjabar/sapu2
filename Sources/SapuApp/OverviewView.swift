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

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Clean up", subtitle: "Each card is one kind of clutter. Open it to see why it's there and what's safe.")
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
                Text(pane.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
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
            if model.versions.isEmpty { return "Not checked" }
            return eol + out == 0 ? "All good" : "\(eol + out) to fix"
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
        if pane == .security, model.versions.contains(where: { $0.level == .eol }) { return .red }
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
