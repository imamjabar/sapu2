import AppKit
import SapuCore
import SwiftUI

/// Guided Full Disk Access setup. macOS reserves the switch itself for the user; everything else is done here.
struct AccessSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 34)).foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hasFullDiskAccess ? "Full Disk Access is on" : "Give Sapu Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text(model.hasFullDiskAccess
                         ? "Sapu can now measure Mail, Safari, Messages and app containers. A full map scan will start when you close this."
                         : "So it can measure Mail, Safari, Messages and app containers. Without it, totals are low. Sapu still never cleans those.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.hasFullDiskAccess {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Click **Open Settings**. Sapu is already added to the list.")
                    step(2, "Turn on the switch next to **Sapu** and confirm with Touch ID or your password.")
                    step(3, "If Sapu is missing from the list, drag this icon into it:")
                    HStack {
                        Spacer()
                        DraggableAppIcon()
                        Spacer()
                    }
                    step(4, "If Settings asks to quit and reopen Sapu, click **Quit & Reopen**.")
                }
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the switch… Sapu notices it on its own.").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                if !model.hasFullDiskAccess {
                    Button("Don't ask again") { model.dismissAccessSetup(forever: true) }
                    Button("Later") { model.dismissAccessSetup(forever: false) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Relaunch Sapu") { model.relaunch() }
                        .help("Use this if you turned the switch on but Sapu has not noticed.")
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Spacer()
                    Button("Done") { model.dismissAccessSetup(forever: false) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.weight(.bold).monospacedDigit())
                .frame(width: 22, height: 22).background(Circle().fill(.tint.opacity(0.2)))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The running app's own bundle, draggable into the Full Disk Access list in System Settings.
struct DraggableAppIcon: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 56, height: 56)
            Text("Sapu").font(.caption)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
        .help("Drag into the Full Disk Access list")
    }
}
