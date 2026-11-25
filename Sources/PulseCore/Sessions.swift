import Foundation

public struct ClaudeSession: Codable, Sendable, Identifiable {
    public var pid: Int32
    public var sessionId: String
    public var name: String
    public var cwd: String
    /// "idle", "busy", or whatever Claude Code writes next.
    public var status: String
    public var entrypoint: String
    public var procStart: String
    public var statusSince: Date?
    /// The session process plus everything it spawned.
    public var rssBytes: UInt64
    public var cpu: Double
    public var processCount: Int
    /// The busiest process the session spawned, when it is really working: a session
    /// can say "idle" while a build or a script it started is still running.
    public var busyChild: String? = nil
    public var busyChildCPU: Double = 0
    /// What a waiting session waits for, in Claude Code's own words.
    public var waitingFor: String? = nil
    /// The apps it was started from, the nearest first.
    public var hosts: [String]? = nil

    /// Above this (percent of one core, the whole tree) an idle session is still working.
    public static let workingCPU: Double = 25
    public var stillWorking: Bool { isIdle && cpu >= Self.workingCPU }

    public var id: Int32 { pid }
    public var project: String { (cwd as NSString).lastPathComponent }
    public var isIdle: Bool { status == "idle" }
    /// It asked something and stands still until someone answers.
    public var isWaiting: Bool { status == "waiting" }
    public var isWorking: Bool { status == "busy" }
    /// A status nobody has seen yet is not called work, and is never idle.
    public var stateWord: String { isWaiting ? "Needs input" : isIdle ? "Idle" : isWorking ? "Working" : "Status unknown" }
    /// Waiting, working, idle.
    var rank: Int { isWaiting ? 0 : isIdle ? 2 : 1 }

    /// The record is not a public format: words nobody has seen yet say only that it waits.
    public var waitingText: String? {
        guard isWaiting else { return nil }
        switch waitingFor {
        case "permission prompt": return "Needs input: permission"
        case "input needed": return "Needs input: an answer"
        case "sandbox request": return "Needs input: sandbox access"
        case "dialog open": return "Needs input: an open dialog"
        case "goal proposal": return "Needs input: a goal to approve"
        case "worker request": return "Needs input: a worker's request"
        default: return "Needs input"
        }
    }

    public func idleSeconds(now: Date) -> TimeInterval {
        guard isIdle, let statusSince else { return 0 }
        return max(0, now.timeIntervalSince(statusSince))
    }
}

/// The panel shows no emoji. Session names are written by other
/// tools and often start with one, so they are cleaned where they are read.
public enum Plain {
    public static func text(_ s: String) -> String {
        let kept = s.filter { ch in
            !ch.unicodeScalars.contains { u in
                u.properties.isEmojiPresentation || u.value == 0xFE0F || u.value == 0x200D
                    || (u.properties.isEmoji && u.value >= 0x2190)
            }
        }
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum ClaudeSessions {
    public static var defaultDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
    }

    /// Reads only the `<pid>.json` records. The `.key` files beside them are never opened.
    public static func load(dir: URL = defaultDir, table: ProcTable, excluding: Set<Int32> = []) -> [ClaudeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [ClaudeSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNum = d["pid"] as? NSNumber else { continue }
            let pid = pidNum.int32Value
            let procStart = d["procStart"] as? String ?? ""
            guard isLive(pid: pid, procStart: procStart, table: table) else { continue }
            // A simulator or emulator the session started is its own row, not part of the session.
            let tree = table.tree(of: pid).filter { !excluding.contains($0.pid) }
            let busiest = tree.filter { $0.pid != pid }.max { $0.cpu < $1.cpu }
            let ms = (d["statusUpdatedAt"] as? NSNumber ?? d["updatedAt"] as? NSNumber)?.doubleValue
            out.append(ClaudeSession(
                pid: pid,
                sessionId: d["sessionId"] as? String ?? "",
                name: Plain.text(d["name"] as? String ?? ""),
                cwd: d["cwd"] as? String ?? "",
                status: d["status"] as? String ?? "unknown",
                entrypoint: d["entrypoint"] as? String ?? "",
                procStart: procStart,
                statusSince: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
                rssBytes: tree.reduce(0) { $0 + $1.rssBytes },
                cpu: tree.reduce(0) { $0 + $1.cpu },
                processCount: tree.count,
                busyChild: busiest.flatMap { $0.cpu >= 5 ? ($0.program as NSString).lastPathComponent : nil },
                busyChildCPU: busiest?.cpu ?? 0,
                waitingFor: (d["waitingFor"] as? String).map(Plain.text),
                hosts: hosts(of: pid, table: table)))
        }
        return out.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.rssBytes > $1.rssBytes
        }
    }

    /// The app bundles above a process, the nearest first.
    static func hosts(of pid: Int32, table: ProcTable) -> [String] {
        var out: [String] = []
        var at = table.byPid[pid]?.ppid ?? 0
        var hops = 0
        while at > 1, hops < 12, let p = table.byPid[at] {
            if let b = AppGroups.bundlePath(of: p.program), !out.contains(b) { out.append(b) }
            at = p.ppid
            hops += 1
        }
        return out
    }

    /// A pid alone proves nothing: pids are reused. The session is live only when the
    /// process that now holds the pid started at the moment the session file recorded.
    public static func isLive(pid: Int32, procStart: String, table: ProcTable) -> Bool {
        guard let p = table.byPid[pid], !procStart.isEmpty else { return false }
        return StartTime.normalize(p.lstart) == StartTime.normalize(procStart)
    }
}
