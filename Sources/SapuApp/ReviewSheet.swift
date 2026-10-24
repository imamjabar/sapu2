import SapuCore
import SwiftUI

/// Dry run: shows exactly what will happen to each item before anything is touched.
struct ReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedYours = false

    var body: some View {
        let items = model.checkedFindings
        let yours = items.filter { $0.safety == .yours }
        let locked = items.filter { $0.lockedReason != nil }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.lastReceipt == nil ? "Review cleanup" : "Cleanup finished").font(.title2.weight(.semibold))
                if let r = model.lastReceipt {
                    Text("Cleaned \(Format.bytes(r.cleanedBytes)). Free space: \(Format.bytes(r.freeBefore)) → \(Format.bytes(r.freeAfter)). Trashed items free their space when you empty the Trash.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(items.count) items · \(Format.bytes(model.checkedBytes)). Nothing is deleted permanently: folders go to the Trash, caches use their tool's own clean command, logs are emptied in place.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            if let r = model.lastReceipt {
                List(r.items, id: \.self) { i in
                    HStack {
                        Image(systemName: i.ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(i.ok ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(i.title)
                            Text(i.message).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.bytes(i.bytes)).monospacedDigit()
                    }
                }
            } else {
                List(items) { f in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.body.weight(.medium))
                            Text(f.action.label).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let r = f.rebuild { Text("Comes back: \(r)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        SafetyBadge(safety: f.safety)
                        Text(Format.bytes(f.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if model.lastReceipt == nil {
                    if !locked.isEmpty {
                        Label("\(locked.count) item(s) belong to active projects. You allowed this in Settings.", systemImage: "lock.open")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    if !yours.isEmpty {
                        Toggle("I checked the \(yours.count) “Your files” item(s) and want them in the Trash", isOn: $confirmedYours)
                    }
                }
                HStack {
                    if model.cleaning {
                        ProgressView().controlSize(.small)
                        Text(model.cleanStatus).font(.caption).lineLimit(1)
                    }
                    Spacer()
                    if model.lastReceipt != nil {
                        Button("Done") { model.lastReceipt = nil; dismiss() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.cleaning)
                        Button("Clean \(Format.bytes(model.checkedBytes))") { model.clean() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.cleaning || items.isEmpty || (!yours.isEmpty && !confirmedYours))
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 680, height: 540)
    }
}
