import AppKit
import PulseCore
import SwiftUI

enum Page: String { case welcome, overview, health, cleanup, plan, done, sessions, processes, rules, alerts, display, drives }

/// The look: always dark. Near-black ground, white ink, one-pixel lines instead of boxes,
/// whole-point type sizes. Drawings are capsules and dots. Orange only for something urgent
/// or about to be closed. Counts sit in brackets. No emoji, no decorative numbers.
enum Ink {
    static let base = Color(red: 0.031, green: 0.031, blue: 0.035)
    static func ground(_ s: ColorScheme) -> Color { base }
    static func tile(_ s: ColorScheme) -> Color { Color(red: 0.075, green: 0.075, blue: 0.082) }
    /// The drawing colour, and the fill of a main button; `base` is written on it.
    static func ink(_ s: ColorScheme) -> Color { Color(red: 0.965, green: 0.965, blue: 0.970) }
    static func line(_ s: ColorScheme) -> Color { .white.opacity(0.11) }
    static let hot = Color(red: 1.0, green: 0.420, blue: 0.110)
    /// Cards. Buttons are capsules; the window itself is rounder than both.
    static let radius: CGFloat = 14
    static let window: CGFloat = 24
}

private let gap: CGFloat = 6
private let contentWidth: CGFloat = 288
private let panelHeight: CGFloat = 440

struct PanelView: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    @State private var page: Page
    @State private var selected: Set<String>
    @State private var byMemory = false
    @State private var filter = ""
    @State private var armed: String?
    @State private var newWord = ""
    @State private var toClean: Set<String> = []

    @State private var wantsAlerts = true
    @State private var wantsLogin = true
    @State private var copied = false
    private let inWindow: Bool

    static let goTo = Notification.Name("pulse.goto")

    init(model: Model, page: Page? = nil, inWindow: Bool = false) {
        self.model = model
        self.inWindow = inWindow
        let page = page ?? (model.settings.welcomed || !model.drawsLive ? .overview : .welcome)
        _page = State(initialValue: page)
        _selected = State(initialValue: model.defaultSelection())
    }

    var body: some View {
        // One size for every page: the window never resizes, so a change of page is only
        // a change of content.
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: gap) {
                switch page {
                case .welcome: welcome
                case .overview: overview
                case .health: healthPage
                case .cleanup: cleanupPage
                case .plan: plan
                case .done: done
                case .sessions: sessions
                case .processes: processes
                case .rules: ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: gap) { rules } }
                case .drives: drivesPage
                case .alerts: ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: gap) { alerts } }
                case .display: ScrollView(showsIndicators: false) { VStack(alignment: .leading, spacing: gap) { display } }
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 16).padding(.vertical, 15).padding(.top, inWindow ? 16 : 0)
        .frame(width: contentWidth + 32, height: panelHeight + (inWindow ? 16 : 0))
        .foregroundStyle(Ink.ink(.dark))
        .background(Ink.base)
        .background { if !inWindow { WindowShape() } }
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, .leftToRight)
        .onReceive(NotificationCenter.default.publisher(for: Self.goTo)) { n in
            if let next = (n.object as? String).flatMap(Page.init(rawValue:)) { go(next) }
        }
        .onAppear { model.opened() }
        .onDisappear { model.closed(); toClean = []; if page != .welcome { page = .overview }; armed = nil }
    }

    private var suggestions: [Suggestion] { model.snap?.suggestions ?? [] }
    /// What the rules tick comes first, then the biggest: 10 GB of simulator is not left under the fold.
    private var actionable: [Suggestion] {
        suggestions.filter { $0.kind != .advice }.sorted {
            let a = model.settings.preselects($0), b = model.settings.preselects($1)
            return a != b ? a : $0.reclaimBytes > $1.reclaimBytes
        }
    }
    private var isClean: Bool { model.snap != nil && actionable.isEmpty }
    private var defaults: [Suggestion] { suggestions.filter { model.settings.preselects($0) } }

    // MARK: Welcome

    private var welcome: some View {
        Group {
            HStack(spacing: 0) {
                Spacer()
                BodyView(model: model).frame(width: 118, height: 118)
                Spacer()
            }
            Text("Pulse lives in the menu bar").font(.system(size: 17, weight: .semibold)).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 9) {
                point("waveform.path.ecg", "What this Mac is doing, and how it is")
                point("hand.raised", "Nothing is closed until you press it twice, or tick it and confirm")
                point("lock", "Everything stays on this Mac. Pulse has no network code")
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                Check(title: "Open at login", isOn: $wantsLogin)
                Check(title: "Alert me, silently, when something needs care", isOn: $wantsAlerts)
            }
            .tile()
            if !AppInfo.isInApplications {
                Text("Move Pulse to the Applications folder first, then open it from there.")
                    .font(.system(size: 11)).foregroundStyle(Ink.hot).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
            Button {
                model.finishWelcome(notify: wantsAlerts, atLogin: wantsLogin)
                go(.overview)
            } label: {
                Text("Start").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.base)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Ink.ink(scheme), in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(PressStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 15)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Overview

    private var overview: some View {
        let s = model.system
        return Group {
            hero
            Hairline()
            HStack(spacing: 0) {
                Button { byMemory = false; filter = ""; go(.processes) } label: {
                    Metric("CPU", String(format: "%.0f%%", s.cpuPercent), hot: s.cpuPercent >= 85)
                }
                .buttonStyle(PressStyle())
                Button { byMemory = true; filter = ""; go(.processes) } label: {
                    Metric("Memory", String(format: "%.0f%%", s.memPercent), hot: s.memPressureLevel >= 2)
                }
                .buttonStyle(PressStyle())
                // An Intel Mac has no readable sensor, and not every Mac has Claude Code.
                if let t = s.chipTempC {
                    Metric("Heat", String(format: "%.0f°", t), hot: s.thermal == "serious" || s.thermal == "critical")
                }
                if model.hasClaude {
                    Button { go(.sessions) } label: { Metric("Sessions", "\(model.snap?.sessions.count ?? 0)", hot: false) }
                        .buttonStyle(PressStyle())
                }
                if s.chipTempC == nil || !model.hasClaude {
                    Metric("Disk", String(format: "%.0f%%", s.diskUsedPercent), hot: s.diskUsedPercent >= 95)
                }
            }
            .frame(height: 36)
            optimizeTile
            if let line = model.notice ?? model.snap?.headline {
                // One line of text; the whole of it on hover.
                let urgent = model.notice == nil && s.memPressureLevel >= 2
                HStack(spacing: 7) {
                    Capsule().fill(urgent ? Ink.hot : Ink.ink(scheme)).frame(width: 3, height: 11)
                    Text(line).font(.system(size: 11)).foregroundStyle(urgent ? Color.primary : Color.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 16)
                .help(line)
            }
            VStack(alignment: .leading, spacing: 2) {
                let rows = Array(((byMemory ? model.snap?.topMemory : model.snap?.topCPU) ?? []).prefix(model.notice == nil && model.snap?.headline == nil ? 4 : 3))
                if rows.isEmpty { Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(rows) { consumerRow($0) }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            Hairline()
            HStack(spacing: 4) {
                Button { filter = ""; go(.processes) } label: {
                    HStack(spacing: 5) {
                        Text("All processes").font(.system(size: 11, weight: .medium))
                        Text("[\(model.snap?.consumers.count ?? 0)]").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                Spacer()
                IconButton(icon: "externaldrive", title: "Drives in sleep") { go(.drives) }
                IconButton(icon: "slider.horizontal.3", title: "Rules") { go(.rules) }
                IconButton(icon: "bell", title: "Alerts") { go(.alerts) }
                IconButton(icon: "menubar.rectangle", title: "Settings") { go(.display) }
            }
            .frame(height: 24)
        }
    }

    private func go(_ next: Page) {
        model.notice = nil
        withAnimation(.easeOut(duration: 0.16)) { page = next }
    }

    // MARK: The body

    /// The Mac as a body of dots, its score, and the eight areas under it.
    private var hero: some View {
        let problems = model.health.problems
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.health.score.map(String.init) ?? "–").font(.system(size: 48, weight: .semibold)).monospacedDigit().tracking(-1.5)
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: model.health.score)
                        if let change = model.health.weekChange(now: Date()), change != 0 {
                            Text((change > 0 ? "+" : "") + "\(change)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 46)
                    Text(healthLine).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { if problems.isEmpty { model.runHealthCheck(shown: true) } else { go(.health) } } label: {
                        Text(problems.isEmpty ? "Check now" : "What to fix").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Ink.base)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Ink.ink(scheme), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressStyle()).disabled(model.checking)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.runHealthCheck(shown: true) } label: {
                    BodyView(model: model).frame(width: 130, height: 130).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Press to check everything again")
                .accessibilityLabel("Check the health of this Mac")
            }
            .frame(height: 130)

            HStack(spacing: 0) {
                ForEach(Array(HealthArea.allCases.enumerated()), id: \.element) { i, area in
                    AreaMark(title: area.title, state: model.health.state(of: area)) { inside in
                        model.scene.setFocus(inside ? i : nil, at: Model.clock)
                    } action: { go(.health) }
                }
            }
        }
    }

    private var healthLine: String {
        if model.checking { return "Checking…" }
        guard model.health.report != nil else { return "Not checked yet" }
        let n = model.health.problems.count
        let urgent = model.health.problems.filter { $0.state == .urgent }.count
        if n == 0 { return "All good" }
        let count = "\(Plural.count(n, "thing")) to fix"
        return urgent == 0 || n == urgent ? count : count + ", \(urgent) urgent"
    }

    private var checkedAgo: String {
        let age = model.healthAge(now: Date())
        return age == .infinity ? "Not checked yet" : age < 90 ? "Checked just now" : "Checked \(Fmt.duration(age)) ago"
    }

    // MARK: Health

    private var healthPage: some View {
        let problems = model.health.problems
        let checks = model.health.report?.checks ?? []
        let ignored = checks.filter { $0.isProblem && model.health.ignored.contains($0.id) }
        let good = checks.filter { $0.state == .ok }
        return Group {
            PageHeader(title: "Mac health", count: problems.count) { go(.overview) }
            ScrollView {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(problems) { c in
                        ProblemCard(check: c, fix: { f in
                            switch f {
                            case .cleanup: toClean = []; go(.cleanup)
                            case .plan: selected = model.defaultSelection(); go(.plan)
                            default: model.fix(f)
                            }
                        }, ignore: { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.ignore(c, true) } })
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    if !model.health.unknowns.isEmpty { plainList("Could not check", model.health.unknowns, mark: "questionmark") }
                    if !good.isEmpty { plainList("Fine", good, mark: "checkmark") }
                    if !ignored.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            TileLabel("Ignored", count: "\(ignored.count)")
                            ForEach(ignored) { c in
                                HStack {
                                    Text(c.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button("Restore") { model.ignore(c, false) }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                                }
                            }
                        }
                        .tile()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: gap) {
                MenuTile(icon: "arrow.clockwise", title: model.checking ? "Checking…" : "Check again") { go(.overview); model.runHealthCheck(shown: true) }
                MenuTile(icon: "shippingbox", title: "What can go") { toClean = []; go(.cleanup) }
            }
            .frame(height: 38)
            Text(model.notice ?? "\(checkedAgo). Runs by itself every six hours. Pulse changes no settings, it opens the right place.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func plainList(_ title: String, _ list: [HealthCheck], mark: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TileLabel(title, count: "\(list.count)")
            ForEach(list) { c in
                HStack(spacing: 8) {
                    Image(systemName: mark).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    Text(c.title).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(c.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .help(c.detail)
            }
        }
        .tile()
    }

    // MARK: Cleanup

    private var cleanupPage: some View {
        let items = model.health.report?.cleanup ?? []
        let chosen = items.filter { toClean.contains($0.id) && $0.blockedBy == nil }
        let bytes = chosen.reduce(0) { $0 + $1.bytes }
        return Group {
            PageHeader(title: "What can be cleared", count: items.count) { go(.health) }
            Text("Only things that are rebuilt or downloaded again. Everything goes to the Trash and can be put back. What is in use is locked.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            if items.isEmpty {
                Text("Nothing to clear right now").font(.system(size: 12)).foregroundStyle(.secondary).tile()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            CleanRow(item: item, isOn: Binding(
                                get: { toClean.contains(item.id) && item.blockedBy == nil },
                                set: { if $0 { toClean.insert(item.id) } else { toClean.remove(item.id) } }))
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 38, 266))
                .tile()
                Button { model.clean(chosen); toClean = []; go(.overview) } label: {
                    HStack {
                        Text(chosen.isEmpty ? "Nothing selected" : "Move to Trash").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !chosen.isEmpty { Text(Fmt.bytes(bytes)).font(.system(size: 12, design: .monospaced)) }
                    }
                    .foregroundStyle(Ink.base)
                    .padding(.horizontal, 18).frame(height: 40)
                    .background(chosen.isEmpty ? Ink.ink(scheme).opacity(0.35) : Ink.ink(scheme), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle()).disabled(chosen.isEmpty || model.cleaning)
            }
        }
    }

    // MARK: Drives

    private var drivesPage: some View {
        let rows = model.drives ?? []
        return Group {
            PageHeader(title: "Drives in sleep", count: rows.count) { go(.overview) }
            Text("A ticked drive is disconnected just before the Mac sleeps and comes back when it wakes. The others are left alone.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            if rows.isEmpty {
                Text(model.drives == nil ? "Checking…" : "No external drive is connected").font(.system(size: 12)).foregroundStyle(.secondary).tile()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            DriveRow(row: row, owed: model.drivesOut.contains { $0.id == row.id },
                                     isOn: Binding(get: { model.settings.sleepDrives.contains { $0.id == row.id } },
                                                   set: { model.setDrive(row, $0) }),
                                     connect: { model.connectDrives() })
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count) * 40, 240))
                .tile()
            }
            Spacer(minLength: 0)
            Text("A drive in use stays connected and you are told which app holds it. Nothing is forced. A closed lid with an external display does not put the Mac to sleep, so nothing is disconnected then.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .onAppear { model.refreshDrives() }
    }

    private var optimizeTile: some View {
        let bytes = defaults.reduce(0) { $0 + $1.reclaimBytes }
        return Button {
            selected = model.defaultSelection()
            go(.plan)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isClean ? "Nothing to close" : "Optimize").font(.system(size: 13, weight: .semibold))
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !isClean, bytes > 0 { Text(Fmt.bytes(bytes)).font(.system(size: 12, weight: .medium, design: .monospaced)) }
                Image(systemName: isClean ? "checkmark" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15).frame(height: 46)
            .background(Ink.tile(scheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(isClean ? 0.11 : 0.28), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(isClean)
        .help(summary)
    }

    private var summary: String {
        if model.snap == nil { return "Checking…" }
        if isClean { return "Everything is in use" }
        // What the user may add by hand: simulators, emulators, sessions under the rule.
        let optional = actionable.filter { !model.settings.preselects($0) && $0.kind != .heavyApp }
        let more = optional.reduce(0) { $0 + $1.reclaimBytes }
        let idle = defaults.filter { $0.kind == .idleSession }.count
        let orphans = defaults.filter { $0.kind == .orphan }.count
        var parts: [String] = []
        if idle > 0 { parts.append(Plural.count(idle, "idle session")) }
        if orphans > 0 { parts.append(Plural.count(orphans, "leftover")) }
        if parts.isEmpty {
            return more >= 1 << 30 ? "Up to \(Fmt.bytes(more)) to choose from"
                : "Press to see what can be closed"
        }
        return "Closes " + parts.joined(separator: " and ")
    }

    /// One row of "what is running", with its own close control. The first press arms
    /// it, the second closes: nothing is closed by a single slip of the pointer.
    private func consumerRow(_ c: Consumer, decimals: Bool = false) -> some View {
        HStack(spacing: 8) {
            Glyph(kind: c.kind == .session ? .lines : c.kind == .app ? .block : c.kind == .runtime ? .cross : .slash)
            (Text(c.name) + Text(c.processCount > 1 && c.kind != .session ? "  ×\(c.processCount)" : "").foregroundColor(.secondary))
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text(byMemory ? Fmt.bytes(c.rssBytes) : String(format: decimals ? "%.1f%%" : "%.0f%%", c.cpuPercent))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            CloseControl(
                armed: armed == c.id, allowed: model.mayClose(c),
                warning: model.hostsSessions(c) ? "Runs sessions"
                    : model.snap?.runtimes.first { $0.id == c.runtimeID }?.working == true ? "Working" : nil,
                arm: {
                    armed = c.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == c.id { armed = nil } }
                },
                fire: { armed = nil; model.close(c) })
        }
        .frame(height: 20)
    }

    // MARK: Plan

    private var plan: some View {
        let chosen = actionable.filter { selected.contains($0.id) }
        let bytes = chosen.reduce(0) { $0 + $1.reclaimBytes }
        return Group {
            PageHeader(title: "What Optimize will do") { go(.overview) }
            Text("Only ticked rows are closed. A working session is never closed, nor is an app that runs sessions. Closing a session stops its process; the conversation stays on disk.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            ForEach(suggestions.filter { $0.kind == .advice }) { a in
                Label(a.title + ": " + a.detail, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(Ink.hot)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(actionable) { s in
                        PlanRow(suggestion: s, isOn: Binding(
                            get: { selected.contains(s.id) },
                            set: { if $0 { selected.insert(s.id) } else { selected.remove(s.id) } }))
                    }
                }
            }
            .frame(height: min(CGFloat(max(actionable.count, 1)) * 38, 228))
            .tile()
            Button {
                model.run(chosen)
                go(.done)
            } label: {
                HStack {
                    Text(chosen.isEmpty ? "Nothing selected" : "Close \(Plural.count(chosen.count, "row"))").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !chosen.isEmpty { Text(Fmt.bytes(bytes)).font(.system(size: 12, design: .monospaced)) }
                }
                .foregroundStyle(Ink.base)
                .padding(.horizontal, 18).frame(height: 40)
                .background(chosen.isEmpty ? Ink.ink(scheme).opacity(0.35) : Ink.ink(scheme), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(chosen.isEmpty)
        }
    }

    // MARK: Result

    private var done: some View {
        let r = model.result
        let lines = r?.lines ?? []
        return Group {
            PageHeader(title: "What was done") { go(.overview) }
            VStack(alignment: .leading, spacing: 4) {
                TileLabel(r?.running == true ? "Working…" : "Done", count: r?.running == true ? nil : "\(lines.filter(\.ok).count)/\(lines.count)")
                if r?.running == true {
                    Text("Shutting down a simulator takes a few seconds.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let r, let after = r.memAfter {
                    Text("Memory in use: \(Fmt.bytes(r.memBefore)) before, \(Fmt.bytes(after)) after")
                        .font(.system(size: 12))
                } else {
                    Text("Measuring memory…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .tile()
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: line.ok ? "checkmark" : "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(line.ok ? Color.primary : Ink.hot)
                            Text(line.text).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(max(lines.count, 1)) * 26, 260))
            .tile()
        }
    }

    // MARK: Sessions

    private var sessions: some View {
        let list = model.snap?.sessions ?? []
        return Group {
            PageHeader(title: "Claude sessions", count: list.count) { go(.overview) }
            if list.isEmpty {
                Text("No open sessions").font(.callout).foregroundStyle(.secondary).tile()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(list) { session in
                            let consumer = model.snap?.consumers.first { $0.kind == .session && $0.members.first?.pid == session.pid }
                            SessionRow(session: session) {
                                if let consumer {
                                    CloseControl(
                                        armed: armed == consumer.id, allowed: model.mayClose(consumer),
                                        warning: session.isIdle ? nil : "Working",
                                        arm: {
                                            armed = consumer.id
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if armed == consumer.id { armed = nil } }
                                        },
                                        fire: { armed = nil; model.close(consumer) })
                                }
                            }
                        }
                    }
                }
                .frame(height: min(CGFloat(list.count) * 38, 342))
                .tile()
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    // MARK: All processes

    private var processes: some View {
        let all = model.snap?.consumers ?? []
        let shown = all
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted { byMemory ? $0.rssBytes > $1.rssBytes : $0.cpuPercent > $1.cpuPercent }
        return Group {
            PageHeader(title: "All processes", count: shown.count) { go(.overview) }
            HStack(spacing: 10) {
                TextField("Search", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 12))
                Spacer(minLength: 0)
                SortSwitch(byMemory: $byMemory)
            }
            .tile(padding: 9)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(shown) { consumerRow($0, decimals: true) }
                }
            }
            .frame(maxHeight: .infinity)
            .tile()
            Text(model.notice ?? "Processes with the same name share a row. Press x and then Close to close the whole row.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    // MARK: Rules

    private var rules: some View {
        Group {
            PageHeader(title: "Rules") { go(.overview) }
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Ticked in advance in Optimize")
                HStack {
                    Text("Session idle over (hours)").font(.system(size: 12))
                    Spacer()
                    Choice(options: [1, 3, 6, 12, 24], value: $model.settings.autoSelectIdleHours) { "\(Int($0))" }
                }
                Check(title: "Processes left by closed sessions", isOn: $model.settings.includeLeftovers)
            }
            .tile()

            VStack(alignment: .leading, spacing: 8) {
                TileLabel("Never touch")
                Text("A name with one of these words is never offered and never closed, not even by hand.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(model.settings.neverTouch, id: \.self) { word in
                    HStack {
                        Text(word).font(.system(size: 12))
                        Spacer()
                        Button { model.settings.neverTouch.removeAll { $0 == word } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 20, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    TextField("For example Docker or qemu", text: $newWord)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(newWord.trimmingCharacters(in: .whitespaces).isEmpty ? .tertiary : .primary)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Ink.line(scheme)))
            }
            .tile()

            Text("Always protected, whatever the rules: Finder, Dock, WindowServer and the other core parts of macOS, and Pulse itself.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !model.settings.neverTouch.contains(word) else { return }
        model.settings.neverTouch.append(word)
        newWord = ""
    }

    // MARK: Alerts

    private var alerts: some View {
        Group {
            PageHeader(title: "Alerts") { go(.overview) }
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("CPU")
                Check(title: "When something uses a lot of CPU", isOn: $model.settings.alertCPU)
                HStack {
                    Text("Over").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Choice(options: [20, 30, 40, 60], value: $model.settings.alertCPUPercent) { "\(Int($0))%" }
                }
                HStack {
                    Text("For").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Choice(options: [5, 10, 20, 30], value: $model.settings.alertCPUMinutes) { "\(Int($0)) min" }
                }
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Heat")
                Check(title: "When the chip is hot", isOn: $model.settings.alertTemp)
                HStack {
                    Text("Over").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Choice(options: [80, 85, 90, 95], value: $model.settings.alertTempC) { "\(Int($0))°" }
                }
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Memory")
                Check(title: "When memory comes under pressure", isOn: $model.settings.alertMemory)
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Health")
                Check(title: "When a check finds something new", isOn: $model.settings.alertHealth)
            }
            .tile()
            HStack {
                Text(model.notice ?? (model.notificationsAllowed == false
                    ? "macOS is blocking notifications from Pulse. Allow them in System Settings, Notifications."
                    : "Silent. At most once every half hour."))
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Test") { model.requestNotifications(); model.sendTestAlert() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: Display

    private var display: some View {
        Group {
            PageHeader(title: "Settings") { go(.overview) }
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("In the menu bar")
                Check(title: "CPU", isOn: $model.settings.barCPU)
                Check(title: "Memory", isOn: $model.settings.barMemory)
                if model.system.chipTempC != nil { Check(title: "Heat", isOn: $model.settings.barTemp) }
                if model.hasClaude { Check(title: "Number of sessions", isOn: $model.settings.barSessions) }
                Rectangle().fill(Ink.line(scheme)).frame(height: 1)
                HStack {
                    Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.barText.isEmpty ? "Icon only" : model.barText)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("For agents")
                Text("Pulse is also a read-only MCP server: an agent can see this Mac, and cannot close or change anything.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                line(copied ? "Copied" : "Copy the Claude Code command", icon: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppInfo.mcpCommand, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
            }
            .tile()
            VStack(alignment: .leading, spacing: 9) {
                TileLabel("Pulse \(AppInfo.version)")
                Check(title: "Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Rectangle().fill(Ink.line(scheme)).frame(height: 1)
                line("Source and updates", icon: "arrow.up.right") { NSWorkspace.shared.open(AppInfo.releases) }
                Rectangle().fill(Ink.line(scheme)).frame(height: 1)
                line("Quit Pulse", icon: "power") { NSApplication.shared.terminate(nil) }
            }
            .tile()
        }
    }
}

private func line(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
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

// MARK: Pieces

/// Rounds the menu bar window itself. macOS draws a plate behind the panel, so the window's
/// own frame is masked, not only the content.
private struct WindowShape: NSViewRepresentable {
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

private struct Hairline: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1) }
}

private struct Metric: View {
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

private struct IconButton: View {
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

/// An area of health under the body: a capsule that is short and pale when fine, and
/// stands up when something needs care.
private struct AreaMark: View {
    let title: String
    let state: HealthState
    let hover: (Bool) -> Void
    let action: () -> Void
    @State private var inside = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Capsule()
                    .fill(state == .urgent ? Ink.hot : Ink.ink(.dark).opacity(state == .attention ? 1 : state == .unknown ? 0.16 : 0.42))
                    .frame(width: 5, height: inside ? 18 : state == .urgent || state == .attention ? 14 : 5)
                    .frame(height: 18, alignment: .bottom)
                Text(title).font(.system(size: 9)).lineLimit(1).fixedSize()
                    .opacity(inside || state == .urgent || state == .attention ? 1 : 0.55)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { inside = h }
            hover(h)
        }
        .accessibilityLabel(title)
    }
}

private struct ProblemCard: View {
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

private struct CleanRow: View {
    let item: CleanupItem
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Check(title: item.title, isOn: $isOn)
            if item.blockedBy != nil { Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Text(Fmt.bytes(item.bytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        .opacity(item.blockedBy == nil ? 1 : 0.55)
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

private struct DriveRow: View {
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
private struct TileLabel: View {
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

private struct BigNumber: View {
    let text: String
    let hot: Bool
    init(_ text: String, hot: Bool) { self.text = text; self.hot = hot }
    var body: some View {
        Text(text).font(.system(size: 30, weight: .regular)).monospacedDigit()
            .foregroundStyle(hot ? Ink.hot : Color.primary).lineLimit(1).fixedSize()
    }
}

private struct MidNumber: View {
    let text: String
    let hot: Bool
    init(_ text: String, hot: Bool) { self.text = text; self.hot = hot }
    var body: some View {
        Text(text).font(.system(size: 20, weight: .regular)).monospacedDigit()
            .foregroundStyle(hot ? Ink.hot : Color.primary).lineLimit(1).fixedSize()
    }
}

/// Eight capsules in a ring, lit clockwise from the top by the used share.
private struct Ring: View {
    @Environment(\.colorScheme) private var scheme
    let fraction: Double
    let hot: Bool
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let lit = Int((min(max(fraction, 0), 1) * 8).rounded())
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    Capsule()
                        .fill(i < lit ? (hot ? Ink.hot : Ink.ink(scheme)) : Ink.ink(scheme).opacity(0.16))
                        .frame(width: side * 0.27, height: side * 0.135)
                        .offset(y: -side * 0.43)
                        .rotationEffect(.degrees(Double(i) * 45 + 22.5))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

/// The small mark before a row: what kind of thing it is, drawn in capsules.
struct Glyph: View {
    enum Kind { case lines, slash, cross, block }
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

/// One dot per session; the filled ones are working.
private struct Dots: View {
    @Environment(\.colorScheme) private var scheme
    let total: Int
    let lit: Int
    var body: some View {
        let shown = min(total, 12)
        let columns = Array(repeating: GridItem(.fixed(5), spacing: 3), count: 4)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
            ForEach(0..<shown, id: \.self) { i in
                Circle()
                    .fill(i < lit ? Ink.ink(scheme) : Ink.ink(scheme).opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 29)
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

/// CPU / Memory, as two words rather than a system control.
private struct SortSwitch: View {
    @Binding var byMemory: Bool
    var body: some View {
        HStack(spacing: 10) {
            word("CPU", on: !byMemory) { byMemory = false }
            word("Memory", on: byMemory) { byMemory = true }
        }
    }

    private func word(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) { Rectangle().fill(on ? Color.primary : .clear).frame(height: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An x, then "Close?" in orange. Two presses to close anything.
private struct CloseControl: View {
    @Environment(\.colorScheme) private var scheme
    let armed: Bool
    let allowed: Bool
    let warning: String?
    let arm: () -> Void
    let fire: () -> Void

    var body: some View {
        if !allowed {
            Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 20, height: 20)
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

private struct MenuTile: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .tile(padding: 10)
        }
        .buttonStyle(.plain)
    }
}

/// A square that is either empty or filled: a checkbox drawn in the panel's own line.
private struct Check: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isOn ? Color.primary : .clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(isOn ? Color.primary : Color.primary.opacity(0.3), lineWidth: 1)
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
private struct Choice: View {
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
                        .overlay(Capsule().strokeBorder(value == option ? .clear : Ink.line(scheme)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct PageHeader: View {
    let title: String
    var count: Int?
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "arrow.left").font(.system(size: 10, weight: .medium))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let count {
                Text("[\(count)]").font(.system(size: 14, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 2).padding(.vertical, 3)
    }
}

private struct SessionRow<Trailing: View>: View {
    let session: ClaudeSession
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
            Circle()
                .fill(session.isIdle ? Color.clear : Color.primary)
                .overlay(Circle().strokeBorder(Color.primary.opacity(session.isIdle ? 0.35 : 0), lineWidth: 1))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name.isEmpty ? session.project : session.name)
                    .font(.system(size: 12)).lineLimit(1)
                Text("\(session.project) · \(source)" + (session.isIdle ? " · idle \(Fmt.duration(session.idleSeconds(now: Date())))" : " · working"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Fmt.bytes(session.rssBytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            trailing()
        }
        .frame(height: 32)
    }
}

private struct PlanRow: View {
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
