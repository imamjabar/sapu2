import SapuCore
import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Project.ID?
    @State private var filter: ProjectStatus?

    var body: some View {
        let all = model.snapshot.projects
        let q = model.search.lowercased()
        let projects = all.filter { (filter == nil || $0.status == filter) && (q.isEmpty || $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q)) }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Projects").font(.title2.weight(.semibold))
                    Text("Active = edited in the last \(model.activeDays) days. Their build folders are locked so you keep developing fast.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $filter) {
                    Text("All \(all.count)").tag(ProjectStatus?.none)
                    ForEach([ProjectStatus.active, .recent, .stale], id: \.self) { s in
                        Text("\(s.label) \(all.filter { $0.status == s }.count)").tag(ProjectStatus?.some(s))
                    }
                }
                .pickerStyle(.segmented).frame(width: 330)
            }
            .padding(16)
            Divider()
            if all.isEmpty {
                EmptyState(symbol: "folder", title: "No projects yet", message: "Scan projects to find every repo, its build folders, git state and runtime versions.",
                           action: ("Scan projects", { model.scan([.projects]) }))
            } else {
                HSplitView {
                    Table(projects, selection: $selection) {
                        TableColumn("Project") { p in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.body.weight(.medium))
                                Text(p.path.tildePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .width(min: 180, ideal: 260)
                        TableColumn("Status") { p in StatusPill(status: p.status) }.width(70)
                        TableColumn("Last activity") { p in Text(Format.age(p.lastActivity)).monospacedDigit() }.width(100)
                        TableColumn("Stack") { p in Text(p.kinds.joined(separator: ", ")).foregroundStyle(.secondary) }.width(min: 70, ideal: 110)
                        TableColumn("Git") { p in GitText(git: p.git) }.width(min: 80, ideal: 120)
                        TableColumn("Build folders") { p in Text(p.artifactBytes > 0 ? Format.bytes(p.artifactBytes) : "—").monospacedDigit() }.width(90)
                    }
                    .frame(minWidth: 520)
                    if let id = selection, let p = all.first(where: { $0.id == id }) {
                        ProjectDetail(project: p).frame(minWidth: 260, idealWidth: 300)
                    }
                }
            }
        }
    }
}

struct StatusPill: View {
    let status: ProjectStatus
    var body: some View {
        let color: Color = status == .active ? .green : status == .recent ? .orange : .secondary
        Text(status.label).font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

struct GitText: View {
    let git: GitState?
    var body: some View {
        if let g = git {
            if g.dirtyFiles > 0 { Text("\(g.dirtyFiles) uncommitted").foregroundStyle(.orange) }
            else if !g.hasUpstream { Text("no remote").foregroundStyle(.orange) }
            else if g.ahead > 0 { Text("\(g.ahead) unpushed").foregroundStyle(.orange) }
            else { Text("clean").foregroundStyle(.secondary) }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct ProjectDetail: View {
    @EnvironmentObject var model: AppModel
    let project: Project

    var body: some View {
        let artifacts = model.snapshot.findings.filter { $0.category == .projects && $0.path.hasPrefix(project.path + "/") }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(project.name).font(.title3.weight(.semibold))
                HStack { StatusPill(status: project.status); Text(Format.age(project.lastActivity)).foregroundStyle(.secondary) }
                if let g = project.git {
                    Label("\(g.branch ?? "?") · \(g.dirtyFiles) uncommitted · \(g.hasUpstream ? "\(g.ahead) unpushed" : "no upstream")", systemImage: "arrow.triangle.branch")
                        .font(.callout)
                }
                if !project.declared.isEmpty {
                    Text("Declared runtimes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(project.declared.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                        let warn = model.versions.first { $0.source.hasPrefix(project.name + " ·") && $0.source.contains(v) && $0.level == .eol }
                        HStack {
                            Text("\(k): \(v)").font(.callout.monospaced())
                            if warn != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(warn!.message) }
                        }
                    }
                }
                if !artifacts.isEmpty {
                    Text("Build folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                Divider()
                Text("Dependency vulnerabilities").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Runs npm audit / composer audit against the lockfile (needs internet).").font(.caption).foregroundStyle(.secondary)
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
