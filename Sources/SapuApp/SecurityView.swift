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
        let issues = model.securityIssues
        let toFix = eol.count + outdated.count + issues.filter { $0.level != .info }.count
        let checked = !v.isEmpty || model.securityChecked != nil
        VStack(spacing: 0) {
            PaneHeader(pane: .security,
                       subtitle: "Leaked keys in your projects, and runtimes that no longer get security fixes.",
                       value: checked ? (toFix == 0 ? "All good" : "\(toFix) to fix") : nil,
                       caption: checked ? "\(model.snapshot.projects.count) projects · \(v.count) runtimes" : nil) {
                Button {
                    Task { await model.refreshVersions(network: true) }
                } label: {
                    if model.checkingVersions { ProgressView().controlSize(.small) } else { Label("Check versions online", systemImage: "arrow.down.circle") }
                }
                .disabled(model.checkingVersions)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    secretsSection(issues)
                    Divider()
                    VStack(alignment: .leading, spacing: 20) {
                        SectionTitle(title: "Runtimes & versions", subtitle: "End-of-life runtimes get no CVE fixes. Patch releases are where the fixes ship.")
                        sourceNote
                        if v.isEmpty {
                            Text(model.checkingVersions ? "Checking…" : "No runtimes found. Sapu looks for PHP (Homebrew, MAMP), Node (nvm), Python (conda), Go and Ruby, plus versions declared in composer.json, package.json, .nvmrc, .python-version and go.mod.")
                                .foregroundStyle(.secondary)
                        }
                        group("Fix now", "End-of-life: these get no security (CVE) fixes any more.", .red, "xmark.shield.fill", eol)
                        group("Update soon", "Supported, but behind the latest patch.", .orange, "exclamationmark.shield.fill", outdated)
                        group("Up to date", "Supported and on the latest patch.", .green, "checkmark.shield.fill", ok)
                        group("Couldn't check", "No support data for these versions.", .gray, "questionmark.circle", unknown)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { if model.securityChecked == nil, !model.snapshot.projects.isEmpty { model.checkSecurity() } }
    }

    @ViewBuilder private func secretsSection(_ issues: [SecurityIssue]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: "Secrets & keys in your projects",
                             subtitle: "Committed .env files and private keys, API tokens written into code, tokens in git remote URLs, installs without a lockfile. Checked on this Mac only; nothing is sent anywhere.")
                Spacer()
                if let name = model.checkingSecurity {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        .frame(maxWidth: 260, alignment: .trailing)
                } else {
                    Button(model.securityChecked == nil ? "Check projects" : "Check again") { model.checkSecurity() }
                        .disabled(model.snapshot.projects.isEmpty)
                }
            }
            if model.snapshot.projects.isEmpty {
                Text("Scan projects first, then Sapu checks each one.").foregroundStyle(.secondary)
                Button("Scan projects") { model.scan([.projects]) }
            } else if model.securityChecked != nil, model.checkingSecurity == nil, issues.isEmpty {
                Label("No leaks found in \(model.snapshot.projects.count) projects.", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
            }
            issueGroup("Leaked", "Anyone who can read the repository can use these. Change the key, not just the file: git history keeps it.", .red, "key.slash", issues.filter { $0.level == .danger })
            issueGroup("About to leak", "Not public yet, but one careless commit away.", .orange, "exclamationmark.triangle.fill", issues.filter { $0.level == .warning })
            issueGroup("Worth a look", "Probably fine, such as throwaway credentials in tests.", .gray, "info.circle", issues.filter { $0.level == .info })
        }
    }

    @ViewBuilder private func issueGroup(_ title: String, _ subtitle: String, _ tint: Color, _ symbol: String, _ items: [SecurityIssue]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol, tint: tint, size: 30)
                    SectionTitle(title: "\(title) · \(items.count)", subtitle: subtitle)
                }
                VStack(spacing: 8) { ForEach(items) { IssueCard(issue: $0, tint: tint) } }
            }
        }
    }

    private var sourceNote: some View {
        HStack(spacing: 8) {
            Image(systemName: model.versionsLive ? "antenna.radiowaves.left.and.right" : "wifi.slash")
            Text(model.versionsLive
                 ? "Live data from endoflife.date (cached 24 h)."
                 : "Offline data: end-of-life dates only. Click Check versions online for the latest patch versions.")
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

/// One leak: what, where, and the exact fix.
struct IssueCard: View {
    @EnvironmentObject var model: AppModel
    let issue: SecurityIssue
    let tint: Color

    var body: some View {
        Card(tint: issue.level == .info ? nil : tint) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.projectName.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(tint).lineLimit(1)
                    Text(kindLabel).font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title).font(.callout.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                    Text(issue.detail).font(.callout).foregroundStyle(.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
                    Label(issue.fix, systemImage: "wrench.adjustable.fill").font(.callout.weight(.medium)).foregroundStyle(tint)
                        .textSelection(.enabled).padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let f = issue.file {
                    Button { model.reveal(issue.projectPath + "/" + f) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("Show in Finder")
                }
            }
        }
    }

    private var kindLabel: String {
        switch issue.kind {
        case "env": "Env file"
        case "key": "Private key"
        case "secret": "Token in code"
        case "remote": "Git remote"
        case "lockfile": "No lockfile"
        default: issue.kind.capitalized
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
