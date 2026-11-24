import Foundation

/// The eight things that make up the health of this Mac.
public enum HealthArea: String, Codable, CaseIterable, Sendable {
    case backup, protection, updates, storage, battery, stability, performance, startup

    public var title: String {
        switch self {
        case .backup: return "Backup"
        case .protection: return "Security"
        case .updates: return "Updates"
        case .storage: return "Storage"
        case .battery: return "Battery"
        case .stability: return "Stability"
        case .performance: return "Speed"
        case .startup: return "Startup"
        }
    }
}

/// `unknown` is its own answer: a reading that failed is never shown as healthy.
public enum HealthState: String, Codable, Sendable { case ok, attention, urgent, unknown }

public enum HealthFix: String, Codable, Sendable {
    case timeMachine, firewall, privacy, softwareUpdate, battery, loginItems, storage, cleanup, acceptStartup, plan

    /// The System Settings page. Pulse opens it; the user changes it.
    public var settingsURL: String? {
        let base = "x-apple.systempreferences:"
        switch self {
        case .timeMachine: return base + "com.apple.Time-Machine-Settings.extension"
        case .firewall: return base + "com.apple.Network-Settings.extension?Firewall"
        case .privacy: return base + "com.apple.settings.PrivacySecurity.extension"
        case .softwareUpdate: return base + "com.apple.Software-Update-Settings.extension"
        case .battery: return base + "com.apple.Battery-Settings.extension"
        case .loginItems: return base + "com.apple.LoginItems-Settings.extension"
        case .storage: return base + "com.apple.settings.Storage"
        case .cleanup, .acceptStartup, .plan: return nil
        }
    }

    public var label: String {
        switch self {
        case .timeMachine: return "Set up backup"
        case .firewall: return "Open Firewall"
        case .privacy: return "Open Security"
        case .softwareUpdate: return "Open Updates"
        case .battery: return "Open Battery"
        case .loginItems: return "Open Login Items"
        case .storage: return "Open Storage"
        case .cleanup: return "See what can go"
        case .acceptStartup: return "I know it"
        case .plan: return "Open Optimize"
        }
    }
}

public struct HealthCheck: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var area: HealthArea
    public var state: HealthState
    public var title: String
    public var detail: String
    /// Points off the score while it is not ok and not ignored.
    public var weight: Int
    public var fix: HealthFix?

    public init(_ id: String, _ area: HealthArea, _ state: HealthState, _ title: String, _ detail: String = "", weight: Int = 0, fix: HealthFix? = nil) {
        self.id = id; self.area = area; self.state = state; self.title = title
        self.detail = detail; self.weight = weight; self.fix = fix
    }

    public var isProblem: Bool { state == .attention || state == .urgent }
}

public struct StartupItem: Codable, Sendable, Equatable {
    public var label: String
    public var program: String
    public var missing: Bool
}

public struct HealthDay: Codable, Sendable, Equatable {
    public var day: String
    public var score: Int
    public var diskFreeBytes: UInt64
}

public struct HealthReport: Codable, Sendable {
    public var takenAt: Date
    public var checks: [HealthCheck]
    public var startup: [StartupItem] = []
    public var cleanup: [CleanupItem] = []

    public init(takenAt: Date, checks: [HealthCheck], startup: [StartupItem] = [], cleanup: [CleanupItem] = []) {
        self.takenAt = takenAt; self.checks = checks; self.startup = startup; self.cleanup = cleanup
    }
}

/// Everything remembered between checks. The app writes it; the MCP server only reads it.
public struct HealthStore: Codable, Sendable {
    public var report: HealthReport?
    public var history: [HealthDay] = []
    /// Startup items the user already had, or accepted. Nil until the first check.
    public var knownStartup: [String]?
    public var ignored: [String] = []
    /// When each finding was last announced, so a chronic one is not repeated at every launch.
    public var notified: [String: Date] = [:]
    /// The wording and rules the report was made with. A report from another version is taken again.
    public var rules: Int? = HealthStore.currentRules
    public static let currentRules = 2

    public init() {}

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("health.json") }

    static var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .iso8601; d.dateDecodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (e, d)
    }

    public static func load(from url: URL = defaultURL) -> HealthStore {
        guard let data = try? Data(contentsOf: url), var s = try? coder.1.decode(HealthStore.self, from: data) else { return HealthStore() }
        if s.rules != currentRules { s.report = nil; s.rules = currentRules }
        return s
    }

    public func save(to url: URL = HealthStore.defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.coder.0.encode(self).write(to: url, options: .atomic)
    }

    // MARK: What the panel and the agents read

    /// Problems first by state, then by how much they cost.
    public var problems: [HealthCheck] {
        (report?.checks ?? []).filter { $0.isProblem && !ignored.contains($0.id) }
            .sorted { $0.state != $1.state ? $0.state == .urgent : $0.weight > $1.weight }
    }
    public var unknowns: [HealthCheck] { (report?.checks ?? []).filter { $0.state == .unknown } }
    public var score: Int? { report.map { _ in max(0, 100 - problems.reduce(0) { $0 + $1.weight }) } }

    public func state(of area: HealthArea) -> HealthState {
        let mine = (report?.checks ?? []).filter { $0.area == area && !($0.isProblem && ignored.contains($0.id)) }
        if mine.contains(where: { $0.state == .urgent }) { return .urgent }
        if mine.contains(where: { $0.state == .attention }) { return .attention }
        // A reading that failed must not hide behind one that worked.
        if mine.isEmpty || mine.contains(where: { $0.state == .unknown }) { return .unknown }
        return .ok
    }

    /// Change against the oldest day inside the last week, once there is one to compare to.
    public func weekChange(now: Date) -> Int? {
        guard let score else { return nil }
        let from = Self.day(now.addingTimeInterval(-7 * 86400)), today = Self.day(now)
        return history.first { $0.day >= from && $0.day < today }.map { score - $0.score }
    }

    public mutating func absorb(_ report: HealthReport, diskFree: UInt64, now: Date) {
        if knownStartup == nil { knownStartup = report.startup.map(\.label) }
        self.report = report
        let today = Self.day(now)
        history.removeAll { $0.day == today }
        history.append(HealthDay(day: today, score: score ?? 0, diskFreeBytes: diskFree))
        history = Array(history.suffix(90))
    }

    /// What has not been announced in the last two weeks. Marks it as announced.
    public mutating func takeNew(now: Date) -> [HealthCheck] {
        let fresh = problems.filter { c in notified[c.id].map { now.timeIntervalSince($0) > 14 * 86400 } ?? true }
        for c in fresh { notified[c.id] = now }
        // Solved and back again is news.
        let open = Set((report?.checks ?? []).filter(\.isProblem).map(\.id))
        notified = notified.filter { open.contains($0.key) }
        return fresh
    }

    public static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

/// Pure readings: text from a tool in, a check out. Nothing here touches the machine.
public enum HealthRules {
    public static let timeMachineTitle = "No Time Machine backup"

    static func backup(destinations: String?, latest: String?, now: Date) -> HealthCheck {
        guard let d = destinations else { return unknown("backup", .backup, "Time Machine") }
        if d.contains("No destinations configured") {
            return .init("backup", .backup, .urgent, timeMachineTitle,
                         "This Mac has no backup disk. If its disk fails, anything not kept elsewhere is lost.", weight: 15, fix: .timeMachine)
        }
        guard d.contains("Kind") || d.contains("Name") else { return unknown("backup", .backup, "Time Machine") }
        // ".../2026-11-20-101010.backup"
        guard let latest, let r = latest.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else {
            return .init("backup", .backup, .unknown, "Last backup date", "A backup disk is set, but it is not connected or Pulse may not read it.", fix: .timeMachine)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        guard let date = f.date(from: String(latest[r])) else { return unknown("backup", .backup, "Time Machine") }
        let days = Int(now.timeIntervalSince(date) / 86400)
        if days >= 10 {
            return .init("backup", .backup, days >= 30 ? .urgent : .attention, "Last backup was \(days) days ago", "Connect the backup disk.", weight: days >= 30 ? 15 : 8, fix: .timeMachine)
        }
        return .init("backup", .backup, .ok, "Backup is recent", days == 0 ? "Today" : "\(Plural.count(days, "day")) ago")
    }

    /// One protection switch, read from a tool's sentence.
    static func toggle(_ id: String, _ name: String, _ out: String?, on: String, off: String, offState: HealthState, offDetail: String, weight: Int, fix: HealthFix) -> HealthCheck {
        guard let out else { return unknown(id, .protection, name) }
        if out.contains(off) { return .init(id, .protection, offState, "\(name) is off", offDetail, weight: weight, fix: fix) }
        if out.contains(on) { return .init(id, .protection, .ok, "\(name) is on") }
        return unknown(id, .protection, name)
    }

    static func protection(fileVault: String?, sip: String?, gatekeeper: String?, firewall: String?) -> [HealthCheck] {
        [
            toggle("filevault", "FileVault", fileVault, on: "FileVault is On", off: "FileVault is Off", offState: .urgent,
                   offDetail: "Whoever holds this Mac can read its disk.", weight: 12, fix: .privacy),
            toggle("sip", "System Integrity Protection", sip, on: "status: enabled", off: "status: disabled", offState: .urgent,
                   offDetail: "It can only be turned back on from Recovery.", weight: 12, fix: .privacy),
            toggle("gatekeeper", "Gatekeeper", gatekeeper, on: "assessments enabled", off: "assessments disabled", offState: .urgent,
                   offDetail: "Any app opens without being checked.", weight: 12, fix: .privacy),
            toggle("firewall", "Firewall", firewall, on: "enabled", off: "disabled", offState: .attention,
                   offDetail: "On a public network, open services on this Mac can be reached. Turning it on may ask about development servers.", weight: 8, fix: .firewall),
        ]
    }

    static func updates(_ plist: [String: Any]?, system: String, now: Date) -> [HealthCheck] {
        guard let p = plist else { return [unknown("updates", .updates, "Software updates")] }
        var out: [HealthCheck] = []
        let offered = p["FirstOfferDateDictionary"] as? [String: Any] ?? [:]
        let recommended = p["RecommendedUpdates"] as? [[String: Any]] ?? []
        let current = system.split(separator: ".").first.map(String.init) ?? ""
        for u in recommended {
            let id = u["Identifier"] as? String ?? "", name = u["Display Name"] as? String ?? "", version = u["Display Version"] as? String ?? ""
            let isSystem = u["MobileSoftwareUpdate"] as? Bool == true
            // A new major macOS is a choice, not a fault: plugins and drivers lag behind it.
            if isSystem, !version.hasPrefix(current + ".") { continue }
            var detail = isSystem ? "\(system) is installed." : ""
            var days = 0
            if let first = offered[id] as? Date {
                days = Int(now.timeIntervalSince(first) / 86400)
                if days >= 1 { detail += (detail.isEmpty ? "" : " ") + "Offered \(Plural.count(days, "day")) ago." }
            }
            let title = isSystem ? (name.contains(version) ? name : "\(name) \(version)") : "\(name) \(version)"
            out.append(.init("update-\(isSystem ? "macos" : name)", .updates, isSystem && days >= 30 ? .urgent : .attention,
                             "Update waiting: \(title)", detail, weight: isSystem ? (days >= 30 ? 12 : 8) : 3, fix: .softwareUpdate))
        }
        if let last = p["LastSuccessfulDate"] as? Date, now.timeIntervalSince(last) > 14 * 86400 {
            out.append(.init("update-check", .updates, .attention, "No update check for \(Int(now.timeIntervalSince(last) / 86400)) days", "", weight: 4, fix: .softwareUpdate))
        }
        if p["CriticalUpdateInstall"] as? Bool == false || p["ConfigDataInstall"] as? Bool == false {
            out.append(.init("update-critical", .updates, .attention, "Security updates are not automatic", "", weight: 8, fix: .softwareUpdate))
        }
        return out.isEmpty ? [.init("updates", .updates, .ok, "Everything is up to date")] : out
    }

    static func battery(_ d: [String: Any]?) -> [HealthCheck] {
        guard let d else { return [unknown("battery", .battery, "Battery")] }
        if d.isEmpty { return [.init("battery", .battery, .ok, "This Mac has no battery")] }
        // On Apple silicon "MaxCapacity" is a percentage; on older Intel Macs it is the figure itself.
        let whole = number(d["MaxCapacity"]).flatMap { $0 > 100 ? $0 : nil }
        guard let raw = number(d["AppleRawMaxCapacity"]) ?? whole, let design = number(d["DesignCapacity"]), design > 0 else {
            return [unknown("battery", .battery, "Battery")]
        }
        // A new battery reads above its design figure; more than 100% says nothing.
        let health = min(100, Int((raw / design * 100).rounded()))
        let cycles = Int(number(d["CycleCount"]) ?? 0)
        let detail = Plural.count(cycles, "charge cycle")
        var out: [HealthCheck] = []
        if (number(d["PermanentFailureStatus"]) ?? 0) != 0 {
            out.append(.init("battery", .battery, .urgent, "The battery reports a fault", detail, weight: 15, fix: .battery))
        } else if health < 80 {
            out.append(.init("battery", .battery, .attention, "Battery health \(health)%", detail + ". Under 80%, consider a replacement.", weight: 8, fix: .battery))
        } else {
            out.append(.init("battery", .battery, .ok, "Battery health \(health)%", detail))
        }
        // Hundredths of a degree.
        if let t = number(d["Temperature"]), t / 100 >= 42 {
            out.append(.init("battery-temp", .battery, .attention, String(format: "The battery is hot: %.0f°", t / 100), "Long heat shortens its life.", weight: 5, fix: .battery))
        }
        return out
    }

    static func disk(free: UInt64, total: UInt64, smart: String?, history: [HealthDay]) -> [HealthCheck] {
        var out: [HealthCheck] = []
        if total == 0 {
            out.append(unknown("disk", .storage, "Free space"))
        } else {
            let share = Double(free) / Double(total)
            let text = String(format: "%.0f GB free of %.0f", Double(free) / 1e9, Double(total) / 1e9)
            if share < 0.05 { out.append(.init("disk", .storage, .urgent, "The disk is almost full", text, weight: 15, fix: .cleanup)) }
            else if share < 0.12 { out.append(.init("disk", .storage, .attention, "The disk is filling up", text, weight: 8, fix: .cleanup)) }
            else { out.append(.init("disk", .storage, .ok, "Enough free space", text)) }
            if share >= 0.12, let days = daysToFull(history, total: total), days <= 45 {
                out.append(.init("disk-trend", .storage, .attention, "At this rate the disk is full in about \(Plural.count(days, "day"))",
                                 "Based on the last two weeks.", weight: 6, fix: .cleanup))
            }
        }
        if let smart {
            if smart.contains("SMART Status") && smart.contains("Verified") { out.append(.init("smart", .storage, .ok, "Disk hardware is fine")) }
            else if smart.contains("Failing") { out.append(.init("smart", .storage, .urgent, "The disk reports a failure", "Back up now.", weight: 30, fix: .timeMachine)) }
            else { out.append(unknown("smart", .storage, "Disk hardware")) }
        } else { out.append(unknown("smart", .storage, "Disk hardware")) }
        return out
    }

    /// Straight-line fit of free space over the last two weeks. Nil with under five days of readings.
    static func daysToFull(_ history: [HealthDay], total: UInt64) -> Int? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        let points = history.suffix(14).compactMap { h in f.date(from: h.day).map { ($0.timeIntervalSince1970 / 86400, Double(h.diskFreeBytes)) } }
        guard points.count >= 5, let last = points.last else { return nil }
        let mx = points.map(\.0).reduce(0, +) / Double(points.count), my = points.map(\.1).reduce(0, +) / Double(points.count)
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        guard sxx > 0 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        // Under 1 GB a day is noise on this scale.
        guard slope < -1e9 else { return nil }
        return Int(last.1 / -slope)
    }

    public struct Crash: Equatable, Sendable {
        public enum Kind: Sendable { case app, simulator, panic, memoryKill }
        public var kind: Kind
        public var name: String
        public var date: Date
    }

    /// First line of an `.ips` report. `body` is only read for memory kills.
    static func crash(header: String, body: () -> String) -> Crash? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any] else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        guard let stamp = d["timestamp"] as? String, let date = f.date(from: stamp) else { return nil }
        let name = d["app_name"] as? String ?? d["name"] as? String ?? ""
        switch d["bug_type"] as? String {
        case "309":
            // Platform 7 is the iOS simulator: the user's own app under development, not this Mac.
            return Crash(kind: (d["platform"] as? Int) == 7 ? .simulator : .app, name: name, date: date)
        case "210": return Crash(kind: .panic, name: "kernel", date: date)
        case "298":
            // A daemon that passed its own limit is routine. Only a real shortage counts.
            let text = body()
            guard text.contains("vm-pageshortage") || text.contains("vm-compressor") || text.contains("jettisoned") else { return nil }
            return Crash(kind: .memoryKill, name: "memory", date: date)
        default: return nil
        }
    }

    static func stability(_ crashes: [Crash]?, bootedAt: Date?, now: Date) -> [HealthCheck] {
        guard let crashes else { return [unknown("crashes", .stability, "Crash reports")] }
        var out: [HealthCheck] = []
        let week = crashes.filter { now.timeIntervalSince($0.date) < 7 * 86400 }
        let panics = week.filter { $0.kind == .panic }.count
        if panics > 0 { out.append(.init("panic", .stability, .urgent, panics == 1 ? "The Mac crashed this week" : "The Mac crashed \(panics) times this week", "A system crash, not an app.", weight: 15)) }
        let kills = week.filter { $0.kind == .memoryKill }.count
        if kills > 0 { out.append(.init("memkill", .stability, .attention, "macOS closed processes for lack of memory", "\(Plural.count(kills, "time")) this week.", weight: 8, fix: .plan)) }
        let names = Dictionary(grouping: week.filter { $0.kind == .app }, by: \.name).mapValues(\.count)
        let repeated = names.filter { $0.value >= 3 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if !repeated.isEmpty {
            out.append(.init("crashes", .stability, .attention, repeated.count == 1 ? "One program keeps crashing" : "\(repeated.count) programs keep crashing",
                             "This week: " + repeated.prefix(3).map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + ".", weight: 4))
        }
        let sim = week.filter { $0.kind == .simulator }.count
        if out.isEmpty {
            out.append(.init("crashes", .stability, .ok, "No repeated crashes", sim > 0 ? "\(Plural.count(sim, "crash", "crashes")) inside a simulator not counted." : ""))
        }
        if let bootedAt {
            let days = Int(now.timeIntervalSince(bootedAt) / 86400)
            out.append(days >= 30 ? .init("uptime", .stability, .attention, "No restart for \(days) days", "A restart frees memory and finishes updates.", weight: 3)
                       : .init("uptime", .stability, .ok, days == 0 ? "Restarted today" : days == 1 ? "Restarted yesterday" : "Restarted \(days) days ago"))
        }
        return out
    }

    static func performance(_ s: SystemStats) -> [HealthCheck] {
        var out: [HealthCheck] = []
        if s.memPressureLevel >= 2 {
            out.append(.init("memory", .performance, s.memPressureLevel >= 4 ? .urgent : .attention, "Memory is under pressure", "", weight: s.memPressureLevel >= 4 ? 12 : 8, fix: .plan))
        } else if s.memTotalBytes > 0 {
            out.append(.init("memory", .performance, .ok, "Memory is not under pressure", String(format: "%.0f%% in use", s.memPercent)))
        } else { out.append(unknown("memory", .performance, "Memory")) }
        if s.swapUsedBytes >= 4 << 30 {
            out.append(.init("swap", .performance, .attention, "macOS is writing memory to disk", String(format: "%.1f GB", Double(s.swapUsedBytes) / 1_073_741_824), weight: 5, fix: .plan))
        }
        if s.thermal == "serious" || s.thermal == "critical" {
            out.append(.init("thermal", .performance, s.thermal == "critical" ? .urgent : .attention, "The Mac slows down from heat", "", weight: 8))
        } else {
            out.append(.init("thermal", .performance, .ok, "No slowdown from heat", s.chipTempC.map { String(format: "Chip at %.0f°", $0) } ?? ""))
        }
        return out
    }

    static func startup(_ items: [StartupItem], known: [String]?) -> [HealthCheck] {
        var out: [HealthCheck] = []
        let fresh = known.map { k in items.filter { !k.contains($0.label) } } ?? []
        if !fresh.isEmpty {
            out.append(.init("startup-new", .startup, .attention, fresh.count == 1 ? "New startup item" : "\(fresh.count) new startup items",
                             fresh.prefix(3).map { "\($0.label)" }.joined(separator: ", "), weight: 5, fix: .acceptStartup))
        }
        let broken = items.filter(\.missing)
        if !broken.isEmpty {
            out.append(.init("startup-broken", .startup, .attention, broken.count == 1 ? "A startup item points to a missing file" : "\(broken.count) startup items point to missing files",
                             broken.prefix(3).map { "\($0.label)" }.joined(separator: ", "), weight: 2, fix: .loginItems))
        }
        return out.isEmpty ? [.init("startup", .startup, .ok, "Startup items unchanged", Plural.count(items.count, "item"))] : out
    }

    static func startupItem(_ plist: [String: Any], file: String, exists: (String) -> Bool) -> StartupItem {
        let label = plist["Label"] as? String ?? (file as NSString).deletingPathExtension
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
        // Only a full path can be checked; a bare name is found through PATH.
        return StartupItem(label: label, program: program, missing: program.hasPrefix("/") && !exists(program))
    }

    static func unknown(_ id: String, _ area: HealthArea, _ name: String) -> HealthCheck {
        .init(id, area, .unknown, "\(name): could not read", "")
    }

    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
}

/// Reads this Mac. No admin rights, nothing written, and no folder macOS guards behind a
/// permission dialog (Downloads, Desktop, the Trash, other apps' containers).
public enum HealthProbe {
    public static func take(system: SystemStats, store: HealthStore, settings: Settings, now: Date = Date()) -> HealthReport {
        func tool(_ path: String, _ args: [String]) -> String? { Shell.output(path, args) }
        let fm = FileManager.default
        var checks: [HealthCheck] = []

        let destinations = tool("/usr/bin/tmutil", ["destinationinfo"])
        let configured = destinations.map { !$0.contains("No destinations") } ?? false
        checks.append(HealthRules.backup(destinations: destinations, latest: configured ? tool("/usr/bin/tmutil", ["latestbackup"]) : nil, now: now))
        checks += HealthRules.protection(
            fileVault: tool("/usr/bin/fdesetup", ["status"]), sip: tool("/usr/bin/csrutil", ["status"]),
            gatekeeper: tool("/usr/sbin/spctl", ["--status"]),
            firewall: tool("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]))

        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        checks += HealthRules.updates(plist("/Library/Preferences/com.apple.SoftwareUpdate.plist"), system: version, now: now)

        let battery = tool("/usr/sbin/ioreg", ["-arn", "AppleSmartBattery", "-d1"]).map { text -> [String: Any] in
            let list = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
            return (list as? [[String: Any]])?.first ?? [:]
        }
        checks += HealthRules.battery(battery)
        checks += HealthRules.disk(free: system.diskFreeBytes, total: system.diskTotalBytes,
                                   smart: tool("/usr/sbin/diskutil", ["info", "disk0"]), history: store.history)
        checks += HealthRules.stability(crashes(now: now), bootedAt: bootTime(), now: now)
        checks += HealthRules.performance(system)

        var items: [StartupItem] = []
        for dir in [NSHomeDirectory() + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for file in (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? [] where file.hasSuffix(".plist") {
                if let p = plist(dir + "/" + file) {
                    items.append(HealthRules.startupItem(p, file: file) { fm.fileExists(atPath: $0) })
                }
            }
        }
        checks += HealthRules.startup(items, known: store.knownStartup)

        let cleanup = Cleanup.find(home: NSHomeDirectory(), table: ProcTable.live(), settings: settings, now: now)
        let bytes = cleanup.reduce(0) { $0 + $1.bytes }
        if bytes >= 5 << 30 {
            checks.append(.init("cleanup", .storage, .attention, String(format: "%.1f GB can be cleared", Double(bytes) / 1_073_741_824),
                                "Files that are rebuilt or downloaded again.", weight: 2, fix: .cleanup))
        }
        return HealthReport(takenAt: now, checks: checks, startup: items, cleanup: cleanup)
    }

    static func plist(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func bootTime() -> Date? {
        var tv = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }

    /// Nil when none of the folders could be listed.
    static func crashes(now: Date) -> [HealthRules.Crash]? {
        let fm = FileManager.default
        let roots = [NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
        var listed = false
        var out: [HealthRules.Crash] = []
        for dir in roots.flatMap({ [$0, $0 + "/Retired"] }) {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            listed = true
            for file in files where file.hasSuffix(".ips") || file.hasSuffix(".panic") {
                let path = dir + "/" + file
                guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(m) < 8 * 86400, let data = fm.contents(atPath: path) else { continue }
                let cut = data.firstIndex(of: 10) ?? data.endIndex
                if let c = HealthRules.crash(header: String(decoding: data[..<cut], as: UTF8.self),
                                             body: { String(decoding: data[cut...], as: UTF8.self) }) { out.append(c) }
            }
        }
        return listed ? out : nil
    }
}
