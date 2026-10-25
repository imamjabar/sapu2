import SapuCore
import SwiftUI

@main
struct SapuApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Sapu") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1020, minHeight: 640)
                .onAppear { model.onLaunch() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowToolbarStyle(.unified)
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
            SettingsView().environmentObject(model)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Projects you are working on") {
                Stepper("Project counts as active if edited in the last \(model.activeDays) days", value: $model.activeDays, in: 3...90)
                Toggle("Allow cleaning active projects", isOn: $model.allowActiveProjects)
                Text("Off by default: node_modules, virtualenvs and build folders of active projects stay so you can keep developing fast.")
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
