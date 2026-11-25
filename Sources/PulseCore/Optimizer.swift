import Foundation

/// Why a row is not suggested, whatever its score. Checked again when the button is pressed.
public enum Guard: Codable, Sendable, Equatable {
    case working(String?)
    case inFront(minutes: Int)
    case keepsAwake(String)
    case servesClients
    case couldNotCheck(String)
    case openedAgain

    public var words: String {
        switch self {
        case .working(let what): return what.map { "its \($0) is working" } ?? "it is working"
        case .inFront(let m): return m == 0 ? "it is in front now" : "it was in front \(m) min ago"
        case .keepsAwake(let why): return why == "audio" ? "it plays or records sound" : "it keeps the Mac awake (\(why))"
        case .servesClients: return "something is connected to it"
        case .couldNotCheck(let what): return "Pulse could not check its \(what)"
        case .openedAgain: return "you opened it again after Pulse closed it"
        }
    }
}

/// One row the optimizer may suggest, with what is known about it.
public struct Candidate: Sendable, Equatable {
    public var id: String
    /// The name its habits are kept under: "app:Safari", "session:api".
    public var key: String
    public var kind: CandidateKind
    public var title: String
    public var footprint: UInt64
    /// What of it the compressor holds, at its size before compression. Nil when it could not be read.
    public var compressed: UInt64?
    /// Idle seconds as its own tool says, when there is such a tool (a session's record).
    public var idleHint: TimeInterval?
    public var cpuPercent: Double
    public var guards: [Guard]

    public init(id: String, key: String, kind: CandidateKind, title: String, footprint: UInt64, compressed: UInt64?, idleHint: TimeInterval?,
                cpuPercent: Double = 0, guards: [Guard] = []) {
        self.id = id; self.key = key; self.kind = kind; self.title = title; self.footprint = footprint; self.compressed = compressed
        self.idleHint = idleHint; self.cpuPercent = cpuPercent; self.guards = guards
    }
}

/// The score of one row, and the words for it. The words are made from the same numbers.
public struct Score: Codable, Sendable, Equatable {
    public var id: String
    /// What closing it is expected to give back to RAM, after calibration.
    public var ramBack: UInt64
    /// How much it eases the compressor, the thing that makes macOS warn.
    public var relief: UInt64
    /// The chance it is wanted again within the horizon.
    public var comeBack: Double
    /// Seconds a person is expected to lose by closing it.
    public var cost: Double
    public var confidence: Double
    public var guards: [Guard]
    /// In the set Pulse would close to reach the target.
    public var suggested: Bool
    /// Why, one sentence each: use, memory, the way back, and any guard.
    public var reasons: [String]
    /// Left behind and using the CPU: worth closing whatever memory does.
    public var cpuLane = false

    public var confidenceWord: String { confidence >= 0.7 ? "high" : confidence >= 0.4 ? "medium" : "low" }
}

/// What the optimizer says as a whole.
public struct Verdict: Codable, Sendable, Equatable {
    public enum Advice: String, Codable, Sendable { case nothing, later, now, noGoodOption }

    public var state: MemoryState
    public var advice: Advice
    public var title: String
    public var detail: String
    /// Compressor bytes to take off; zero when nothing is needed.
    public var target: UInt64
    /// How much the suggested rows ease the compressor together, against the target.
    public var covers: UInt64
    /// What they are expected to give back to RAM together: the number a person sees.
    public var ramBack: UInt64 = 0
    /// Memory that can be taken without macOS compressing more: free and cached. For an agent about to start something heavy.
    public var availableBytes: UInt64
    public var forecastMinutes: Double?
    public var growing: [Growing]
    public var scores: [Score]
    /// "learned" when the state comes from the menu bar app's minute of readings, "instant" from one reading.
    public var basis: String

    public var suggested: [String] { scores.filter(\.suggested).map(\.id) }
}

/// Something whose memory has only grown for at least half an hour.
public struct Growing: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var perHour: UInt64
    public var gained: UInt64
    public var minutes: Int
}

public enum Optimizer {
    /// How far ahead a return is counted, in awake time.
    public static let horizon: TimeInterval = 4 * 3600
    /// What a gigabyte-hour of relief is worth, in seconds of a person's time, by state.
    static func worth(_ s: MemoryState) -> Double { s == .critical ? 20 : s == .strained ? 4 : 0 }
    /// Resident pages ease the compressor only by making room for it.
    static let residentRelief = 0.5
    static let unit: UInt64 = 64 << 20

    public struct Inputs: Sendable {
        public var candidates: [Candidate]
        public var vm: VMReading?
        public var state: MemoryState
        public var swapinRate: Double
        public var forecastMinutes: Double?
        public var memory: OptimizerMemory
        public var memUsed: UInt64
        public var growing: [Growing]
        public var learned: Bool
        public var now: Date
        /// Instead of the target read from the kernel: for simulations.
        public var target: UInt64?

        public init(candidates: [Candidate], vm: VMReading?, state: MemoryState, swapinRate: Double = 0, forecastMinutes: Double? = nil,
                    memory: OptimizerMemory = OptimizerMemory(), memUsed: UInt64 = 0, growing: [Growing] = [], learned: Bool = false, now: Date,
                    target: UInt64? = nil) {
            self.target = target
            self.candidates = candidates; self.vm = vm; self.state = state; self.swapinRate = swapinRate; self.forecastMinutes = forecastMinutes
            self.memory = memory; self.memUsed = memUsed; self.growing = growing; self.learned = learned; self.now = now
        }
    }

    public static func decide(_ x: Inputs) -> Verdict {
        let k = x.vm?.compression ?? 0.33
        let target = x.target ?? PressureTracker.target(x.vm, state: x.state, swapinRate: x.swapinRate)
        let horizon = x.state == .critical ? 3600 : Self.horizon
        var scores = x.candidates.map { score($0, x: x, k: k, horizon: horizon) }

        // The set to close: the least expected loss that still reaches the target.
        let open = scores.indices.filter { scores[$0].guards.isEmpty && worthIt(scores[$0], state: x.state, horizon: horizon) }
        let chosen = target == 0 ? [] : cover(open.map { (scores[$0].relief, scores[$0].cost, scores[$0].id) }, target: target).map { open[$0] }
        for i in chosen { scores[i].suggested = true }
        for i in scores.indices where scores[i].cpuLane && scores[i].guards.isEmpty { scores[i].suggested = true }
        let covers = scores.filter(\.suggested).reduce(0) { $0 + $1.relief }

        scores.sort {
            if $0.suggested != $1.suggested { return $0.suggested }
            if $0.guards.isEmpty != $1.guards.isEmpty { return $0.guards.isEmpty }
            let a = $0.cost / max(Double($0.relief), 1), b = $1.cost / max(Double($1.relief), 1)
            return a != b ? a < b : $0.id < $1.id
        }
        let available = x.vm.map { $0.free + $0.inactive } ?? 0
        var v = Verdict(state: x.state, advice: .nothing, title: "", detail: "", target: target, covers: covers, availableBytes: available,
                        forecastMinutes: x.forecastMinutes, growing: x.growing, scores: scores, basis: x.learned ? "learned" : "instant")
        v.ramBack = scores.filter(\.suggested).reduce(0) { $0 + $1.ramBack }
        words(&v, memUsed: x.memUsed)
        return v
    }

    static func score(_ c: Candidate, x: Inputs, k: Double, horizon: TimeInterval) -> Score {
        let rho = x.memory.calibration.share(of: c.kind)
        let z = Double(min(c.compressed ?? 0, c.footprint)), f = Double(c.footprint)
        let ram = rho * ((f - z) + k * z)
        let relief = rho * (k * z + residentRelief * (f - z))
        let idle = x.memory.returns.idle(c.key) ?? c.idleHint ?? 0
        let back = x.memory.returns.comeBack(c.key, kind: c.kind, idle: idle, horizon: horizon)
        let factor = x.memory.taste.factor(key: c.key, kind: c.kind, now: x.now)
        let cost = factor * back.p * c.kind.reopenSeconds + 2
        var guards = c.guards
        if let at = x.memory.reopened[c.key], x.now.timeIntervalSince(at) < 86400 { guards.append(.openedAgain) }
        let seen = Double(back.seen)
        let confidence = (0.3 + 0.7 * seen / (seen + 4)) * (c.compressed == nil ? 0.7 : 1)
        var s = Score(id: c.id, ramBack: UInt64(max(0, ram)), relief: UInt64(max(0, relief)), comeBack: back.p, cost: cost,
                      confidence: confidence, guards: guards, suggested: false, reasons: [])
        s.cpuLane = c.kind == .leftover && c.cpuPercent >= 10
        s.reasons = reasons(c, s, idle: idle, seen: back.seen, cameBack: back.cameBack, horizon: horizon)
        return s
    }

    /// A row is worth closing only if the relief, for the hours ahead, outweighs what its return would cost.
    static func worthIt(_ s: Score, state: MemoryState, horizon: TimeInterval) -> Bool {
        worth(state) * Double(s.relief) / 1_073_741_824 * horizon / 3600 > s.cost
    }

    /// Minimum-cost cover by dynamic programming over 64 MB units: exact, and under a millisecond for forty rows.
    /// Ties go to fewer rows. When even all of them do not reach the target, all of them.
    static func cover(_ items: [(relief: UInt64, cost: Double, id: String)], target: UInt64) -> [Int] {
        guard !items.isEmpty, target > 0 else { return [] }
        let need = Int(min((target + unit - 1) / unit, 256))
        let units = items.map { Int($0.relief / unit) }
        if units.reduce(0, +) < need { return Array(items.indices) }
        struct Cell: Comparable { var cost: Double, count: Int
            static func < (a: Cell, b: Cell) -> Bool { a.cost != b.cost ? a.cost < b.cost : a.count < b.count } }
        let none = Cell(cost: .infinity, count: .max)
        var best = [Cell](repeating: none, count: need + 1)
        best[0] = Cell(cost: 0, count: 0)
        var took = [[Bool]](repeating: [Bool](repeating: false, count: need + 1), count: items.count)
        // Input order must not matter: always the same order, by id.
        let order = items.indices.sorted { items[$0].id < items[$1].id }
        for i in order where units[i] > 0 {
            for j in stride(from: need, through: 0, by: -1) {
                let from = max(0, j - units[i])
                guard best[from].cost.isFinite else { continue }
                let c = Cell(cost: best[from].cost + items[i].cost, count: best[from].count + 1)
                if c < best[j] { best[j] = c; took[i][j] = true }
            }
        }
        // Walk back through the items in reverse order of their pass.
        var j = need, out: [Int] = []
        for i in order.reversed() where units[i] > 0 && j > 0 && took[i][j] {
            out.append(i)
            j = max(0, j - units[i])
        }
        return out.sorted()
    }

    // MARK: Words. Every number in a sentence is one of the terms above.

    static func reasons(_ c: Candidate, _ s: Score, idle: Double, seen: Int, cameBack: Int, horizon: TimeInterval) -> [String] {
        var out: [String] = []
        let h = Int(horizon / 3600)
        // What Pulse saw, not what it was told: it counts from when it last saw the thing in use, or first saw it at all.
        let idleWords = idle >= 60 ? "Not seen in use for \(duration(idle))." : "Seen in use just now."
        if seen >= 3 {
            out.append(idleWords + " Of \(seen) pauses this long, \(cameBack) ended within \(h) h.")
        } else if idle >= 60 {
            out.append(idleWords + " Typical for \(c.kind.noun): \(odds(s.comeBack)) come back within \(h) h. Not yet your own habit.")
        } else {
            out.append(idleWords)
        }
        if s.cpuLane { out.append(String(format: "Left behind, and using %.0f%% of the CPU.", c.cpuPercent)) }
        if let z = c.compressed {
            out.append(z * 2 > c.footprint
                ? "Gives back about \(gb(s.ramBack)) to RAM. \(gb(c.footprint)) is counted, most of it compressed."
                : "Gives back about \(gb(s.ramBack)) to RAM.")
        } else {
            out.append("Gives back up to \(gb(s.ramBack)) to RAM.")
        }
        out.append(c.kind.wayBack)
        if let g = s.guards.first { out.append("Not suggested: " + g.words + ".") }
        return out
    }

    static func words(_ v: inout Verdict, memUsed: UInt64) {
        let n = v.suggested.count
        switch v.state {
        case .calm:
            v.advice = .nothing
            v.title = "Nothing to do"
            v.detail = (memUsed > 0 ? "\(gb(memUsed)) is in use, and " : "") + "macOS is not short of memory. Closing things now would not help it."
        case .tight:
            v.advice = .later
            v.title = "Memory is getting tight"
            v.detail = v.forecastMinutes.map { "At this rate macOS will start to warn in about \(Int($0.rounded())) min. Nothing to close yet." }
                ?? "The compressor holds a lot, but macOS does not warn. Nothing to close yet."
        case .strained, .critical:
            let short = v.state == .critical ? "Memory is very short" : "Memory is short"
            if n == 0 {
                v.advice = .noGoodOption
                v.title = short
                v.detail = "Everything large is in use. Pulse suggests nothing; quitting an app you are done with helps."
            } else {
                v.advice = .now
                v.title = "Close " + (n == 1 ? "one row" : "\(n) rows") + " to ease memory"
                v.detail = (n == 1 ? "It gives" : "They give") + " back about \(gb(v.ramBack)), and you are the least likely to want "
                    + (n == 1 ? "it" : "them") + " soon." + (v.covers >= v.target ? "" : " It may not be enough: the rest is in use.")
            }
        }
        if v.advice != .now, let g = v.growing.first {
            v.detail += " \(g.name) has grown by \(gb(g.gained)) in \(g.minutes) min."
        }
    }

    static func odds(_ p: Double) -> String {
        if p >= 0.95 { return "almost all" }
        if p >= 0.15 { return "about \(Int((p * 10).rounded())) in 10" }
        if p < 0.02 { return "almost none" }
        return "about 1 in \(Int((1 / p).rounded()))"
    }

    static func gb(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    static func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(max(m, 1)) min" : m < 48 * 60 ? "\(m / 60) h" : "\(m / 1440) days"
    }
}

extension CandidateKind {
    var noun: String {
        switch self {
        case .app: return "an app"
        case .session: return "a session"
        case .simulator: return "a simulator"
        case .emulator: return "an emulator"
        case .buildDaemon: return "a build daemon"
        case .leftover: return "a leftover process"
        }
    }

    var wayBack: String {
        switch self {
        case .app: return "Way back: open it again. It may ask to save first."
        case .session: return "Way back: resume it. The conversation stays on this Mac."
        case .simulator: return "Way back: boot it again. Its data stays."
        case .emulator: return "Way back: start it again. Its data stays."
        case .buildDaemon: return "Starts again by itself on the next build."
        case .leftover: return "No way back: Pulse cannot start it again."
        }
    }
}
