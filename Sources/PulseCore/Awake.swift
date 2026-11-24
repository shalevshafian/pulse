import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Something that asks this Mac not to sleep.
public struct AwakeHolder: Codable, Sendable, Identifiable, Equatable {
    /// The name of its row in the process list.
    public var name: String
    public var kind: Consumer.Kind
    /// In a few words: audio, caffeinate, or what the app itself wrote.
    public var reason: String
    public var since: Date?
    public var pids: [Int32]
    public var id: String { "\(kind.rawValue):\(name)" }
}

public enum Awake {
    /// Nil when macOS does not answer.
    public static func read(table: ProcTable, sessions: [ClaudeSession], runtimes: [DevRuntime]) -> [AwakeHolder]? {
        var ref: Unmanaged<CFDictionary>?
        let code = IOPMCopyAssertionsByProcess(&ref)
        return answer(code, ref?.takeRetainedValue()).map { holders($0, table: table, sessions: sessions, runtimes: runtimes) }
    }

    /// Success without a list is a Mac nothing keeps awake. A failure, or a list of another shape, is not known.
    static func answer(_ code: IOReturn, _ dict: CFDictionary?) -> [Int32: [[String: Any]]]? {
        guard code == kIOReturnSuccess else { return nil }
        guard let dict else { return [:] }
        guard let typed = dict as? [NSNumber: [[String: Any]]] else { return nil }
        return Dictionary(typed.map { ($0.key.int32Value, $0.value) }, uniquingKeysWith: +)
    }

    /// One row per name, the longest first. Only what keeps the whole Mac awake: not the display, not
    /// the pointer that just moved, not a mounted drive, and not the power daemon's own bookkeeping.
    static func holders(_ all: [Int32: [[String: Any]]], table: ProcTable, sessions: [ClaudeSession], runtimes: [DevRuntime]) -> [AwakeHolder] {
        var rows: [String: AwakeHolder] = [:]
        for (owner, list) in all {
            for a in list {
                // Apps may still ask by the type's old name; the true type is the one that counts.
                let type = a["AssertionTrueType"] as? String ?? a["AssertType"] as? String ?? ""
                guard type == "PreventUserIdleSystemSleep" || type == "PreventSystemSleep" || type == "NoIdleSleepAssertion",
                      (a["AssertLevel"] as? NSNumber)?.intValue != 0 else { continue }
                let process = a["Process Name"] as? String ?? table.byPid[owner].map { ($0.program as NSString).lastPathComponent } ?? ""
                // `runningboardd` renews one every few seconds.
                guard process != "powerd", process != "runningboardd" else { continue }
                // The audio daemon holds one for whoever plays or records.
                let asked = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
                let (kind, name) = who(asked ?? owner, climb: process == "caffeinate", fallback: process, table: table, sessions: sessions, runtimes: runtimes)
                guard !name.isEmpty else { continue }
                let since = a["AssertStartWhen"] as? Date
                var row = rows["\(kind):\(name)"] ?? AwakeHolder(name: name, kind: kind, reason: reason(a, process: process), since: since, pids: [])
                if let since, since < row.since ?? .distantFuture { row.since = since; row.reason = reason(a, process: process) }
                if !row.pids.contains(owner) { row.pids = (row.pids + [owner]).sorted() }
                rows["\(kind):\(name)"] = row
            }
        }
        return rows.values.sorted { ($0.since ?? .distantPast, $0.name) < ($1.since ?? .distantPast, $1.name) }
    }

    /// Named as the process list names it. `caffeinate` is only a hand: it reads as what started it.
    private static func who(_ pid: Int32, climb: Bool, fallback: String, table: ProcTable, sessions: [ClaudeSession], runtimes: [DevRuntime]) -> (Consumer.Kind, String) {
        var at = pid
        for hop in 0..<12 {
            if let r = runtimes.first(where: { r in r.members.contains { $0.pid == at } }) { return (.runtime, r.name) }
            if let s = sessions.first(where: { $0.pid == at || isUnder(at, $0.pid, table) }) { return (.session, s.name.isEmpty ? s.project : s.name) }
            guard let p = table.byPid[at] else { break }
            if let b = AppGroups.bundlePath(of: p.program) { return (.app, (b as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) }
            let name = (p.program as NSString).lastPathComponent
            if !climb || p.ppid <= 1 { return (.process, hop == 0 || !climb ? name : fallback) }
            at = p.ppid
        }
        return (.process, fallback)
    }

    private static func isUnder(_ pid: Int32, _ root: Int32, _ table: ProcTable) -> Bool {
        var at = pid
        for _ in 0..<16 {
            guard at > 1, let p = table.byPid[at] else { return false }
            if p.ppid == root { return true }
            at = p.ppid
        }
        return false
    }

    private static func reason(_ a: [String: Any], process: String) -> String {
        if process == "caffeinate" { return "caffeinate" }
        if (a["ResourcesUsed"] as? [String])?.contains(where: { $0.hasPrefix("audio") }) == true { return "audio" }
        let name = Plain.text(a["AssertName"] as? String ?? "")
        return name.isEmpty || name.hasPrefix("com.apple.") || name.caseInsensitiveCompare("Electron") == .orderedSame ? "asks to stay awake" : name
    }
}

/// The battery right now.
public struct Charge: Equatable, Sendable {
    public var percent: Double
    public var onBattery: Bool
    public init(percent: Double, onBattery: Bool) { self.percent = percent; self.onBattery = onBattery }

    /// Nil on a Mac without a battery.
    public static func read() -> Charge? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return list.lazy.compactMap { parse(IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] ?? [:]) }.first
    }

    static func parse(_ d: [String: Any]) -> Charge? {
        guard d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType, let now = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
              let full = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, full > 0 else { return nil }
        return Charge(percent: now / full * 100, onBattery: d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
    }
}

/// One sleep, from the moment the Mac went until somebody woke it. Dark wakes are inside it.
public struct SleepRecord: Codable, Equatable, Sendable {
    public var from: Date
    public var to: Date
    /// Percent of charge lost. Nil on a Mac without a battery, or one that was plugged in at either end.
    public var lost: Double?
    public var darkWakes: Int?

    public var seconds: TimeInterval { to.timeIntervalSince(from) }
}

/// Follows the Mac's sleep through the kernel's messages. Reading the charge takes under a millisecond;
/// nothing slower happens before the Mac is let to sleep.
public struct SleepCost: Codable, Equatable, Sendable {
    public private(set) var sleeps: [SleepRecord] = []
    private var began: Began?
    /// How many times the Mac has woken by itself since it started. It only grows in sleep, so
    /// what was read after the last wake still holds when the next sleep begins.
    private var count: Int?

    private struct Began: Codable, Equatable, Sendable { var at: Date, percent: Double?, onBattery: Bool, count: Int? }
    private enum CodingKeys: String, CodingKey { case sleeps }

    public init() {}

    /// The first of a row: a dark wake ends in another will-sleep, and that is the same sleep.
    public mutating func willSleep(_ c: Charge?, at: Date) {
        guard began == nil else { return }
        began = Began(at: at, percent: c?.percent, onBattery: c?.onBattery ?? false, count: count)
    }

    /// Somebody is there. Returns true when a sleep ended with it.
    public mutating func fullWake(_ c: Charge?, darkWakes: Int?, at: Date) -> Bool {
        count = darkWakes
        guard let b = began else { return false }
        began = nil
        guard at > b.at else { return false }
        var lost: Double?
        // Charged on the way, at either end or between them: what sleep cost is not known.
        if let c, let p = b.percent, b.onBattery, c.onBattery, c.percent <= p { lost = p - c.percent }
        // A count that went back is from after a restart.
        let woke = darkWakes.flatMap { now in b.count.flatMap { now >= $0 ? now - $0 : nil } }
        sleeps = Array((sleeps + [SleepRecord(from: b.at, to: at, lost: lost, darkWakes: woke)]).suffix(10))
        return true
    }

    /// The one worth a line: a nap after a night does not hide the night.
    public func last(now: Date) -> SleepRecord? {
        let recent = sleeps.filter { now.timeIntervalSince($0.to) < 24 * 3600 }
        return recent.last { $0.seconds >= 1800 } ?? recent.last
    }

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("sleep.json") }

    public static func load(from url: URL = defaultURL) -> SleepCost {
        (try? Data(contentsOf: url)).flatMap { try? HealthStore.coder.1.decode(SleepCost.self, from: $0) } ?? SleepCost()
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? HealthStore.coder.0.encode(self).write(to: url, options: .atomic)
    }

    public static func readDarkWakes() -> Int? { Shell.output("/usr/bin/pmset", ["-g", "stats"], timeout: 5).flatMap(darkWakes) }

    /// "Dark Wake Count:216"
    static func darkWakes(_ text: String) -> Int? {
        text.split(separator: "\n").first { $0.hasPrefix("Dark Wake Count:") }.flatMap { Int($0.dropFirst(16).trimmingCharacters(in: .whitespaces)) }
    }
}

extension HealthRules {
    static let sleepHours = 4.0, sleepLoss = 10.0

    /// What keeps the Mac awake counts only when it costs something: on battery, for over an hour.
    static func sleep(holders: [AwakeHolder]?, charge: Charge?, cost: SleepCost, now: Date) -> [HealthCheck] {
        var out: [HealthCheck] = []
        if let h = holders {
            let long = h.filter { $0.since.map { now.timeIntervalSince($0) >= 3600 } ?? false }
            if charge?.onBattery == true, let first = long.first {
                out.append(.init("awake", .battery, .attention, "On battery, and kept awake by " + (long.count == 1 ? first.name : Plural.count(long.count, "program")),
                                 "For over an hour. " + long.prefix(3).map(\.name).joined(separator: ", ") + ".", weight: 2, fix: .sleep))
            } else {
                out.append(.init("awake", .battery, .ok, h.isEmpty ? "Nothing keeps this Mac awake" : "Kept awake by \(Plural.count(h.count, "program"))", "", fix: .sleep))
            }
        } else { out.append(unknown("awake", .battery, "What keeps this Mac awake")) }
        if let bad = cost.sleeps.last(where: { now.timeIntervalSince($0.to) < 3 * 86400 && $0.seconds > sleepHours * 3600 && ($0.lost ?? 0) > sleepLoss }) {
            out.append(.init("sleep-loss", .battery, .attention, String(format: "Sleep cost %.0f%% of the charge", bad.lost ?? 0),
                             String(format: "In %.0f hours on battery.", bad.seconds / 3600) + (bad.darkWakes.map { " The Mac woke by itself \(Plural.count($0, "time"))." } ?? ""),
                             weight: 4, fix: .sleep))
        }
        return out
    }
}
