import XCTest
@testable import PulseCore

/// A session that asked something and stands still until it is answered.
final class WaitingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func dir(_ records: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for r in records { try JSONSerialization.data(withJSONObject: r).write(to: dir.appendingPathComponent("\(r["pid"]!).json")) }
        return dir
    }

    let table = ProcTable.parse("""
      90      1 204800   1.5 Sun Nov 22 11:00:00 2026 /Applications/Term.app/Contents/MacOS/Term
      91     90  20480   0.0 Sun Nov 22 11:00:01 2026 -zsh
      100    91 204800  50.0 Sun Nov 22 11:20:22 2026 claude
      101     1 204800   1.5 Sun Nov 22 11:20:22 2026 claude
      102     1 102400   1.5 Sun Nov 22 11:20:22 2026 claude
    """)

    func record(_ pid: Int, _ status: String, _ waits: String? = nil) -> [String: Any] {
        var r: [String: Any] = ["pid": pid, "name": "s\(pid)", "cwd": "/p", "status": status, "procStart": "Sun Nov 22 11:20:22 2026",
                                "statusUpdatedAt": (t0.timeIntervalSince1970 - 90_000) * 1000]
        r["waitingFor"] = waits
        return r
    }

    func testWaitingComesFirstIsNotIdleAndIsNeverOfferedForClosing() throws {
        let d = try dir([record(100, "busy"), record(101, "idle"), record(102, "waiting", "permission prompt")])
        let s = ClaudeSessions.load(dir: d, table: table)
        XCTAssertEqual(s.map(\.pid), [102, 100, 101])
        XCTAssertTrue(s[0].isWaiting); XCTAssertFalse(s[0].isIdle)
        XCTAssertEqual(s[0].waitingText, "Needs input: permission")
        XCTAssertEqual(s[1].hosts, ["/Applications/Term.app"], "the app it runs in, through the shell between them")
        let out = Suggestions.build(system: .empty, sessions: s, apps: [], table: table, sessionPids: [], now: t0)
        XCTAssertEqual(out.map(\.pid), [101], "idle for a day is offered; waiting for a day is not")
        XCTAssertFalse(Actions.closeIdleSession(pid: 102, dir: d))
    }

    // Pid 102 above does not exist, so refusing it proves little. This one is alive.
    func testARealWaitingProcessIsNotClosed() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        addTeardownBlock { child.terminate() }
        let start = try XCTUnwrap(ProcTable.live().byPid[child.processIdentifier]?.lstart)
        let d = try dir([["pid": Int(child.processIdentifier), "status": "waiting", "waitingFor": "input needed", "procStart": start]])
        XCTAssertFalse(Actions.closeIdleSession(pid: child.processIdentifier, dir: d))
        usleep(100_000)
        XCTAssertTrue(child.isRunning)
    }

    func testUnknownWordsSayOnlyThatItWaitsOrWorks() throws {
        let s = ClaudeSessions.load(dir: try dir([record(100, "waiting", "telepathy"), record(101, "thinking"), record(102, "waiting")]), table: table)
        XCTAssertEqual(s.first { $0.pid == 100 }?.waitingText, "Needs input")
        XCTAssertEqual(s.first { $0.pid == 101 }?.stateWord, "Status unknown", "a new word is not called work")
        XCTAssertEqual(s.first { $0.pid == 101 }?.isIdle, false, "and is never idle: idle rows can be closed")
        XCTAssertEqual(s.first { $0.pid == 102 }?.waitingText, "Needs input")
        let odd = try XCTUnwrap(s.first { $0.pid == 101 })
        XCTAssertNil(odd.waitingText)
        XCTAssertFalse(odd.isIdle, "a status nobody has seen is work, not idleness")
    }

    func testHeadlineNamesTheOneThatWaits() throws {
        let s = ClaudeSessions.load(dir: try dir([record(100, "waiting"), record(101, "idle"), record(102, "waiting")]), table: table)
        var snap = Snapshot(system: .empty, sessions: s, apps: [], topCPU: [], topMemory: [], suggestions: [])
        XCTAssertEqual(Insights.headline(snap), "2 sessions wait for you.")
        snap.sessions.removeAll { $0.pid == 100 }
        XCTAssertEqual(Insights.headline(snap), "“s102” waits for you.")
    }

    func testOneAlertPerWaitAfterThirtySeconds() {
        var engine = AlertEngine()
        func session(_ status: String) -> ClaudeSession {
            ClaudeSession(pid: 7, sessionId: "a", name: "Checkout", cwd: "/p", status: status, entrypoint: "cli", procStart: "", statusSince: nil,
                          rssBytes: 0, cpu: 0, processCount: 1, waitingFor: "input needed")
        }
        func at(_ s: Double, _ status: String, _ settings: Settings = Settings()) -> [String] {
            engine.evaluate(system: .empty, consumers: [], sessions: [session(status)], settings: settings, now: t0 + s).map(\.key)
        }
        XCTAssertEqual(at(0, "waiting"), [])
        XCTAssertEqual(at(29, "waiting"), [])
        XCTAssertEqual(at(31, "waiting"), ["wait:7"])
        XCTAssertEqual(at(35, "waiting"), [])
        XCTAssertEqual(at(31 + 600, "waiting"), [])
        XCTAssertEqual(at(31 + 2400, "waiting"), [], "past the half hour too: one wait, one alert")
        XCTAssertEqual(at(2500, "busy"), [])
        XCTAssertEqual(at(2510, "waiting"), [])
        XCTAssertEqual(at(2541, "waiting"), ["wait:7"], "answered and waiting again, inside the half hour")
        var off = Settings(); off.alertWaiting = false
        XCTAssertEqual(at(2600, "busy"), []); _ = at(2610, "waiting", off)
        XCTAssertEqual(at(2700, "waiting", off), [])
    }

    func testTheSettingLoadsAndStaysOffForSomeoneWithoutAlerts() throws {
        var s = Settings(); s.alertWaiting = false
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)), s)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).alertWaiting)
        let none = #"{"alertCPU":false,"alertTemp":false,"alertMemory":false,"alertHealth":false}"#
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(none.utf8)).alertWaiting)
    }
}
