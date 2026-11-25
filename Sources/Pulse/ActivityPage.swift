import PulseCore
import SwiftUI

/// What is running: the live figures, then every row, now or over twelve hours, or by its open port.
struct ActivityPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState
    @FocusState private var searching: Bool
    @State private var everything = false
    /// What is not in the first forty does close to nothing. Search looks through all of them.
    private static let first = 40

    var body: some View {
        let all = model.snap?.consumers ?? []
        strip
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Search", text: $ui.filter).textFieldStyle(.plain).font(.system(size: 12)).focused($searching)
            if !ui.filter.isEmpty {
                Button { ui.filter = "" } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 14, height: 14).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
            Spacer(minLength: 0)
            ForEach(Sort.allCases, id: \.self) { s in
                Button { ui.sort = s } label: {
                    Text(s.title).font(.system(size: 10, weight: ui.sort == s ? .semibold : .regular))
                        .foregroundStyle(ui.sort == s ? Color.primary : Color.secondary).fixedSize()
                        .padding(.bottom, 2)
                        .overlay(alignment: .bottom) { Rectangle().fill(ui.sort == s ? Color.primary : .clear).frame(height: 1) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .tile(padding: 9)
        ScrollView {
            LazyVStack(spacing: 4) {
                switch ui.sort {
                case .cpu, .memory:
                    let rows = shown(all)
                    ForEach(everything || !ui.filter.isEmpty ? rows[...] : rows.prefix(Self.first)) { ConsumerRow(model: model, ui: ui, consumer: $0, armed: ui.armed == $0.id, byMemory: ui.sort == .memory, decimals: true) }
                    if !everything, ui.filter.isEmpty, rows.count > Self.first {
                        line("All \(rows.count)", icon: "chevron.down") { everything = true }.foregroundStyle(.secondary).frame(height: 24)
                    }
                case .hours: ForEach(past) { pastRow($0, all) }
                case .ports: ports
                }
            }
        }
        .scrollFade()
        .tile()
        .task(id: ui.sort) { if ui.sort == .ports { model.refreshPorts() } }
        Text(model.notice ?? note(all.count)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }

    private var strip: some View {
        let s = model.system
        return HStack(spacing: gap) {
            Meter("CPU", String(format: "%.0f%%", s.cpuPercent), model.cpuHistory, hot: s.cpuPercent >= 85)
            Meter("Memory", Fmt.short(s.memUsedBytes), model.memHistory, hot: s.memPressureLevel >= 2)
            if let g = s.gpuPercent { Meter("GPU", String(format: "%.0f%%", g), model.gpuHistory, hot: false) }
            if let d = s.netDown, let u = s.netUp {
                Meter("Network", Fmt.rate(d + u), model.netHistory, hot: false).help("Down \(Fmt.rate(d)), up \(Fmt.rate(u))")
            }
        }
        .frame(height: 56)
    }

    private func matches(_ name: String) -> Bool { ui.filter.isEmpty || name.localizedCaseInsensitiveContains(ui.filter) }

    private func shown(_ all: [Consumer]) -> [Consumer] {
        all.filter { matches($0.name) }.sorted { ui.sort == .memory ? $0.rssBytes > $1.rssBytes : $0.cpuPercent > $1.cpuPercent }
    }

    private var past: [LoadHistory.Row] { model.past.filter { matches($0.name) } }

    private func pastRow(_ row: LoadHistory.Row, _ all: [Consumer]) -> some View {
        let running = all.first { $0.kind == row.kind && $0.name == row.name }
        return Button { (running?.id).map(ui.openRow) } label: {
            PastRow(row: row) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).opacity(running == nil ? 0 : 1).frame(width: 14)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(running == nil)
        .help(running == nil ? "Not running now" : "What it is, and what can be done")
    }

    @ViewBuilder private var ports: some View {
        if let list = model.ports?.filter({ matches($0.program) || String($0.port).hasPrefix(ui.filter) }) {
            if list.isEmpty { Text(ui.filter.isEmpty ? "No open ports" : "None found").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(list) { p in
                let owner = model.row(ofPid: p.pid)
                Button { (owner?.id).map(ui.openRow) } label: {
                    HStack(spacing: 8) {
                        Text(String(p.port)).font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 46, alignment: .leading)
                        Text(owner?.name ?? p.program).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(p.network ? "network" : "this Mac").font(.system(size: 10)).foregroundStyle(p.network ? Color.primary : Color.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).opacity(owner == nil ? 0 : 1)
                    }
                    .frame(height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(owner == nil)
            }
        } else {
            Text("Reading…").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func note(_ count: Int) -> String {
        switch ui.sort {
        case .cpu, .memory: return "\(count) rows. Press one to see what it is. The x asks once more before it closes."
        case .hours: return Past.note(since: model.pastSince)
        case .ports: return "Your own programs. Network: other machines can try to reach it, unless the firewall stops them."
        }
    }
}

/// A figure and its last two minutes.
private struct Meter: View {
    let title: String, value: String
    let history: [Double]
    let hot: Bool
    init(_ title: String, _ value: String, _ history: [Double], hot: Bool) { self.title = title; self.value = value; self.history = history; self.hot = hot }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(hot ? Ink.hot : Color.primary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Sparkline(values: history, color: hot ? Ink.hot : Ink.ink(.dark), bars: 12).frame(height: 12)
        }
        .tile(padding: 7, fill: true)
    }
}

/// One row of "what is running". The row opens its page; the x closes, and only on the second press.
struct ConsumerRow: View {
    // Not observed: the page that holds the rows is, and six hundred observers of one object are not free.
    let model: Model
    let ui: PanelState
    let consumer: Consumer
    /// Handed over, because the row itself watches nothing.
    let armed: Bool
    var byMemory = false
    var decimals = false

    var body: some View {
        let c = consumer
        HStack(spacing: 8) {
            Button { ui.openRow(c.id) } label: {
                HStack(spacing: 8) {
                    Glyph(kind: Glyph.of(c.kind))
                    (Text(c.name) + Text(c.processCount > 1 && c.kind != .session ? "  ×\(c.processCount)" : "").foregroundColor(.secondary))
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(byMemory ? Fmt.bytes(c.rssBytes) : String(format: decimals ? "%.1f%%" : "%.0f%%", c.cpuPercent))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("What it is, and what can be done")
            CloseControl(armed: armed, allowed: model.mayClose(c), warning: armed ? model.warning(closing: c) : nil,
                         arm: { ui.arm(c.id) }, fire: { ui.disarm(); model.close(c) })
        }
        .frame(height: 22)
    }
}

/// One thing that runs: what it is, what it costs, what depends on it, what can be done.
struct ProcessPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let c = model.snap?.consumers.first { $0.id == ui.row }
        PageHeader(title: c?.name ?? "No longer running") { ui.back() }
        if let c {
            if let about = model.about(c) {
                Text(about).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: gap) {
                    VStack(spacing: 7) { ForEach(model.facts(c), id: \.name) { Fact(name: $0.name, value: $0.value) } }.tile()
                    if model.series.contains(where: { ($0 ?? 0) > 0 }) { BusyTile(series: model.series) }
                    actions(c)
                }
            }
            .scrollFade()
            Text(model.notice ?? consequence(c)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            closeButton(c)
        } else {
            Text("It ended, or its name changed.").font(.system(size: 12)).foregroundStyle(.secondary).tile()
        }
    }

    @ViewBuilder private func actions(_ c: Consumer) -> some View {
        let session = model.session(of: c)
        VStack(alignment: .leading, spacing: 9) {
            if let session { line("Open the app it runs in", icon: "arrow.up.right") { model.showHost(of: session) }; Hairline() }
            if let session, let command = Receipts.resume(cwd: session.cwd, id: session.sessionId) {
                line("Copy the command that resumes it", icon: "doc.on.doc") { Model.copy(command); model.notice = "Copied" }
                Hairline()
            }
            if let path = c.bundlePath ?? c.program { line("Show in Finder", icon: "arrow.up.right") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }; Hairline() }
            Check(title: "Never close this", isOn: Binding(get: { model.settings.isProtected(c.name) }, set: { model.protect(c.name, $0) }))
        }
        .tile()
        .task(id: c.id) { model.refreshPorts(); model.showSeries(of: c) }
        .onDisappear { model.showSeries(of: nil) }
    }

    private func verb(_ c: Consumer) -> String {
        switch c.kind {
        case .app: return "Quit \(c.name)"
        case .runtime: return "Shut down"
        case .session: return "Stop session"
        case .process: return c.processCount > 1 ? "Stop \(c.processCount) processes" : "Stop it"
        }
    }

    /// Said before the press, not after.
    private func consequence(_ c: Consumer) -> String {
        guard model.mayClose(c) else { return "macOS needs it, or your rules protect it. Pulse will not close it." }
        switch c.kind {
        case .app: return "It is asked to quit, as if you did it, and may ask you to save."
        case .runtime: return "Shut down with its own tool. Its data stays."
        case .session: return "Stops its process. The conversation stays on disk and can be resumed."
        case .process: return "Asked to stop. What it was in the middle of is lost, and Pulse cannot start it again."
        }
    }

    @ViewBuilder private func closeButton(_ c: Consumer) -> some View {
        let allowed = model.mayClose(c), armed = ui.armed == "page:" + c.id
        Button { if armed { ui.disarm(); model.close(c) } else { ui.arm("page:" + c.id) } } label: {
            HStack {
                Text(!allowed ? "Protected" : armed ? (model.warning(closing: c).map { $0 + ". " } ?? "") + "Press again" : verb(c)).lineLimit(1).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Fmt.bytes(c.rssBytes)).font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(armed ? Color.white : allowed ? Ink.base : Color.secondary)
            .padding(.horizontal, 18).frame(height: 38)
            .background(armed ? Ink.hot : allowed ? Ink.ink(.dark) : Ink.tile(.dark), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle()).disabled(!allowed)
    }
}

/// When it worked, a capsule a quarter of an hour. A faint dot is a time Pulse was not running.
private struct BusyTile: View {
    let series: [Double?]

    var body: some View {
        let top = max(series.compactMap { $0 }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            TileLabel("When it was busy")
            GeometryReader { g in
                let step = g.size.width / CGFloat(series.count)
                HStack(alignment: .bottom, spacing: step * 0.4) {
                    ForEach(Array(series.enumerated()), id: \.offset) { _, v in
                        Capsule().fill(Ink.ink(.dark).opacity(v == nil ? 0.12 : (v ?? 0) / top < 0.02 ? 0.3 : 0.9))
                            .frame(width: step * 0.6, height: max(step * 0.6, CGFloat((v ?? 0) / top) * g.size.height))
                    }
                }
                .frame(height: g.size.height, alignment: .bottom)
            }
            .frame(height: 24)
            HStack {
                Text("12 h ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .tile()
    }
}

struct Fact: View {
    let name: String, value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11)).monospacedDigit().lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .help(value)
    }
}

/// Claude Code sessions, the ones that wait first, and what is left of the plan.
struct SessionsPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let list = model.snap?.sessions ?? []
        let waits = list.filter(\.isWaiting).count, idle = list.filter(\.isIdle).count
        PageHeader(title: "Claude sessions", count: list.count, back: nil)
        Text(list.isEmpty ? "None is open." : "\(waits) waiting, \(list.count - waits - idle) working, \(idle) idle. They hold \(Fmt.bytes(list.reduce(0) { $0 + $1.rssBytes })).")
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
        PlanUsageTile(model: model)
        if !list.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(list) { session in
                        let consumer = model.snap?.consumers.first { $0.kind == .session && $0.members.first?.pid == session.pid }
                        SessionRow(session: session, open: { (consumer?.id).map(ui.openRow) }) {
                            if session.isWaiting {
                                Button { model.showHost(of: session) } label: { Text("Open").font(.system(size: 10, weight: .semibold)).fixedSize().pill() }
                                    .buttonStyle(PressStyle()).help("Bring the app it runs in to the front")
                            } else if !session.isIdle {
                                // A working one is stopped from its own page only.
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20)
                            } else if let c = consumer {
                                CloseControl(armed: ui.armed == c.id, allowed: model.mayClose(c), warning: model.warning(closing: c),
                                             arm: { ui.arm(c.id) }, fire: { ui.disarm(); model.close(c) })
                            }
                        }
                    }
                }
            }
            .scrollFade()
            .tile()
        }
        Spacer(minLength: 0)
        if let notice = model.notice {
            NoticeLine(text: notice)
        } else if !model.settings.planUsage {
            line("Show how much of the plan is used", icon: "chevron.right") { ui.go(.display) }.foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }
}
