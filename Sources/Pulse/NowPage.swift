import PulseCore
import SwiftUI

/// The first page answers one question: is there anything to do? The score and the body, the four
/// figures, then what needs a person, the costliest first. One button does the closing.
struct NowPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let needs = model.needs
        hero(needs)
        Hairline().padding(.top, 2)
        figures
        Hairline()
        if let notice = model.notice {
            NoticeLine(text: notice)
        }
        if needs.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(model.snap == nil || model.health.report == nil ? "Checking…" : "Nothing needs you").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .frame(height: 20)
            TileLabel("Using the most")
            ForEach((model.snap?.topCPU ?? []).prefix(4)) { ConsumerRow(model: model, ui: ui, consumer: $0) }
            Spacer(minLength: 0)
        } else {
            TileLabel("Needs you", count: "\(needs.count)")
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(needs) { n in
                        NeedRow(need: n, open: { act(n, direct: false) }, press: { act(n, direct: true) }, later: n.id == "memory" || n.id == "heat" ? nil : { model.hide(n) }) { focus(n, $0) }
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    if needs.count < 3 {
                        TileLabel("Using the most").padding(.top, 6)
                        ForEach((model.snap?.topCPU ?? []).prefix(4)) { ConsumerRow(model: model, ui: ui, consumer: $0) }
                    }
                }
            }
            .scrollFade()
        }
    }

    /// A press leads to where the thing is dealt with. Nothing is closed, moved or changed from here.
    private func act(_ n: Need, direct: Bool) {
        switch n.place {
        case .session:
            guard direct, let s = model.snap?.sessions.first(where: { String($0.pid) == n.ref }) else { ui.go(.sessions); return }
            model.showHost(of: s)
        case .row: n.ref.map(ui.openRow)
        case .plan: ui.go(.plan)
        case .cleanup: ui.go(.cleanup)
        case .sleep: ui.go(.sleep)
        case .sessions: ui.go(.sessions)
        case .drives: if direct { model.connectDrives() }; ui.go(.drives)
        case .health:
            guard direct, let fix = model.health.problems.first(where: { $0.id == n.ref })?.fix else { ui.go(.health); return }
            switch fix {
            case .plan: ui.go(.plan)
            case .cleanup: ui.go(.cleanup)
            case .sleep: ui.go(.sleep)
            case .acceptStartup: ui.go(.startup)
            default: model.fix(fix)
            }
        }
    }

    /// The body turns the part a finding belongs to.
    private func focus(_ n: Need, _ inside: Bool) {
        let area = model.health.problems.first { n.place == .health && $0.id == n.ref }?.area
        model.scene.setFocus(inside ? area.flatMap { HealthArea.allCases.firstIndex(of: $0) } : nil, at: Model.clock)
    }

    // MARK: The body

    private func hero(_ needs: [Need]) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.health.score.map(String.init) ?? "–").font(.system(size: 46, weight: .semibold)).monospacedDigit().tracking(-1.5)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: model.health.score)
                    if model.health.score != nil { Text("/100").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let change = model.health.weekChange(now: Date()), change != 0 {
                        Text((change > 0 ? "+" : "") + "\(change)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .help("Against a week ago")
                    }
                }
                .frame(height: 44)
                Text(line(needs)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                mainButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.runHealthCheck(shown: true) } label: {
                BodyView(model: model).frame(width: 112, height: 112).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Press to check everything again")
            .accessibilityLabel("Check the health of this Mac")
        }
        .frame(height: 112)
    }

    private func line(_ needs: [Need]) -> String {
        if model.checking { return "Checking…" }
        guard model.health.report != nil else { return "Not checked yet" }
        let now = needs.filter { $0.level == .now }.count, soon = needs.filter { $0.level == .soon }.count
        if now > 0 { return "\(Plural.count(now, "thing")) cannot wait" }
        return soon > 0 ? "\(Plural.count(soon, "thing")) to look at" : "All good"
    }

    /// Always the one thing Pulse itself can do now.
    @ViewBuilder private var mainButton: some View {
        let chosen = model.defaults, bytes = chosen.reduce(0) { $0 + $1.reclaimBytes }
        let closes = !model.actionable.isEmpty
        Button { if closes { ui.go(.plan) } else { model.runHealthCheck(shown: true) } } label: {
            HStack(spacing: 7) {
                Text(closes ? "Optimize" : "Check now").font(.system(size: 12, weight: .semibold))
                if closes, bytes > 0 { Text(Fmt.bytes(bytes)).font(.system(size: 11, weight: .medium, design: .monospaced)).opacity(0.65) }
            }
            .foregroundStyle(Ink.base)
            .padding(.horizontal, 13).frame(height: 28)
            .background(Ink.ink(.dark), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle()).disabled(!closes && model.checking)
        .help(closes ? "See what can be closed. Nothing is closed before you confirm." : "Check the health of this Mac")
    }

    private var figures: some View {
        let s = model.system
        return HStack(spacing: 0) {
            Button { ui.activity(.cpu) } label: { Metric("CPU", String(format: "%.0f%%", s.cpuPercent), hot: s.cpuPercent >= 85) }.buttonStyle(PressStyle())
            Button { ui.activity(.memory) } label: { Metric("Memory", String(format: "%.0f%%", s.memPercent), hot: s.memPressureLevel >= 2) }.buttonStyle(PressStyle())
                .help("\(Fmt.bytes(s.memUsedBytes)) of \(Fmt.bytes(s.memTotalBytes)). Pressure \(s.memPressureLevel >= 4 ? "critical" : s.memPressureLevel >= 2 ? "high" : "normal"), swap \(Fmt.bytes(s.swapUsedBytes))")
            // An Intel Mac has no readable sensor.
            if let t = s.chipTempC {
                Button { ui.activity(.hours) } label: { Metric("Chip heat", String(format: "%.0f°", t), hot: s.thermal == "serious" || s.thermal == "critical") }.buttonStyle(PressStyle())
            } else if let g = s.gpuPercent {
                Button { ui.activity(.cpu) } label: { Metric("GPU", String(format: "%.0f%%", g), hot: false) }.buttonStyle(PressStyle())
            }
            Button { ui.go(.disk) } label: { Metric("Disk free", Fmt.drive(s.diskFreeBytes), hot: s.diskUsedPercent >= 95) }.buttonStyle(PressStyle())
        }
        .frame(height: 34)
    }
}

struct NoticeLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 7) {
            Capsule().fill(Ink.ink(.dark)).frame(width: 3, height: 11)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 16).help(text)
    }
}

/// What it is, how we know, and the word for what happens next.
private struct NeedRow: View {
    let need: Need
    let open: () -> Void
    let press: () -> Void
    let later: (() -> Void)?
    let hover: (Bool) -> Void
    @State private var inside = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Capsule().fill(need.level == .now ? Ink.hot : Ink.ink(.dark).opacity(need.level == .soon ? 1 : 0.3)).frame(width: 3, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(need.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(need.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if inside, let later {
                Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.85), later) } label: {
                    Text("Not today").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize().contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Back tomorrow, if it is still so")
            }
            Button(action: press) {
                Text(need.verb).font(.system(size: 10, weight: .semibold)).fixedSize().pill()
            }
            .buttonStyle(PressStyle())
        }
        .frame(height: 38)
        .onHover { inside = $0; hover($0) }
        .help(need.title + (need.detail.isEmpty ? "" : "\n" + need.detail))
        .contextMenu { if let later { Button("Not today", action: later) } }
        .accessibilityElement(children: .contain)
    }
}

struct WelcomePage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState
    @State private var wantsAlerts = true
    @State private var wantsLogin = true

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            BodyView(model: model).frame(width: 98, height: 98)
            Spacer()
        }
        Text("Pulse lives in the menu bar").font(.system(size: 17, weight: .semibold)).padding(.horizontal, 2)
        VStack(alignment: .leading, spacing: 9) {
            point("list.bullet", "What needs you comes first, with the way to deal with it")
            point("hand.raised", "Nothing is closed until you press it twice, or tick it and confirm")
            point("lock", "Everything stays on this Mac. Pulse has no network code")
        }
        .tile()
        VStack(alignment: .leading, spacing: 9) {
            Check(title: "Open at login", isOn: $wantsLogin)
            Check(title: "Silent alerts when something is wrong", isOn: $wantsAlerts)
        }
        .tile()
        if !AppInfo.isInApplications {
            Text("Move Pulse to the Applications folder first, then open it from there.")
                .font(.system(size: 11)).foregroundStyle(Ink.hot).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        Spacer(minLength: 0)
        MainButton(title: "Start") {
            model.finishWelcome(notify: wantsAlerts, atLogin: wantsLogin)
            ui.go(.overview)
        }
        .keyboardShortcut(.defaultAction)
        .padding(.bottom, 9)
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 15)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
