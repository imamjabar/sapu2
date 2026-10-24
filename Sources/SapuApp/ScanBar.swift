import SapuCore
import SwiftUI

/// Always-visible scan status: which layers are fresh, and live progress with an honest ETA.
struct ScanBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let layer = model.scanning {
                running(layer)
            } else {
                HStack(spacing: 8) {
                    ForEach(ScanLayer.allCases, id: \.self) { LayerChip(layer: $0) }
                    Spacer()
                    if let v = model.snapshot.volume {
                        Text("\(Format.bytes(v.free)) free of \(Format.bytes(v.total))")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private func running(_ layer: ScanLayer) -> some View {
        let p = model.progress
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(layer.name).font(.callout.weight(.semibold))
            if !model.queue.isEmpty {
                Text("then " + model.queue.map(\.short).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p {
                Text(etaText(p)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Cancel") { model.cancelScan() }.controlSize(.small)
        }
        ProgressView(value: p?.fraction ?? 0).progressViewStyle(.linear)
        HStack {
            Text(p?.phase ?? "Starting…").font(.caption)
            Text(p.map { $0.currentPath.tildePath } ?? "").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            if let p, p.bytesSoFar > 0 { Text("\(Format.bytes(p.bytesSoFar)) measured").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
    }

    private func etaText(_ p: ScanProgress) -> String {
        let pct = "\(Int(p.fraction * 100))%"
        guard let eta = p.eta else { return "\(pct) · estimating…" }
        return "\(pct) · about \(Format.duration(eta)) left" + (p.etaFromHistory ? "" : " (first scan, rough)")
    }
}

/// Freshness of one scan layer; click to rescan just that layer.
struct LayerChip: View {
    @EnvironmentObject var model: AppModel
    let layer: ScanLayer

    var body: some View {
        let date = model.snapshot.layerDates[layer.rawValue]
        let took = model.snapshot.layerDurations[layer.rawValue]
        Button { model.scan([layer]) } label: {
            HStack(spacing: 6) {
                Circle().fill(date == nil ? Color.secondary.opacity(0.4) : (Date().timeIntervalSince(date!) < 86_400 ? .green : .orange))
                    .frame(width: 7, height: 7)
                Text(layer.short).font(.callout.weight(.medium))
                Text(date.map { Format.age($0) } ?? "not scanned").font(.caption).foregroundStyle(.secondary)
                if let took { Text("· \(Format.duration(took))").font(.caption).foregroundStyle(.tertiary) }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Rescan only this layer. \(layer.name).")
    }
}

struct SelectionBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            Text("\(model.checked.count) selected · \(Format.bytes(model.checkedBytes))").font(.callout.weight(.medium).monospacedDigit())
            Spacer()
            Button("Clear") { model.checked.removeAll() }
            Button("Review & clean…") { model.reviewing = true }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
