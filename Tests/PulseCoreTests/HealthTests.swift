import XCTest
@testable import PulseCore

/// Fixtures are the outputs of real tools, unless a test says otherwise.
final class HealthTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_795_510_000)  // 2026-11-24

    func temp() throws -> String {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pulse-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // /var is a link to /private/var, and Foundation strips the prefix again.
        let real = try XCTUnwrap(realpath(dir.path, nil))
        defer { free(real) }
        return String(cString: real)
    }

    func testNoBackupIsUrgentAndAFailedReadingIsUnknownNotHealthy() {
        XCTAssertEqual(HealthRules.backup(destinations: "tmutil: No destinations configured.\n", latest: nil, now: now).state, .urgent)
        XCTAssertEqual(HealthRules.backup(destinations: nil, latest: nil, now: now).state, .unknown)
        XCTAssertEqual(HealthRules.backup(destinations: "", latest: nil, now: now).state, .unknown)
        let disk = "Name          : Backup\nKind          : Local\n"
        XCTAssertEqual(HealthRules.backup(destinations: disk, latest: "Failed to mount backup destination", now: now).state, .unknown)
        XCTAssertEqual(HealthRules.backup(destinations: disk, latest: "/Volumes/B/2026-11-23-080000.backup", now: now).state, .ok)
        XCTAssertEqual(HealthRules.backup(destinations: disk, latest: "/Volumes/B/2026-11-10-080000.backup", now: now).state, .attention)
        XCTAssertEqual(HealthRules.backup(destinations: disk, latest: "/Volumes/B/2026-09-10-080000.backup", now: now).state, .urgent)
    }

    func testProtectionReadsThisMac() {
        let c = HealthRules.protection(fileVault: "FileVault is On.", sip: "System Integrity Protection status: enabled.",
                                       gatekeeper: "assessments enabled", firewall: "Firewall is disabled. (State = 0)")
        XCTAssertEqual(c.map(\.state), [.ok, .ok, .ok, .attention])
        let off = HealthRules.protection(fileVault: "FileVault is Off.", sip: "System Integrity Protection status: disabled.",
                                         gatekeeper: "assessments disabled", firewall: "Firewall is enabled. (State = 1)")
        XCTAssertEqual(off.map(\.state), [.urgent, .urgent, .urgent, .ok])
        XCTAssertTrue(HealthRules.protection(fileVault: nil, sip: "", gatekeeper: "?", firewall: nil).allSatisfy { $0.state == .unknown })
    }

    func testUpdatesReportThisMajorOnly() {
        let offered: [String: Any] = ["MSU_26.7.3": now.addingTimeInterval(-8.5 * 86400)]
        let plist: [String: Any] = [
            "FirstOfferDateDictionary": offered, "LastSuccessfulDate": now, "CriticalUpdateInstall": true, "ConfigDataInstall": true,
            "RecommendedUpdates": [
                ["Display Name": "Safari", "Display Version": "27.2", "Identifier": "Safari27"],
                ["Display Name": "macOS Tahoe 26.7.3", "Display Version": "26.7.3", "Identifier": "MSU_26.7.3", "MobileSoftwareUpdate": true],
                ["Display Name": "macOS 27.2.1", "Display Version": "27.2.1", "Identifier": "MSU_27", "MobileSoftwareUpdate": true],
            ]]
        let c = HealthRules.updates(plist, system: "26.4", now: now)
        XCTAssertEqual(c.map(\.title), ["Update waiting: Safari 27.2", "Update waiting: macOS Tahoe 26.7.3"])
        XCTAssertTrue(c[1].detail.contains("8 days"))
        XCTAssertEqual(HealthRules.updates(["RecommendedUpdates": [], "LastSuccessfulDate": now], system: "26.4", now: now).map(\.state), [.ok])
        XCTAssertEqual(HealthRules.updates(["LastSuccessfulDate": now.addingTimeInterval(-20 * 86400)], system: "26.4", now: now).map(\.state), [.attention])
        XCTAssertEqual(HealthRules.updates(nil, system: "26.4", now: now).map(\.state), [.unknown])
    }

    func testBatteryNeverReadsAboveOneHundred() {
        let c = HealthRules.battery(["AppleRawMaxCapacity": 8909, "DesignCapacity": 8579, "CycleCount": 5, "Temperature": 3068, "PermanentFailureStatus": 0])
        XCTAssertEqual(c.map(\.title), ["Maximum capacity 100%"])
        XCTAssertEqual(HealthRules.battery(["AppleRawMaxCapacity": 6000, "DesignCapacity": 8579]).map(\.state), [.attention])
        XCTAssertEqual(HealthRules.battery(["AppleRawMaxCapacity": 8909, "DesignCapacity": 8579, "PermanentFailureStatus": 1]).map(\.state), [.urgent])
        XCTAssertEqual(HealthRules.battery([:]).map(\.state), [.ok], "a Mac without a battery")
        XCTAssertEqual(HealthRules.battery(nil).map(\.state), [.unknown])
    }

    func testSimulatorCrashesAndRoutineKillsAreNotThisMacsProblem() {
        func header(_ name: String, platform: Int, bug: String = "309") -> String {
            #"{"app_name":"\#(name)","timestamp":"2026-11-23 12:19:56.00 +0200","platform":\#(platform),"bug_type":"\#(bug)"}"#
        }
        XCTAssertEqual(HealthRules.crash(header: header("Widgets", platform: 7), body: { "" })?.kind, .simulator)
        XCTAssertEqual(HealthRules.crash(header: header("Chromium", platform: 1), body: { "" })?.kind, .app)
        XCTAssertNil(HealthRules.crash(header: header("", platform: 1, bug: "298"), body: { #""reason" : "per-process-limit""# }))
        XCTAssertEqual(HealthRules.crash(header: header("", platform: 1, bug: "298"), body: { #""reason" : "vm-pageshortage""# })?.kind, .memoryKill)
        XCTAssertNil(HealthRules.crash(header: "not json", body: { "" }))

        let at = now.addingTimeInterval(-86400)
        let sim = (0..<90).map { _ in HealthRules.Crash(kind: .simulator, name: "Widgets", date: at) }
        XCTAssertEqual(HealthRules.stability(sim, bootedAt: nil, now: now).map(\.state), [.ok])
        let app = (0..<3).map { _ in HealthRules.Crash(kind: .app, name: "Chromium", date: at) }
        XCTAssertEqual(HealthRules.stability(sim + app, bootedAt: nil, now: now).map(\.state), [.attention])
        let old = app.map { HealthRules.Crash(kind: .app, name: $0.name, date: now.addingTimeInterval(-9 * 86400)) }
        XCTAssertEqual(HealthRules.stability(old, bootedAt: nil, now: now).map(\.state), [.ok])
        XCTAssertEqual(HealthRules.stability(nil, bootedAt: nil, now: now).map(\.state), [.unknown])
    }

    func testDiskForecastNeedsDaysAndARealSlope() {
        func days(_ n: Int, perDay: Double) -> [HealthDay] {
            (0..<n).map { HealthDay(day: HealthStore.day(now.addingTimeInterval(Double($0 - n) * 86400)), score: 90, diskFreeBytes: UInt64(500e9 - Double($0) * perDay)) }
        }
        XCTAssertNil(HealthRules.daysToFull(days(4, perDay: 20e9), total: 2_000_000_000_000))
        XCTAssertNil(HealthRules.daysToFull(days(10, perDay: 0.1e9), total: 2_000_000_000_000))
        XCTAssertEqual(HealthRules.daysToFull(days(10, perDay: 20e9), total: 2_000_000_000_000), 16)  // 320 GB left
        XCTAssertEqual(HealthRules.disk(free: 10, total: 1000, smart: "SMART Status: Verified", history: []).map(\.state), [.urgent, .ok])
        XCTAssertEqual(HealthRules.disk(free: 500, total: 1000, smart: "SMART Status: Failing", history: []).map(\.state), [.ok, .urgent])
        XCTAssertEqual(HealthRules.disk(free: 500, total: 1000, smart: "Could not find disk", history: []).map(\.state), [.ok, .unknown])
    }

    func testStartupBaselineFlagsOnlyWhatIsNewOrBroken() {
        let a = StartupItem(label: "a", program: "/bin/ls", missing: false), b = StartupItem(label: "b", program: "/x", missing: false)
        XCTAssertEqual(HealthRules.startup([a, b], known: nil).map(\.state), [.ok], "the first check is the baseline")
        XCTAssertEqual(HealthRules.startup([a, b], known: ["a"]).map(\.id), ["startup-new"])
        XCTAssertTrue(HealthRules.startupItem(["Label": "x", "ProgramArguments": ["/gone/tool"]], file: "x.plist", exists: { _ in false }).missing)
        XCTAssertFalse(HealthRules.startupItem(["Label": "x", "ProgramArguments": ["bash", "-c"]], file: "x.plist", exists: { _ in false }).missing)
    }

    func report(_ checks: [HealthCheck]) -> HealthReport { HealthReport(takenAt: now, checks: checks) }

    func testScoreIgnoresAndAnnouncements() {
        var s = HealthStore()
        XCTAssertNil(s.score)
        let backup = HealthCheck("backup", .backup, .urgent, "b", weight: 15), fw = HealthCheck("firewall", .protection, .attention, "f", weight: 8)
        let lost = HealthCheck("fv", .protection, .unknown, "u")
        s.absorb(report([fw, backup, lost]), diskFree: 1, now: now)
        XCTAssertEqual(s.score, 77)
        XCTAssertEqual(s.problems.map(\.id), ["backup", "firewall"], "urgent first")
        XCTAssertEqual(s.state(of: .battery), .unknown, "nothing read is not healthy")
        XCTAssertEqual(s.takeNew(now: now).count, 2)
        XCTAssertEqual(s.takeNew(now: now.addingTimeInterval(86400)).count, 0, "a chronic finding is not repeated daily")
        XCTAssertEqual(s.takeNew(now: now.addingTimeInterval(15 * 86400)).count, 2)
        s.ignored = ["firewall"]
        XCTAssertEqual(s.score, 85)
        XCTAssertEqual(s.state(of: .protection), .unknown)
        s.absorb(report([fw]), diskFree: 1, now: now)
        _ = s.takeNew(now: now)
        s.absorb(report([backup]), diskFree: 1, now: now)
        XCTAssertEqual(s.takeNew(now: now).map(\.id), ["backup"], "solved and back is news")
        XCTAssertEqual(s.history.count, 1, "one row per day")
    }

    func testStoreSurvivesTheDisk() throws {
        let url = URL(fileURLWithPath: try temp() + "/health.json")
        var s = HealthStore()
        s.absorb(report([HealthCheck("backup", .backup, .urgent, "b", weight: 15, fix: .timeMachine)]), diskFree: 7, now: now)
        _ = s.takeNew(now: now)
        s.save(to: url)
        let back = HealthStore.load(from: url)
        XCTAssertEqual(back.problems, s.problems)
        XCTAssertEqual(back.history, s.history)
        XCTAssertEqual(back.notified.count, 1)
    }

    func testMCPReadsTheStoredReportAndNeverTakesASnapshot() throws {
        var s = HealthStore()
        s.absorb(report([HealthCheck("backup", .backup, .urgent, "b", weight: 15)]), diskFree: 1, now: Date())
        let server = MCPServer(provider: { XCTFail("no snapshot"); return Snapshot(system: .empty, sessions: [], apps: [], topCPU: [], topMemory: [], suggestions: []) },
                               healthStore: { s })
        let text = try XCTUnwrap(server.call("health_report"))
        XCTAssertTrue(text.contains("\"score\":85"), text)
        XCTAssertTrue(MCPServer(healthStore: { HealthStore() }).call("health_report")!.contains("No health check"))
    }

    // MARK: Cleanup. Only ever in a temporary folder.

    func makeTarget(_ home: String, _ project: String, tag: String? = "Signature: 8a477f597d28d172789f06886806bc55\n# created by cargo.\n", daysOld: Double) throws -> String {
        let path = home + "/Code/\(project)/target"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let tag { try tag.write(toFile: path + "/CACHEDIR.TAG", atomically: true, encoding: .utf8) }
        let d = now.addingTimeInterval(-daysOld * 86400)
        for p in [path + "/CACHEDIR.TAG", path] where FileManager.default.fileExists(atPath: p) {
            try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: p)
        }
        return path
    }

    func clean(_ path: String, _ home: String, table: ProcTable = ProcTable([]), settings: Settings = Settings()) -> Bool {
        var moved: [String] = []
        let ok = Cleanup.trash(CleanupItem(title: "t", detail: "", path: path, bytes: 1), home: home, table: table, settings: settings, now: now) { moved.append($0.path) }
        XCTAssertEqual(ok, !moved.isEmpty)
        return ok
    }

    func testCleanupTakesOnlyStaleCargoFolders() throws {
        let home = try temp()
        let stale = try makeTarget(home, "old", daysOld: 30), fresh = try makeTarget(home, "new", daysOld: 2)
        let notCargo = try makeTarget(home, "mine", tag: nil, daysOld: 30)
        XCTAssertEqual(Set(Cleanup.cargoTargets(under: home + "/Code")), [stale, fresh])
        XCTAssertTrue(clean(stale, home))
        XCTAssertFalse(clean(fresh, home), "still being built")
        XCTAssertFalse(clean(notCargo, home), "a folder that is only called target")
        XCTAssertFalse(clean(home + "/Code/old", home), "the project itself")
        XCTAssertFalse(clean(home, home))
        var s = Settings(); s.neverTouch = ["old"]
        XCTAssertFalse(clean(stale, home, settings: s))
    }

    func testCleanupRefusesWhatIsInUseAndLinks() throws {
        let home = try temp()
        let stale = try makeTarget(home, "old", daysOld: 30)
        let running = ProcTable([ProcInfo(pid: 5, ppid: 1, rssBytes: 0, cpu: 0, lstart: "", command: stale + "/debug/app --serve")])
        XCTAssertFalse(clean(stale, home, table: running))

        let npm = home + "/.npm/_cacache"
        try FileManager.default.createDirectory(atPath: npm, withIntermediateDirectories: true)
        XCTAssertTrue(clean(npm, home))
        let npmRuns = ProcTable([ProcInfo(pid: 6, ppid: 1, rssBytes: 0, cpu: 0, lstart: "", command: "npm install", exec: "/opt/homebrew/bin/npm")])
        XCTAssertFalse(clean(npm, home, table: npmRuns))

        let real = home + "/precious"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.gradle", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.gradle/caches", withDestinationPath: real)
        XCTAssertFalse(clean(home + "/.gradle/caches", home), "a link to somewhere else")
        XCTAssertFalse(clean(home + "/Code/old/../old/target", home), "a path that is not itself")
    }
}
