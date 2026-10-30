import AppKit
import SapuCore
import SwiftUI

/// The folder the Disk map shows, and the sizes measured so far. It starts at the top of the startup disk, so
/// everything on it is mapped: your home, apps, Homebrew, macOS, and macOS's own volumes beside it. It only ever
/// measures; nothing outside your home folder can be moved.
///
/// Both tabs share one walk of the disk. Each folder is walked once: the walk keeps the size of every folder it passes
/// through (4 MB and up) and every file of 200 MB or more in your home, so opening a folder shows sizes at once and
/// Largest files reads what the walk already found. A folder that has a walk of its own is stepped around by walks of
/// the folders above it, which add its size when it's done. Leaving a folder doesn't stop its walks: what they find is
/// what the next folder you open shows.
@MainActor
final class ExplorerModel: ObservableObject {
    let root = "/"
    let home = NSHomeDirectory()
    @Published private(set) var path = "/"
    @Published private(set) var entries: [DiskExplorer.Entry] = []
    @Published private(set) var sizes: [String: SizeResult] = [:]
    @Published var selection: String?
    enum Mode: String, CaseIterable { case folders = "Folders", largest = "Largest files" }
    @Published var mode = Mode.folders
    @Published private(set) var largest: [DiskExplorer.LargeFile] = []
    private var started = false
    /// macOS's own volumes (update space, Recovery, swap), read once from diskutil.
    private var volumes: [(entry: DiskExplorer.Entry, bytes: Int64)] = []

    nonisolated static let bigFile: Int64 = 200_000_000
    nonisolated static let keepFolder: Int64 = 4_000_000

    /// Three walks at a time, in the background, so the Mac stays responsive. The open folder's walks go first.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    /// Walks queued or running, by folder.
    private var ops: [String: Operation] = [:]
    /// Folders with a walk of their own (queued, running or done). Walks of folders above them step around them.
    private let claimed = Locked(Set<String>())
    /// Sizes of folders a walk passed through, ready for when you open their parent.
    private let known = Locked([String: SizeResult]())
    /// Files of 200 MB or more the walks met in your home folder.
    private let bigFiles = Locked([String: DiskExplorer.LargeFile]())
    private var bigSeen = 0
    /// Finished walks still waiting for folders they stepped around.
    private var waiting: [String: (result: SizeResult, borrowed: [String])] = [:]
    /// Bumped when everything is measured again, so late answers from stopped walks are dropped.
    private var generation = 0

    /// When a size last arrived; a long silence while measuring usually means macOS is asking for permission.
    @Published private(set) var lastProgressAt = Date()

    var total: Int64 { entries.reduce(0) { $0 + (sizes[$1.path]?.bytes ?? 0) } }
    /// Finished items plus what the running ones hold so far: the one figure every total on screen shows.
    var totalSoFar: Int64 { total + runningHere.values.reduce(0) { $0 + $1.bytes } }
    var measured: Int { entries.filter { sizes[$0.path] != nil }.count }
    var measuring: Bool { measured < entries.count }
    var biggest: Int64 { entries.compactMap { sizes[$0.path]?.bytes }.max() ?? 0 }
    /// Items macOS wouldn't let Sapu2 read in full here.
    var denied: Int { entries.filter { sizes[$0.path]?.denied == true }.count }

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

    /// Folders from the top of the disk down to the current one.
    var crumbs: [String] {
        var out = [path], p = path
        while p != root && p.count > 1 { p = p.parentPath; out.insert(p, at: 0) }
        return out
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        open(root)
    }

    func open(_ p: String) {
        guard p.hasPrefix("/") else { return }
        path = p
        selection = nil
        lastProgressAt = Date()
        entries = listing(p)
        measure()
    }

    /// A folder's items. At the top of the disk: no links (etc, tmp, var point into private), plus macOS's volumes.
    private func listing(_ p: String) -> [DiskExplorer.Entry] {
        guard p == root else { return DiskExplorer.entries(in: p) }
        if volumes.isEmpty { volumes = DiskExplorer.systemVolumes() }
        for v in volumes { sizes[v.entry.path] = SizeResult(bytes: v.bytes) }
        return DiskExplorer.entries(in: p).filter { !$0.isLink } + volumes.map(\.entry)
    }

    func up() { if path != root { open(path.parentPath) } }

    /// Measures the open folder again: its items, and the folders above it whose sizes included them.
    func refresh() {
        if path == root {
            volumes = []
            reset()
        } else {
            for e in entries { forget(e.path) }
        }
        entries = listing(path)
        measure()
    }

    /// After Full Disk Access is turned on: forget every size and measure again, so protected folders count.
    func remeasureAll() {
        guard started else { return }
        reset()
        open(path)
    }

    /// After a move to the Trash: drop the item, and forget the sizes of the folders that held it.
    func removed(_ p: String) {
        entries.removeAll { $0.path == p }
        forget(p)
        largest.removeAll { $0.path == p || $0.path.hasPrefix(p + "/") }
        if selection == p { selection = nil }
    }

    // MARK: Walks

    private func measure() {
        measureStarted = Date()
        refreshDisk()
        let here = Set(entries.map(\.path))
        // Walks for folders you left keep going, behind the ones for this folder.
        for (p, op) in ops where !here.contains(p) { op.queuePriority = .low }
        let k = known.value
        for e in entries where sizes[e.path] == nil {
            if let s = k[e.path] {
                // An earlier walk already went through it.
                sizes[e.path] = s
                claimed.mutate { _ = $0.insert(e.path) }
            } else {
                walk(e.path, urgent: true)
            }
        }
        startPump()
    }

    /// Measures `p` once. Walks of the folders above it step around it and add its size when it's done.
    private func walk(_ p: String, urgent: Bool) {
        if let op = ops[p] { if urgent { op.queuePriority = .veryHigh }; return }
        guard sizes[p] == nil, waiting[p] == nil else { return }
        claimed.mutate { _ = $0.insert(p) }
        if coversHome(p), !homeDone, searchStarted == nil || searchFinished != nil { searchStarted = Date(); searchFinished = nil }
        let gen = generation, live = liveSizes, known = known, big = bigFiles, claimed = claimed, home = home
        let op = BlockOperation()
        op.queuePriority = urgent ? .veryHigh : .normal
        op.addExecutionBlock { [weak op, weak self] in
            guard let op, !op.isCancelled else { return }
            live.mutate { $0[p] = (0, 0) }
            let borrowed = Locked([String]())
            let r = DiskSizer.size(
                p, cancelled: { op.isCancelled },
                progress: { b, n in live.mutate { $0[p] = (b, n) } },
                largeFile: { f, b, t in
                    guard f.hasPrefix(home + "/") else { return }
                    big.mutate { $0[f] = DiskExplorer.LargeFile(path: f, bytes: b, modified: t > 0 ? Date(timeIntervalSince1970: t) : nil) }
                },
                largeThreshold: Self.bigFile,
                skipDir: { d in
                    guard claimed.value.contains(d) else { return false }
                    borrowed.mutate { $0.append(d) }
                    return true
                },
                onDir: { d, s in known.mutate { $0[d] = s } },
                dirThreshold: Self.keepFolder)
            guard !op.isCancelled else { return }
            let lent = borrowed.value
            Task { @MainActor in self?.walked(p, r, borrowed: lent, gen: gen) }
        }
        ops[p] = op
        queue.addOperation(op)
    }

    private func walked(_ p: String, _ r: SizeResult, borrowed: [String], gen: Int) {
        guard gen == generation, ops[p] != nil else { return }
        ops[p] = nil
        waiting[p] = (r, borrowed)
        settle()
    }

    /// Finishes every walk whose stepped-around folders all have sizes now; one finishing can let others finish.
    private func settle() {
        var changed = true
        while changed {
            changed = false
            for (p, w) in waiting where w.borrowed.allSatisfy({ sizes[$0] != nil }) {
                var s = w.result
                for d in w.borrowed {
                    // Gone (moved to the Trash) or measured again since: the walk above it is measured again too.
                    guard let b = sizes[d] else { continue }
                    s.bytes += b.bytes; s.files += b.files; s.newest = max(s.newest, b.newest); s.denied = s.denied || b.denied
                }
                waiting[p] = nil
                sizes[p] = s
                liveSizes.mutate { $0[p] = nil }
                changed = true
            }
        }
        lastProgressAt = Date()
        if homeDone, searchStarted != nil, searchFinished == nil { searchFinished = Date() }
        if !measuring { refreshDisk() }
    }

    /// Forgets `p`, everything inside it and every folder above it (their sizes included it), and stops those walks.
    private func forget(_ p: String) {
        func hit(_ x: String) -> Bool { x == p || x.hasPrefix(p + "/") || p.hasPrefix(x == "/" ? "/" : x + "/") }
        for (x, op) in ops where hit(x) { op.cancel(); ops[x] = nil }
        sizes = sizes.filter { !hit($0.key) }
        waiting = waiting.filter { !hit($0.key) }
        claimed.mutate { $0 = $0.filter { !hit($0) } }
        known.mutate { $0 = $0.filter { !hit($0.key) } }
        liveSizes.mutate { $0 = $0.filter { !hit($0.key) } }
        bigFiles.mutate { $0 = $0.filter { $0.key != p && !$0.key.hasPrefix(p + "/") } }
        bigSeen = -1
    }

    /// Forgets everything and stops every walk.
    private func reset() {
        generation += 1
        queue.cancelAllOperations()
        ops = [:]; waiting = [:]; running = [:]
        sizes = sizes.filter { $0.key.hasPrefix("volume:") }
        claimed.mutate { $0 = [] }
        known.mutate { $0 = [:] }
        liveSizes.mutate { $0 = [:] }
        bigFiles.mutate { $0 = [:] }
        bigSeen = -1
        largest = []
        searchStarted = nil; searchFinished = nil
    }

    // MARK: Live progress

    /// A folder being measured right now: what it holds so far, and when that last grew.
    struct Running: Equatable { var bytes: Int64 = 0; var files = 0; var movedAt = Date() }
    /// Every walk running now, wherever it is.
    @Published private(set) var running: [String: Running] = [:]
    /// The running walks for items of the open folder.
    var runningHere: [String: Running] {
        let here = Set(entries.map(\.path))
        return running.filter { here.contains($0.key) }
    }
    @Published private(set) var measureStarted = Date()
    /// Files counted in this folder's items, finished and running.
    var filesCounted: Int { entries.reduce(0) { $0 + (sizes[$1.path]?.files ?? 0) } + runningHere.values.reduce(0) { $0 + $1.files } }
    /// Workers write running totals here; the screen reads it five times a second, so millions of files never
    /// flood the main thread.
    private let liveSizes = Locked([String: (Int64, Int)]())
    private var pump: Timer?

    private func startPump() {
        guard pump == nil else { return }
        pump = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.drain() } }
    }

    private func drain() {
        let snap = liveSizes.value
        var next: [String: Running] = [:]
        for (p, (b, n)) in snap where sizes[p] == nil {
            var r = running[p] ?? Running()
            if r.bytes != b || r.files != n { r.movedAt = Date() }
            r.bytes = b; r.files = n
            next[p] = r
        }
        if next != running { running = next }
        let found = bigFiles.value
        if found.count != bigSeen {
            bigSeen = found.count
            largest = found.values.filter { !DiskExplorer.isPrivate($0.path, home: home) }.sorted { $0.bytes > $1.bytes }
        }
        if ops.isEmpty && waiting.isEmpty && snap.isEmpty { pump?.invalidate(); pump = nil; running = [:] }
    }

    /// The disk's size and free space, read when measuring starts and again when it ends,
    /// so the Startup disk bar compares like with like instead of a figure from the last scan.
    @Published private(set) var disk: VolumeInfo?

    func refreshDisk() {
        Task.detached(priority: .utility) {
            let v = SystemProbe.capacity()
            await MainActor.run { self.disk = v }
        }
    }

    // MARK: Largest files

    @Published private(set) var searchStarted: Date?
    @Published private(set) var searchFinished: Date?

    /// Walks that pass through your home folder: the folders above it, it, and folders inside it.
    private func coversHome(_ x: String) -> Bool { x == home || x.hasPrefix(home + "/") || (x != root && home.hasPrefix(x + "/")) }
    /// Your home folder has been walked in full, by its own walk or one above it.
    var homeDone: Bool {
        var q = home
        while q.count > 1 { if sizes[q] != nil { return true }; q = q.parentPath }
        return false
    }
    var searchingLargest: Bool { !homeDone }
    /// The walks going through your home folder right now, biggest first.
    var homeWalks: [(path: String, run: Running)] {
        running.filter { coversHome($0.key) }.map { ($0.key, $0.value) }.sorted { $0.run.files > $1.run.files }
    }
    /// Files the home walks have looked at.
    var filesChecked: Int {
        if homeDone {
            var q = home
            while q.count > 1 { if let s = sizes[q] { return s.files }; q = q.parentPath }
        }
        return homeWalks.reduce(0) { $0 + $1.run.files }
    }

    /// Opening Largest files: the walk the map already runs finds them. Only if nothing is walking your home folder
    /// (it was measured again from inside) does it start one.
    func findLargest() {
        guard started, !homeDone else { return }
        if !ops.keys.contains(where: coversHome) && !waiting.keys.contains(where: coversHome) { walk(home, urgent: true) }
        startPump()
    }

    /// Search again: measures your home folder again, and the folders above it.
    func searchAgain() {
        forget(home)
        walk(home, urgent: true)
        startPump()
    }
}

struct DiskMapView: View {
    @Environment(AppModel.self) var model
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
                       value: ex.mode == .largest ? Format.bytes(ex.largest.reduce(0) { $0 + $1.bytes }) : Format.bytes(ex.totalSoFar),
                       caption: ex.mode == .largest ? (ex.searchingLargest ? "Searching…" : "\(ex.largest.count) files")
                                                    : ex.measuring ? "Measuring \(ex.measured) of \(ex.entries.count)…" : "\(ex.entries.count) items") {
                HStack(spacing: 8) {
                    Picker("View", selection: $ex.mode) {
                        ForEach(ExplorerModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Button { ex.mode = .folders; ex.open(ex.home) } label: { Label("Home folder", systemImage: "house") }
                        .help("Jump to your home folder")
                    Button { ex.up() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(ex.path == ex.root || ex.mode == .largest).keyboardShortcut("[", modifiers: .command)
                        .help("Up one folder (⌘[)")
                    Button { ex.mode == .largest ? ex.searchAgain() : ex.refresh() } label: { Label("Measure again", systemImage: "arrow.clockwise") }
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
        .alert("Sapu2 won't move this", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
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
        if p.hasPrefix("/") { menuItems(p, bytes: bytes) }
    }

    /// Outside your home folder Sapu2 only shows and measures, so only Finder and Copy Path are offered there.
    @ViewBuilder private func menuItems(_ p: String, bytes: Int64) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p, forType: .string)
        }
        if p.hasPrefix(ex.home + "/") {
            Divider()
            if model.isProtected(p) {
                Button("Allow cleaning again") { model.setProtected(ProtectList.entry(covering: p, in: model.protectList) ?? p, false) }
            } else {
                Button("Never clean this") { model.setProtected(p, true) }
            }
            Button("Move to Trash…", role: .destructive) { askTrash(p, bytes) }
        }
    }

    @ViewBuilder private var folders: some View {
        // A lazy stack like the rest of Sapu2: the strip, the hint and the path scroll with the rows, and only rows on
        // screen are built while sizes stream in.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if ex.path == ex.root, let v = model.snapshot.volume { WholeDisk(ex: ex, volume: v, fullAccess: model.hasFullDiskAccess) }
                if ex.measuring { MeasureProgress(ex: ex) }
                breadcrumbs
                if ex.entries.isEmpty {
                    EmptyState(symbol: "folder", title: "Empty folder", message: "Nothing here, or macOS didn't let Sapu2 read it.")
                        .frame(minHeight: 300)
                } else {
                    if ex.total > 0 && model.search.isEmpty {
                        Skyline(ex: ex).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    let found = model.memo("findingsByPath") {
                        Dictionary(model.snapshot.findings.filter { $0.category != .home }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                    }
                    ForEach(rows) { e in
                        DiskRow(entry: e, ex: ex, finding: found[e.path])
                            .padding(.horizontal, 12).padding(.vertical, 3)
                            .background(ex.selection == e.path ? Depot.bayHigh : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { ex.selection = e.path }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if e.isFolder, e.sealed == nil { ex.open(e.path) } })
                            .contextMenu { menu(e.path, bytes: ex.sizes[e.path]?.bytes ?? 0) }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var largestList: some View {
        let top = ex.largest.first?.bytes ?? 1
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SearchProgress(ex: ex)
                if ex.largest.isEmpty {
                    if !ex.searchingLargest && ex.searchFinished != nil {
                        EmptyState(symbol: "doc", title: "No files of 200 MB or more", message: "Nothing that big outside private folders.")
                            .frame(minHeight: 260)
                    }
                } else {
                    Text("FOUND · \(ex.largest.count)" + (ex.searchingLargest ? " SO FAR" : ""))
                        .font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
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
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(ex.selection == f.path ? Depot.bayHigh : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { ex.selection = f.path }
                        .contextMenu { menu(f.path, bytes: f.bytes) }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(ex.crumbs.enumerated()), id: \.element) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(p == "/" ? "Macintosh HD" : p == ex.home ? "Home (\(p.lastComponent))" : p.lastComponent) { ex.open(p) }
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
    /// What the folders at the top of the disk are, in a few words.
    static let about: [String: String] = [
        "/Applications": "Your apps.",
        "/Users": "Every account's home folder; yours is inside.",
        "/System": "macOS itself. Sealed and read-only; updates replace it.",
        "/Library": "Settings, fonts and support files shared by every account.",
        "/private": "macOS's working data: logs, caches, temporary files, swap.",
        "/opt": "Homebrew on Apple silicon, and other tools you installed.",
        "/usr": "Command-line tools. /usr/local holds ones you installed.",
        "/bin": "Core commands macOS ships.",
        "/sbin": "Core system commands macOS ships.",
        "/cores": "Crash dumps, if any app saved one.",
    ]

    @Environment(AppModel.self) var model
    let entry: DiskExplorer.Entry
    @ObservedObject var ex: ExplorerModel
    /// Sapu2's finding for this exact path, looked up once for the whole list (the full scan's per-folder records only
    /// repeat the name, so they're left out).
    let finding: Finding?

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
            } else if let r = ex.runningHere[entry.path] {
                // Measuring now: what it holds so far, counting up.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("\(Format.bytes(r.bytes)) · \(r.files.formatted()) files so far").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(width: 216, alignment: .trailing)
            } else {
                Text("waiting").font(.caption).foregroundStyle(.tertiary).frame(width: 216, alignment: .trailing)
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
        } else if let about = Self.about[entry.path] ?? (entry.path == ex.home ? "Your home folder: documents, projects, app data." : nil) {
            Text(about + (ex.sizes[entry.path]?.denied == true ? " Part of it is protected by macOS, so this is the least it holds." : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else if entry.isLink {
            Text("Link. Sapu2 doesn't follow it.").font(.caption).foregroundStyle(.secondary)
        } else if entry.isFolder, case let c = DiskExplorer.cleanable(under: entry.path, in: model.snapshot.findings), c > 0 {
            Text("\(Format.bytes(c)) inside Sapu2 can clean").font(.caption).foregroundStyle(.green)
        }
    }
}

/// The folder at a glance: its biggest items as blocks, wide as the space they take. Click a block to open it.
struct Skyline: View {
    @ObservedObject var ex: ExplorerModel
    private static let palette = [Depot.yours, Depot.go, Depot.choice, Color(red: 0.75, green: 0.55, blue: 1), Color(red: 0.35, green: 0.85, blue: 0.9), Depot.alert, Depot.stays]

    var body: some View {
        let sized = ex.sorted.compactMap { e in ex.sizes[e.path].map { (e, $0.bytes) } }.filter { $0.1 > 0 }
        let total = Double(max(sized.reduce(Int64(0)) { $0 + $1.1 }, 1))
        // Blocks under 4 % of the folder join "Other", so every block is wide enough to click.
        let top = Array(sized.prefix(7).filter { Double($0.1) / total >= 0.04 })
        let rest = Int64(total) - top.reduce(Int64(0)) { $0 + $1.1 }
        GeometryReader { g in
            let gaps = CGFloat(top.count + (rest > 0 ? 1 : 0) - 1) * 4
            HStack(spacing: 4) {
                ForEach(Array(top.enumerated()), id: \.element.0.path) { i, item in
                    let w = (g.size.width - gaps) * Double(item.1) / total
                    let c = Self.palette[i % Self.palette.count]
                    Button { if item.0.isFolder, item.0.sealed == nil { ex.open(item.0.path) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Spacer(minLength: 0)
                            if w > 70 {
                                Text(item.0.name).font(.caption.weight(.bold)).lineLimit(1)
                                Text(Format.bytes(item.1)).font(.caption2.monospacedDigit()).lineLimit(1).opacity(0.8)
                            }
                        }
                        .foregroundStyle(Depot.floor)
                        .padding(8)
                        .frame(width: w, height: g.size.height, alignment: .bottomLeading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c.gradient))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(item.0.name) · \(Format.bytes(item.1))")
                }
                if rest > 0 {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Depot.bayHigh)
                        .overlay(alignment: .bottomLeading) { Text("Other").font(.caption.weight(.bold)).foregroundStyle(Depot.ink2).padding(8) }
                        .frame(width: (g.size.width - gaps) * Double(rest) / total)
                }
            }
        }
        .frame(height: 74)
        .clipped()
    }
}

/// The top of the disk adds up: what Sapu2 measured, plus what only an administrator can read, equals what is used.
struct WholeDisk: View {
    @ObservedObject var ex: ExplorerModel
    let volume: VolumeInfo
    let fullAccess: Bool

    var body: some View {
        // Same figures Finder shows: purgeable space counts as available, so "used" is total minus available.
        let v = ex.disk ?? volume
        let used = v.used
        let seen = ex.totalSoFar
        let mapped = min(seen, used)
        let rest = max(used - seen, 0)
        // Under 1 GB is rounding and file system bookkeeping, not worth a slice of its own.
        let unread = ex.measuring || rest < 1_000_000_000 ? 0 : rest
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("STARTUP DISK").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Depot.ink3)
                Spacer()
                Text("\(Format.bytes(used)) used · \(Format.bytes(v.available)) available of \(Format.bytes(v.total))")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Depot.ink2)
            }
            Ribbon(parts: [
                .init(id: "seen", name: ex.measuring ? "Measured so far" : "Mapped below", bytes: mapped, color: Depot.yours),
                .init(id: "wait", name: "Still measuring", bytes: ex.measuring ? rest : 0, color: Depot.stays.opacity(0.35)),
                .init(id: "unread", name: "System and hidden areas", bytes: unread, color: Depot.stays),
                .init(id: "purge", name: "Purgeable", bytes: v.purgeable, color: Depot.bayHigh.opacity(0.7)),
                .init(id: "free", name: "Free", bytes: v.free, color: Depot.bayHigh),
            ], height: 10)
            Text(note(v, unread: unread, over: ex.measuring ? 0 : seen - used))
                .font(.caption).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .bay()
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
        .onAppear { ex.refreshDisk() }
    }

    private func note(_ v: VolumeInfo, unread: Int64, over: Int64) -> String {
        var s = "Every folder on the disk, biggest first, plus macOS's own volumes. Open any folder to see what fills it."
            + " Used and available match System Settings and Finder."
        if v.purgeable > 0 {
            s += " About \(Format.bytes(v.purgeable)) is purgeable: files macOS frees by itself when space runs low"
               + " (caches, local snapshots, iCloud copies), so it counts as available, not used. No need to clean it."
        }
        if unread > 0 {
            s += " About \(Format.bytes(unread)) more is in system and hidden areas no app can read, even with Full Disk Access:"
               + " protected system folders, other accounts, local snapshots and file system bookkeeping."
        }
        if over > 1_000_000_000 {
            s += " Some files share the same disk space (APFS clones), so the folders add up to \(Format.bytes(over)) more than is used."
               + " Used is the real figure."
        }
        if !fullAccess { s += " Without Full Disk Access some folders in your home are counted only partly." }
        return s + " Sapu2 only measures here; outside your home folder nothing can be moved."
    }
}

/// Largest files, live. There is no search of its own: the walk that measures the map finds big files as it goes,
/// so this shows that walk's progress through your home folder and what it has found so far.
struct SearchProgress: View {
    @ObservedObject var ex: ExplorerModel

    var body: some View {
        let searching = ex.searchingLargest
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if searching { ProgressView().controlSize(.small) }
                Text(searching ? "Finding files of 200 MB or more while the map measures your home folder"
                               : "Files of 200 MB or more in your home folder")
                    .font(.callout.weight(.semibold)).foregroundStyle(Depot.ink)
                Spacer()
                if !searching {
                    Button("Search again") { ex.searchAgain() }.buttonStyle(GhostButtonStyle())
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { t in
                let secs = ex.searchStarted.map { Int((ex.searchFinished ?? t.date).timeIntervalSince($0)) }
                Text("\(ex.filesChecked.formatted()) files checked · \(ex.largest.count) found" + (secs.map { " · \($0) s" } ?? "")
                     + (searching ? "" : " · same walk as Folders, nothing measured twice"))
                    .font(.caption.monospacedDigit()).foregroundStyle(Depot.ink2)
            }
            if searching, !ex.homeWalks.isEmpty {
                TimelineView(.periodic(from: .now, by: 2)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ex.homeWalks, id: \.path) { w in
                            let stuck = t.date.timeIntervalSince(w.run.movedAt) > 8
                            HStack(spacing: 8) {
                                Image(systemName: stuck ? "hand.raised.fill" : "magnifyingglass").font(.caption)
                                    .foregroundStyle(stuck ? Depot.choice : Depot.ink3).frame(width: 14)
                                Text("Measuring " + w.path.tildePath).font(.caption).foregroundStyle(Depot.ink).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(stuck ? "waiting on macOS: answer its dialog if one asked about this folder"
                                           : "\(Format.bytes(w.run.bytes)) · \(w.run.files.formatted()) files").font(.caption.monospacedDigit())
                                    .foregroundStyle(stuck ? Depot.choice : Depot.ink2)
                            }
                        }
                    }
                }
            }
            Text("Files inside private folders (keys, mail, messages, password managers, cloud files) are never listed.")
                .font(.caption).foregroundStyle(Depot.ink3)
        }
        .padding(14)
        .bay()
        .padding(.horizontal, 16).padding(.top, 10)
    }
}

/// Folders, live: how many items are measured, files counted so far, and what is being measured right now.
struct MeasureProgress: View {
    @ObservedObject var ex: ExplorerModel

    var body: some View {
        let done = ex.measured, total = ex.entries.count
        let now = ex.runningHere.sorted { $0.value.bytes > $1.value.bytes }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Measuring \(ex.path == "/" ? "Macintosh HD" : ex.path.tildePath)").font(.callout.weight(.semibold)).foregroundStyle(Depot.ink)
                Spacer()
            }
            ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Depot.yours)
            TimelineView(.periodic(from: .now, by: 1)) { t in
                Text("\(done) of \(total) items · \(ex.filesCounted.formatted()) files counted · \(Format.bytes(ex.totalSoFar)) so far · \(Int(t.date.timeIntervalSince(ex.measureStarted))) s"
                     + (total - done - now.count > 0 ? " · \(total - done - now.count) waiting" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(Depot.ink2)
            }
            if !now.isEmpty {
                TimelineView(.periodic(from: .now, by: 2)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(now, id: \.key) { p, r in
                            let stuck = t.date.timeIntervalSince(r.movedAt) > 8
                            HStack(spacing: 8) {
                                Image(systemName: stuck ? "hand.raised.fill" : "ruler").font(.caption)
                                    .foregroundStyle(stuck ? Depot.choice : Depot.ink3).frame(width: 14)
                                Text("Measuring " + (p == "/" ? "/" : p.tildePath)).font(.caption).foregroundStyle(Depot.ink).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(stuck ? "waiting on macOS: answer its dialog if one asked about this folder"
                                           : "\(Format.bytes(r.bytes)) · \(r.files.formatted()) files").font(.caption.monospacedDigit())
                                    .foregroundStyle(stuck ? Depot.choice : Depot.ink2)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .bay()
        .padding(.horizontal, 16).padding(.top, 10)
    }
}
