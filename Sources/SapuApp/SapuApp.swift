import SapuCore
import SwiftUI

@main
struct SapuApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sapu2") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1020, minHeight: 640)
                .onAppear { model.onLaunch() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            if Updater.enabled {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { model.checkForUpdates(manual: true) }
                }
            }
            CommandMenu("Scan") {
                Button("Quick scan") { model.scan([.quick]) }.keyboardShortcut("r")
                Button("Scan projects") { model.scan([.projects]) }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Full map") { model.scan([.full]) }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Scan everything") { model.scan(ScanLayer.allCases) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Full rescan (ignore cache)") { model.rescanFresh() }
                Divider()
                Button("Cancel scan") { model.cancelScan() }.keyboardShortcut(".").disabled(model.scanning == nil)
            }
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Form {
            Section("Projects you are working on") {
                Stepper("Project counts as active if edited in the last \(model.activeDays) days", value: Bindable(model).activeDays, in: 3...90)
                Text("Build folders of projects you edited recently are locked so your next build stays fast. Unlock any of them with the lock button on its row; unlocks last until you quit Sapu2.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Scan cache & receipts", value: Store.directory.path.tildePath)
                Button("Show in Finder") { model.reveal(Store.directory.path) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}
