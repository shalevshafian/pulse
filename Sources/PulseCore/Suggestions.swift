import Darwin
import Foundation

public struct Suggestion: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case idleSession, orphan, runtime, heavyApp, advice }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var reclaimBytes: UInt64
    public var pid: Int32?
    public var procStart: String?
    public var bundlePath: String?
    /// For a session: how long idle. For a runtime: how long it has been up.
    public var idleSeconds: TimeInterval?
    /// Share of the whole machine it holds right now, where that matters to the choice.
    public var cpuPercent: Double? = nil
    /// An idle session whose own processes are still running. Never ticked for the user.
    public var stillWorking = false
    public var busyChild: String? = nil
    public var runtimeID: String? = nil
    public var runtimeKind: DevRuntime.Kind? = nil

    public init(kind: Kind, title: String, detail: String, reclaimBytes: UInt64, pid: Int32?, procStart: String?,
                bundlePath: String?, idleSeconds: TimeInterval?, cpuPercent: Double? = nil, stillWorking: Bool = false,
                busyChild: String? = nil, runtimeID: String? = nil, runtimeKind: DevRuntime.Kind? = nil) {
        self.kind = kind; self.title = title; self.detail = detail; self.reclaimBytes = reclaimBytes
        self.pid = pid; self.procStart = procStart; self.bundlePath = bundlePath; self.idleSeconds = idleSeconds
        self.cpuPercent = cpuPercent; self.stillWorking = stillWorking; self.busyChild = busyChild
        self.runtimeID = runtimeID; self.runtimeKind = runtimeKind
    }

    public var id: String { "\(kind.rawValue)-\(pid.map(String.init) ?? bundlePath ?? title)" }
}

public struct Snapshot: Codable, Sendable {
    public var system: SystemStats
    public var sessions: [ClaudeSession]
    public var apps: [AppGroup]
    public var topCPU: [Consumer]
    public var topMemory: [Consumer]
    /// Everything running, grouped. The panel's full list; MCP serves the two top lists.
    public var consumers: [Consumer] = []
    /// Apps that launched a live session. Closing one takes those sessions with it.
    public var sessionHosts: [String] = []
    /// Booted simulators, running emulators and build daemons, each as one tree.
    public var runtimes: [DevRuntime] = []
    /// What asks this Mac to stay awake. Nil when macOS did not say.
    public var awake: [AwakeHolder]? = nil
    /// One sentence on what stands out right now, or nil when nothing does.
    public var headline: String? = nil
    public var suggestions: [Suggestion]

    public var sessionsRSS: UInt64 { sessions.reduce(0) { $0 + $1.rssBytes } }
    public var reclaimable: UInt64 {
        suggestions.filter { $0.kind == .idleSession || $0.kind == .orphan }.reduce(0) { $0 + $1.reclaimBytes }
    }

    public static func take(system: SystemStats, sessionsDir: URL = ClaudeSessions.defaultDir, settings: Settings = .load(), now: Date = Date()) -> Snapshot {
        let table = ProcTable.live()
        let runtimes = Runtimes.detect(table: table, now: now)
        let runtimePids = Set(runtimes.flatMap { $0.members.map(\.pid) })
        let sessions = ClaudeSessions.load(dir: sessionsDir, table: table, excluding: runtimePids)
        let sessionPids = Set(sessions.flatMap { table.tree(of: $0.pid).map(\.pid) }).union(runtimePids)
        let apps = AppGroups.build(table, excluding: sessionPids)
        // An app that launched a live session (Claude, T3 Code, a terminal) is never
        // offered for quitting: quitting it would take working sessions down with it.
        let hosts = Set(sessions.flatMap { $0.hosts ?? [] })
        let consumers = Consumers.build(table: table, sessions: sessions, runtimes: runtimes)
        var snap = Snapshot(
            system: system, sessions: sessions, apps: Array(apps.prefix(8)),
            topCPU: Consumers.topCPU(consumers, 8), topMemory: Consumers.topMemory(consumers, 8), consumers: consumers, sessionHosts: hosts.sorted(),
            runtimes: runtimes,
            suggestions: Suggestions.build(system: system, sessions: sessions, apps: apps, table: table, sessionPids: sessionPids,
                                           launchdJobs: LaunchdJobs.live(), protectedBundles: hosts, runtimes: runtimes, now: now)
                .filter { !settings.isProtected($0.title, $0.detail) })
        snap.awake = Awake.read(table: table, sessions: sessions, runtimes: runtimes)
        snap.headline = Insights.headline(snap)
        return snap
    }
}

/// What launchd itself runs for this user. Such a process also has launchd as its parent, and
/// it is there on purpose: a background service is not something a session left behind.
enum LaunchdJobs {
    static func live() -> Set<Int32> { parse(Shell.run("/bin/launchctl", ["list"])) }

    /// "PID\tStatus\tLabel"; "-" for a job that is not running.
    static func parse(_ text: String) -> Set<Int32> {
        Set(text.split(separator: "\n").compactMap { $0.split(separator: "\t").first.flatMap { Int32($0) } })
    }
}

public enum Suggestions {
    /// A session has to be idle this long before closing it is offered at all.
    public static let idleMinimum: TimeInterval = 3600
    /// The "close all" button only takes sessions idle at least this long.
    public static let idleBulk: TimeInterval = 12 * 3600
    static let heavyApp: UInt64 = 2 << 30
    static let orphanAge: TimeInterval = 3600
    /// A simulator, emulator or build daemon is offered once it has been up this long.
    static let runtimeAge: TimeInterval = 3600

    public static func build(
        system: SystemStats, sessions: [ClaudeSession], apps: [AppGroup],
        table: ProcTable, sessionPids: Set<Int32>, launchdJobs: Set<Int32> = [], protectedBundles: Set<String> = [],
        runtimes: [DevRuntime] = [], cores: Int = ProcessInfo.processInfo.activeProcessorCount, now: Date
    ) -> [Suggestion] {
        var out: [Suggestion] = []

        for s in sessions where s.isIdle && s.idleSeconds(now: now) >= idleMinimum {
            out.append(Suggestion(
                kind: .idleSession,
                title: s.name.isEmpty ? s.project : s.name,
                detail: s.project,
                reclaimBytes: s.rssBytes, pid: s.pid, procStart: s.procStart,
                bundlePath: nil, idleSeconds: s.idleSeconds(now: now),
                cpuPercent: s.cpu / Double(max(cores, 1)), stillWorking: s.stillWorking, busyChild: s.busyChild))
        }

        for r in runtimes where r.upSeconds >= runtimeAge {
            out.append(Suggestion(
                kind: .runtime, title: r.name, detail: r.handle, reclaimBytes: r.rssBytes,
                pid: r.root.pid, procStart: r.root.lstart, bundlePath: nil, idleSeconds: r.upSeconds,
                cpuPercent: r.cpuPercent, stillWorking: r.working, runtimeID: r.id, runtimeKind: r.kind))
        }

        let me = getpid()
        for p in table.all where p.ppid == 1 && p.pid != me && !sessionPids.contains(p.pid) && !launchdJobs.contains(p.pid) {
            guard looksLikeAgentLeftover(p.command),
                  let started = StartTime.date(p.lstart),
                  now.timeIntervalSince(started) >= orphanAge else { continue }
            let tree = table.tree(of: p.pid)
            out.append(Suggestion(
                kind: .orphan,
                title: shortCommand(p.command),
                detail: p.command,
                reclaimBytes: tree.reduce(0) { $0 + $1.rssBytes }, pid: p.pid, procStart: p.lstart,
                bundlePath: nil, idleSeconds: now.timeIntervalSince(started)))
        }

        for a in apps where a.rssBytes >= heavyApp && !protectedBundles.contains(a.bundlePath) {
            out.append(Suggestion(
                kind: .heavyApp, title: a.name, detail: Plural.count(a.processCount, "process", "processes"),
                reclaimBytes: a.rssBytes, pid: nil, procStart: nil, bundlePath: a.bundlePath, idleSeconds: nil))
        }

        if system.memPressureLevel >= 2 {
            out.append(advice((system.memPressureLevel >= 4 ? "Critical" : "High") + " memory pressure",
                              "macOS is compressing and swapping. Start with the idle rows below."))
        }
        if system.swapUsedBytes >= 4 << 30 {
            out.append(advice("Large swap", "macOS is writing memory to disk, and that slows everything."))
        }
        if system.diskTotalBytes > 0, Double(system.diskFreeBytes) / Double(system.diskTotalBytes) < 0.1 {
            out.append(advice("The disk is almost full", "Less than 10% is free."))
        }

        return out.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.reclaimBytes > $1.reclaimBytes }
    }

    static func rank(_ s: Suggestion) -> Int {
        switch s.kind {
        case .advice: return 0
        case .idleSession: return 1
        case .orphan: return 2
        case .runtime: return 3
        case .heavyApp: return 4
        }
    }

    static func advice(_ title: String, _ detail: String) -> Suggestion {
        Suggestion(kind: .advice, title: title, detail: detail, reclaimBytes: 0,
                   pid: nil, procStart: nil, bundlePath: nil, idleSeconds: nil)
    }

    /// Reparented to launchd and running out of an agent's temp or config folder,
    /// or as an MCP server: most likely left behind by a session that has ended.
    static func looksLikeAgentLeftover(_ command: String) -> Bool {
        let c = command.lowercased()
        if c.contains("/pulse.app/") { return false }
        return c.contains("/claude-\(getuid())/") || c.contains("/.claude/") || c.contains("/.codex/")
            || c.contains("mcp-server") || c.contains("-mcp") || c.hasSuffix(" mcp") || c.contains(" --mcp")
    }

    static func shortCommand(_ command: String) -> String {
        let words = command.split(separator: " ").prefix(2).map { ($0 as NSString).lastPathComponent }
        return words.joined(separator: " ")
    }
}

/// The one sentence at the top of the panel: the single thing most worth knowing now.
public enum Insights {
    public static func headline(_ snap: Snapshot) -> String? {
        let gb = { (b: UInt64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        if snap.system.memPressureLevel >= 2, let top = snap.topMemory.first {
            return "Memory is under pressure. Biggest: \(top.name) (\(gb(top.rssBytes)))."
        }
        let asking = snap.sessions.filter(\.isWaiting)
        if asking.count > 1 { return "\(asking.count) sessions wait for you." }
        if let s = asking.first { return "“\(s.name.isEmpty ? s.project : s.name)” waits for you." }
        if let s = snap.sessions.filter(\.stillWorking).max(by: { $0.cpu < $1.cpu }) {
            let name = s.name.isEmpty ? s.project : s.name
            return "“\(name)” says idle, but " + (s.busyChild.map { "its \($0)" } ?? "something in it") + " is still working."
        }
        if let top = snap.topCPU.first, top.cpuPercent >= 25 {
            return String(format: "%@ is using %.0f%% of the CPU.", top.name, top.cpuPercent)
        }
        let waiting = snap.suggestions.filter { $0.kind == .runtime }
        let bytes = waiting.reduce(0) { $0 + $1.reclaimBytes }
        if bytes >= 4 << 30 {
            let longest = waiting.compactMap(\.idleSeconds).max() ?? 0
            if waiting.count == 1 { return "\(waiting[0].title) has been open for \(Plural.count(Int(longest / 3600), "hour")) and holds \(gb(bytes))." }
            return "\(waiting.count) simulators, emulators and build daemons hold \(gb(bytes)), open up to \(Plural.count(Int(longest / 3600), "hour"))."
        }
        return nil
    }
}

public enum Actions {
    /// Closing these takes the login session or the whole machine down. Never, whatever is asked.
    public static let untouchable: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Pulse", "Finder", "Dock", "SystemUIServer", "ControlCenter",
        "Control Center", "NotificationCenter", "Notification Center", "WindowManager", "coreaudiod", "securityd", "trustd",
        "opendirectoryd", "cfprefsd", "distnoted", "UserEventAgent", "logd", "mds", "fseventsd", "diskarbitrationd",
    ]

    public static func mayClose(_ c: Consumer, settings: Settings) -> Bool {
        !untouchable.contains(c.name) && !settings.isProtected(c.name)
    }

    /// The user pressed close on a row. Sends SIGTERM to each member that is still the
    /// same process. Returns how many were signalled.
    @discardableResult
    public static func close(_ c: Consumer, settings: Settings) -> Int {
        // A runtime is closed through `close(_: DevRuntime)`, with its own tool.
        guard mayClose(c, settings: settings), c.kind != .runtime else { return 0 }
        return c.members.filter { terminate(pid: $0.pid, expectedStart: $0.lstart) }.count
    }

    /// Shuts a simulator or emulator down with its own tool, a build daemon with SIGTERM.
    /// Only if the root is still the same process, and never a protected name.
    @discardableResult
    public static func close(_ r: DevRuntime, settings: Settings) -> Bool {
        guard !settings.isProtected(r.name), isSame(pid: r.root.pid, expectedStart: r.root.lstart) else { return false }
        switch Runtimes.shutdown(for: r) {
        case let .command(path, args):
            return Shell.succeeds(path, args)
        case .signal:
            return r.members.filter { terminate(pid: $0.pid, expectedStart: $0.lstart) }.count > 0
        }
    }

    static func isSame(pid: Int32, expectedStart: String) -> Bool {
        guard pid > 1, pid != getpid(), !expectedStart.isEmpty else { return false }
        let now = Shell.run("/bin/ps", ["-o", "lstart=", "-p", String(pid)])
        return StartTime.normalize(now) == StartTime.normalize(expectedStart)
    }

    /// SIGTERM, and only if the pid is still the same process (same start time).
    @discardableResult
    public static func terminate(pid: Int32, expectedStart: String) -> Bool {
        isSame(pid: pid, expectedStart: expectedStart) && kill(pid, SIGTERM) == 0
    }

    /// Closes a Claude session only if its own record still says it is idle right now.
    @discardableResult
    public static func closeIdleSession(pid: Int32, dir: URL = ClaudeSessions.defaultDir) -> Bool {
        let file = dir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              d["status"] as? String == "idle",
              let procStart = d["procStart"] as? String else { return false }
        return terminate(pid: pid, expectedStart: procStart)
    }
}
