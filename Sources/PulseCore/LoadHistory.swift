import Foundation

/// The CPU time one process has used since it started, as the kernel counts it.
public struct ProcTime: Sendable, Equatable {
    public var pid: Int32
    public var lstart: String
    public var seconds: Double
}

/// CPU time per row over the last twelve hours, in buckets of five minutes. Made of differences between
/// readings of a counter that only grows with work, so a sleep or a clock that jumps adds nothing.
public struct LoadHistory: Codable, Sendable {
    public struct Bucket: Codable, Sendable, Equatable {
        /// Seconds since 1970.
        var start: Int
        var cpu: [String: Double] = [:]
        /// The most it held at any reading.
        var memory: [String: UInt64] = [:]
    }

    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public var kind: Consumer.Kind
        public var name: String
        public var cpuSeconds: Double
        public var peakBytes: UInt64
        public var id: String { "\(kind.rawValue):\(name)" }
    }

    static let width = 300, count = 144, names = 8

    private(set) var buckets: [Bucket] = []
    private var last: [Int32: (lstart: String, seconds: Double)] = [:]
    private var lastAt: Date?

    private enum CodingKeys: String, CodingKey { case buckets }

    public init() {}

    public mutating func add(_ rows: [Consumer], at now: Date) {
        var seen: [Int32: (lstart: String, seconds: Double)] = [:]
        var cpu: [String: Double] = [:], memory: [String: UInt64] = [:]
        for row in rows {
            let key = Self.key(row)
            var used = 0.0
            for t in row.times {
                seen[t.pid] = (t.lstart, t.seconds)
                used += worked(t)
            }
            if used > 0 { cpu[key, default: 0] += used }
            memory[key, default: 0] += row.rssBytes
        }
        last = seen
        lastAt = now
        let start = Int(now.timeIntervalSince1970) / Self.width * Self.width
        // A clock set back keeps filling the newest bucket.
        if buckets.last.map({ $0.start < start }) ?? true {
            if let i = buckets.indices.last { buckets[i] = Self.trimmed(buckets[i]) }
            buckets.append(Bucket(start: start))
        }
        let i = buckets.count - 1
        buckets[i].cpu.merge(cpu, uniquingKeysWith: +)
        buckets[i].memory.merge(memory, uniquingKeysWith: max)
        drop(before: now)
    }

    /// What it did since the last reading. A process first seen counts only if it was born since then:
    /// the hours it worked before Pulse was looking belong to no bucket here.
    private func worked(_ t: ProcTime) -> Double {
        if let was = last[t.pid], was.lstart == t.lstart { return max(0, t.seconds - was.seconds) }
        guard let lastAt, let born = StartTime.date(t.lstart), born >= lastAt.addingTimeInterval(-1) else { return 0 }
        return t.seconds
    }

    private static func key(_ c: Consumer) -> String { "\(c.kind.rawValue):\(c.name)" }

    /// The heaviest of each, once a bucket is full.
    private static func trimmed(_ b: Bucket) -> Bucket {
        func top<V: Comparable>(_ d: [String: V]) -> [String: V] {
            Dictionary(uniqueKeysWithValues: d.sorted { $0.value > $1.value }.prefix(names).map { ($0.key, $0.value) })
        }
        return Bucket(start: b.start, cpu: top(b.cpu), memory: top(b.memory))
    }

    private mutating func drop(before now: Date) {
        let oldest = Int(now.timeIntervalSince1970) - Self.width * Self.count
        buckets.removeAll { $0.start <= oldest }
        if buckets.count > Self.count { buckets.removeFirst(buckets.count - Self.count) }
    }

    /// The most CPU time first. What only ever held memory is not a row.
    public func rows(now: Date) -> [Row] {
        let oldest = Int(now.timeIntervalSince1970) - Self.width * Self.count
        var cpu: [String: Double] = [:], peak: [String: UInt64] = [:]
        for b in buckets where b.start > oldest {
            cpu.merge(b.cpu, uniquingKeysWith: +)
            peak.merge(b.memory, uniquingKeysWith: max)
        }
        return cpu.compactMap { key, seconds in
            guard let cut = key.firstIndex(of: ":"), let kind = Consumer.Kind(rawValue: String(key[..<cut])), seconds >= 1 else { return nil }
            return Row(kind: kind, name: String(key[key.index(after: cut)...]), cpuSeconds: seconds, peakBytes: peak[key] ?? 0)
        }
        .sorted { $0.cpuSeconds != $1.cpuSeconds ? $0.cpuSeconds > $1.cpuSeconds : $0.id < $1.id }
    }

    /// CPU time of one row over the twelve hours, oldest first, in as many equal parts. Nil for a part
    /// Pulse was not running in, which is not the same as idle.
    public func series(_ id: String, parts: Int, now: Date) -> [Double?] {
        let end = Int(now.timeIntervalSince1970) / Self.width * Self.width + Self.width
        let span = Self.width * Self.count / max(parts, 1)
        var out = [Double?](repeating: nil, count: max(parts, 1))
        for b in buckets {
            let at = parts - 1 - (end - 1 - b.start) / span
            guard b.start < end, out.indices.contains(at) else { continue }
            out[at] = (out[at] ?? 0) + (b.cpu[id] ?? 0)
        }
        return out
    }

    public func since(now: Date) -> Date? {
        let oldest = Int(now.timeIntervalSince1970) - Self.width * Self.count
        return buckets.first { $0.start > oldest }.map { Date(timeIntervalSince1970: Double($0.start)) }
    }

    // MARK: On disk

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("load.json") }

    public static func load(from url: URL = defaultURL, now: Date = Date()) -> LoadHistory {
        guard let data = try? Data(contentsOf: url), var h = try? JSONDecoder().decode(LoadHistory.self, from: data) else { return LoadHistory() }
        // One from the future would be the newest for ever.
        h.buckets.removeAll { $0.start > Int(now.timeIntervalSince1970) }
        h.drop(before: now)
        return h
    }

    public func save(to url: URL) {
        var out = self
        if let i = out.buckets.indices.last { out.buckets[i] = Self.trimmed(out.buckets[i]) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(out).write(to: url, options: .atomic)
    }
}

/// Finds what only grows: at least doubled in an hour, by 4 GB or more, and on the way never gave
/// back a tenth. A program that fills up and empties, however high, is not it.
struct Growth {
    static let window: TimeInterval = 3600, gain: UInt64 = 4 << 30, every: TimeInterval = 60
    private var points: [String: [(at: Date, bytes: UInt64)]] = [:]
    private var lastAt: Date?

    mutating func add(_ rows: [Consumer], at now: Date) -> [(row: Consumer, from: UInt64)] {
        if let lastAt {
            guard now.timeIntervalSince(lastAt) >= Self.every else { return [] }
            // Slept, or was not looking: what happened in between is not known.
            if now.timeIntervalSince(lastAt) > 600 { points = [:] }
        }
        lastAt = now
        var next: [String: [(at: Date, bytes: UInt64)]] = [:]
        var out: [(row: Consumer, from: UInt64)] = []
        for row in rows {
            var list = (points[row.id] ?? []) + [(now, row.rssBytes)]
            // Kept a little over the hour, so that the first of them is a whole hour old.
            while list.count > 1, now.timeIntervalSince(list[1].at) >= Self.window { list.removeFirst() }
            next[row.id] = list
            let first = list[0], bytes = row.rssBytes
            guard now.timeIntervalSince(first.at) >= Self.window, bytes >= first.bytes * 2, bytes - first.bytes >= Self.gain else { continue }
            var high: UInt64 = 0
            let held = list.allSatisfy { p in high = max(high, p.bytes); return p.bytes >= high - high / 10 }
            if held { out.append((row, first.bytes)) }
        }
        points = next
        return out
    }
}
