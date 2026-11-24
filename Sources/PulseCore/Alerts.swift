import Foundation

public struct PulseAlert: Equatable, Sendable {
    public var key: String
    public var title: String
    public var body: String

    public init(key: String, title: String, body: String) {
        self.key = key; self.title = title; self.body = body
    }
}

/// Decides when something deserves a notification. Pure: it is fed readings with their
/// time and returns what to announce, so the rules can be tested without waiting.
public struct AlertEngine {
    /// The same thing is not announced again inside this window.
    public static let cooldown: TimeInterval = 30 * 60
    static let tempHold: TimeInterval = 60
    static let waitHold: TimeInterval = 30

    var cpuSince: [String: Date] = [:]
    var tempSince: Date?
    var lastSent: [String: Date] = [:]
    var memoryWasHigh = false
    /// When each waiting session began to wait, and whether it was announced. Forgotten once it
    /// was seen doing anything else, so a wait is announced once however long it lasts.
    var waits: [Int32: (since: Date, said: Bool)] = [:]

    public init() {}

    public mutating func evaluate(system: SystemStats, consumers: [Consumer], sessions: [ClaudeSession] = [], settings: Settings, now: Date) -> [PulseAlert] {
        var out: [PulseAlert] = []

        if settings.alertCPU {
            var still: [String: Date] = [:]
            for c in consumers where c.cpuPercent >= settings.alertCPUPercent {
                let since = cpuSince[c.id] ?? now
                still[c.id] = since
                if now.timeIntervalSince(since) >= settings.alertCPUMinutes * 60 {
                    out.append(PulseAlert(
                        key: "cpu:" + c.id,
                        title: "\(c.name) is using a lot of CPU",
                        body: String(format: "%.0f%% of this Mac for %.0f minutes.", c.cpuPercent, now.timeIntervalSince(since) / 60)))
                }
            }
            cpuSince = still
        } else {
            cpuSince = [:]
        }

        if settings.alertTemp, let t = system.chipTempC, t >= settings.alertTempC {
            let since = tempSince ?? now
            tempSince = since
            if now.timeIntervalSince(since) >= Self.tempHold {
                out.append(PulseAlert(key: "temp", title: "The Mac is hot", body: String(format: "The chip is at %.0f°.", t)))
            }
        } else {
            tempSince = nil
        }

        let memoryHigh = system.memPressureLevel >= 2
        if settings.alertMemory, memoryHigh, !memoryWasHigh {
            out.append(PulseAlert(key: "memory", title: "Memory is under pressure", body: "macOS is compressing and swapping. Open Pulse to see what can be closed."))
        }
        memoryWasHigh = memoryHigh

        return out.filter { alert in
            if let last = lastSent[alert.key], now.timeIntervalSince(last) < Self.cooldown { return false }
            lastSent[alert.key] = now
            return true
        } + waiting(sessions, settings: settings, now: now)
    }

    /// Outside the cooldown: a session answered and waiting again is news.
    private mutating func waiting(_ sessions: [ClaudeSession], settings: Settings, now: Date) -> [PulseAlert] {
        var still: [Int32: (since: Date, said: Bool)] = [:]
        var out: [PulseAlert] = []
        for s in sessions where s.isWaiting {
            var w = waits[s.pid] ?? (min(s.statusSince ?? now, now), false)
            if !w.said, now.timeIntervalSince(w.since) >= Self.waitHold {
                w.said = true
                if settings.alertWaiting {
                    out.append(PulseAlert(key: "wait:\(s.pid)", title: s.name.isEmpty ? s.project : s.name, body: s.waitingText ?? ""))
                }
            }
            still[s.pid] = w
        }
        waits = still
        return out
    }
}
