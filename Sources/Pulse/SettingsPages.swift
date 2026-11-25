import AppKit
import PulseCore
import SwiftUI

/// Every choice on one page; what needs room has a page behind its row.
struct SettingsPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState
    @State private var copied = false

    var body: some View {
        let s = model.settings
        let alerts = [s.alertCPU, s.alertTemp && model.system.chipTempC != nil, s.alertMemory, s.alertGrowth, s.alertHealth, s.alertWaiting && model.hasClaude].filter { $0 }.count
        PageHeader(title: "Settings", count: nil, back: nil)
        VStack(spacing: 9) {
            row("Menu bar", model.barText.isEmpty ? "Icon only" : model.barText) { ui.go(.display) }
            Hairline()
            row("Notifications", alerts == 0 ? "Off" : "\(alerts) on") { ui.go(.alerts) }
            Hairline()
            row("Closing", s.neverTouch.isEmpty ? "" : "\(s.neverTouch.count) never closed") { ui.go(.rules) }
        }
        .tile()
        VStack(alignment: .leading, spacing: 9) {
            Check(title: "Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Hairline()
            HStack(spacing: 4) {
                Text("Keyboard shortcut").font(.system(size: 12))
                Spacer()
                ForEach(PulseCore.Settings.Shortcut.allCases, id: \.self) { k in
                    Button { model.settings.shortcut = k } label: {
                        Text(k.label).font(.system(size: 11, weight: s.shortcut == k ? .semibold : .regular)).fixedSize()
                            .foregroundStyle(s.shortcut == k ? Ink.base : Color.secondary)
                            .padding(.horizontal, 8).frame(height: 21)
                            .background(s.shortcut == k ? Color.primary : .clear, in: Capsule())
                            .overlay(Capsule(style: .circular).strokeBorder(s.shortcut == k ? .clear : .white.opacity(0.2)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .help("Opens Pulse in a window from any app")
        }
        .tile()
        VStack(alignment: .leading, spacing: 9) {
            line("Connect an agent (MCP)", icon: "chevron.right") { ui.go(.agents) }
                .help("Pulse is also a read-only MCP server: Claude Code, Codex and others can see this Mac, and cannot close or change anything.")
            Hairline()
            line("Source and updates", icon: "arrow.up.right") { NSWorkspace.shared.open(AppInfo.releases) }
            Hairline()
            line("Quit Pulse", icon: "power") { NSApplication.shared.terminate(nil) }
        }
        .tile()
        Spacer(minLength: 0)
        Text(model.notice ?? "Pulse \(AppInfo.version)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 4)
    }

    private func row(_ title: String, _ value: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(value).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension PulseCore.Settings.Shortcut {
    var label: String {
        switch self {
        case .off: return "Off"
        case .controlOptionP: return "⌃⌥P"
        case .optionCommandP: return "⌥⌘P"
        }
    }
}

struct DisplayPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        PageHeader(title: "Menu bar") { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                VStack(alignment: .leading, spacing: 9) {
                    TileLabel("Beside the icon")
                    Check(title: "CPU", isOn: $model.settings.barCPU)
                    Check(title: "Memory", isOn: $model.settings.barMemory)
                    if model.system.chipTempC != nil { Check(title: "Temperature", isOn: $model.settings.barTemp) }
                    if model.hasClaude { Check(title: "Number of sessions", isOn: $model.settings.barSessions) }
                    Hairline()
                    HStack {
                        Text("Preview").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.barText.isEmpty ? "Icon only" : model.barText).font(.system(size: 12, design: .monospaced))
                    }
                }
                .tile()
                if model.hasClaude {
                    VStack(alignment: .leading, spacing: 9) {
                        TileLabel("On the Sessions page")
                        Check(title: "Plan limits", isOn: $model.settings.planUsage)
                        Text("Reads the limits Claude Code and Codex already saved on this Mac. Nothing is sent. Claude Code keeps them in ~/.claude.json, which also holds your account; Pulse takes only the limits from it and keeps nothing.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .tile()
                }
            }
        }
    }
}

struct AlertsPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState

    var body: some View {
        PageHeader(title: "Notifications") { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                VStack(alignment: .leading, spacing: 9) {
                    TileLabel("CPU")
                    Check(title: "When something uses a lot of CPU", isOn: $model.settings.alertCPU)
                    choice("Over", [20, 30, 40, 60], $model.settings.alertCPUPercent) { "\(Int($0))%" }
                    choice("For", [5, 10, 20, 30], $model.settings.alertCPUMinutes) { "\(Int($0)) min" }
                }
                .tile()
                // An Intel Mac has no readable sensor: an alert that cannot come is not offered.
                if model.system.chipTempC != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        TileLabel("Temperature")
                        Check(title: "When the chip is hot", isOn: $model.settings.alertTemp)
                        choice("Over", [80, 85, 90, 95], $model.settings.alertTempC) { "\(Int($0))°" }
                    }
                    .tile()
                }
                VStack(alignment: .leading, spacing: 9) {
                    TileLabel("Also")
                    Check(title: "When memory comes under pressure", isOn: $model.settings.alertMemory)
                    Check(title: "When something keeps growing", isOn: $model.settings.alertGrowth)
                    Check(title: "When a check finds something new", isOn: $model.settings.alertHealth)
                    if model.hasClaude { Check(title: "When a session needs input", isOn: $model.settings.alertWaiting) }
                }
                .tile()
            }
        }
        .scrollFade()
        HStack {
            Text(model.notice ?? (model.notificationsAllowed == false
                ? "macOS is blocking notifications from Pulse. Allow them in System Settings, Notifications."
                : "Silent. Once every half hour at most, or per wait."))
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Send test notification") { model.requestNotifications(); model.sendTestAlert() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 4)
    }

    private func choice(_ title: String, _ options: [Double], _ value: Binding<Double>, _ label: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Choice(options: options, value: value, label: label)
        }
    }
}

struct RulesPage: View {
    @ObservedObject var model: Model
    @ObservedObject var ui: PanelState
    @State private var newWord = ""

    var body: some View {
        PageHeader(title: "Closing") { ui.back() }
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                VStack(alignment: .leading, spacing: 9) {
                    TileLabel("Selected for you, when memory is short")
                    if model.hasClaude { HStack {
                        Text("Session idle (hours)").font(.system(size: 12))
                        Spacer()
                        Choice(options: [1, 3, 6, 12, 24], value: $model.settings.autoSelectIdleHours) { "\(Int($0))" }
                    } }
                    Check(title: "Processes left by closed sessions", isOn: $model.settings.includeLeftovers)
                }
                .tile()
                VStack(alignment: .leading, spacing: 8) {
                    TileLabel("Never close")
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
                            .buttonStyle(.plain).accessibilityLabel("Remove \(word)")
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("For example Docker or qemu", text: $newWord).textFieldStyle(.plain).font(.system(size: 12)).onSubmit(addWord)
                        Button("Add", action: addWord).buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(newWord.trimmingCharacters(in: .whitespaces).isEmpty ? .tertiary : .primary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(Ink.line(.dark)))
                }
                .tile()
                VStack(alignment: .leading, spacing: 8) {
                    TileLabel("What Pulse learned")
                    Text("When you used apps, sessions and simulators, which rows you ticked or opened again, and how much memory closing gave back. It only changes the order and the suggestions, and stays on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Forget it") { model.forgetLearned() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                }
                .tile()
                Text("Always protected, whatever you choose: Finder, Dock, WindowServer and the other core parts of macOS, and Pulse itself.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !model.settings.neverTouch.contains(word) else { return }
        model.settings.neverTouch.append(word)
        newWord = ""
    }
}

/// How an agent reaches Pulse. Pulse writes no other app's settings: it copies the lines, the user pastes them.
struct AgentsPage: View {
    @ObservedObject var model: Model
    @State private var copied: String?

    var body: some View {
        PageHeader(title: "Connect an agent") { NotificationCenter.default.post(name: PanelView.goTo, object: Page.settings.rawValue) }
        Text("Pulse answers agents over MCP. It shows them this Mac and changes nothing: every tool only reads.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: gap) {
                agent("Claude Code", "Paste in a terminal.", AppInfo.mcpCommand)
                agent("Codex", "Paste at the end of ~/.codex/config.toml. The Codex app and the codex command read it; new chats see Pulse.", AppInfo.codexConfig)
                agent("Other apps", "For a client that takes a JSON file, such as Cursor's ~/.cursor/mcp.json.", AppInfo.mcpJSON)
            }
        }
        .scrollFade()
    }

    private func agent(_ name: String, _ how: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    Model.copy(text)
                    copied = name
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == name { copied = nil } }
                } label: {
                    Text(copied == name ? "Copied" : "Copy").font(.system(size: 10, weight: .semibold)).pill()
                }
                .buttonStyle(PressStyle())
            }
            Text(how).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .tile()
    }
}
