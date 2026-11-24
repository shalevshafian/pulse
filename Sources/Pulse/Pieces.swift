import AppKit
import PulseCore
import SwiftUI

func line(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}


/// Rounds the menu bar window itself. macOS draws a plate behind the panel, so the window's
/// own frame is masked, not only the content.
struct WindowShape: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frame = window.contentView?.superview ?? window.contentView else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            frame.wantsLayer = true
            frame.layer?.cornerRadius = Ink.window
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
            DispatchQueue.main.async { window.invalidateShadow() }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1) }
}

struct Metric: View {
    let title: String, value: String, hot: Bool
    init(_ title: String, _ value: String, hot: Bool) { self.title = title; self.value = value; self.hot = hot }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(hot ? Ink.hot : Color.primary)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct IconButton: View {
    let icon: String, title: String
    let action: () -> Void
    @State private var inside = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(inside ? Color.primary : Color.secondary)
                .frame(width: 28, height: 24)
                .background(.white.opacity(inside ? 0.1 : 0), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).onHover { inside = $0 }.help(title).accessibilityLabel(title)
    }
}

/// An area of health: a capsule that is short and pale when fine, and stands up when something needs care.
struct AreaMark: View {
    let title: String
    let state: HealthState

    var body: some View {
        let up = state == .urgent || state == .attention
        VStack(spacing: 4) {
            Capsule()
                .fill(state == .urgent ? Ink.hot : Ink.ink(.dark).opacity(state == .attention ? 1 : state == .unknown ? 0.16 : 0.42))
                .frame(width: 5, height: up ? 14 : 5)
                .frame(height: 14, alignment: .bottom)
            Text(title).font(.system(size: 8.5)).lineLimit(1).fixedSize().opacity(up ? 1 : 0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement().accessibilityLabel("\(title): \(state.rawValue)")
    }
}

struct ProblemCard: View {
    @Environment(\.colorScheme) private var scheme
    let check: HealthCheck
    let fix: (HealthFix) -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Capsule().fill(check.state == .urgent ? Ink.hot : Ink.ink(scheme)).frame(width: 4, height: 13)
                Text(check.title).font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(check.area.title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !check.detail.isEmpty {
                Text(check.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let f = check.fix {
                    Button { fix(f) } label: {
                        Text(f.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.base)
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(Ink.ink(scheme), in: Capsule()).contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle())
                }
                Button(action: ignore) { Text("Ignore").font(.system(size: 11)).foregroundStyle(.secondary).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .tile()
    }
}

struct CleanRow: View {
    let item: CleanupItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Check(title: item.title, isOn: $isOn)
            if item.blockedBy != nil { Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.secondary) }
            Text(Fmt.bytes(item.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .opacity(item.blockedBy == nil ? 1 : 0.7)
        .disabled(item.blockedBy != nil)
        .overlay(alignment: .bottomLeading) {
            Text(item.blockedBy.map { "In use now: \($0)" } ?? item.detail)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 24).offset(y: 12)
        }
        .frame(height: 38, alignment: .top)
        .padding(.top, 2)
        .help(item.path)
    }
}

struct DriveRow: View {
    let row: DriveGuard.Row
    let owed: Bool
    @Binding var isOn: Bool
    let connect: () -> Void

    private var holding: String {
        let names = row.holders.prefix(2).joined(separator: ", ")
        return names + (row.holders.count > 2 ? " and \(row.holders.count - 2) more" : "")
    }

    private var line: String {
        if !row.attached { return owed ? "Unplugged, returns when plugged in" : "Not plugged in" }
        if !row.mounted { return owed ? "Disconnected by Pulse" : "Plugged in, not mounted" }
        if !isOn { return "Stays connected in sleep" }
        return row.holders.isEmpty ? "Disconnects in sleep" : "Would stay now, in use by " + holding
    }

    var body: some View {
        HStack(spacing: 6) {
            Check(title: row.name, isOn: $isOn)
            if owed, row.attached, !row.mounted {
                Button(action: connect) {
                    Text("Connect").font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.base)
                        .padding(.horizontal, 9).frame(height: 18).background(Color.primary, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            if let b = row.bytes { Text(Fmt.drive(b)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
        }
        .overlay(alignment: .bottomLeading) {
            Text(line).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 24).offset(y: 13)
        }
        .frame(height: 40, alignment: .top)
        .padding(.top, 2)
        .help(row.holders.joined(separator: ", "))
    }
}

struct Tile: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var padding: CGFloat = 11
    /// Takes the height of its row. A tile on its own is as tall as what it holds.
    var fill = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Ink.radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(Ink.tile(scheme), in: shape)
            .overlay(shape.strokeBorder(Ink.line(scheme), lineWidth: 1))
            .contentShape(shape)
    }
}

extension View {
    func tile(padding: CGFloat = 11, fill: Bool = false) -> some View { modifier(Tile(padding: padding, fill: fill)) }
}

/// A tile's name, and a count beside it when the count says something.
struct TileLabel: View {
    let title: String
    var count: String?
    init(_ title: String, count: String? = nil) { self.title = title; self.count = count }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            if let count {
                Text("[\(count)]").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}




/// The small mark before a row: what kind of thing it is, drawn in capsules.
struct Glyph: View {
    enum Kind { case lines, slash, cross, block }
    static func of(_ k: Consumer.Kind) -> Kind { k == .session ? .lines : k == .app ? .block : k == .runtime ? .cross : .slash }
    @Environment(\.colorScheme) private var scheme
    let kind: Kind
    var body: some View {
        let c = Ink.ink(scheme).opacity(0.55)
        ZStack {
            switch kind {
            case .lines:
                VStack(spacing: 1.6) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(c).frame(width: 9, height: 2.2) } }
            case .slash:
                Capsule().fill(c).frame(width: 10, height: 2.6).rotationEffect(.degrees(-45))
            case .cross:
                Capsule().fill(c).frame(width: 10, height: 3.2)
                Capsule().fill(c).frame(width: 3.2, height: 10)
            case .block:
                RoundedRectangle(cornerRadius: 2.5).fill(c).frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
    }
}


/// The last two minutes as a row of capsules: a quiet stretch is a row of dots, a
/// busy one stands up.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var bars = 20

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let thick = min(max((w - CGFloat(bars - 1) * 2) / CGFloat(bars), 2), 5)
            // Newest at the right; missing history on the left stays as faint dots.
            let padded = Array(repeating: -1.0, count: max(0, 60 - values.count)) + values.suffix(60)
            let per = max(padded.count / bars, 1)
            HStack(alignment: .bottom, spacing: (w - thick * CGFloat(bars)) / CGFloat(bars - 1)) {
                ForEach(0..<bars, id: \.self) { i in
                    let chunk = padded[(i * per)..<min((i + 1) * per, padded.count)].filter { $0 >= 0 }
                    let v = chunk.isEmpty ? -1 : chunk.reduce(0, +) / Double(chunk.count)
                    Capsule()
                        .fill(color.opacity(v < 0 ? 0.16 : 0.9))
                        .frame(width: thick, height: v < 0 ? thick : max(thick, CGFloat(v) * h))
                }
            }
            .frame(width: w, height: h, alignment: .bottom)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}


/// An x, then "Close?" in orange. Two presses to close anything.
struct CloseControl: View {
    @Environment(\.colorScheme) private var scheme
    let armed: Bool
    let allowed: Bool
    let warning: String?
    let arm: () -> Void
    let fire: () -> Void

    var body: some View {
        if !allowed {
            Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 20, height: 20)
        } else if armed {
            Button(action: fire) {
                Text(warning.map { "\($0) · Close?" } ?? "Close?")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Ink.hot, in: Capsule())
                    .fixedSize()
            }
            .buttonStyle(.plain)
        } else {
            Button(action: arm) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Ink.line(scheme)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}


/// A square that is either empty or filled: a checkbox drawn in the panel's own line.
struct Check: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isOn ? Color.primary : .clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? Color.primary : Color.primary.opacity(0.5), lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Ink.base)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A short row of values to pick one from.
struct Choice: View {
    @Environment(\.colorScheme) private var scheme
    let options: [Double]
    @Binding var value: Double
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button { value = option } label: {
                    Text(label(option))
                        .font(.system(size: 11, weight: value == option ? .semibold : .regular)).monospacedDigit()
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(value == option ? Ink.base : Color.secondary)
                        .padding(.horizontal, 7).frame(height: 21)
                        .background(value == option ? Color.primary : .clear, in: Capsule())
                        .overlay(Capsule(style: .circular).strokeBorder(value == option ? .clear : .white.opacity(0.2)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension View {
    /// The outline of a small button. White fills belong to a page's one main button.
    func pill() -> some View {
        padding(.horizontal, 9).frame(height: 20)
            .background(Capsule(style: .circular).strokeBorder(.white.opacity(0.28), lineWidth: 1))
            .contentShape(Capsule())
    }

    /// Every list that goes on past its edge fades there, instead of being cut.
    func scrollFade() -> some View {
        contentMargins(.bottom, 18, for: .scrollContent)
            .frame(maxHeight: .infinity)
            .mask(VStack(spacing: 0) { Rectangle(); LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18) })
    }
}

/// The white capsule at the bottom of a page: the one thing that page does.
struct MainButton: View {
    let title: String
    var value: String?
    var on = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if value == nil { Spacer() }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if let value { Text(value).font(.system(size: 12, design: .monospaced)) }
            }
            .foregroundStyle(Ink.base)
            .padding(.horizontal, 18).frame(height: 38)
            .background(Ink.ink(.dark).opacity(on ? 1 : 0.5), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle()).disabled(!on)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct PageHeader: View {
    let title: String
    var count: Int?
    /// Nil on a tab's own page.
    let back: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "arrow.left").font(.system(size: 10, weight: .medium))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Back")
            }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let count {
                Text("[\(count)]").font(.system(size: 14, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 2).frame(height: 32)
    }
}

struct SessionRow<Trailing: View>: View {
    let session: ClaudeSession
    let open: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    private var source: String {
        switch session.entrypoint {
        case "claude-desktop": return "Desktop"
        case "t3-code": return "T3"
        case "cli": return "CLI"
        default: return session.entrypoint
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain).help("What it is, and what can be done")
            trailing()
        }
        .frame(height: 32)
    }

    private var row: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isWaiting ? Ink.hot : session.isIdle ? Color.clear : Color.primary)
                .overlay(Circle().strokeBorder(Color.primary.opacity(session.isIdle ? 0.35 : 0), lineWidth: 1))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name.isEmpty ? session.project : session.name)
                    .font(.system(size: 12)).lineLimit(1)
                Text(session.waitingText.map { $0 + " · \(session.project)" }
                     ?? "\(session.project) · \(source)" + (session.isIdle ? " · idle \(Fmt.duration(session.idleSeconds(now: Date())))" : " · working"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !session.isWaiting { Text(Fmt.bytes(session.rssBytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
        }
    }
}

struct PlanRow: View {
    let suggestion: Suggestion
    @Binding var isOn: Bool

    private var cpu: String { String(format: "%.0f%%", suggestion.cpuPercent ?? 0) }

    private var what: String {
        switch suggestion.kind {
        case .idleSession:
            let idle = Fmt.duration(suggestion.idleSeconds ?? 0)
            guard suggestion.stillWorking else { return "Close a session idle for \(idle)" }
            return "Idle \(idle), but \(suggestion.busyChild ?? "something") still works (\(cpu) CPU)"
        case .runtime:
            let age = "open \(Fmt.duration(suggestion.idleSeconds ?? 0))"
            if suggestion.stillWorking { return "Working now (\(cpu) CPU) · closing stops that work" }
            let up = age + ", \(cpu) CPU"
            switch suggestion.runtimeKind {
            case .simulator: return "Shut down · " + up
            case .emulator: return "Shut down · " + up
            default: return "Stop · " + age + " · starts again on the next build"
            }
        case .orphan: return "Close a process a closed session left"
        case .heavyApp: return "Quit the app"
        case .advice: return suggestion.detail
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Check(title: suggestion.title, isOn: $isOn)
            Text(Fmt.bytes(suggestion.reclaimBytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            Text(what).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                .padding(.leading, 24).offset(y: 12)
        }
        .frame(height: 38, alignment: .top)
        .padding(.top, 2)
    }
}
