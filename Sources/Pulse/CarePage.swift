import PulseCore
import SwiftUI

/// The state of the Mac over days: every row says how it is before it is opened.
struct CarePage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let h = model.health
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(h.score.map { "Score \($0)" } ?? "Not checked yet").font(.system(size: 14, weight: .semibold))
                Text(model.checking ? "Checking…" : model.checkedAgo).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if h.history.count >= 3 { ScoreTrend(days: h.history).frame(width: 84, height: 22).help("The score of the last \(min(h.history.count, 21)) days with a check") }
            Button { model.runHealthCheck(shown: true); ui.go(.overview) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18))).contentShape(Circle())
            }
            .buttonStyle(PressStyle()).disabled(model.checking).help("Check everything again").accessibilityLabel("Check again")
        }
        .frame(height: 34).padding(.horizontal, 2)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Hairline() }
                CareRow(row: r) { ui.go(r.page) }
            }
        }
        .tile(padding: 0)
        .onAppear { model.refreshDrives(); model.refreshSleep() }
        Spacer(minLength: 0)
        if let notice = model.notice { NoticeLine(text: notice) }
    }

    struct Row { var icon: String, title: String, state: String, page: Page; var mark: HealthState = .ok }

    private var rows: [Row] {
        let h = model.health, s = model.system
        let problems = h.problems
        let checks = h.report?.checks ?? []
        func first(_ area: HealthArea) -> HealthCheck? { checks.filter { $0.area == area }.first { $0.isProblem } ?? checks.first { $0.area == area } }
        let free = (h.report?.cleanup ?? []).filter { $0.blockedBy == nil }
        let awake = model.snap?.awake
        let ticked = model.settings.sleepDrives.count
        let startup = h.report?.startup ?? []
        return [
            Row(icon: "waveform.path.ecg", title: "Health", state: h.report == nil ? "Not checked yet" : problems.isEmpty ? "Nothing to fix" : "\(problems.count) to fix: \(problems[0].title)", page: .health,
                mark: problems.contains { $0.state == .urgent } ? .urgent : problems.isEmpty ? .ok : .attention),
            Row(icon: "shippingbox", title: "Cleanup", state: free.isEmpty ? "Nothing to clear" : "\(Fmt.bytes(free.reduce(0) { $0 + $1.bytes })) in \(Plural.count(free.count, "place"))", page: .cleanup),
            Row(icon: "internaldrive", title: "Disk", state: "\(Fmt.drive(s.diskFreeBytes)) free of \(Fmt.drive(s.diskTotalBytes))" + (h.report?.wear.map { ", wear \($0)%" } ?? ""), page: .disk, mark: h.state(of: .storage) == .urgent ? .urgent : .ok),
            Row(icon: "moon", title: "Sleep", state: awake.map { a in a.first.map { "Awake because of \($0.name)" + (a.count > 1 ? " and \(a.count - 1) more" : "") } ?? "Nothing keeps it awake" } ?? "What keeps it awake", page: .sleep),
            Row(icon: "externaldrive", title: "Drives in sleep", state: model.drivesOut.isEmpty ? (ticked == 0 ? "None is disconnected" : "\(Plural.count(ticked, "drive")) disconnected before sleep") : "\(model.drivesOut.count) still disconnected", page: .drives,
                mark: model.drivesOut.isEmpty ? .ok : .attention),
            Row(icon: "battery.75percent", title: "Battery", state: battery, page: .health, mark: h.state(of: .battery) == .ok || h.state(of: .battery) == .unknown ? .ok : .attention),
            Row(icon: "power", title: "Startup", state: first(.startup)?.title ?? (startup.isEmpty ? "Not checked yet" : Plural.count(startup.count, "item")), page: .startup, mark: h.state(of: .startup) == .attention ? .attention : .ok),
            Row(icon: "clock.arrow.circlepath", title: "History", state: model.receipts.list.first.map { "\($0.title), \(Fmt.ago($0.at))" } ?? "Nothing yet", page: .history),
        ]
    }

    private var battery: String {
        guard let c = (model.health.report?.checks ?? []).first(where: { $0.area == .battery }) else { return "Not checked yet" }
        return c.title.replacingOccurrences(of: "Battery health ", with: "Health ") + (c.detail.isEmpty ? "" : ", " + c.detail)
    }

    private struct CareRow: View {
        let row: Row
        let action: () -> Void
        @State private var inside = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: row.icon).font(.system(size: 12)).foregroundStyle(inside ? Color.primary : Color.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.system(size: 12, weight: .medium))
                        Text(row.state).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if row.mark == .attention || row.mark == .urgent { Capsule().fill(row.mark == .urgent ? Ink.hot : Ink.ink(.dark)).frame(width: 3, height: 14) }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11).frame(height: 39)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle()).onHover { inside = $0 }
        }
    }
}

/// A capsule a day, as high as that day's score.
private struct ScoreTrend: View {
    let days: [HealthDay]
    var body: some View {
        let shown = days.suffix(21)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, d in
                Capsule().fill(Ink.ink(.dark).opacity(i == shown.count - 1 ? 1 : 0.4)).frame(width: 2.5, height: max(3, CGFloat(d.score) / 100 * 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct HealthPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let problems = model.health.problems
        let checks = model.health.report?.checks ?? []
        let ignored = checks.filter { $0.isProblem && model.health.ignored.contains($0.id) }
        let good = checks.filter { $0.state == .ok }
        PageHeader(title: "Health", count: nil) { ui.back() }
        HStack(spacing: 0) {
            ForEach(HealthArea.allCases, id: \.self) { AreaMark(title: $0.title, state: model.health.state(of: $0)) }
        }
        .padding(.bottom, 4)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(problems) { c in
                    ProblemCard(check: c, fix: { f in
                        switch f {
                        case .cleanup: ui.go(.cleanup)
                        case .plan: ui.go(.plan)
                        case .sleep: ui.go(.sleep)
                        case .loginItems where c.area == .startup: ui.go(.startup)
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
        .scrollFade()
        Text(model.notice ?? "\(model.checkedAgo). Runs by itself every six hours. Pulse changes no settings, it opens the right place.")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
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
                    if c.fix == .sleep { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
                .onTapGesture { if c.fix == .sleep { ui.go(.sleep) } }
                .help(c.detail)
            }
        }
        .tile()
    }
}

struct CleanupPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let items = model.health.report?.cleanup ?? []
        let chosen = items.filter { ui.toClean.contains($0.id) && $0.blockedBy == nil }
        let bytes = chosen.reduce(0) { $0 + $1.bytes }
        PageHeader(title: "Cleanup", count: items.count) { ui.back() }
        Text("Only things that are rebuilt or downloaded again. Everything goes to the Trash and can be put back. What is in use is locked.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        if items.isEmpty {
            Text("Nothing to clear right now").font(.system(size: 12)).foregroundStyle(.secondary).tile()
            line("Largest folders on this Mac", icon: "chevron.right") { ui.go(.disk) }.tile()
            Spacer(minLength: 0)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        CleanRow(item: item, isOn: Binding(
                            get: { ui.toClean.contains(item.id) && item.blockedBy == nil },
                            set: { if $0 { ui.toClean.insert(item.id) } else { ui.toClean.remove(item.id) } }))
                    }
                }
                .tile()
            }
            .scrollFade()
            MainButton(title: chosen.isEmpty ? "Nothing selected" : "Move to Trash", value: chosen.isEmpty ? nil : Fmt.bytes(bytes), on: !chosen.isEmpty && !model.cleaning) {
                model.clean(chosen)
                ui.toClean = []
                ui.replace(with: .done)
            }
        }
    }
}

/// What the disk holds, how worn it is, and what takes the space.
struct DiskPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let s = model.system
        let checks = (model.health.report?.checks ?? []).filter { $0.area == .storage && $0.id != "cleanup" && !($0.id == "disk" && $0.state == .ok) }
        let free = (model.health.report?.cleanup ?? []).filter { $0.blockedBy == nil }
        PageHeader(title: "Disk") { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.drive(s.diskFreeBytes)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        Text("free of \(Fmt.drive(s.diskTotalBytes))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Ink.ink(.dark).opacity(0.16))
                            Capsule().fill(s.diskUsedPercent >= 95 ? Ink.hot : Ink.ink(.dark)).frame(width: max(6, g.size.width * s.diskUsedPercent / 100))
                        }
                    }
                    .frame(height: 6)
                    ForEach(checks) { c in Fact(name: c.title, value: c.detail) }
                }
                .tile()
                if !free.isEmpty { line("\(Fmt.bytes(free.reduce(0) { $0 + $1.bytes })) can be cleared", icon: "chevron.right") { ui.go(.cleanup) }.tile() }
                LargeFoldersTile(model: model)
            }
        }
        .scrollFade()
    }
}

struct StartupPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let items = model.health.report?.startup ?? []
        let news = (model.health.report?.checks ?? []).filter { $0.area == .startup && $0.isProblem && !model.health.ignored.contains($0.id) }
        PageHeader(title: "Startup", count: items.count) { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(news) { c in
                    ProblemCard(check: c, fix: { model.fix($0) }, ignore: { model.ignore(c, true) })
                }
                StartupTile(title: "Loaded now", items: items.filter { $0.loaded == true })
                StartupTile(title: "Set up, not loaded", items: items.filter { $0.loaded != true })
            }
        }
        .scrollFade()
        line("Open Login Items in System Settings", icon: "arrow.up.right") { model.fix(.loginItems) }.tile()
        Text("Pulse removes nothing here. Items that are registered and were never loaded cannot be seen.")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
}

struct DrivesPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let rows = model.drives ?? []
        PageHeader(title: "Drives in sleep", count: rows.count) { ui.back() }
        AwakeRow(holders: model.snap?.awake) { ui.go(.sleep) }
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
                .tile()
            }
            .scrollFade()
        }
        Spacer(minLength: 0)
        Text("A drive in use stays connected, and nothing is forced. A closed lid with an external display is not sleep.")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            .onAppear { model.refreshDrives() }
    }
}

/// Everything Pulse did on the user's word, and the way back.
struct HistoryPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let list = model.receipts.list
        PageHeader(title: "History", count: list.count) { ui.back() }
        if list.isEmpty {
            Text("Nothing yet. What you close or clear is written here, with the way back.").font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).tile()
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) { ForEach(list) { ReceiptRow(model: model, receipt: $0) } }.tile()
            }
            .scrollFade()
        }
        Spacer(minLength: 0)
        Text(model.notice ?? "The last 100, kept on this Mac. An app, a session and the Trash have a way back; a process has none.")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
}

struct ReceiptRow: View {
    @ObservedObject var model: Model
    let receipt: Receipt
    /// The page of what was just done knows when it was.
    var dated = true

    var body: some View {
        let r = receipt
        HStack(spacing: 8) {
            Image(systemName: r.undone ? "arrow.uturn.backward" : r.ok ? "checkmark" : "xmark").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(r.ok ? Color.secondary : Color.primary).frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(.system(size: 12)).lineLimit(1)
                Text([dated ? Fmt.ago(r.at) : "", r.detail, r.bytes > 0 && r.ok ? Fmt.bytes(r.bytes) : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if r.ok, !r.undone, let back = r.back {
                Button { model.undo(r) } label: {
                    Text(back.verb).font(.system(size: 10, weight: .semibold)).fixedSize().pill()
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(height: 30)
        .help(r.title)
    }
}

extension Receipt.Back {
    var verb: String {
        switch self {
        case .app: return "Open again"
        case .session: return "Resume"
        case .trash: return "Put back"
        }
    }
}
