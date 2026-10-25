import AppKit
import SapuCore
import SwiftUI

/// The folder the Disk map shows, and the sizes measured so far. Sizes are kept while the app runs, so
/// going back is instant; Refresh measures the current folder again.
@MainActor
final class ExplorerModel: ObservableObject {
    let root = NSHomeDirectory()
    @Published private(set) var path = NSHomeDirectory()
    @Published private(set) var entries: [DiskExplorer.Entry] = []
    @Published private(set) var sizes: [String: SizeResult] = [:]
    @Published var selection: String?
    enum Mode: String, CaseIterable { case folders = "Folders", largest = "Largest files" }
    @Published var mode = Mode.folders
    @Published private(set) var largest: [DiskExplorer.LargeFile] = []
    @Published private(set) var searchingLargest = false
    private var largestLoaded = false
    private var started = false
    /// Three folders at a time, in the background, so the Mac stays responsive while ~/Library is measured.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    var total: Int64 { entries.reduce(0) { $0 + (sizes[$1.path]?.bytes ?? 0) } }
    var measured: Int { entries.filter { sizes[$0.path] != nil }.count }
    var measuring: Bool { measured < entries.count }
    var biggest: Int64 { entries.compactMap { sizes[$0.path]?.bytes }.max() ?? 0 }

    /// Biggest first; ones still being measured follow, by name.
    var sorted: [DiskExplorer.Entry] {
        entries.sorted { a, b in
            switch (sizes[a.path]?.bytes, sizes[b.path]?.bytes) {
            case let (x?, y?): x == y ? a.name.localizedStandardCompare(b.name) == .orderedAscending : x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Folders from the home folder down to the current one.
    var crumbs: [String] {
        var out = [path], p = path
        while p != root && p.count > root.count { p = p.parentPath; out.insert(p, at: 0) }
        return out
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        open(root)
    }

    func open(_ p: String) {
        guard p == root || p.hasPrefix(root + "/") else { return }
        queue.cancelAllOperations()
        path = p
        selection = nil
        entries = DiskExplorer.entries(in: p)
        measure()
    }

    func up() { if path != root { open(path.parentPath) } }

    /// Single big files anywhere in your home folder, found once per session (Refresh looks again).
    func findLargest(force: Bool = false) {
        guard !searchingLargest, force || !largestLoaded else { return }
        searchingLargest = true
        let root = root
        Task.detached(priority: .utility) {
            let files = DiskExplorer.largestFiles(under: root)
            await MainActor.run { self.largest = files; self.searchingLargest = false; self.largestLoaded = true }
        }
    }

    /// After a move to the Trash: drop the item, and forget the sizes of the folders that held it.
    func removed(_ p: String) {
        entries.removeAll { $0.path == p }
        sizes[p] = nil
        var q = p.parentPath
        while q.count >= root.count { sizes[q] = nil; if q == root { break }; q = q.parentPath }
        largest.removeAll { $0.path == p || $0.path.hasPrefix(p + "/") }
        if selection == p { selection = nil }
    }

    func refresh() {
        queue.cancelAllOperations()
        for e in entries { sizes[e.path] = nil }
        entries = DiskExplorer.entries(in: path)
        measure()
    }

    private func measure() {
        for e in entries where sizes[e.path] == nil {
            let op = BlockOperation()
            let p = e.path
            op.addExecutionBlock { [weak op, weak self] in
                guard let op, !op.isCancelled else { return }
                let r = DiskSizer.size(p, cancelled: { op.isCancelled })
                guard !op.isCancelled else { return }
                Task { @MainActor in self?.sizes[p] = r }
            }
            queue.addOperation(op)
        }
    }
}

struct DiskMapView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var ex: ExplorerModel
    @State private var trashTarget: (path: String, bytes: Int64)?
    @State private var refusal: String?
    @State private var status: String?

    private var rows: [DiskExplorer.Entry] {
        let q = model.search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? ex.sorted : ex.sorted.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .map, subtitle: ex.mode == .largest ? "Single files of 200 MB or more anywhere in your home folder."
                                                                 : ex.path == ex.root ? nil : ex.path.tildePath,
                       value: ex.mode == .largest ? Format.bytes(ex.largest.reduce(0) { $0 + $1.bytes }) : Format.bytes(ex.total),
                       caption: ex.mode == .largest ? (ex.searchingLargest ? "Searching…" : "\(ex.largest.count) files")
                                                    : ex.measuring ? "Measuring \(ex.measured) of \(ex.entries.count)…" : "\(ex.entries.count) items") {
                HStack(spacing: 8) {
                    Picker("View", selection: $ex.mode) {
                        ForEach(ExplorerModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { ex.up() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(ex.path == ex.root || ex.mode == .largest).keyboardShortcut("[", modifiers: .command)
                        .help("Up one folder (⌘[)")
                    Button { ex.mode == .largest ? ex.findLargest(force: true) : ex.refresh() } label: { Label("Measure again", systemImage: "arrow.clockwise") }
                        .help("Measure again")
                }
                .labelStyle(.iconOnly)
            }
            if ex.mode == .largest {
                largestList
            } else {
                folders
            }
            Text(status ?? "Nothing is removed unless you choose Move to Trash. It goes to the Trash with a receipt, so Receipts can put it back.")
                .font(.caption).foregroundStyle(status == nil ? Color.secondary : Color.blue)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(alignment: .top) { Divider() }
        }
        .onAppear { ex.startIfNeeded() }
        .onChange(of: ex.mode) { _, m in if m == .largest { ex.findLargest() } }
        .onChange(of: ex.selection) { _, p in
            model.focused = p.flatMap { p in model.snapshot.findings.first { $0.path == p && $0.category != .home }?.id }
        }
        .confirmationDialog(trashTarget.map { "Move “\($0.path.lastComponent)” to the Trash?" } ?? "",
                            isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } })) {
            Button("Move to Trash", role: .destructive) { if let t = trashTarget { moveToTrash(t.path, t.bytes) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let t = trashTarget { Text("\(Format.bytes(t.bytes)) at \(t.path.tildePath). It stays in the Trash until you empty it, and Receipts can put it back.") }
        }
        .alert("Sapu won't move this", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(refusal ?? "") }
    }

    /// Checks first, so a refused item explains why instead of asking.
    private func askTrash(_ p: String, _ bytes: Int64) {
        if let why = DiskExplorer.trashRefusal(p, projects: model.snapshot.projects) { refusal = why } else { trashTarget = (p, bytes) }
    }

    private func moveToTrash(_ p: String, _ bytes: Int64) {
        let projects = model.snapshot.projects
        status = "Moving \(p.lastComponent) to the Trash…"
        Task.detached(priority: .userInitiated) {
            let r = DiskExplorer.moveToTrash(p, bytes: bytes, projects: projects)
            await MainActor.run {
                status = r.message
                if r.ok { ex.removed(p) }
                model.receipts = Store.receipts()
            }
        }
    }

    @ViewBuilder private func menu(_ p: String, bytes: Int64) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p, forType: .string)
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { askTrash(p, bytes) }
    }

    @ViewBuilder private var folders: some View {
            breadcrumbs
            Divider()
            if ex.entries.isEmpty {
                EmptyState(symbol: "folder", title: "Empty folder", message: "Nothing here, or macOS didn't let Sapu read it.")
            } else {
                List(selection: $ex.selection) {
                    ForEach(rows) { DiskRow(entry: $0, ex: ex).tag($0.path) }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let p = ids.first { menu(p, bytes: ex.sizes[p]?.bytes ?? 0) }
                } primaryAction: { ids in
                    if let p = ids.first, let e = ex.entries.first(where: { $0.path == p }), e.isFolder, e.sealed == nil { ex.open(p) }
                }
            }
    }

    @ViewBuilder private var largestList: some View {
        if ex.largest.isEmpty {
            if ex.searchingLargest {
                ProgressView("Looking through your home folder for big files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(symbol: "doc", title: "No files of 200 MB or more", message: "Nothing that big outside private folders.")
            }
        } else {
            let top = ex.largest.first?.bytes ?? 1
            List(selection: $ex.selection) {
                ForEach(ex.largest) { f in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").foregroundStyle(Pane.map.tint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.path.lastComponent).lineLimit(1).truncationMode(.middle)
                            Text("\(f.path.parentPath.tildePath)\(f.modified.map { " · changed \(Format.age($0))" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        RelativeBar(value: f.bytes, max: top, color: Pane.map.tint).frame(width: 120)
                        Text(Format.bytes(f.bytes)).font(.body.monospacedDigit().weight(.semibold)).frame(width: 84, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .tag(f.path)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                if let p = ids.first, let f = ex.largest.first(where: { $0.path == p }) { menu(p, bytes: f.bytes) }
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(ex.crumbs.enumerated()), id: \.element) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(i == 0 ? "Home" : p.lastComponent) { ex.open(p) }
                        .buttonStyle(.plain)
                        .font(.callout.weight(p == ex.path ? .semibold : .regular))
                        .foregroundStyle(p == ex.path ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

struct DiskRow: View {
    @EnvironmentObject var model: AppModel
    let entry: DiskExplorer.Entry
    @ObservedObject var ex: ExplorerModel

    /// Sapu's finding for this exact path. The full scan's per-folder records only repeat the name, so they're skipped.
    private var finding: Finding? { model.snapshot.findings.first { $0.path == entry.path && $0.category != .home } }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(entry.sealed != nil ? Color.secondary : entry.isFolder ? Pane.map.tint : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 12)
            if let s = ex.sizes[entry.path] {
                RelativeBar(value: s.bytes, max: ex.biggest, color: Pane.map.tint).frame(width: 120)
                Text(Format.bytes(s.bytes)).font(.body.monospacedDigit().weight(.semibold))
                    .frame(width: 84, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small).frame(width: 216, alignment: .trailing)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).opacity(entry.isFolder && entry.sealed == nil ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        if entry.sealed != nil { return "lock.fill" }
        if entry.isLink { return "arrow.turn.up.right" }
        if entry.isFolder { return "folder.fill" }
        return DiskSizer.isDirectory(entry.path) ? "shippingbox.fill" : "doc"
    }

    @ViewBuilder private var detail: some View {
        if let f = finding {
            HStack(spacing: 6) {
                SafetyBadge(safety: f.safety)
                Text(f.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let why = entry.sealed {
            Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if entry.isLink {
            Text("Link. Sapu doesn't follow it.").font(.caption).foregroundStyle(.secondary)
        } else if entry.isFolder, case let c = DiskExplorer.cleanable(under: entry.path, in: model.snapshot.findings), c > 0 {
            Text("\(Format.bytes(c)) inside Sapu can clean").font(.caption).foregroundStyle(.green)
        }
    }
}
