import XCTest
@testable import PulseCore

final class CoreTests: XCTestCase {
    let ps = """
      100     1 204800   1.5 Sun Nov 22 11:20:22 2026 claude --output-format stream-json --verbose
      101   100  51200   0.5 Sun Nov 22 11:20:30 2026 /usr/bin/node /x/mcp-server.js --flag a b
      200     1 102400   0.0 Sun Nov  1 09:00:00 2026 claude --output-format stream-json
      300     1  20480   0.0 Sat Nov 21 08:00:00 2026 node /private/tmp/claude-\(getuid())/proj/abc/server.js
      400     1 3145728  9.0 Sat Nov 21 08:00:00 2026 /Applications/Big.app/Contents/MacOS/Big
      401   400 1048576  1.0 Sat Nov 21 08:00:01 2026 /Applications/Big.app/Contents/Frameworks/Big Helper.app/Contents/MacOS/Big Helper --type=gpu
    """

    func sessionsDir(_ records: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for r in records {
            let data = try JSONSerialization.data(withJSONObject: r)
            try data.write(to: dir.appendingPathComponent("\(r["pid"]!).json"))
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testParsesPsLinesIncludingSpacesAndSingleDigitDays() {
        let t = ProcTable.parse(ps)
        XCTAssertEqual(t.all.count, 6)
        XCTAssertEqual(t.byPid[101]?.command, "/usr/bin/node /x/mcp-server.js --flag a b")
        XCTAssertEqual(t.byPid[200]?.lstart, "Sun Nov 1 09:00:00 2026")
        XCTAssertEqual(t.byPid[100]?.rssBytes, 204800 * 1024)
        XCTAssertEqual(Set(t.tree(of: 100).map(\.pid)), [100, 101])
    }

    // A session file whose pid now belongs to a different process must not be
    // shown, and above all must never be offered for closing: pids are reused.
    func testSessionWithReusedPidIsNotLive() throws {
        let t = ProcTable.parse(ps)
        let dir = try sessionsDir([
            ["pid": 100, "sessionId": "a", "name": "real", "cwd": "/x/proj", "status": "idle",
             "procStart": "Sun Nov 22 11:20:22 2026", "statusUpdatedAt": 0],
            ["pid": 200, "sessionId": "b", "name": "reused pid", "cwd": "/x/other", "status": "idle",
             "procStart": "Mon Oct 12 10:00:00 2026", "statusUpdatedAt": 0],
            ["pid": 999, "sessionId": "c", "name": "dead", "cwd": "/x", "status": "idle",
             "procStart": "Sun Nov 22 11:20:22 2026", "statusUpdatedAt": 0],
        ])
        let sessions = ClaudeSessions.load(dir: dir, table: t)
        XCTAssertEqual(sessions.map(\.name), ["real"])
        XCTAssertEqual(sessions[0].rssBytes, (204800 + 51200) * 1024, "memory is the whole tree")
        XCTAssertEqual(sessions[0].project, "proj")
    }

    func testSuggestionsOnlyTakeLongIdleSessionsNeverBusyOnes() throws {
        let t = ProcTable.parse(ps)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ms(_ ago: TimeInterval) -> Double { (now.timeIntervalSince1970 - ago) * 1000 }
        let dir = try sessionsDir([
            ["pid": 100, "name": "busy", "cwd": "/p", "status": "busy",
             "procStart": "Sun Nov 22 11:20:22 2026", "statusUpdatedAt": ms(90000)],
            ["pid": 200, "name": "long idle", "cwd": "/p", "status": "idle",
             "procStart": "Sun Nov 1 09:00:00 2026", "statusUpdatedAt": ms(50000)],
            ["pid": 300, "name": "just went idle", "cwd": "/p", "status": "idle",
             "procStart": "Sat Nov 21 08:00:00 2026", "statusUpdatedAt": ms(120)],
        ])
        let sessions = ClaudeSessions.load(dir: dir, table: t)
        XCTAssertEqual(sessions.count, 3)
        let pids = Set(sessions.flatMap { t.tree(of: $0.pid).map(\.pid) })
        let apps = AppGroups.build(t, excluding: pids)
        let out = Suggestions.build(system: .empty, sessions: sessions, apps: apps, table: t, sessionPids: pids, now: now)
        XCTAssertEqual(out.filter { $0.kind == .idleSession }.map(\.title), ["long idle"])
        XCTAssertEqual(out.filter { $0.kind == .heavyApp }.map(\.title), ["Big"])
        XCTAssertEqual(out.first { $0.kind == .heavyApp }?.reclaimBytes, (3145728 + 1048576) * 1024)
        let guarded = Suggestions.build(system: .empty, sessions: sessions, apps: apps, table: t, sessionPids: pids,
                                        protectedBundles: ["/Applications/Big.app"], now: now)
        XCTAssertTrue(guarded.filter { $0.kind == .heavyApp }.isEmpty, "an app hosting live sessions is never offered for quitting")
        XCTAssertTrue(out.filter { $0.kind == .orphan }.isEmpty, "pid 300 is a session here, not an orphan")
    }

    func testOrphanIsALeftoverAgentProcessUnderLaunchd() {
        let t = ProcTable.parse(ps)
        let now = StartTime.date("Sun Nov 22 12:00:00 2026")!
        let out = Suggestions.build(system: .empty, sessions: [], apps: [], table: t, sessionPids: [], now: now)
        XCTAssertEqual(out.filter { $0.kind == .orphan }.map(\.pid), [300])
    }

    func testTerminateRefusesWhenStartTimeDiffers() {
        // Our own parent is alive, but this is not its start time.
        XCTAssertFalse(Actions.terminate(pid: getppid(), expectedStart: "Thu Jan 1 00:00:00 1970"))
        XCTAssertFalse(Actions.terminate(pid: getpid(), expectedStart: ""))
        XCTAssertFalse(Actions.terminate(pid: 1, expectedStart: "x"))
    }

    func testConsumersGroupSessionsAppsAndBareProcesses() {
        let t = ProcTable.parse(ps + "\n  500 1 1024 40.0 Sat Nov 21 08:00:00 2026 /opt/homebrew/bin/node a.js\n  501 1 1024 60.0 Sat Nov 21 08:00:00 2026 node b.js\n")
        let session = ClaudeSession(pid: 100, sessionId: "", name: "work", cwd: "/p", status: "busy", entrypoint: "",
                                    procStart: "", statusSince: nil, rssBytes: 1, cpu: 2.0, processCount: 2)
        let all = Consumers.build(table: t, sessions: [session], cores: 10)
        let top = Consumers.topCPU(all, 3)
        XCTAssertEqual(top.map(\.name), ["node", "Big", "work"])
        XCTAssertEqual(top[0].cpuPercent, 10, accuracy: 0.001, "node processes summing to 100% of one core, out of ten cores")
        XCTAssertEqual(top[0].processCount, 3, "by executable name, whatever path it was started from")
        XCTAssertEqual(top[1].kind, .app)
        XCTAssertFalse(all.contains { $0.name == "mcp-server.js" || $0.processCount == 0 })
    }

    func testTemperaturePickIgnoresDeadSensors() {
        let t = ThermalSensors.pick([("PMU tdie1", 64.9), ("PMU tdie6", 66.1), ("PMU tdev1", -9201.1),
                                     ("NAND CH0 temp", 37), ("PMU tcal", 51.8)])
        XCTAssertEqual(t.chip, 66.1, "the hottest die sensor, not a calibration or a dead one")
        XCTAssertEqual(t.ssd, 37)
        XCTAssertNil(t.battery)
        XCTAssertNil(ThermalSensors.pick([("PMU tdie1", -9201)]).chip)
    }

    func testSettingsLoadOldFilesAndProtectNames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-settings-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"autoSelectIdleHours": 3, "neverTouch": ["Portal"]}"#.utf8).write(to: url)
        var s = Settings.load(from: url)
        XCTAssertEqual(s.autoSelectIdleHours, 3)
        XCTAssertTrue(s.alertCPU, "a key the file lacks keeps its default")
        XCTAssertTrue(s.isProtected("Improve portal home"))
        XCTAssertFalse(s.isProtected("qemu"))
        s.barTemp = true
        s.save(to: url)
        XCTAssertEqual(Settings.load(from: url), s)

        func idle(_ hours: Double) -> Suggestion {
            Suggestion(kind: .idleSession, title: "x", detail: "", reclaimBytes: 1, pid: 1, procStart: nil, bundlePath: nil, idleSeconds: hours * 3600)
        }
        XCTAssertTrue(s.preselects(idle(4)))
        XCTAssertFalse(s.preselects(idle(2)), "under the owner's threshold a session is offered but not ticked")
    }

    func testAlertNeedsSustainedLoadAndDoesNotRepeat() {
        var engine = AlertEngine()
        let settings = Settings()
        let hot = [Consumer(kind: .process, name: "qemu", rssBytes: 0, cpuPercent: 62, processCount: 1)]
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(engine.evaluate(system: .empty, consumers: hot, settings: settings, now: t0).isEmpty)
        XCTAssertTrue(engine.evaluate(system: .empty, consumers: hot, settings: settings, now: t0 + 300).isEmpty, "five minutes is not ten")
        XCTAssertEqual(engine.evaluate(system: .empty, consumers: hot, settings: settings, now: t0 + 601).map(\.key), ["cpu:process:qemu"])
        XCTAssertTrue(engine.evaluate(system: .empty, consumers: hot, settings: settings, now: t0 + 700).isEmpty, "no repeat inside the cooldown")
        // A dip resets the clock.
        var dipped = AlertEngine()
        _ = dipped.evaluate(system: .empty, consumers: hot, settings: settings, now: t0)
        _ = dipped.evaluate(system: .empty, consumers: [], settings: settings, now: t0 + 300)
        XCTAssertTrue(dipped.evaluate(system: .empty, consumers: hot, settings: settings, now: t0 + 601).isEmpty)
        var off = Settings(); off.alertCPU = false
        var silent = AlertEngine()
        _ = silent.evaluate(system: .empty, consumers: hot, settings: off, now: t0)
        XCTAssertTrue(silent.evaluate(system: .empty, consumers: hot, settings: off, now: t0 + 900).isEmpty)
    }

    func testManualCloseSignalsTheGroupAndRefusesProtectedOnes() throws {
        let (a, aStart) = try spawnSleep()
        let (b, bStart) = try spawnSleep()
        let group = Consumer(kind: .process, name: "sleep", rssBytes: 0, cpuPercent: 0, processCount: 2,
                             members: [ProcRef(pid: a.processIdentifier, lstart: aStart), ProcRef(pid: b.processIdentifier, lstart: bStart)])
        var guarded = Settings(); guarded.neverTouch = ["SLEEP"]
        XCTAssertEqual(Actions.close(group, settings: guarded), 0, "a name on the never-touch list is refused")
        XCTAssertTrue(a.isRunning)
        var system = group; system.name = "WindowServer"
        XCTAssertEqual(Actions.close(system, settings: Settings()), 0)
        XCTAssertEqual(Actions.close(group, settings: Settings()), 2)
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual(a.terminationReason, .uncaughtSignal)
    }

    func spawnSleep() throws -> (Process, String) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        addTeardownBlock { if child.isRunning { child.terminate() } }
        let table = ProcTable.live()
        let start = try XCTUnwrap(table.byPid[child.processIdentifier]?.lstart)
        return (child, start)
    }

    // The only test of the path that really closes something. Every other test of
    // `terminate` asserts a refusal, and would pass if it always refused.
    func testClosesAnIdleSessionAndRefusesABusyOne() throws {
        let (idle, idleStart) = try spawnSleep()
        let (busy, busyStart) = try spawnSleep()
        let dir = try sessionsDir([
            ["pid": Int(idle.processIdentifier), "name": "idle", "cwd": "/p", "status": "idle", "procStart": idleStart],
            ["pid": Int(busy.processIdentifier), "name": "busy", "cwd": "/p", "status": "busy", "procStart": busyStart],
        ])
        XCTAssertFalse(Actions.closeIdleSession(pid: busy.processIdentifier, dir: dir))
        XCTAssertTrue(Actions.closeIdleSession(pid: idle.processIdentifier, dir: dir))
        idle.waitUntilExit()
        XCTAssertEqual(idle.terminationReason, .uncaughtSignal)
        XCTAssertTrue(busy.isRunning, "a session that is not idle is never closed")
    }

    func testMCPHandshakeListAndCall() throws {
        let snap = Snapshot(system: .empty, sessions: [], apps: [], topCPU: [], topMemory: [], suggestions: [])
        let server = MCPServer(provider: { snap }, settings: { Settings() })
        func obj(_ s: String?) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(s).utf8)) as? [String: Any])
        }
        let initReply = try obj(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        XCTAssertEqual((initReply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNil(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        let list = try obj(server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        // The MCP surface is read-only: an agent must not be able to close a session.
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }.sorted(),
                       ["claude_sessions", "dev_runtimes", "health_report", "optimize_suggestions", "recent_load", "sleep_blockers", "system_usage", "top_cpu", "top_memory"])
        let call = try obj(server.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"claude_sessions"}}"#))
        let content = try XCTUnwrap((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "[]")
        let bad = try obj(server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"kill"}}"#))
        XCTAssertNotNil(bad["error"])
    }

    func testSessionNamesAreShownWithoutEmoji() throws {
        XCTAssertEqual(Plain.text("🎮 me/raft: stills #3 (2×)"), "me/raft: stills #3 (2×)")
        XCTAssertEqual(Plain.text("a ✅ test of 100% 👨‍👩‍👧 ❤️ end"), "a test of 100% end")
        let t = ProcTable.parse(ps)
        let dir = try sessionsDir([["pid": 100, "name": "🚀 launch ✨", "cwd": "/p", "status": "busy", "procStart": "Sun Nov 22 11:20:22 2026"]])
        XCTAssertEqual(ClaudeSessions.load(dir: dir, table: t).first?.name, "launch")
    }

    // MARK: Simulators, emulators, build daemons

    static let udid = "DCCFDB8E-2977-4200-8A9B-68AAFC9B9423"
    static let rt = "/Library/Developer/CoreSimulator/Volumes/iOS_23E244/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.4.simruntime/Contents/Resources/RuntimeRoot"
    static let qemu = "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless"
    static let java = "/opt/homebrew/Cellar/openjdk@17/17.0.21/libexec/openjdk.jdk/Contents/Home/bin/java"

    /// Real shapes from this Mac: a simulator tree, an emulator a session started, a Gradle daemon with its Kotlin child.
    var devTable: ProcTable {
        let rows: [(Int, Int, Int, Double, String, String, String)] = [
            (500, 1, 18000, 0.0, "Sat Nov 21 20:46:00 2026", "launchd_sim", "launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(Self.udid)/data/var/run/launchd_bootstrap.plist"),
            (501, 500, 900000, 2.0, "Sat Nov 21 20:46:05 2026", "\(Self.rt)/usr/libexec/backboardd", "\(Self.rt)/usr/libexec/backboardd"),
            (502, 500, 600000, 0.0, "Sat Nov 21 20:46:09 2026", "\(Self.rt)/Applications/MobileSafari.app/MobileSafari", "\(Self.rt)/Applications/MobileSafari.app/MobileSafari"),
            (600, 1, 204800, 1.0, "Sun Nov 22 11:20:22 2026", "claude", "claude --output-format stream-json"),
            (601, 600, 4000000, 3.0, "Sun Nov 22 11:30:00 2026", Self.qemu, "\(Self.qemu) -avd Pixel_8 -no-audio -port 5556 -camera-back x"),
            (602, 600, 100000, 80.0, "Sun Nov 22 11:31:00 2026", "/usr/bin/python3", "/usr/bin/python3 train.py"),
            (700, 1, 1400000, 0.0, "Sun Nov 22 09:00:00 2026", Self.java, "\(Self.java) --add-opens=x -cp /g/gradle-8.11.1/lib/gradle-daemon-main-8.11.1.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.11.1"),
            (701, 700, 2300000, 0.0, "Sun Nov 22 09:00:09 2026", Self.java, "\(Self.java) -cp /k.jar org.jetbrains.kotlin.daemon.KotlinCompileDaemon --daemon-runFilesPath /x"),
            (702, 600, 3000, 0.0, "Sun Nov 22 12:40:00 2026", "/bin/zsh", "/bin/zsh -c grep org.gradle.launcher.daemon.bootstrap.GradleDaemon KotlinCompileDaemon org.jetbrains.kotlin.daemon.KotlinCompileDaemon"),
            (800, 1, 50000, 0.0, "Sun Nov 22 09:00:00 2026", "/Library/My Tools/helper daemon", "/Library/My Tools/helper daemon --flag /Applications/Other.app/x"),
        ]
        return ProcTable.parse(
            rows.map { "\($0.0) \($0.1) \($0.2) \($0.3) \($0.4) \($0.6)" }.joined(separator: "\n"),
            execs: rows.map { "\($0.0) \($0.5)" }.joined(separator: "\n"))
    }

    let devNow = ISO8601DateFormatter().date(from: "2026-11-22T12:46:00Z")!

    func testFindsSimulatorEmulatorAndBuildDaemonAsWholeTrees() {
        let found = Runtimes.detect(table: devTable, cores: 10, now: devNow, simulatorName: { $0 == Self.udid ? "iPhone 17" : nil })
        XCTAssertEqual(found.map(\.name).sorted(), ["Gradle 8.11.1", "Pixel_8 emulator", "iPhone 17 simulator"])
        let sim = found.first { $0.kind == .simulator }!
        XCTAssertEqual(sim.processCount, 3, "everything under launchd_sim is the simulator")
        XCTAssertEqual(sim.handle, Self.udid)
        XCTAssertEqual(sim.upSeconds, 16 * 3600)
        XCTAssertEqual(found.first { $0.kind == .emulator }?.handle, "emulator-5556")
        let gradle = found.first { $0.kind == .buildDaemon }!
        XCTAssertEqual(gradle.processCount, 2, "the Kotlin daemon is Gradle's child, not a second row")
        XCTAssertEqual(gradle.rssBytes, UInt64(1400000 + 2300000) * 1024)
        XCTAssertEqual(found.count, 3, "a shell that only quotes the daemon's class name is not a daemon")
        XCTAssertFalse(gradle.working)
        // The same daemon in the middle of a build: 180% of one core is 18% of this 10-core machine.
        let building = ProcTable(devTable.all.map { var p = $0; if p.pid == 701 { p.cpu = 180 }; return p })
        let busy = Runtimes.detect(table: building, cores: 10, now: devNow, simulatorName: { _ in nil }).first { $0.kind == .buildDaemon }!
        XCTAssertTrue(busy.working)
        let offered = Suggestions.build(system: .empty, sessions: [], apps: [], table: building, sessionPids: [], runtimes: [busy], cores: 10, now: devNow)
        XCTAssertEqual(offered.first { $0.kind == .runtime }?.stillWorking, true, "the plan row has to say it is building")
    }

    // Before `exec`, the command line was cut at its first space: every simulator process
    // was one row called "iOS", and its ✕ would have signalled all of them at once.
    func testProcessesAreNamedByExecutableEvenWithSpacesInThePath() throws {
        let t = devTable
        let runtimes = Runtimes.detect(table: t, cores: 10, now: devNow, simulatorName: { _ in nil })
        let taken = Set(runtimes.flatMap { $0.members.map(\.pid) })
        let dir = try sessionsDir([["pid": 600, "name": "work", "cwd": "/p", "status": "idle", "procStart": "Sun Nov 22 11:20:22 2026"]])
        let sessions = ClaudeSessions.load(dir: dir, table: t, excluding: taken)
        let all = Consumers.build(table: t, sessions: sessions, runtimes: runtimes, cores: 10)
        XCTAssertEqual(Set(all.map(\.name)), ["work", "helper daemon", "Gradle 8.11.1", "Pixel_8 emulator", "DCCFDB8E simulator"])
        XCTAssertEqual(all.filter { $0.kind == .app }.count, 0, "an .app in the arguments or inside a simulator is not an app on this Mac")
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.rssBytes, UInt64(204800 + 100000 + 3000) * 1024, "the emulator the session started is its own row")
        XCTAssertEqual(all.first { $0.kind == .runtime && $0.name.hasSuffix("emulator") }?.members.map(\.pid), [601])
    }

    func testRuntimeShutdownUsesItsOwnToolAndFallsBackToASignal() {
        let found = Runtimes.detect(table: devTable, cores: 10, now: devNow, simulatorName: { _ in nil })
        let sim = found.first { $0.kind == .simulator }!, emu = found.first { $0.kind == .emulator }!
        XCTAssertEqual(Runtimes.shutdown(for: sim), .command(path: "/usr/bin/xcrun", args: ["simctl", "shutdown", Self.udid]))
        XCTAssertEqual(Runtimes.shutdown(for: emu, fileExists: { _ in true }),
                       .command(path: "/Users/me/Library/Android/sdk/platform-tools/adb", args: ["-s", "emulator-5556", "emu", "kill"]))
        XCTAssertEqual(Runtimes.shutdown(for: emu, fileExists: { _ in false }), .signal)
        XCTAssertEqual(Runtimes.shutdown(for: found.first { $0.kind == .buildDaemon }!), .signal)
    }

    func testRuntimesAndWorkingSessionsAreOfferedButNeverTicked() throws {
        let t = devTable
        let runtimes = Runtimes.detect(table: t, cores: 10, now: devNow, simulatorName: { _ in nil })
        let taken = Set(runtimes.flatMap { $0.members.map(\.pid) })
        let idleSince = devNow.addingTimeInterval(-20 * 3600).timeIntervalSince1970 * 1000
        let dir = try sessionsDir([["pid": 600, "name": "work", "cwd": "/p", "status": "idle",
                                    "procStart": "Sun Nov 22 11:20:22 2026", "statusUpdatedAt": idleSince]])
        let sessions = ClaudeSessions.load(dir: dir, table: t, excluding: taken)
        let out = Suggestions.build(system: .empty, sessions: sessions, apps: [], table: t, sessionPids: taken.union([600, 602]),
                                    runtimes: runtimes, cores: 10, now: devNow)
        // The emulator started 76 minutes ago, the simulator 16 hours ago, Gradle under 4 hours ago.
        XCTAssertEqual(out.filter { $0.kind == .runtime }.count, 3)
        let young = Runtimes.detect(table: t, cores: 10, now: devNow.addingTimeInterval(-3600), simulatorName: { _ in nil })
        let early = Suggestions.build(system: .empty, sessions: [], apps: [], table: t, sessionPids: [], runtimes: young, cores: 10, now: devNow)
        XCTAssertEqual(early.filter { $0.kind == .runtime }.map(\.title).sorted(), ["DCCFDB8E simulator", "Gradle 8.11.1"], "under an hour old is not offered")

        let settings = Settings()
        XCTAssertTrue(out.filter { $0.kind == .runtime }.allSatisfy { !settings.preselects($0) })
        let session = try XCTUnwrap(out.first { $0.kind == .idleSession })
        XCTAssertTrue(session.stillWorking)
        XCTAssertEqual(session.busyChild, "python3")
        XCTAssertFalse(settings.preselects(session), "idle for 20 hours, but its script holds 80% of a core")
        var quiet = session; quiet.stillWorking = false
        XCTAssertTrue(settings.preselects(quiet))

        var snap = Snapshot(system: .empty, sessions: sessions, apps: [], topCPU: [], topMemory: [], suggestions: out)
        XCTAssertEqual(Insights.headline(snap), "“work” says idle, but its python3 is still working.")
        snap.sessions = []
        XCTAssertEqual(Insights.headline(snap), "3 simulators, emulators and build daemons hold 8.8 GB, open up to 16 hours.")
        snap.suggestions = []
        XCTAssertNil(Insights.headline(snap))
    }

    // A build daemon has no tool of its own: its tree gets SIGTERM, under the same guards.
    func testClosingABuildDaemonSignalsItsTreeAndRefusesProtectedOrChanged() throws {
        let (a, aStart) = try spawnSleep()
        let (b, bStart) = try spawnSleep()
        let root = ProcRef(pid: a.processIdentifier, lstart: aStart)
        let daemon = DevRuntime(kind: .buildDaemon, name: "Gradle 8.11.1", handle: "", rssBytes: 0, cpuPercent: 0, processCount: 2,
                                upSeconds: 7200, root: root, rootExec: "/bin/sleep",
                                members: [root, ProcRef(pid: b.processIdentifier, lstart: bStart)])
        var guarded = Settings(); guarded.neverTouch = ["gradle"]
        XCTAssertFalse(Actions.close(daemon, settings: guarded))
        var reused = daemon; reused.root.lstart = "Sun Nov 1 09:00:00 2026"
        XCTAssertFalse(Actions.close(reused, settings: Settings()), "the root pid now belongs to another process")
        XCTAssertTrue(a.isRunning && b.isRunning)
        XCTAssertTrue(Actions.close(daemon, settings: Settings()))
        a.waitUntilExit(); b.waitUntilExit()
        XCTAssertEqual(b.terminationReason, .uncaughtSignal)
    }

    // Boots a throwaway simulator, finds it in the real process table and shuts it down
    // through the same call the panel makes. Slow and heavy, so only when asked:
    //   PULSE_SIM_TEST=1 swift test --filter testShutsDownARealSimulator
    func testShutsDownARealSimulator() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PULSE_SIM_TEST"] == "1", "set PULSE_SIM_TEST=1")
        func simctl(_ args: String...) -> String {
            let p = Process(); let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); p.arguments = ["simctl"] + args
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let udid = simctl("create", "pulse-throwaway", "iPhone 17")
        XCTAssertEqual(udid.count, 36, "simctl create: \(udid)")
        addTeardownBlock { _ = simctl("shutdown", udid); _ = simctl("delete", udid) }
        _ = simctl("boot", udid)
        var mine: DevRuntime?
        for _ in 0..<40 where mine == nil {
            mine = Runtimes.detect(table: ProcTable.live()).first { $0.handle == udid }
            if mine == nil { usleep(500_000) }
        }
        let runtime = try XCTUnwrap(mine, "the booted simulator was not found in the process table")
        XCTAssertEqual(runtime.name, "pulse-throwaway simulator")
        XCTAssertTrue(Actions.close(runtime, settings: Settings()))
        XCTAssertNil(Runtimes.detect(table: ProcTable.live()).first { $0.handle == udid }, "still running after shutdown")
    }
}
