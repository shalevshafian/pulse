import Foundation

/// How much of a plan is used, as Claude Code and Codex last wrote it on this Mac. Read only after the
/// tick in Settings. Neither file is a public format: what is stale, unknown or missing is left out.
public struct PlanUsage: Codable, Equatable, Sendable, Identifiable {
    public struct Limit: Codable, Equatable, Sendable {
        /// "week", "5 hours", or the model a limit is for.
        public var name: String
        public var percent: Double
        public var resetsAt: Date
    }

    public var tool: String
    /// When the tool itself read it.
    public var readAt: Date
    public var limits: [Limit]
    public var id: String { tool }

    /// Older than this it says nothing about now.
    static let fresh: TimeInterval = 6 * 3600

    public static func read(home: String = NSHomeDirectory(), now: Date = Date()) -> [PlanUsage] {
        [claude(FileManager.default.contents(atPath: home + "/.claude.json"), now: now),
         codex(folder: home + "/.codex/sessions", now: now)].compactMap { $0 }
    }

    /// Nil unless something in it still holds.
    private static func make(_ tool: String, _ readAt: Date, _ limits: [Limit], now: Date) -> PlanUsage? {
        let age = now.timeIntervalSince(readAt)
        guard age < fresh, age > -300 else { return nil }
        let held = limits.filter { $0.resetsAt > now }
        return held.isEmpty ? nil : PlanUsage(tool: tool, readAt: readAt, limits: held)
    }

    // MARK: Claude Code

    /// Everything else in that file, the account and the keys of MCP servers among it, has no place to go.
    private struct ClaudeFile: Decodable {
        struct Cached: Decodable { var fetchedAtMs: Double, utilization: Utilization }
        struct Utilization: Decodable { var limits: [Entry] }
        struct Entry: Decodable { var group: String?, percent: Double?, resets_at: String?, scope: Scope? }
        struct Scope: Decodable { var model: Named? }
        struct Named: Decodable { var display_name: String? }
        var cachedUsageUtilization: Cached
    }

    static func claude(_ data: Data?, now: Date) -> PlanUsage? {
        guard let data, let cached = (try? JSONDecoder().decode(ClaudeFile.self, from: data))?.cachedUsageUtilization else { return nil }
        let limits = cached.utilization.limits.compactMap { e -> Limit? in
            guard let percent = e.percent, percent.isFinite, let resets = e.resets_at.flatMap(date) else { return nil }
            let window: String
            switch e.group {
            case "weekly": window = "week"
            case "session", "five_hour": window = "5 hours"
            default: return nil
            }
            if let scope = e.scope {
                // A limit for something this cannot name is not shown as if it were the whole plan.
                guard let model = scope.model?.display_name.map(Plain.text), !model.isEmpty else { return nil }
                return Limit(name: model, percent: percent, resetsAt: resets)
            }
            return Limit(name: window, percent: percent, resetsAt: resets)
        }
        return make("Claude", Date(timeIntervalSince1970: cached.fetchedAtMs / 1000), limits, now: now)
    }

    /// With six digits of a second, or none.
    static func date(_ s: String) -> Date? {
        let plain = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)
    }

    // MARK: Codex

    private struct CodexLine: Decodable {
        struct Payload: Decodable { var type: String?, rate_limits: Rates? }
        struct Rates: Decodable { var primary: Window?, secondary: Window? }
        struct Window: Decodable { var used_percent: Double?, window_minutes: Double?, resets_at: Double? }
        var timestamp: String
        var payload: Payload
    }

    /// The newest files only, and of each only its end: they are whole conversations, and can be very large.
    static func codex(folder: String, now: Date, tail: Int = 2 << 20) -> PlanUsage? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: Array(keys)) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in walk where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true, let m = v.contentModificationDate,
                  now.timeIntervalSince(m) < fresh else { continue }
            files.append((url, m))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
            if let data = try? h.readToEnd(), let found = codex(data, now: now) { return found }
        }
        return nil
    }

    /// The last line that really is a reading: a conversation may well mention the word.
    static func codex(_ data: Data, now: Date) -> PlanUsage? {
        let word = Data("\"rate_limits\"".utf8)
        for line in data.split(separator: 10).reversed() where line.range(of: word) != nil {
            guard let d = try? JSONDecoder().decode(CodexLine.self, from: Data(line)), d.payload.type == "token_count",
                  let at = date(d.timestamp), let r = d.payload.rate_limits else { continue }
            let limits = [r.primary, r.secondary].compactMap { w -> Limit? in
                guard let w, let p = w.used_percent, p.isFinite, let m = w.window_minutes, m > 0, m < 1e6, let resets = w.resets_at else { return nil }
                return Limit(name: window(minutes: Int(m)), percent: p, resetsAt: Date(timeIntervalSince1970: resets))
            }
            // Null in some lines: the one before may hold it.
            if !limits.isEmpty { return make("Codex", at, limits, now: now) }
        }
        return nil
    }

    static func window(minutes: Int) -> String {
        if minutes == 10_080 { return "week" }
        return minutes >= 2880 ? Plural.count(minutes / 1440, "day") : minutes >= 60 ? Plural.count(minutes / 60, "hour") : "\(minutes) min"
    }

    // MARK: In words

    /// "resets 19:00" today and tonight, "resets Thursday" this week, a date after that.
    public static func resets(_ d: Date, now: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        let away = d.timeIntervalSince(now)
        f.dateFormat = away < 20 * 3600 ? "HH:mm" : away < 6.5 * 86400 ? "EEEE" : "MMM d"
        return "resets " + f.string(from: d)
    }
}
