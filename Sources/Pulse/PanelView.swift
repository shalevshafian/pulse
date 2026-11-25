import AppKit
import PulseCore
import SwiftUI

/// Every page. The raw names are what `--page` takes.
enum Page: String {
    case welcome
    case overview, processes, sessions, care, settings
    case plan, done, decides, agents, process, health, cleanup, disk, startup, sleep, drives, history, display, alerts, rules
}

/// The five places everything is in. Always in sight, always named.
enum Tab: CaseIterable {
    case overview, activity, sessions, care, settings

    var root: Page {
        switch self {
        case .overview: return .overview
        case .activity: return .processes
        case .sessions: return .sessions
        case .care: return .care
        case .settings: return .settings
        }
    }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .activity: return "Activity"
        case .sessions: return "Sessions"
        case .care: return "Care"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "circle.dotted"
        case .activity: return "chart.bar.fill"
        case .sessions: return "text.bubble"
        case .care: return "stethoscope"
        case .settings: return "slider.horizontal.3"
        }
    }
    init?(root: Page) {
        guard let t = Self.allCases.first(where: { $0.root == root }) else { return nil }
        self = t
    }
}

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

let gap: CGFloat = 6
private let contentWidth: CGFloat = 288
private let panelHeight: CGFloat = 440

enum Sort: CaseIterable {
    case cpu, memory, hours, ports
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .hours: return "12 h"
        case .ports: return "Ports"
        }
    }
}

/// Where the panel is, and what was picked in it. One way forward, one way back, for every page.
final class PanelState: ObservableObject {
    @Published var stack: [Page]
    @Published var row: String?
    @Published var sort = Sort.cpu
    @Published var filter = ""
    @Published var selected: Set<String> = []
    @Published var toClean: Set<String> = []
    /// What Pulse itself ticked: the rules when the plan opened, or "Select the suggested". The rest is the user's, and teaches.
    @Published var baseline: Set<String> = []
    /// The row whose close was pressed once. It forgets after four seconds.
    @Published private(set) var armed: String?
    let model: Model

    init(model: Model, page: Page) {
        self.model = model
        stack = [page]
        selected = model.defaultSelection()
        baseline = selected
        // A page deeper than a root has its root to go back to.
        if Tab(root: page) == nil, page != .welcome { stack = [Self.home(of: page), page] }
        row = page == .process ? model.snap?.topCPU.first?.id : nil
        // For `--render`.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--sort"), i + 1 < args.count { sort = Sort.allCases.first { "\($0)" == args[i + 1] } ?? .cpu }
        if args.contains("--armed") { armed = row.map { "page:" + $0 } ?? model.snap?.topCPU.first?.id }
    }

    var page: Page { stack.last ?? .overview }
    var tab: Tab { Tab(root: stack.first ?? .overview) ?? .overview }

    static func home(of page: Page) -> Page {
        switch page {
        case .plan, .done, .decides: return .overview
        case .agents: return .settings
        case .process: return .processes
        case .display, .alerts, .rules: return .settings
        default: return .care
        }
    }

    func go(_ next: Page) {
        guard next != page else { return }
        model.notice = nil
        armed = nil
        if next == .plan, page != .decides { selected = model.defaultSelection(); baseline = selected; model.preparePlan() }
        if next == .cleanup { toClean = [] }
        withAnimation(.easeOut(duration: 0.16)) {
            if Tab(root: next) != nil { stack = [next] } else if let i = stack.firstIndex(of: next) { stack = Array(stack[...i]) } else { stack.append(next) }
        }
    }

    func back() {
        guard stack.count > 1 else { return }
        model.notice = nil
        armed = nil
        withAnimation(.easeOut(duration: 0.16)) { _ = stack.removeLast() }
    }

    /// After something was done its page has nothing left to say: going back skips it.
    func replace(with next: Page) {
        model.notice = nil
        armed = nil
        withAnimation(.easeOut(duration: 0.16)) { stack[stack.count - 1] = next }
    }

    func openRow(_ id: String) {
        row = id
        go(.process)
    }

    func activity(_ sort: Sort, filter: String = "") {
        self.sort = sort
        self.filter = filter
        go(.processes)
    }

    func arm(_ id: String) {
        armed = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.armed == id { self?.armed = nil } }
    }

    func disarm() { armed = nil }

    func closed() {
        toClean = []
        armed = nil
        filter = ""
        if page != .welcome { stack = [.overview] }
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    @StateObject private var ui: PanelState
    private let inWindow: Bool

    static let goTo = Notification.Name("pulse.goto")

    init(model: Model, page: Page? = nil, inWindow: Bool = false) {
        self.model = model
        self.inWindow = inWindow
        let page = page ?? (model.settings.welcomed || !model.drawsLive ? .overview : .welcome)
        _ui = StateObject(wrappedValue: PanelState(model: model, page: page))
    }

    var body: some View {
        // One size for every page: the window never resizes, so a change of page is only
        // a change of content.
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                VStack(alignment: .leading, spacing: gap) { content }
                    .id(ui.page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 6)
            if ui.page != .welcome { TabBar(model: model, ui: ui) }
        }
        .frame(width: contentWidth + 32, height: panelHeight)
        .foregroundStyle(Ink.ink(.dark))
        .background(Ink.base)
        .background { if !inWindow { WindowShape() } }
        .background { if ui.page != .welcome { Keys(ui: ui, model: model).equatable() } }
        .environment(\.colorScheme, .dark)
        .environment(\.layoutDirection, .leftToRight)
        .onReceive(NotificationCenter.default.publisher(for: Self.goTo)) { n in
            if let next = (n.object as? String).flatMap(Page.init(rawValue:)) { ui.go(next) }
        }
        .onAppear {
            // Finished in the other place: the window or the menu bar panel.
            if ui.page == .welcome, model.settings.welcomed, model.drawsLive { ui.stack = [.overview] }
            model.opened()
        }
        .onDisappear { model.closed(); ui.closed() }
    }

    @ViewBuilder private var content: some View {
        switch ui.page {
        case .welcome: WelcomePage(model: model, ui: ui)
        case .overview: OverviewPage(model: model, ui: ui)
        case .processes: ActivityPage(model: model, ui: ui)
        case .process: ProcessPage(model: model, ui: ui)
        case .sessions: SessionsPage(model: model, ui: ui)
        case .care: CarePage(model: model, ui: ui)
        case .health: HealthPage(model: model, ui: ui)
        case .cleanup: CleanupPage(model: model, ui: ui)
        case .disk: DiskPage(model: model, ui: ui)
        case .startup: StartupPage(model: model, ui: ui)
        case .sleep: SleepPage(model: model, ui: ui)
        case .drives: DrivesPage(model: model, ui: ui)
        case .history: HistoryPage(model: model, ui: ui)
        case .plan: PlanPage(model: model, ui: ui)
        case .done: DonePage(model: model, ui: ui)
        case .decides: DecidesPage(model: model, ui: ui)
        case .agents: AgentsPage(model: model)
        case .settings: SettingsPage(model: model, ui: ui)
        case .display: DisplayPage(model: model, ui: ui)
        case .alerts: AlertsPage(model: model, ui: ui)
        case .rules: RulesPage(model: model, ui: ui)
        }
    }
}

/// Where everything is. A mark over a name says something waits there.
private struct TabBar: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        let needs = model.needs
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 0) {
                ForEach(Tab.allCases.filter { $0 != .sessions || model.hasClaude }, id: \.self) { tab in
                    Item(title: tab.title, icon: tab.icon, on: ui.tab == tab, mark: mark(tab, needs)) { ui.go(tab.root) }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
        }
    }

    private func mark(_ tab: Tab, _ needs: [Need]) -> Color? {
        func of(_ list: [Need]) -> Color? { list.isEmpty ? nil : list.contains { $0.level == .now } ? Ink.hot : Ink.ink(.dark) }
        switch tab {
        case .sessions: return of(needs.filter { $0.place == .session })
        case .care: return of(needs.filter { [.health, .drives].contains($0.place) && $0.level != .know })
        default: return nil
        }
    }

    private struct Item: View {
        let title: String, icon: String
        let on: Bool
        let mark: Color?
        let action: () -> Void
        @State private var inside = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: icon).font(.system(size: 13, weight: on ? .semibold : .regular)).frame(height: 15)
                        .overlay(alignment: .topTrailing) {
                            if let mark { Circle().fill(mark).frame(width: 5, height: 5).offset(x: 6, y: -1) }
                        }
                    Text(title).font(.system(size: 9, weight: on ? .semibold : .regular))
                }
                .foregroundStyle(on || inside ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle()).onHover { inside = $0 }
            .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// Everything is reachable without the pointer.
private struct Keys: View, Equatable {
    // Watches nothing: the keys are the same on every page.
    let ui: PanelState
    let model: Model
    static func == (a: Keys, b: Keys) -> Bool { a.ui === b.ui }

    var body: some View {
        let tabs = Tab.allCases.filter { $0 != .sessions || model.hasClaude }
        ZStack {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                Button("") { ui.go(tab.root) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { ui.go(.processes) }.keyboardShortcut("f", modifiers: .command)
            Button("") { ui.go(.settings) }.keyboardShortcut(",", modifiers: .command)
            Button("") { ui.back() }.keyboardShortcut("[", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}
