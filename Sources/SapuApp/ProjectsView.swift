import SapuCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) var model
    @State private var selection: Project.ID?
    @State private var filter: ProjectStatus?

    var body: some View {
        let all = model.snapshot.projects
        let q = model.search.lowercased()
        let projects = all.filter { (filter == nil || $0.status == filter) && (q.isEmpty || $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)) }
        let biggest = max(projects.map(\.artifactBytes).max() ?? 1, 1)
        VStack(spacing: 0) {
            PaneHeader(pane: .projects,
                       subtitle: "Active = edited in the last \(model.activeDays) days. Their build folders are locked so you keep developing fast.",
                       value: all.isEmpty ? nil : "\(all.filter { $0.status == .active }.count) active",
                       caption: all.isEmpty ? nil : "of \(all.count) projects")
            if all.isEmpty {
                EmptyState(symbol: "folder", title: "No projects yet", message: "Scan projects to find every repo, its build folders, git state and runtime versions.",
                           action: ("Scan projects", { model.scan([.projects]) }))
            } else {
                HStack(spacing: 8) {
                    FilterChip(title: "All", count: all.count, color: Depot.ink2, on: filter == nil) { filter = nil }
                    ForEach([ProjectStatus.active, .recent, .stale], id: \.self) { s in
                        FilterChip(title: s.label, count: all.filter { $0.status == s }.count, color: StatusPill.color(s), on: filter == s) { filter = filter == s ? nil : s }
                    }
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.bottom, 12)
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        ProjectColumns { Text("PROJECT") } status: { Text("STATUS") } activity: { Text("LAST EDIT") } stack: { Text("STACK") }
                            git: { Text("GIT") } size: { Text("BUILD FOLDERS") }
                            .font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        Rectangle().fill(Depot.line).frame(height: 1)
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(projects) { p in
                                    ProjectRow(project: p, biggest: biggest, selected: selection == p.id) {
                                        withAnimation(.easeOut(duration: 0.18)) { selection = selection == p.id ? nil : p.id }
                                    }
                                }
                                if projects.isEmpty {
                                    Text("No project matches.").font(.callout).foregroundStyle(Depot.ink2).padding(30)
                                }
                            }
                        }
                    }
                    .bay()
                    .frame(minWidth: 560)
                    if let id = selection, let p = all.first(where: { $0.id == id }) {
                        ProjectDetail(project: p, close: { withAnimation(.easeOut(duration: 0.18)) { selection = nil } })
                            .frame(width: 330)
                            .bay()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 18)
            }
        }
    }
}

/// One column layout shared by the header and every row, so they line up.
struct ProjectColumns<A: View, B: View, C: View, D: View, E: View, F: View>: View {
    @ViewBuilder let name: A
    @ViewBuilder let status: B
    @ViewBuilder let activity: C
    @ViewBuilder let stack: D
    @ViewBuilder let git: E
    @ViewBuilder let size: F
    var body: some View {
        HStack(spacing: 14) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            status.frame(width: 120, alignment: .leading)
            activity.frame(width: 96, alignment: .leading)
            stack.frame(width: 120, alignment: .leading)
            git.frame(width: 120, alignment: .leading)
            size.frame(width: 150, alignment: .trailing)
        }
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let color: Color
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.callout.weight(.semibold))
                Text("\(count)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(on ? Depot.floor.opacity(0.7) : Depot.ink3)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(on ? Depot.floor : Depot.ink)
            .background(on ? Depot.ink : Depot.bay, in: Capsule())
            .overlay(Capsule().strokeBorder(Depot.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct ProjectRow: View {
    let project: Project
    let biggest: Int64
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let p = project
        Button(action: action) {
            ProjectColumns {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.body.weight(.semibold)).foregroundStyle(Depot.ink).lineLimit(1)
                    Text(p.path.tildePath).font(.caption).foregroundStyle(Depot.ink3).lineLimit(1).truncationMode(.middle)
                }
            } status: {
                StatusPill(status: p.status, uncommitted: p.keptForUncommittedWork)
            } activity: {
                Text(Format.age(p.lastActivity)).font(.callout.monospacedDigit()).foregroundStyle(Depot.ink2)
            } stack: {
                Text(p.kinds.isEmpty ? "—" : p.kinds.joined(separator: ", ")).font(.callout).foregroundStyle(Depot.ink2).lineLimit(1)
            } git: {
                GitText(git: p.git).font(.callout).lineLimit(1)
            } size: {
                HStack(spacing: 10) {
                    Capsule().fill(Depot.line).frame(width: 56, height: 4)
                        .overlay(alignment: .leading) {
                            Capsule().fill(StatusPill.color(p.status)).frame(width: max(2, 56 * CGFloat(Double(p.artifactBytes) / Double(biggest))), height: 4)
                        }
                        .opacity(p.artifactBytes > 0 ? 1 : 0)
                    Text(p.artifactBytes > 0 ? Format.bytes(p.artifactBytes) : "—").font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(p.artifactBytes > 0 ? Depot.ink : Depot.ink3).frame(width: 76, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(selected ? Depot.bayHigh : hover ? Depot.bayHigh.opacity(0.5) : .clear)
            .overlay(alignment: .leading) { if selected { Rectangle().fill(StatusPill.color(p.status)).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(p.name), \(p.status.label), last edited \(Format.age(p.lastActivity))")
    }
}

struct StatusPill: View {
    /// Active projects are yours (locked), recent ones are a judgement call, idle ones can be swept.
    static func color(_ s: ProjectStatus) -> Color { s == .active ? Depot.yours : s == .recent ? Depot.choice : Depot.stays }
    let status: ProjectStatus
    var uncommitted = false
    var body: some View {
        let color = Self.color(status)
        Text(uncommitted ? "Uncommitted work" : status.label).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

struct GitText: View {
    let git: GitState?
    var body: some View {
        if let g = git {
            if g.dirtyFiles > 0 { Text("\(g.dirtyFiles) uncommitted").foregroundStyle(Depot.choice) }
            else if !g.hasUpstream { Text("no remote").foregroundStyle(Depot.choice) }
            else if g.ahead > 0 { Text("\(g.ahead) unpushed").foregroundStyle(Depot.choice) }
            else { Text("clean").foregroundStyle(Depot.ink2) }
        } else {
            Text("—").foregroundStyle(Depot.ink3)
        }
    }
}

struct ProjectDetail: View {
    @Environment(AppModel.self) var model
    let project: Project
    var close: (() -> Void)? = nil

    var body: some View {
        let artifacts = model.snapshot.findings.filter { $0.category == .projects && $0.path.hasPrefix(project.path + "/") }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(project.name).font(Depot.sign(22, .heavy)).foregroundStyle(Depot.ink).lineLimit(2)
                    Spacer()
                    if let close {
                        Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(Depot.ink3) }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close details")
                    }
                }
                HStack { StatusPill(status: project.status, uncommitted: project.keptForUncommittedWork); Text("edited " + Format.age(project.lastActivity)).foregroundStyle(Depot.ink2) }
                if let g = project.git {
                    Label("\(g.branch ?? "?") · \(g.dirtyFiles) uncommitted · \(g.hasUpstream ? "\(g.ahead) unpushed" : "no upstream")", systemImage: "arrow.triangle.branch")
                        .font(.callout)
                }
                if !project.declared.isEmpty {
                    Text("Declared runtimes").font(.caption.weight(.semibold)).foregroundStyle(Depot.ink2)
                    ForEach(project.declared.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        let warn = model.versions.first { $0.source.hasPrefix(project.name + " ·") && $0.source.contains(v) && $0.level == .eol }
                        HStack {
                            Text("\(k): \(v)").font(.callout.monospaced())
                            if let warn { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Depot.alert).help(warn.message) }
                        }
                    }
                }
                if !artifacts.isEmpty {
                    HStack {
                        Text("Build folders").font(.caption.weight(.semibold)).foregroundStyle(Depot.ink2)
                        Spacer()
                        let locked = artifacts.filter { model.canUnlock($0) }
                        if !locked.isEmpty { UnlockButton(items: locked, label: locked.count == artifacts.count ? "Unlock project" : "Unlock \(locked.count)") }
                    }
                    ForEach(artifacts) { f in
                        HStack {
                            Text(f.path.lastComponent).font(.callout.monospaced())
                            Spacer()
                            Text(Format.bytes(f.bytes)).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.focused = f.id }
                    }
                }
                Hairline()
                let issues = model.securityIssues.filter { $0.projectPath == project.path }
                HStack {
                    Text("Secrets & keys").font(.caption.weight(.semibold)).foregroundStyle(Depot.ink2)
                    Spacer()
                    if model.checkingSecurity != nil { ProgressView().controlSize(.mini) } else {
                        Button("Check") { model.checkSecurity(only: project) }.controlSize(.small)
                    }
                }
                if issues.isEmpty {
                    Text(model.securityChecked == nil ? "Not checked yet. Offline: committed .env files, keys, tokens in code." : "No leaks found.")
                        .font(.caption).foregroundStyle(Depot.ink2)
                }
                ForEach(issues) { i in
                    Label { Text(i.title).font(.callout).help(i.fix) } icon: {
                        Image(systemName: i.level == .danger ? "key.slash" : i.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(i.level == .danger ? Depot.alert : i.level == .warning ? Depot.choice : Depot.ink2)
                    }
                }
                Hairline()
                Text("Dependency vulnerabilities").font(.caption.weight(.semibold)).foregroundStyle(Depot.ink2)
                Text("Runs the ecosystem's own audit against the lockfile: npm, pnpm, composer, plus cargo-audit, pip-audit and osv-scanner when installed. Needs internet.").font(.caption).foregroundStyle(Depot.ink2)
                Button("Run audit") { model.audit(project: project) }.disabled(model.audits[project.path] == "Running…")
                if let out = model.audits[project.path] { Text(out).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("Reveal in Finder") { model.reveal(project.path) }
                }
            }
            .padding(16)
        }
    }
}
