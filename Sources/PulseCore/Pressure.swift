import Darwin
import Foundation

/// The kernel's own memory counters, as one reading. What decides whether memory is short is not how
/// much is used but how much of it the compressor has to hold, and whether pages go to disk and back.
public struct VMReading: Codable, Sendable, Equatable {
    /// Bytes. `free` already holds the speculative pages.
    public var active: UInt64, inactive: UInt64, free: UInt64
    /// What the compressor occupies in RAM, and what it holds before compression.
    public var compressor: UInt64, stored: UInt64
    /// Counters since boot, in pages. They only grow.
    public var swapins: UInt64, swapouts: UInt64, decompressions: UInt64
    public var total: UInt64

    public init(active: UInt64, inactive: UInt64, free: UInt64, compressor: UInt64, stored: UInt64,
                swapins: UInt64 = 0, swapouts: UInt64 = 0, decompressions: UInt64 = 0, total: UInt64) {
        self.active = active; self.inactive = inactive; self.free = free; self.compressor = compressor; self.stored = stored
        self.swapins = swapins; self.swapouts = swapouts; self.decompressions = decompressions; self.total = total
    }

    /// Memory the kernel can still hand out without compressing more: A_nc in the kernel's notes.
    public var uncompressed: UInt64 { active + inactive + free }
    /// A_nc + C: everything that is not wired.
    public var available: UInt64 { uncompressed + compressor }
    /// The share of that the compressor does not hold. macOS warns under 0.50 and stops warning over 0.60.
    public var ratio: Double { available == 0 ? 1 : Double(uncompressed) / Double(available) }
    /// Bytes in RAM per byte held: how much one compressed byte of a program really costs.
    public var compression: Double { stored == 0 ? 0.33 : min(1, max(0.05, Double(compressor) / Double(stored))) }

    static func read() -> VMReading? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(sysconf(_SC_PAGESIZE))
        return VMReading(active: UInt64(vm.active_count) * page, inactive: UInt64(vm.inactive_count) * page, free: UInt64(vm.free_count) * page,
                         compressor: UInt64(vm.compressor_page_count) * page, stored: UInt64(vm.total_uncompressed_pages_in_compressor) * page,
                         swapins: vm.swapins, swapouts: vm.swapouts, decompressions: vm.decompressions, total: ProcessInfo.processInfo.physicalMemory)
    }
}

/// How short memory is, with the kernel's own lines and room on each side so it does not flicker.
public enum MemoryState: String, Codable, Sendable, Comparable {
    /// Nothing to do. Used memory being high is not a problem: macOS keeps files in it.
    case calm
    /// The compressor holds a lot and is close to the line macOS warns at. Worth watching.
    case tight
    /// macOS warns, or pages go to disk and come back every minute.
    case strained
    case critical

    var order: Int { [.calm: 0, .tight: 1, .strained: 2, .critical: 3][self] ?? 0 }
    public static func < (a: MemoryState, b: MemoryState) -> Bool { a.order < b.order }
}

/// Follows the readings and keeps the state with hysteresis. Fed every two seconds by the menu bar app.
/// The rates are moving averages over a minute, of the kind Linux calls pressure stall.
public struct PressureTracker: Sendable {
    public private(set) var state = MemoryState.calm
    /// Bytes a minute, over about a minute.
    public private(set) var swapinRate = 0.0, swapoutRate = 0.0
    public private(set) var last: VMReading?
    private var lastAt: TimeInterval?
    /// Since when the condition that lets the state go down has held.
    private var easing: TimeInterval?
    private var hard: TimeInterval?
    /// Compressor bytes, a point every five minutes, for the forecast.
    public private(set) var compressorTrend: [(at: TimeInterval, bytes: Double)] = []

    public init() {}

    static let tightEnter = 0.65, tightLeave = 0.70, strainedLeave = 0.62
    /// Pages back from disk at this share of active memory a minute is thrashing (Google's far-memory line).
    static let thrash = 0.002, thrashLeave = 0.0005

    /// `level` is kern.memorystatus_vm_pressure_level: 1, 2 or 4. `at` is the uptime, which stands still in sleep.
    public mutating func add(_ r: VMReading, level: Int, at: TimeInterval) {
        defer { last = r; lastAt = at }
        if let prev = last, let was = lastAt, at > was, at - was < 30, r.swapins >= prev.swapins, r.swapouts >= prev.swapouts {
            let dt = at - was, page = Double(sysconf(_SC_PAGESIZE))
            let a = 1 - exp(-dt / 60)
            swapinRate += a * (Double(r.swapins - prev.swapins) * page / dt * 60 - swapinRate)
            swapoutRate += a * (Double(r.swapouts - prev.swapouts) * page / dt * 60 - swapoutRate)
        } else if lastAt.map({ at - $0 >= 30 }) ?? false {
            // Slept, or was not looking: a minute's average from before says nothing now.
            swapinRate = 0; swapoutRate = 0; easing = nil; hard = nil; compressorTrend = []
        }
        if compressorTrend.last.map({ at - $0.at >= 300 }) ?? true {
            compressorTrend = Array((compressorTrend + [(at, Double(r.compressor))]).suffix(24))
        }
        let thrashing = swapinRate > Self.thrash * Double(r.active) && swapoutRate > 0
        let wanted = Self.enter(r, level: level, thrashing: thrashing)
        if wanted > state {
            // macOS's own warning has to last ten seconds: one reading is not a state. Thrashing is already an average.
            if wanted == .strained, !thrashing {
                hard = hard ?? at
                if at - hard! < 10 {
                    if state < .tight, r.ratio < Self.tightEnter { state = .tight }
                    return
                }
            }
            state = wanted
            easing = nil
            hard = nil
            return
        }
        hard = nil
        let calmer: Bool
        switch state {
        case .critical: calmer = level <= 2
        case .strained: calmer = level <= 1 && r.ratio > Self.strainedLeave && swapinRate < Self.thrashLeave * Double(r.active)
        case .tight: calmer = r.ratio > Self.tightLeave && forecastMinutes(r) == nil
        case .calm: calmer = false
        }
        guard calmer else { easing = nil; return }
        easing = easing ?? at
        let hold: TimeInterval = state == .critical ? 30 : 120
        if at - easing! >= hold {
            state = state == .critical ? .strained : state == .strained ? .tight : .calm
            easing = nil
        }
    }

    static func enter(_ r: VMReading, level: Int, thrashing: Bool) -> MemoryState {
        if level >= 4 { return .critical }
        if level >= 2 || thrashing { return .strained }
        return r.ratio < tightEnter ? .tight : .calm
    }

    /// One reading only, for a process that has no history: the MCP server.
    public static func instant(_ r: VMReading?, level: Int) -> MemoryState {
        guard let r else { return level >= 4 ? .critical : level >= 2 ? .strained : .calm }
        return enter(r, level: level, thrashing: false)
    }

    /// Minutes until the compressor reaches the line macOS warns at, if it keeps growing as in the last
    /// two hours. Theil-Sen: the median of the slopes between every two points, so one jump does not
    /// make a trend. Nil when it does not grow, or would take more than two hours.
    public func forecastMinutes(_ r: VMReading? = nil) -> Double? {
        guard let r = r ?? last else { return nil }
        return Self.forecast(compressorTrend, now: r)
    }

    static func forecast(_ points: [(at: TimeInterval, bytes: Double)], now r: VMReading) -> Double? {
        guard points.count >= 6, let slope = Robust.theilSen(points.map { ($0.at, $0.bytes) }), slope > 0 else { return nil }
        // C reaches half of what is available: A_nc / A = 0.5.
        let line = 0.5 * Double(r.available), left = line - Double(r.compressor)
        guard left > 0 else { return 0 }
        let minutes = left / slope / 60
        return minutes <= 120 ? minutes : nil
    }

    /// The compressor bytes to take off so that the ratio is back over the kernel's line with room.
    /// Zero unless memory is strained: closing things when nothing waits for memory gains nothing.
    public static func target(_ r: VMReading?, state: MemoryState, swapinRate: Double = 0) -> UInt64 {
        guard state >= .strained, let r else { return 0 }
        let over = Double(r.compressor) - 0.38 * Double(r.available)
        // Short only of what comes back from disk: ten minutes of it.
        let fromSwap = min(8 * 1_073_741_824, max(0.5 * 1_073_741_824, swapinRate * 10))
        return UInt64(max(over, swapinRate > 0 ? fromSwap : 0, state == .critical ? 1_073_741_824 : 0))
    }
}

/// Statistics that one wild value cannot move.
public enum Robust {
    /// Median of the slopes between every pair. Nil with fewer than two distinct times.
    public static func theilSen(_ points: [(Double, Double)]) -> Double? {
        var slopes: [Double] = []
        for i in points.indices { for j in points.indices where j > i && points[j].0 != points[i].0 {
            slopes.append((points[j].1 - points[i].1) / (points[j].0 - points[i].0))
        } }
        return median(slopes)
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Median absolute deviation.
    public static func mad(_ xs: [Double]) -> Double? {
        guard let m = median(xs) else { return nil }
        return median(xs.map { abs($0 - m) })
    }
}

/// The menu bar app's state of memory, for the MCP server, which is a process of its own with no minute of readings.
public struct PressureNote: Codable, Sendable, Equatable {
    public var state: MemoryState
    public var swapinRate: Double
    public var forecastMinutes: Double?
    public var at: Date

    public init(state: MemoryState, swapinRate: Double, forecastMinutes: Double?, at: Date) {
        self.state = state; self.swapinRate = swapinRate; self.forecastMinutes = forecastMinutes; self.at = at
    }

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("pressure.json") }

    /// Nil when it is older than two minutes: then the app is not running, or the Mac slept.
    public static func load(from url: URL = defaultURL, now: Date = Date()) -> PressureNote? {
        guard let n = (try? Data(contentsOf: url)).flatMap({ try? HealthStore.coder.1.decode(PressureNote.self, from: $0) }),
              abs(now.timeIntervalSince(n.at)) < 120 else { return nil }
        return n
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? HealthStore.coder.0.encode(self).write(to: url, options: .atomic)
    }
}

extension Optimizer {
    /// The whole decision for one snapshot: rows, guards, scores, the verdict. The scores are also put on the suggestions.
    public static func plan(_ snap: inout Snapshot, compressed: [Int32: UInt64]?, served: Set<Int32>?, frontmost: String?, memory: OptimizerMemory,
                            note: PressureNote?, history: LoadHistory?, now: Date) -> Verdict {
        let vm = snap.system.vm
        let state = note?.state ?? PressureTracker.instant(vm, level: snap.system.memPressureLevel)
        let v = decide(Inputs(candidates: candidates(snap, compressed: compressed, served: served, frontmost: frontmost, memory: memory),
                              vm: vm, state: state, swapinRate: note?.swapinRate ?? 0, forecastMinutes: note?.forecastMinutes, memory: memory,
                              memUsed: snap.system.memUsedBytes, growing: history?.growing(now: now) ?? [], learned: note != nil, now: now))
        let byId = Dictionary(v.scores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in snap.suggestions.indices { snap.suggestions[i].score = byId[snap.suggestions[i].id] }
        return v
    }
}
