import SapuCore
import SwiftUI

struct SecurityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Security & versions").font(.title2.weight(.semibold))
                    Text("Runtimes installed on this Mac and versions your projects require, checked against endoflife.date. End-of-life lines get no CVE fixes; patch releases are where security fixes ship.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(model.versionsLive ? "Live data (cached 24 h)" : "Offline data: end-of-life dates only. Check online for latest patch versions.")
                        .font(.caption).foregroundStyle(model.versionsLive ? .green : .orange)
                }
                Spacer()
                Button {
                    Task { await model.refreshVersions(network: true) }
                } label: {
                    if model.checkingVersions { ProgressView().controlSize(.small) } else { Label("Check online", systemImage: "arrow.down.circle") }
                }
                .disabled(model.checkingVersions)
            }
            .padding(16)
            Divider()
            if model.versions.isEmpty {
                EmptyState(symbol: "shield", title: model.checkingVersions ? "Checking…" : "No runtimes found",
                           message: "Sapu looks for PHP (Homebrew, MAMP), Node (nvm), Python (conda), Go and Ruby, plus versions declared in composer.json, package.json, .nvmrc, .python-version and go.mod.")
            } else {
                List(model.versions) { v in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(v.level)).foregroundStyle(color(v.level)).font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(v.product) \(v.version)").font(.body.weight(.semibold).monospaced())
                                Text(v.source).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(v.message).font(.callout)
                            if let fix = v.fix { Label(fix, systemImage: "arrow.up.circle").font(.callout.weight(.medium)).foregroundStyle(color(v.level)) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private func icon(_ l: VersionFinding.Level) -> String {
        switch l {
        case .eol: "xmark.shield.fill"
        case .outdated: "exclamationmark.shield.fill"
        case .ok: "checkmark.shield.fill"
        case .unknown: "questionmark.circle"
        }
    }
    private func color(_ l: VersionFinding.Level) -> Color {
        switch l {
        case .eol: .red
        case .outdated: .orange
        case .ok: .green
        case .unknown: .secondary
        }
    }
}

struct ReceiptsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Receipts").font(.title2.weight(.semibold))
                    Text("Every cleanup is recorded with where each item went, so you can put it back from the Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open folder") { model.reveal(Store.receiptsDirectory.path) }
            }
            .padding(16)
            Divider()
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
