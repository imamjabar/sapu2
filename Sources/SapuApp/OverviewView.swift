import Charts
import SapuCore
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let v = s.volume { DiskCard(volume: v, coverage: Insights.coverage(s)) }
                if s.layerDates.isEmpty && model.scanning == nil {
                    EmptyState(symbol: "sparkles", title: "Welcome to Sapu",
                               message: "Sapu scans in layers so your Mac stays responsive: a quick pass over known caches, then your projects, then an optional full map.",
                               action: ("Start quick scan", { model.scan([.quick, .projects]) }))
                }
                if !s.insights.isEmpty {
                    Text("Insights").font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(s.insights) { InsightCard(insight: $0) }
                    }
                }
                let breakdown = Insights.breakdown(s).filter { $0.1 > 0 }
                if !breakdown.isEmpty {
                    Text("Where the space goes").font(.title3.weight(.semibold))
                    Chart(breakdown, id: \.0) { item in
                        BarMark(x: .value("Size", Double(item.1) / 1e9), y: .value("Category", item.0.rawValue))
                            .foregroundStyle(by: .value("Category", item.0.rawValue))
                            .annotation(position: .trailing) { Text(Format.bytes(item.1)).font(.caption.monospacedDigit()) }
                    }
                    .chartLegend(.hidden)
                    .chartXAxisLabel("GB")
                    .frame(height: CGFloat(breakdown.count) * 30 + 30)
                }
                let top = s.findings.filter { model.isSelectable($0) && $0.safety <= .check }.sorted { $0.bytes > $1.bytes }.prefix(8)
                if !top.isEmpty {
                    HStack {
                        Text("Biggest wins").font(.title3.weight(.semibold))
                        Spacer()
                        Button("See all") { model.section = .cleanable }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(top)) { f in
                            FindingRow(finding: f, maxBytes: top.first?.bytes ?? 1)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture { model.focused = f.id }
                            Divider()
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
    }
}

struct DiskCard: View {
    let volume: VolumeInfo
    let coverage: (accounted: Int64, used: Int64)?

    var body: some View {
        let usedFrac = Double(volume.used) / Double(max(volume.total, 1))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.bytes(volume.free)).font(.system(size: 34, weight: .bold).monospacedDigit())
                Text("free of \(Format.bytes(volume.total))").foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(usedFrac * 100))% used").font(.headline.monospacedDigit())
                    .foregroundStyle(usedFrac > 0.9 ? .red : usedFrac > 0.8 ? .orange : .primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 6).fill(usedFrac > 0.9 ? Color.red : usedFrac > 0.8 ? .orange : .accentColor)
                        .frame(width: geo.size.width * usedFrac)
                }
            }
            .frame(height: 12)
            HStack(spacing: 16) {
                stat("Swap", volume.swapBytes)
                if volume.available > volume.free { stat("Purgeable", volume.available - volume.free) }
                if volume.localSnapshots > 0 { Label("\(volume.localSnapshots) local snapshots", systemImage: "clock.arrow.circlepath").font(.caption) }
                Spacer()
                if let c = coverage {
                    let pct = Int(Double(c.accounted) / Double(max(c.used, 1)) * 100)
                    Text("Scans explain \(Format.bytes(c.accounted)) of \(Format.bytes(c.used)) used (\(min(pct, 100))%). The rest is macOS, other users and Full Disk Access–protected data.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                } else {
                    Text("Run the Full map layer to see where every GB goes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ label: String, _ b: Int64) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Format.bytes(b)).font(.caption.monospacedDigit().weight(.medium))
        }
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
