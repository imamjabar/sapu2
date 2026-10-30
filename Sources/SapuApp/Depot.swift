import SapuCore
import SwiftUI

/// The sorting depot: Sapu2's visual world. A dark floor, raised bays, and four colour-coded bins every item is
/// sorted into before anything moves. Colour only ever means which bin.
enum Depot {
    static let floor = Color(red: 0.071, green: 0.086, blue: 0.110)       // #12161C
    static let floorTop = Color(red: 0.094, green: 0.114, blue: 0.145)    // #181D25
    static let bay = Color(red: 0.102, green: 0.125, blue: 0.161)         // #1A2029
    static let bayHigh = Color(red: 0.133, green: 0.161, blue: 0.204)     // #222934
    static let line = Color.white.opacity(0.08)
    static let ink = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let ink2 = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let ink3 = Color(red: 0.42, green: 0.46, blue: 0.52)

    static let go = Color(red: 0.239, green: 0.839, blue: 0.549)          // #3DD68C
    static let choice = Color(red: 1.0, green: 0.710, blue: 0.278)        // #FFB547
    static let yours = Color(red: 0.357, green: 0.608, blue: 1.0)         // #5B9BFF
    static let stays = Color(red: 0.545, green: 0.584, blue: 0.647)       // #8B95A5
    static let alert = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Signage type: rounded and heavy for numbers and headings, so the depot reads at a glance.
    static func sign(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}

/// The four bins. Every finding lands in exactly one.
enum Bin: String, CaseIterable, Identifiable {
    case go, choice, yours, stays
    var id: String { rawValue }

    var name: String {
        switch self {
        case .go: "Sweep"
        case .choice: "Your call"
        case .yours: "Your files"
        case .stays: "Stays"
        }
    }
    var promise: String {
        switch self {
        case .go: "Rebuilds itself. Ticked for you, goes to the Trash."
        case .choice: "Rebuilds, but costs a download or a wait. Tick what you want."
        case .yours: "Your own data. Never ticked; look first."
        case .stays: "In use, protected, or only its app should remove it."
        }
    }
    var color: Color {
        switch self {
        case .go: Depot.go
        case .choice: Depot.choice
        case .yours: Depot.yours
        case .stays: Depot.stays
        }
    }
    /// What happens to a bin, in two or three words.
    var verb: String {
        switch self {
        case .go: "goes to the Trash"
        case .choice: "you decide"
        case .yours: "look first"
        case .stays: "left alone"
        }
    }
    var symbol: String {
        switch self {
        case .go: "arrow.3.trianglepath"
        case .choice: "hand.raised.fill"
        case .yours: "person.fill"
        case .stays: "lock.fill"
        }
    }
}

// MARK: Bin drawing

/// A sorting bin: open top with a lip, rounded base, filled to `level` with its colour.
struct BinShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let taper = r.width * 0.08, radius = r.width * 0.14
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - taper, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - taper - radius, y: r.maxY), control: CGPoint(x: r.maxX - taper, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + taper + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + taper, y: r.maxY - radius), control: CGPoint(x: r.minX + taper, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct BinView: View {
    let bin: Bin
    /// 0...1 of the bin's height.
    let level: Double
    var label: String? = nil
    var value: String? = nil
    var selected = false
    var height: CGFloat = 120

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                BinShape().fill(Depot.bayHigh)
                BinShape().fill(bin.color.gradient)
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: max(0, height * CGFloat(min(level, 1))))
                    }
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: level)
                BinShape().stroke(selected ? bin.color : Depot.line, lineWidth: selected ? 2 : 1)
                // The lip.
                Capsule().fill(selected ? bin.color : Depot.ink3.opacity(0.6))
                    .frame(height: 5).offset(y: -height + 2).padding(.horizontal, -4)
                Image(systemName: bin.symbol).font(.system(size: 18, weight: .bold))
                    .foregroundStyle(level > 0.3 ? Depot.floor.opacity(0.75) : bin.color)
                    .padding(.bottom, 14)
            }
            .frame(height: height)
            if let label {
                VStack(spacing: 2) {
                    Text(label).font(Depot.sign(13, .semibold)).foregroundStyle(Depot.ink).lineLimit(1).fixedSize()
                    if let value { Text(value).font(Depot.sign(12, .medium).monospacedDigit()).foregroundStyle(Depot.ink2).lineLimit(1).fixedSize() }
                    Text(bin.verb).font(.system(size: 11, weight: .semibold)).foregroundStyle(bin.color).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Dust

/// Specks drifting down into the bins while Sapu2 sorts. Pure drawing; stops under Reduce Motion.
struct DustFall: View {
    var colors: [Color] = Bin.allCases.map(\.color)
    var speed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate * speed
                for i in 0..<70 {
                    let seed = Double(i) * 12.9898
                    let lane = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let x = abs(lane) * size.width
                    let period = 2.2 + abs(cos(seed)) * 2.5
                    let phase = (t / period + abs(lane)).truncatingRemainder(dividingBy: 1)
                    let y = phase * size.height
                    let s = 2 + abs(sin(seed * 3)) * 3
                    let c = colors[i % colors.count]
                    ctx.opacity = (1 - phase) * 0.9
                    ctx.fill(Path(roundedRect: CGRect(x: x + sin(t * 2 + seed) * 6, y: y, width: s, height: s), cornerRadius: s / 3), with: .color(c))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A one-shot burst of sorted specks, for the moment a sweep finishes.
struct Burst: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: still)) { tl in
            Canvas { ctx, size in
                let e = min(tl.date.timeIntervalSince(start), 1.6)
                guard e < 1.6 else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<48 {
                    let a = Double(i) / 48 * .pi * 2 + Double(i % 3) * 0.2
                    let v = 140 + Double((i * 37) % 90)
                    let d = v * e - 60 * e * e
                    let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d + 40 * e * e)
                    ctx.opacity = max(0, 1 - e / 1.6)
                    let s = 4 + Double(i % 4)
                    ctx.fill(Path(roundedRect: CGRect(x: p.x, y: p.y, width: s, height: s), cornerRadius: 1.5),
                             with: .color(Bin.allCases[i % 4].color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Controls

/// The big rounded action, depot-sign style.
struct SignButtonStyle: ButtonStyle {
    var tint: Color = Depot.go
    var large = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Depot.sign(large ? 18 : 14, .bold))
            .foregroundStyle(Depot.floor)
            .padding(.horizontal, large ? 34 : 16).padding(.vertical, large ? 14 : 8)
            .background(Capsule().fill(tint.opacity(enabled ? 1 : 0.35)))
            .shadow(color: tint.opacity(enabled ? 0.35 : 0), radius: configuration.isPressed ? 4 : 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Quiet capsule button for secondary actions on the depot floor.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(configuration.role == .destructive ? Depot.alert : Depot.ink)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Depot.bayHigh.opacity(configuration.isPressed ? 1 : 0.8)))
            .overlay(Capsule().strokeBorder(Depot.line))
            .contentShape(Capsule())
    }
}

/// A raised bay: the panel every group of rows sits on.
struct Bay: ViewModifier {
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Depot.bay, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Depot.line))
    }
}

extension View {
    func bay(padding: CGFloat = 0) -> some View { modifier(Bay(padding: padding)) }
}

/// Disclosure chevron that turns as the row opens.
struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Depot.ink2)
            .rotationEffect(.degrees(open ? 90 : 0))
            .animation(.easeOut(duration: 0.15), value: open)
            .frame(width: 16)
    }
}

/// Round tick box in a bin's colour. `mixed` when only some of a group is ticked.
struct Tick: View {
    let on: Bool
    var mixed = false
    var color: Color = Depot.go
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(on || mixed ? color : Depot.ink3, lineWidth: 1.5)
                    .background(Circle().fill(on ? color : .clear))
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(Depot.floor) }
                else if mixed { Capsule().fill(color).frame(width: 8, height: 2.5) }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : on ? 0.7 : 0.3)
        .accessibilityLabel(on ? "Ticked" : mixed ? "Partly ticked" : "Not ticked")
        .accessibilityAddTraits(.isButton)
    }
}

/// A pane's prominent action, as a small depot sign.
struct GradientButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Depot.floor)
            .background(Capsule().fill(Depot.go))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

// MARK: Charts and heroes

/// A ring gauge: track, coloured arc, big number in the middle.
struct Ring: View {
    let value: Double
    let color: Color
    var lineWidth: CGFloat = 12
    var size: CGFloat = 120
    var big: String
    var small: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.8, dampingFraction: 0.85), value: value)
            VStack(spacing: 0) {
                Text(big).font(Depot.sign(size * 0.2, .heavy).monospacedDigit()).foregroundStyle(Depot.ink)
                    .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.5)
                if let small { Text(small).font(.system(size: max(10, size * 0.09), weight: .medium)).foregroundStyle(Depot.ink2).lineLimit(1) }
            }
            .padding(lineWidth + 6)
        }
        .frame(width: size, height: size)
    }
}

/// One horizontal ribbon split into coloured parts, with a legend under it.
struct Ribbon: View {
    struct Part: Identifiable { let id: String; let name: String; let bytes: Int64; let color: Color }
    let parts: [Part]
    var height: CGFloat = 14

    var body: some View {
        let total = Double(max(parts.reduce(Int64(0)) { $0 + $1.bytes }, 1))
        let shown = parts.filter { $0.bytes > 0 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 3) {
                    ForEach(shown) { p in
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.color.gradient)
                            .frame(width: max(4, (g.size.width - CGFloat(shown.count - 1) * 3) * Double(p.bytes) / total))
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 16) {
                ForEach(shown) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text(p.name).foregroundStyle(Depot.ink2)
                        Text(Format.bytes(p.bytes)).foregroundStyle(Depot.ink).monospacedDigit()
                    }
                    .font(.caption.weight(.medium))
                }
            }
        }
    }
}

/// Small caps label used above groups.
struct Kicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Depot.ink3)
    }
}

/// Hairline divider in depot ink.
struct Hairline: View {
    var inset: CGFloat = 0
    var body: some View { Rectangle().fill(Depot.line).frame(height: 1).padding(.leading, inset) }
}

// MARK: Unlocking

/// The lock on an active project's item. Clicking it explains what unlocking costs before anything changes.
struct UnlockButton: View {
    @Environment(AppModel.self) var model
    let items: [Finding]
    var label: String? = nil
    @State private var asking = false

    var body: some View {
        Button { asking = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                if let label { Text(label).font(.caption.weight(.semibold)) }
            }
            .foregroundStyle(Depot.choice)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, label == nil ? 0 : 8).padding(.vertical, label == nil ? 0 : 3)
            .background(Capsule().fill(label == nil ? .clear : Depot.choice.opacity(0.12)))
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .help("Locked: active project. Click to unlock.")
        .accessibilityLabel("Unlock \(items.first?.title ?? "")")
        .popover(isPresented: $asking, arrowEdge: .bottom) { UnlockSheet(items: items) { asking = false } }
    }
}

struct UnlockSheet: View {
    @Environment(AppModel.self) var model
    let items: [Finding]
    let done: () -> Void
    @State private var facts: [YourContext.Fact] = []

    var body: some View {
        let first = items[0]
        let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.open.fill").foregroundStyle(Depot.floor).frame(width: 30, height: 30).background(Circle().fill(Depot.choice))
                VStack(alignment: .leading, spacing: 2) {
                    Text(items.count == 1 ? "Unlock \(first.title)?" : "Unlock \(items.count) items in \(first.owner ?? "this project")?")
                        .font(Depot.sign(15, .bold)).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true)
                    Text("\(Format.bytes(bytes)) · you edited this project recently").font(.caption).foregroundStyle(Depot.ink2)
                }
            }
            if let e = Explainer.explain(first) {
                Text(e.impactText).font(.callout).foregroundStyle(Depot.ink).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(facts, id: \.self) { f in
                Label { Text(.init(f.text)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: f.symbol).foregroundStyle(Depot.ink2) }
                    .font(.caption).foregroundStyle(Depot.ink2)
            }
            Text("Unlocking ticks it. It still goes to the Trash, so Put back works, and everything locks again when you quit Sapu2.")
                .font(.caption).foregroundStyle(Depot.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep locked", action: done).keyboardShortcut(.cancelAction)
                Spacer()
                Button { model.unlock(items); done() } label: { Label("Unlock & tick", systemImage: "lock.open") }
                    .buttonStyle(SignButtonStyle(tint: Depot.choice, large: false))
            }
        }
        .padding(16)
        .frame(width: 380)
        // Solid depot surface, not the system's grey glass, so the small print stays readable.
        .background(Depot.bay.padding(-60))
        .environment(\.colorScheme, .dark)
        .task {
            // Facts from every item, once each: a project's .venv and node_modules each say how they come back.
            let projects = model.snapshot.projects, all = items
            facts = await Task.detached(priority: .userInitiated) {
                var seen = Set<String>()
                return all.flatMap { YourContext.facts(for: $0, projects: projects, running: []) }.filter { seen.insert($0.text).inserted }.prefix(6).map { $0 }
            }.value
        }
    }
}
