import SapuCore
import SwiftUI

extension Safety {
    var color: Color {
        switch self {
        case .safe: Depot.go
        case .check: Depot.choice
        case .yours: Depot.yours
        case .protected: Depot.stays
        }
    }
    var symbol: String {
        switch self {
        case .safe: "checkmark.seal.fill"
        case .check: "exclamationmark.triangle.fill"
        case .yours: "person.crop.circle.fill"
        case .protected: "lock.fill"
        }
    }
}

extension Insight.Level {
    var color: Color {
        switch self {
        case .danger: .red
        case .warning: .orange
        case .tip: .green
        case .info: .blue
        }
    }
    var symbol: String {
        switch self {
        case .danger: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        case .info: "info.circle.fill"
        }
    }
}

struct SafetyBadge: View {
    let safety: Safety
    var body: some View {
        Label(safety.label, systemImage: safety.symbol)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.12), in: Capsule())
    }
}

struct SizeText: View {
    let bytes: Int64
    var body: some View {
        Text(Format.bytes(bytes)).font(.body.monospacedDigit().weight(.semibold))
    }
}

/// Horizontal bar relative to the biggest item in a list.
struct RelativeBar: View {
    let value: Int64
    let max: Int64
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(color.opacity(0.18))
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(Double(value) / Double(Swift.max(max, 1))))
                }
        }
        .frame(height: 4)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(Depot.ink3)
                .frame(width: 76, height: 76).background(Circle().fill(Depot.bay)).overlay(Circle().strokeBorder(Depot.line))
            Text(title).font(Depot.sign(20, .bold)).foregroundStyle(Depot.ink)
            Text(message).foregroundStyle(Depot.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let action { Button(action.0, action: action.1).buttonStyle(SignButtonStyle(large: false)).padding(.top, 6) }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
