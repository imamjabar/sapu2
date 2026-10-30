import AppKit
import SapuCore
import SwiftUI

/// Newer versions of your apps. Checking reads Homebrew's records, each app's own update feed and Apple's lookup;
/// nothing installs until you choose Update on a row.
struct UpdatesView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: .updates, value: model.updatesChecked == nil ? nil : "\(model.appUpdates.count)",
                       caption: model.updatesChecked == nil ? nil : "update\(model.appUpdates.count == 1 ? "" : "s")") {
                Button { model.checkAppUpdates() } label: { Label("Check now", systemImage: "arrow.clockwise") }
                    .disabled(model.checkingUpdates != nil)
            }
            if let s = model.checkingUpdates {
                SmartWorking(title: "Checking for updates", detail: s, fraction: nil, cancel: nil)
            } else if model.updatesChecked == nil {
                EmptyState(symbol: "arrow.down.app", title: "See which apps have updates",
                           message: "Sapu2 reads Homebrew's records, the update feed each app publishes, and Apple's App Store lookup. Nothing is installed until you choose.",
                           action: ("Check for updates", { model.checkAppUpdates() }))
            } else if model.appUpdates.isEmpty {
                EmptyState(symbol: "checkmark.circle", title: "Everything is up to date",
                           message: "Checked \(Format.age(model.updatesChecked ?? Date())). Apps without an update feed (and command-line tools) aren't covered; Homebrew packages are listed in Optimize.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // App icons as a shelf of what's waiting.
                        HStack(spacing: -10) {
                            ForEach(model.appUpdates.prefix(12)) { u in
                                Image(nsImage: NSWorkspace.shared.icon(forFile: u.app.path)).resizable().frame(width: 46, height: 46)
                                    .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                            }
                        }
                        .padding(.bottom, 6)
                        LazyVStack(spacing: 0) {
                            ForEach(model.appUpdates) { UpdateRow(update: $0).padding(.horizontal, 16).padding(.vertical, 8); Hairline(inset: 64) }
                        }
                        .bay()
                        Text("Homebrew apps update in place. Apps with their own updater open so you can choose Check for Updates. App Store apps open in the App Store.")
                            .font(.caption).foregroundStyle(Depot.ink3)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
    }
}

struct UpdateRow: View {
    @Environment(AppModel.self) var model
    let update: AppUpdate

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.path)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(update.app.name).font(.body.weight(.medium))
                    HStack(spacing: 4) {
                        Text(update.installed).foregroundStyle(Depot.ink3)
                        Image(systemName: "arrow.right").font(.caption2.weight(.bold)).foregroundStyle(Depot.ink3)
                        Text(update.latest).foregroundStyle(Depot.go)
                    }
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Depot.bayHigh))
                }
                Text("\(update.sourceName) · \(update.howTo)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let r = model.updateResults[update.id] { Text(r).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if model.updatingApp == update.id {
                ProgressView().controlSize(.small)
            } else {
                Button(buttonTitle) { model.install(update) }
                    .buttonStyle(SignButtonStyle(tint: update.source.isHomebrew ? Depot.go : Depot.yours, large: false))
                    .disabled(model.updatingApp != nil)
            }
            Menu {
                if let n = update.notes { Button("Release notes") { NSWorkspace.shared.open(n) } }
                Button("Show in Finder") { model.reveal(update.app.path) }
                if case .homebrew(let t) = update.source {
                    Button("Copy Terminal command") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew upgrade --cask \(t)", forType: .string)
                    }
                }
                Divider()
                Button("Uninstall…") { model.uninstallFlow(update.app) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(update.app.name)")
        }
        .padding(.vertical, 4)
    }

    private var buttonTitle: String {
        switch update.source {
        case .homebrew: "Update"
        case .sparkle: "Open app"
        case .appStore: "App Store"
        }
    }
}

/// The Trash: what is there, which items Sapu2 can still put back, and Empty Trash behind a deliberate confirmation.
struct TrashView: View {
    @Environment(AppModel.self) var model
    @State private var confirming = false
    @State private var understood = false

    var body: some View {
        let t = model.trashSummary
        VStack(spacing: 0) {
            PaneHeader(pane: .trash, value: t.flatMap { $0.readable ? Format.bytes($0.bytes) : nil }, caption: t.flatMap { $0.readable ? "\($0.items) item\($0.items == 1 ? "" : "s")" : nil }) {
                Button("Open in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: TrashBin.folder())) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let t, !t.readable {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("macOS keeps the Trash private", systemImage: "lock").font(.headline)
                            Text("Apps can only look inside the Trash with Full Disk Access, so Sapu2 can't count or empty it yet. You can still empty it in Finder (Finder › Empty Trash), or allow Full Disk Access and come back.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Allow Full Disk Access…") { model.showAccessSetup = true; model.watchFullDiskAccess() }
                                Button("Open Trash in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: TrashBin.folder())) }
                            }
                        }
                        .padding(16)
                        .bay()
                    } else if let t {
                        HStack(spacing: 28) {
                            BinView(bin: .stays, level: t.items == 0 ? 0 : min(0.92, 0.15 + Double(t.bytes) / 20_000_000_000), height: 130)
                                .frame(width: 120)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(t.items == 0 ? "The Trash is empty" : Format.bytes(t.bytes)).font(Depot.sign(40, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                                Text(t.items == 0 ? "Nothing waiting to be removed." : "waiting in the Trash · \(t.items) item\(t.items == 1 ? "" : "s"). This space isn't free until the Trash is emptied.")
                                    .font(.callout).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 6)
                        VStack(alignment: .leading, spacing: 0) {
                            fact("tray.full", "In the Trash", "\(t.items) item\(t.items == 1 ? "" : "s"), \(Format.bytes(t.bytes)). This space isn't free yet.")
                            Divider().padding(.leading, 40)
                            fact("arrow.uturn.backward", "Put there by Sapu2", t.fromSapu == 0 ? "None. Everything here came from you or other apps."
                                                                                         : "\(t.fromSapu) item\(t.fromSapu == 1 ? "" : "s"). Receipts can put them back while they're in the Trash.")
                            if let o = t.oldest {
                                Divider().padding(.leading, 40)
                                fact("calendar", "Oldest item", "Moved \(Format.age(o)).")
                            }
                        }
                        .bay()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Empty the Trash").font(.headline)
                            Text("Removes everything in your Trash for good and gives the space back. It's the only thing Sapu2 does that can't be undone, so it's never part of Smart Clean.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button(role: .destructive) { understood = false; confirming = true } label: { Text("Empty Trash…") }
                                    .disabled(t.items == 0 || model.emptyingTrash)
                                if model.emptyingTrash { ProgressView().controlSize(.small) }
                                if let r = model.trashResult { Text(r).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                    } else {
                        ProgressView("Looking in the Trash…")
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.loadTrash() }
        .sheet(isPresented: $confirming) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Empty the Trash for good?", systemImage: "exclamationmark.triangle.fill").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                Text("\(t?.items ?? 0) item\((t?.items ?? 0) == 1 ? "" : "s") (\(Format.bytes(t?.bytes ?? 0))) will be removed permanently. \((t?.fromSapu ?? 0) > 0 ? "Put back stops working for the \(t?.fromSapu ?? 0) item\((t?.fromSapu ?? 0) == 1 ? "" : "s") Sapu2 moved there. " : "")This can't be undone.")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("I understand these items can't be recovered", isOn: $understood).toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button("Cancel") { confirming = false }.keyboardShortcut(.cancelAction)
                    Button("Empty Trash", role: .destructive) { confirming = false; model.emptyTrash() }
                        .disabled(!understood)
                }
            }
            .padding(22)
            .frame(width: 440)
        }
    }

    private func fact(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
    }
}

extension AppUpdate.Source {
    var isHomebrew: Bool { if case .homebrew = self { return true }; return false }
}
