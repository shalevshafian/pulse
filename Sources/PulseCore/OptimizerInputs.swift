import Foundation

/// What of each process the compressor holds, from `top`. Read only when a plan is made: it takes
/// about half a second, and `top` is the one tool that may read it for every process without root.
public enum Compressed {
    public static func read() -> [Int32: UInt64]? {
        Shell.output("/usr/bin/top", ["-l", "1", "-stats", "pid,cmprs"], timeout: 5).map(parse).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "  417  2464K", "99510  47M+", "1  0B". The header and anything else are skipped.
    static func parse(_ text: String) -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        var table = false
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ")
            if words.first == "PID" { table = true; continue }
            guard table, words.count == 2, let pid = Int32(words[0]), let bytes = size(words[1]) else { continue }
            out[pid] = bytes
        }
        return out
    }

    static func size(_ w: Substring) -> UInt64? {
        var s = w
        while let c = s.last, c == "+" || c == "-" { s = s.dropLast() }
        guard let unit = s.last, let n = Double(s.dropLast()) else { return nil }
        switch unit {
        case "B": return UInt64(n)
        case "K": return UInt64(n * 1024)
        case "M": return UInt64(n * 1_048_576)
        case "G": return UInt64(n * 1_073_741_824)
        default: return nil
        }
    }
}

extension Ports {
    /// Programs with something connected to a port they listen on. Nil when `lsof` did not answer.
    public static func served() -> Set<Int32>? {
        Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN,ESTABLISHED", "-FpnT"], timeout: 8).map(served)
    }

    /// p pid, then per descriptor n "host:port" or "host:port->peer:port", T "ST=LISTEN".
    static func served(_ text: String) -> Set<Int32> {
        var listens: [Int32: Set<String>] = [:], connected: [Int32: Set<String>] = [:]
        var pid: Int32 = 0, name = ""
        func port(_ addr: Substring) -> String? { addr.lastIndex(of: ":").map { String(addr[addr.index(after: $0)...]) } }
        for line in text.split(separator: "\n") {
            let value = line.dropFirst()
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "n": name = String(value)
            case "T":
                guard pid > 0, value.hasPrefix("ST=") else { continue }
                let local = name.split(separator: "-").first ?? Substring(name)
                guard let p = port(local) else { continue }
                if value == "ST=LISTEN" { listens[pid, default: []].insert(p) } else if value == "ST=ESTABLISHED", name.contains("->") { connected[pid, default: []].insert(p) }
            default: continue
            }
        }
        return Set(connected.compactMap { pid, ports in listens[pid].map { $0.isDisjoint(with: ports) } == false ? pid : nil })
    }
}

extension Optimizer {
    /// The name a row's habits are kept under. Sessions by their folder: a session is new each time, its work is not.
    public static func key(_ s: Suggestion) -> String {
        switch s.kind {
        case .idleSession: return "session:" + s.detail
        case .runtime: return "runtime:" + s.title
        case .orphan: return "leftover:" + s.title
        case .heavyApp: return "app:" + s.title
        case .advice: return "advice:" + s.title
        }
    }

    public static func kind(_ s: Suggestion) -> CandidateKind {
        switch s.kind {
        case .idleSession: return .session
        case .orphan, .advice: return .leftover
        case .heavyApp: return .app
        case .runtime:
            switch s.runtimeKind {
            case .simulator: return .simulator
            case .emulator: return .emulator
            default: return .buildDaemon
            }
        }
    }

    /// Every row the plan shows, with what guards it. `frontmost` is the bundle of the app in front.
    public static func candidates(_ snap: Snapshot, compressed: [Int32: UInt64]?, served: Set<Int32>?, frontmost: String?,
                                  memory: OptimizerMemory) -> [Candidate] {
        snap.suggestions.filter { $0.kind != .advice }.map { s in
            let key = key(s)
            var guards: [Guard] = []
            if s.stillWorking { guards.append(.working(s.busyChild)) }
            if s.kind == .heavyApp {
                if let front = frontmost, front == s.bundlePath { guards.append(.inFront(minutes: 0)) } else if let idle = memory.returns.idle(key), idle < 900 {
                    guards.append(.inFront(minutes: Int(idle / 60)))
                }
            }
            if let holder = snap.awake?.first(where: { $0.name == s.title || ($0.pids.contains { s.pids.contains($0) }) }) {
                guards.append(.keepsAwake(holder.reason))
            }
            if s.kind == .orphan {
                if let served { if s.pids.contains(where: served.contains) { guards.append(.servesClients) } } else { guards.append(.couldNotCheck("connections")) }
            }
            let held = compressed.map { c in s.pids.reduce(UInt64(0)) { $0 + (c[$1] ?? 0) } }
            return Candidate(id: s.id, key: key, kind: kind(s), title: s.title, footprint: s.reclaimBytes, compressed: held,
                             idleHint: s.kind == .idleSession ? s.idleSeconds : s.kind == .orphan ? s.idleSeconds : nil,
                             cpuPercent: s.cpuPercent ?? 0, guards: guards)
        }
    }

    /// What was in use at this reading, for the habits. Every app, session and runtime is seen; only
    /// the app in front, a busy or waiting session and a working runtime are in use.
    public static func observe(_ snap: Snapshot, frontmost: String?, into returns: inout Returns, now: Date) {
        var present = Set<String>()
        for s in snap.sessions {
            let key = "session:" + s.project
            present.insert(key)
            if !s.isIdle || s.stillWorking { returns.used(key, now: now) } else { returns.track(key, idle: s.idleSeconds(now: now), now: now) }
        }
        for r in snap.runtimes {
            let key = "runtime:" + r.name
            present.insert(key)
            if r.working { returns.used(key, now: now) } else { returns.track(key, idle: nil, now: now) }
        }
        for c in snap.consumers where c.kind == .app {
            let key = "app:" + c.name
            present.insert(key)
            if let b = c.bundlePath, b == frontmost { returns.used(key, now: now) } else { returns.track(key, idle: nil, now: now) }
        }
        // Closed and not back for three days: the pause is known to be at least that long, and is counted so.
        for (key, h) in returns.habits where !present.contains(key) && h.lastUse.map({ returns.clock - $0 >= Returns.edges.last! }) == true {
            returns.gone(key, now: now)
        }
    }
}

extension Returns {
    /// First sight of something not in use: its pause starts now, or when its own tool says it went idle.
    public mutating func track(_ key: String, idle: Double?, now: Date) {
        guard habits[key]?.lastUse == nil else { return }
        var h = habits[key] ?? Habit()
        h.lastUse = clock - max(0, idle ?? 0)
        h.stamp = h.stamp ?? now
        habits[key] = h
    }
}
