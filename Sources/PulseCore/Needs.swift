import Foundation

/// One thing that is worth a person's attention now, and the one place where it is dealt with.
public struct Need: Codable, Sendable, Equatable, Identifiable {
    /// `now` costs something every minute, `soon` should be dealt with, `know` is only worth knowing.
    public enum Level: Int, Codable, Sendable, Comparable {
        case now, soon, know
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    public enum Place: String, Codable, Sendable { case session, row, plan, cleanup, sleep, drives, health, sessions }

    public var id: String
    public var level: Level
    public var title: String
    public var detail: String
    /// The word on its button.
    public var verb: String
    public var place: Place
    /// The session's pid, the row's id, the health check's id.
    public var ref: String?

    public init(_ id: String, _ level: Level, _ title: String, _ detail: String, verb: String, place: Place, ref: String? = nil) {
        self.id = id; self.level = level; self.title = title; self.detail = detail; self.verb = verb; self.place = place; self.ref = ref
    }
}

/// Every source in one list, the costliest first. Pure: what was read goes in, rows come out.
public enum Needs {
    /// "Not today".
    public static let rest: TimeInterval = 24 * 3600

    /// A finding of health and a reading of now can be the same thing said twice.
    static let sameAsNow: Set<String> = ["memory", "thermal", "cleanup"]

    public static func build(snap: Snapshot?, health: HealthStore, plan: [PlanUsage] = [], drivesOut: [String] = [], hidden: [String: Date] = [:],
                             settings: Settings = Settings(), now: Date) -> [Need] {
        var out: [Need] = []
        if let snap {
            let s = snap.system
            if s.memPressureLevel >= 2 {
                let top = snap.topMemory.first
                out.append(Need("memory", .now, s.memPressureLevel >= 4 ? "Memory is critical" : "Memory is under pressure",
                                top.map { "Biggest: \($0.name), \(gb($0.rssBytes))" } ?? "macOS is compressing and swapping", verb: "Optimize", place: .plan))
            }
            if s.thermal == "serious" || s.thermal == "critical" {
                let top = snap.topCPU.first
                out.append(Need("heat", .now, "The Mac is slowing itself down: heat", top.map { String(format: "%@ is using %.0f%% of the CPU", $0.name, $0.cpuPercent) } ?? "",
                                verb: "Look", place: .row, ref: top?.id))
            }
            for w in snap.sessions where w.isWaiting {
                out.append(Need("wait:\(w.pid)", .now, w.name.isEmpty ? w.project : w.name,
                                (w.waitingText ?? "Waiting for you") + (w.statusSince.map { since(now.timeIntervalSince($0)) } ?? ""), verb: "Open", place: .session, ref: String(w.pid)))
            }
            for w in snap.sessions where w.stillWorking {
                out.append(Need("still:\(w.pid)", .know, w.name.isEmpty ? w.project : w.name,
                                "Says idle, but " + (w.busyChild.map { "its \($0)" } ?? "something in it") + " still works", verb: "Look", place: .row, ref: "session:\(w.pid)"))
            }
            if s.thermal != "serious", s.thermal != "critical", let top = snap.topCPU.first, top.cpuPercent >= 25, top.kind != .session {
                out.append(Need("cpu:" + top.id, .know, "\(top.name) is busy", String(format: "%.0f%% of this Mac's CPU", top.cpuPercent), verb: "Look", place: .row, ref: top.id))
            }
        }
        for name in drivesOut {
            out.append(Need("drive:" + name, .soon, "\(name) is still disconnected", "Pulse let go of it before sleep", verb: "Connect", place: .drives))
        }
        for p in plan {
            guard let l = p.limits.max(by: { $0.percent < $1.percent }), l.percent >= 90 else { continue }
            out.append(Need("limit:" + p.tool, .soon, String(format: "%@ plan %.0f%% used", p.tool, l.percent), l.name + ", " + PlanUsage.resets(l.resetsAt, now: now), verb: "See", place: .sessions))
        }
        for c in health.problems {
            // Pressure and heat are read every few seconds above; the check is hours old.
            if c.id == "cleanup" || snap != nil, sameAsNow.contains(c.id) { continue }
            out.append(Need("health:" + c.id, c.state == .urgent ? .now : .soon, c.title, c.detail, verb: c.fix.map(verb) ?? "See", place: .health, ref: c.id))
        }
        let free = (health.report?.cleanup ?? []).filter { $0.blockedBy == nil && !settings.isProtected($0.title, $0.path) }
        let bytes = free.reduce(0) { $0 + $1.bytes }
        if bytes >= 5 << 30, !health.ignored.contains("cleanup") {
            out.append(Need("cleanup", .know, "\(gb(bytes)) can be cleared", "\(free[0].title)" + (free.count > 1 ? " and \(free.count - 1) more" : "") + ", built again when needed", verb: "Choose", place: .cleanup))
        }
        // A thing that is happening now keeps its place; "not today" is for what can wait.
        let kept = out.filter { n in n.id == "memory" || n.id == "heat" || hidden[n.id].map { now.timeIntervalSince($0) >= rest } ?? true }
        return kept.enumerated().sorted { $0.element.level != $1.element.level ? $0.element.level < $1.element.level : $0.offset < $1.offset }.map(\.element)
    }

    static func verb(_ f: HealthFix) -> String {
        switch f {
        case .timeMachine: return "Set up"
        case .cleanup: return "Choose"
        case .acceptStartup, .sleep: return "Look"
        case .plan: return "Optimize"
        default: return "Open"
        }
    }

    private static func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    private static func since(_ s: TimeInterval) -> String { s < 60 ? "" : s < 7200 ? ", \(Int(s / 60)) min" : ", \(Int(s / 3600)) h" }
}
