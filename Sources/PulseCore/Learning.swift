import Foundation

/// When each thing was last in use and how long its pauses tend to last, counted in awake time.
/// A model of piecewise constant return rates, smoothed towards a prior for its kind: with no history
/// it says what is typical, and every pause seen moves it towards this user's own habit.
public struct Returns: Codable, Sendable, Equatable {
    /// Edges of the pause lengths, in seconds: one minute to three days.
    public static let edges: [Double] = [60, 300, 900, 1800, 3600, 7200, 14400, 28800, 43200, 86400, 172_800, 259_200]
    /// Pauses decay with a half life of two weeks: an old habit counts less than a new one.
    static let halfLife: TimeInterval = 14 * 86400
    /// How many pauses the prior is worth.
    static let priorWeight = 4.0

    public struct Habit: Codable, Sendable, Equatable {
        /// Per bin: pauses that ended in it (the thing was used again), and the hours spent in it by all pauses.
        public var ended: [Double] = Array(repeating: 0, count: Returns.edges.count)
        public var hours: [Double] = Array(repeating: 0, count: Returns.edges.count)
        /// Pauses that reached the bin, ended or not.
        public var reached: [Double] = Array(repeating: 0, count: Returns.edges.count)
        /// Awake clock of the last use, and the wall time the counts were last decayed at.
        public var lastUse: Double?
        public var stamp: Date?
        public var pauses: Double = 0
    }

    public var habits: [String: Habit] = [:]
    /// Seconds this Mac was awake while Pulse looked. Stands still in sleep and while Pulse is not running.
    public var clock: Double = 0
    private var lastTick: TimeInterval?
    private enum CodingKeys: String, CodingKey { case habits, clock }

    public init() {}

    /// Advances the awake clock. A gap over two minutes is sleep or Pulse not running: it adds nothing.
    public mutating func tick(uptime: TimeInterval) {
        if let lastTick, uptime > lastTick, uptime - lastTick <= 120 { clock += uptime - lastTick }
        lastTick = uptime
    }

    /// The thing is in use now: in front, busy, or building.
    public mutating func used(_ key: String, now: Date) {
        var h = decayed(habits[key] ?? Habit(), now: now)
        if let last = h.lastUse, clock - last >= Self.edges[0] { h.add(pause: clock - last, ended: true) }
        h.lastUse = clock
        habits[key] = h
        trim()
    }

    /// The thing was closed or went away while idle: its pause is known to have lasted at least this long.
    public mutating func gone(_ key: String, now: Date) {
        guard var h = habits[key], let last = h.lastUse else { return }
        h = decayed(h, now: now)
        if clock - last >= Self.edges[0] { h.add(pause: clock - last, ended: false) }
        h.lastUse = nil
        habits[key] = h
    }

    /// Awake seconds since its last use. Nil when Pulse never saw it in use.
    public func idle(_ key: String) -> Double? { habits[key]?.lastUse.map { max(0, clock - $0) } }

    /// The chance it is used again within `horizon` seconds of awake time, now that it has been idle `idle`.
    public func comeBack(_ key: String, kind: CandidateKind, idle: Double, horizon: Double) -> (p: Double, seen: Int, cameBack: Int) {
        let h = habits[key] ?? Habit()
        var exposure = 0.0, seen = 0.0, back = 0.0
        let from = max(idle, Self.edges[0]), to = from + horizon
        for b in Self.edges.indices {
            let lo = Self.edges[b], hi = b + 1 < Self.edges.count ? Self.edges[b + 1] : .infinity
            let overlap = max(0, min(hi, to) - max(lo, from)) / 3600
            guard overlap > 0 else { continue }
            let widthHours = (hi.isFinite ? hi - lo : 86400) / 3600
            let prior = kind.priorRate(atHours: (lo + min(hi, lo + 86400)) / 2 / 3600)
            // Gamma-Poisson: the prior is `priorWeight` pauses spent in the bin at the prior rate.
            let rate = (h.ended[b] + prior * Self.priorWeight * widthHours) / (h.hours[b] + Self.priorWeight * widthHours)
            exposure += rate * overlap
            back += h.ended[b]
        }
        if let b = Self.bin(from) { seen = h.reached[b] }
        return (1 - exp(-exposure), Int(seen.rounded()), Int(min(back, seen).rounded()))
    }

    static func bin(_ seconds: Double) -> Int? { edges.lastIndex { $0 <= seconds } }

    private func decayed(_ h: Habit, now: Date) -> Habit {
        guard let stamp = h.stamp else { var n = h; n.stamp = now; return n }
        let f = pow(0.5, max(0, now.timeIntervalSince(stamp)) / Self.halfLife)
        guard f < 0.999 else { return h }
        var n = h
        n.ended = h.ended.map { $0 * f }; n.hours = h.hours.map { $0 * f }; n.reached = h.reached.map { $0 * f }
        n.pauses *= f; n.stamp = now
        return n
    }

    /// At most 200 names; the ones not used longest go first.
    private mutating func trim() {
        guard habits.count > 200 else { return }
        for (k, _) in habits.sorted(by: { ($0.value.lastUse ?? -1) < ($1.value.lastUse ?? -1) }).prefix(habits.count - 200) { habits[k] = nil }
    }
}

extension Returns.Habit {
    mutating func add(pause: Double, ended: Bool) {
        pauses += 1
        for b in Returns.edges.indices {
            let lo = Returns.edges[b], hi = b + 1 < Returns.edges.count ? Returns.edges[b + 1] : .infinity
            guard pause >= lo else { break }
            reached[b] += 1
            hours[b] += (min(pause, hi) - lo) / 3600
            if ended, pause < hi { self.ended[b] += 1 }
        }
    }
}

/// What kind of thing a candidate is, with what is typical for it before Pulse knows this user.
public enum CandidateKind: String, Codable, Sendable, CaseIterable {
    case app, session, simulator, emulator, buildDaemon, leftover

    /// Return rate an hour, before any history. From what a person typically does: an app idle an hour
    /// comes back within four hours six times in ten, a day-old one once in ten. A constant to tune, not a fact.
    func priorRate(atHours t: Double) -> Double {
        // p(4 h) at idle 1, 4, 12 and 24 hours, turned into a rate: -ln(1 - p) / 4.
        let table: [Double]
        switch self {
        case .app: table = [0.60, 0.35, 0.15, 0.10]
        case .session: table = [0.45, 0.25, 0.10, 0.05]
        case .simulator, .emulator, .buildDaemon: table = [0.30, 0.15, 0.08, 0.05]
        case .leftover: table = [0.05, 0.03, 0.02, 0.01]
        }
        // Each p is an average over the four hours after the idle time, so it is the rate two hours on.
        let at: [Double] = [3, 6, 14, 26]
        let rates = table.map { -log(1 - $0) / 4 }
        if t <= at[0] { return rates[0] * min(3, at[0] / max(t, 0.05)).squareRoot() }
        for i in 1..<at.count where t <= at[i] {
            let f = (t - at[i - 1]) / (at[i] - at[i - 1])
            return rates[i - 1] + f * (rates[i] - rates[i - 1])
        }
        return rates[3]
    }

    /// Seconds a person loses when it is closed and wanted again: opening it, then finding the place.
    public var reopenSeconds: Double {
        switch self {
        case .app: return 28
        case .session: return 20
        case .simulator: return 35
        case .emulator: return 40
        case .buildDaemon: return 20
        // Nothing starts it again.
        case .leftover: return 65
        }
    }
}

/// What the user's own choices say about closing a kind of thing, and one thing by name.
/// Beta counts, decayed over a month. They change how much a return costs, by a factor of a half to two,
/// and nothing else: they never lift a guard and never change how much memory is needed.
public struct Taste: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable { public var close = 0.0, keep = 0.0, stamp: Date? }
    public var byKey: [String: Counts] = [:]
    public var byKind: [String: Counts] = [:]
    static let halfLife: TimeInterval = 30 * 86400

    public init() {}

    public enum Choice: Sendable { case ticked, unticked, acceptedAsIs, openedAgain }

    public mutating func learn(_ choice: Choice, key: String, kind: CandidateKind, now: Date) {
        let (close, keep): (Double, Double)
        switch choice {
        case .ticked: (close, keep) = (1, 0)
        case .unticked: (close, keep) = (0, 1)
        case .acceptedAsIs: (close, keep) = (0.25, 0)
        case .openedAgain: (close, keep) = (0, 2)
        }
        for (dict, k) in [(\Taste.byKey, key), (\Taste.byKind, kind.rawValue)] {
            var c = Self.decay(self[keyPath: dict][k] ?? Counts(), now)
            c.close += close; c.keep += keep
            self[keyPath: dict][k] = c
        }
        if byKey.count > 200, let old = byKey.min(by: { ($0.value.stamp ?? .distantPast) < ($1.value.stamp ?? .distantPast) }) { byKey[old.key] = nil }
    }

    /// A half to two. Above one: this user keeps such things, so a return costs more.
    public func factor(key: String, kind: CandidateKind, now: Date) -> Double {
        let k = byKey[key].map { Self.decay($0, now) } ?? Counts(), g = byKind[kind.rawValue].map { Self.decay($0, now) } ?? Counts()
        // The kind's habit stands in for the name's until the name has its own, worth at most four choices.
        let n = g.close + g.keep, w = n > 0 ? min(4, n) / n : 0
        let close = 2 + k.close + g.close * w, keep = 2 + k.keep + g.keep * w
        let theta = close / (close + keep)
        return min(2, max(0.5, (1 - theta) / theta))
    }

    static func decay(_ c: Counts, _ now: Date) -> Counts {
        guard let s = c.stamp else { var n = c; n.stamp = now; return n }
        let f = pow(0.5, max(0, now.timeIntervalSince(s)) / halfLife)
        return Counts(close: c.close * f, keep: c.keep * f, stamp: now)
    }
}

/// What a close promised against what memory did, per kind, so the next promise is closer.
public struct Calibration: Codable, Sendable, Equatable {
    /// The share of a promise that really came back. Starts at 0.8: other programs move memory at the same time.
    public var share: [String: Double] = [:]
    public var outcomes: [Outcome] = []

    public struct Outcome: Codable, Sendable, Equatable {
        public var at: Date
        public var kinds: [String]
        public var promised: UInt64
        /// Memory in use fell by this much, or rose (negative).
        public var fell: Int64
        public var noise: UInt64
        public var stateBefore: MemoryState
        public var stateAfter: MemoryState?

        public init(at: Date, kinds: [String], promised: UInt64, fell: Int64, noise: UInt64, stateBefore: MemoryState, stateAfter: MemoryState?) {
            self.at = at; self.kinds = kinds; self.promised = promised; self.fell = fell; self.noise = noise
            self.stateBefore = stateBefore; self.stateAfter = stateAfter
        }
    }

    public init() {}

    public func share(of kind: CandidateKind) -> Double { share[kind.rawValue] ?? 0.8 }

    /// Learns only from a clean case: one kind, at least half a gigabyte, and memory that was steady before.
    public mutating func record(_ o: Outcome) {
        outcomes = Array((outcomes + [o]).suffix(50))
        guard o.kinds.count == 1, let kind = o.kinds.first, o.promised >= 512 << 20, Double(o.noise) < 0.25 * Double(o.promised) else { return }
        let seen = min(1.2, max(0.2, Double(o.fell) / Double(o.promised)))
        let was = share[kind] ?? 0.8
        share[kind] = was + 0.2 * (seen - was)
    }
}

/// Everything the optimizer learns, in one small file beside the settings. Names of apps, sessions and
/// programs, and numbers. Nothing leaves this Mac.
public struct OptimizerMemory: Codable, Sendable, Equatable {
    public var returns = Returns()
    public var taste = Taste()
    public var calibration = Calibration()
    /// Opened again after Pulse closed it: not offered again for a day.
    public var reopened: [String: Date] = [:]

    public init() {}

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("learned.json") }

    public static func load(from url: URL = defaultURL) -> OptimizerMemory {
        (try? Data(contentsOf: url)).flatMap { try? HealthStore.coder.1.decode(OptimizerMemory.self, from: $0) } ?? OptimizerMemory()
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? HealthStore.coder.0.encode(self).write(to: url, options: .atomic)
    }
}
