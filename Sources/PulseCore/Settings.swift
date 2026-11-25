import Foundation

/// Everything the user can change. One JSON file, so the menu bar app and the MCP
/// server (a separate process) read the same rules.
public struct Settings: Codable, Equatable, Sendable {
    // Rules for the optimize button.
    /// A session idle at least this long is ticked in the plan, when memory is short.
    public var autoSelectIdleHours: Double = 12
    /// Leftover agent processes are ticked in the plan. Off until asked for: Pulse recognises
    /// them by how they look, and a tool someone started by hand can look the same.
    public var includeLeftovers = false
    /// Names Pulse never offers to close and never closes. Matched as part of a name, any case.
    public var neverTouch: [String] = []

    // Alerts.
    public var alertCPU = true
    /// Share of the whole machine one thing has to hold...
    public var alertCPUPercent: Double = 40
    /// ...for this many minutes.
    public var alertCPUMinutes: Double = 10
    public var alertTemp = true
    public var alertTempC: Double = 90
    public var alertMemory = true
    /// A new health finding, at most once every two weeks each.
    public var alertHealth = true
    /// A Claude session that asked something, once per wait.
    public var alertWaiting = true
    /// Something whose memory only grows. Off until asked for.
    public var alertGrowth = false
    public var anyAlert: Bool { alertCPU || alertTemp || alertMemory || alertHealth }

    // What the menu bar item shows.
    public var barCPU = true
    public var barMemory = true
    public var barTemp = false
    public var barSessions = false

    /// Reads the limits Claude Code and Codex saved. Off until ticked: one of the files also holds the account.
    public var planUsage = false

    /// Drives unmounted before sleep and mounted after. Empty until the user ticks one.
    public var sleepDrives: [SleepDrive] = []

    /// Rows of the list on the first page put away for a day, and when.
    public var hidden: [String: Date] = [:]

    /// A key that opens Pulse from anywhere. Off until picked.
    public var shortcut = Shortcut.off
    public enum Shortcut: String, Codable, Sendable, CaseIterable { case off, controlOptionP, optionCommandP }

    /// The welcome page was finished. A settings file from before it existed counts as finished.
    public var welcomed = false

    public init() {}

    /// Tolerant: a file written by an older version, or with a key missing, still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        autoSelectIdleHours = try c.decodeIfPresent(Double.self, forKey: .autoSelectIdleHours) ?? d.autoSelectIdleHours
        includeLeftovers = try c.decodeIfPresent(Bool.self, forKey: .includeLeftovers) ?? d.includeLeftovers
        neverTouch = try c.decodeIfPresent([String].self, forKey: .neverTouch) ?? d.neverTouch
        alertCPU = try c.decodeIfPresent(Bool.self, forKey: .alertCPU) ?? d.alertCPU
        alertCPUPercent = try c.decodeIfPresent(Double.self, forKey: .alertCPUPercent) ?? d.alertCPUPercent
        alertCPUMinutes = try c.decodeIfPresent(Double.self, forKey: .alertCPUMinutes) ?? d.alertCPUMinutes
        alertTemp = try c.decodeIfPresent(Bool.self, forKey: .alertTemp) ?? d.alertTemp
        alertTempC = try c.decodeIfPresent(Double.self, forKey: .alertTempC) ?? d.alertTempC
        alertMemory = try c.decodeIfPresent(Bool.self, forKey: .alertMemory) ?? d.alertMemory
        alertHealth = try c.decodeIfPresent(Bool.self, forKey: .alertHealth) ?? d.alertHealth
        // Someone who turned every alert off before this one existed stays without alerts.
        alertWaiting = try c.decodeIfPresent(Bool.self, forKey: .alertWaiting) ?? anyAlert
        barCPU = try c.decodeIfPresent(Bool.self, forKey: .barCPU) ?? d.barCPU
        barMemory = try c.decodeIfPresent(Bool.self, forKey: .barMemory) ?? d.barMemory
        barTemp = try c.decodeIfPresent(Bool.self, forKey: .barTemp) ?? d.barTemp
        barSessions = try c.decodeIfPresent(Bool.self, forKey: .barSessions) ?? d.barSessions
        alertGrowth = try c.decodeIfPresent(Bool.self, forKey: .alertGrowth) ?? d.alertGrowth
        planUsage = try c.decodeIfPresent(Bool.self, forKey: .planUsage) ?? d.planUsage
        sleepDrives = try c.decodeIfPresent([SleepDrive].self, forKey: .sleepDrives) ?? d.sleepDrives
        hidden = (try? c.decodeIfPresent([String: Date].self, forKey: .hidden)) ?? d.hidden
        // A value from a newer version must not lose the rest of the file.
        shortcut = (try? c.decodeIfPresent(Shortcut.self, forKey: .shortcut)) ?? d.shortcut
        welcomed = try c.decodeIfPresent(Bool.self, forKey: .welcomed) ?? true
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse/settings.json")
    }

    public static func load(from url: URL = defaultURL) -> Settings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL = Settings.defaultURL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(self).write(to: url, options: .atomic)
    }

    public func isProtected(_ names: String...) -> Bool {
        let words = neverTouch.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return names.contains { name in words.contains { name.lowercased().contains($0) } }
    }

    /// Whether the optimize plan starts with this row ticked. Never while memory is not short: the plan says
    /// there is nothing to do, and a tick beside that would say the opposite.
    public func preselects(_ s: Suggestion, memory: MemoryState?) -> Bool {
        guard let memory, memory >= .strained else { return false }
        switch s.kind {
        // Idle on paper, but its own processes are running: the user decides, not the rule.
        case .idleSession: return !s.stillWorking && (s.idleSeconds ?? 0) >= autoSelectIdleHours * 3600
        // Pulse cannot know whether someone is looking at a simulator. Always the user's tick.
        case .runtime: return false
        case .orphan: return includeLeftovers
        case .heavyApp, .advice: return false
        }
    }
}
