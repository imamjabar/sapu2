import SapuCore
import SwiftUI

struct SecurityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let v = model.versions
        let eol = v.filter { $0.level == .eol }
        let outdated = v.filter { $0.level == .outdated }
        let ok = v.filter { $0.level == .ok }
        let unknown = v.filter { $0.level == .unknown }
        VStack(spacing: 0) {
            PaneHeader(pane: .security,
                       value: v.isEmpty ? nil : (eol.count + outdated.count == 0 ? "All good" : "\(eol.count + outdated.count) to fix"),
                       caption: v.isEmpty ? nil : "\(v.count) checked") {
                Button {
                    Task { await model.refreshVersions(network: true) }
                } label: {
                    if model.checkingVersions { ProgressView().controlSize(.small) } else { Label("Check online", systemImage: "arrow.down.circle") }
                }
                .disabled(model.checkingVersions)
            }
            if v.isEmpty {
                EmptyState(symbol: "shield", title: model.checkingVersions ? "Checking…" : "No runtimes found",
                           message: "Sapu looks for PHP (Homebrew, MAMP), Node (nvm), Python (conda), Go and Ruby, plus versions declared in composer.json, package.json, .nvmrc, .python-version and go.mod.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        sourceNote
                        group("Fix now", "End-of-life: these get no security (CVE) fixes any more.", .red, "xmark.shield.fill", eol)
                        group("Update soon", "Supported, but behind the latest patch. Patch releases are where CVE fixes ship.", .orange, "exclamationmark.shield.fill", outdated)
                        group("Up to date", "Supported and on the latest patch.", .green, "checkmark.shield.fill", ok)
                        group("Couldn't check", "No support data for these versions.", .gray, "questionmark.circle", unknown)
                    }
                    .padding(24)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var sourceNote: some View {
        HStack(spacing: 8) {
            Image(systemName: model.versionsLive ? "antenna.radiowaves.left.and.right" : "wifi.slash")
            Text(model.versionsLive
                 ? "Live data from endoflife.date (cached 24 h)."
                 : "Offline data: end-of-life dates only. Click Check online for the latest patch versions.")
        }
        .font(.callout)
        .foregroundStyle(model.versionsLive ? .green : .orange)
    }

    @ViewBuilder
    private func group(_ title: String, _ subtitle: String, _ tint: Color, _ symbol: String, _ items: [VersionFinding]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol, tint: tint, size: 30)
                    SectionTitle(title: "\(title) · \(items.count)", subtitle: subtitle)
                }
                VStack(spacing: 8) {
                    ForEach(items) { VersionCard(finding: $0, tint: tint) }
                }
            }
        }
    }
}

struct VersionCard: View {
    let finding: VersionFinding
    let tint: Color

    var body: some View {
        Card(tint: finding.level == .ok ? nil : tint) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.product.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(tint)
                    Text(finding.version).font(.system(size: 20, weight: .bold, design: .monospaced))
                }
                .frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.source).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(finding.message).font(.callout).foregroundStyle(.primary.opacity(0.72)).lineLimit(3)
                    if let fix = finding.fix {
                        Label(fix, systemImage: "arrow.up.circle.fill").font(.callout.weight(.medium)).foregroundStyle(tint)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct ReceiptsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .receipts, value: model.receipts.isEmpty ? nil : "\(model.receipts.count)", caption: "cleanups") {
                Button("Open folder") { model.reveal(Store.receiptsDirectory.path) }
            }
            if model.receipts.isEmpty {
                EmptyState(symbol: "list.bullet.clipboard", title: "No cleanups yet", message: "Receipts appear here after you clean something.")
            } else {
                List(model.receipts) { r in
                    DisclosureGroup {
                        ForEach(r.items, id: \.self) { i in
                            HStack(alignment: .top) {
                                Image(systemName: i.ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(i.ok ? .green : .orange)
                                VStack(alignment: .leading) {
                                    Text(i.title)
                                    Text(i.message).font(.caption).foregroundStyle(.secondary)
                                    if let t = i.trashedTo { Text("In Trash: \(t.tildePath)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Text(Format.bytes(i.bytes)).monospacedDigit()
                            }
                        }
                    } label: {
                        HStack {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.body.weight(.medium))
                            Text("\(r.items.count) items").foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.bytes(r.cleanedBytes)).monospacedDigit().font(.body.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
