import XCTest
@testable import PulseCore

/// Assertions have the shapes macOS 26 returned; the names are made up.
final class AwakeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let table = ProcTable.parse("""
      50     1 1000 0 Sun Nov 22 11:00:00 2026 /Applications/Player.app/Contents/MacOS/Player
      51     1 1000 0 Sun Nov 22 11:00:00 2026 /Applications/Chat.app/Contents/Frameworks/Chat Helper.app/Contents/MacOS/Chat Helper
      60     1 1000 0 Sun Nov 22 11:00:00 2026 claude
      61    60 1000 0 Sun Nov 22 11:00:00 2026 /bin/zsh -c x
      62    61 1000 0 Sun Nov 22 11:00:00 2026 /usr/bin/caffeinate -i
      63     1 1000 0 Sun Nov 22 11:00:00 2026 /usr/bin/caffeinate -i
      64    65 1000 0 Sun Nov 22 11:00:00 2026 /usr/bin/caffeinate -i
      65    66 1000 0 Sun Nov 22 11:00:00 2026 -zsh
      66     1 1000 0 Sun Nov 22 11:00:00 2026 /Applications/Term.app/Contents/MacOS/Term
      70     1 1000 0 Sun Nov 22 11:00:00 2026 /usr/sbin/coreaudiod
    """)

    func a(_ process: String, _ type: String = "PreventUserIdleSystemSleep", as old: String? = nil, for pid: Int? = nil, name: String = "x", hours: Double = 1, level: Int = 255) -> [String: Any] {
        var d: [String: Any] = ["Process Name": process, "AssertionTrueType": type, "AssertType": old ?? type, "AssertName": name,
                                "AssertStartWhen": t0.addingTimeInterval(-hours * 3600), "AssertLevel": NSNumber(value: level)]
        d["AssertionOnBehalfOfPID"] = pid.map { NSNumber(value: $0) }
        if process == "coreaudiod" { d["ResourcesUsed"] = ["audio-out"] }
        return d
    }

    func read(_ all: [Int32: [[String: Any]]]) -> [AwakeHolder] {
        let s = ClaudeSession(pid: 60, sessionId: "", name: "Checkout", cwd: "/p", status: "busy", entrypoint: "", procStart: "", statusSince: nil, rssBytes: 0, cpu: 0, processCount: 1)
        return Awake.holders(all, table: table, sessions: [s], runtimes: [])
    }

    func testOnlyWhatKeepsTheWholeMacAwake() {
        XCTAssertEqual(read([
            418: [a("WindowServer", "UserIsActive")],
            358: [a("powerd"), a("powerd", "ExternalMedia")],
            171: [a("runningboardd")],
            300: [a("mds_stores", "BackgroundTask"), a("x", "PreventUserIdleDisplaySleep"), a("x", "ExternalMedia")],
            51: [a("Chat", level: 0)],
        ]), [])
        XCTAssertEqual(read([50: [a("Player", "PreventSystemSleep")]]).map(\.name), ["Player"])
    }

    func testTheOldNameOfATypeStillCountsAndTheTrueOneDecides() {
        XCTAssertEqual(read([51: [a("Chat", as: "NoIdleSleepAssertion", name: "Electron")]]).map(\.name), ["Chat"])
        var bare = a("Chat", as: "NoIdleSleepAssertion"); bare["AssertionTrueType"] = nil
        XCTAssertEqual(read([51: [bare]]).map(\.name), ["Chat"], "where only the old name is given")
        XCTAssertEqual(read([51: [a("Chat", "PreventUserIdleDisplaySleep", as: "PreventUserIdleSystemSleep")]]), [])
        XCTAssertEqual(read([51: [a("Chat", name: "Electron")]]).first?.reason, "asks to stay awake")
    }

    func testTheAudioDaemonNamesWhoeverPlays() {
        let r = read([70: [a("coreaudiod", for: 50, name: "com.apple.audio.x"), a("coreaudiod", for: 51, name: "com.apple.audio.y", hours: 5)]])
        XCTAssertEqual(r.map(\.name), ["Chat", "Player"], "the longest first")
        XCTAssertEqual(r.map(\.kind), [.app, .app])
        XCTAssertEqual(r.map(\.reason), ["audio", "audio"])
        XCTAssertEqual(r[0].pids, [70], "the pid pmset shows")
    }

    func testCaffeinateReadsAsWhatStartedIt() {
        let r = read([62: [a("caffeinate", hours: 3)], 63: [a("caffeinate", hours: 2)], 64: [a("caffeinate", hours: 1)]])
        XCTAssertEqual(r.map(\.name), ["Checkout", "caffeinate", "Term"])
        XCTAssertEqual(r.map(\.kind), [.session, .process, .app])
        XCTAssertEqual(r[0].reason, "caffeinate")
    }

    func testOneRowPerNameWithTheOldestTime() {
        let r = read([50: [a("Player", name: "new", hours: 1), a("Player", name: "old", hours: 9)]])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].since, t0.addingTimeInterval(-9 * 3600))
        XCTAssertEqual(r[0].reason, "old")
    }

    func testThisMacAnswers() {
        XCTAssertNotNil(Awake.read(table: ProcTable([]), sessions: [], runtimes: []))
    }

    // MARK: What sleep cost

    let h = 3600.0
    func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
    func bat(_ p: Double) -> Charge { Charge(percent: p, onBattery: true) }
    func ac(_ p: Double) -> Charge { Charge(percent: p, onBattery: false) }

    func testADarkWakeDoesNotSplitASleep() {
        var c = SleepCost()
        XCTAssertFalse(c.fullWake(bat(90), darkWakes: 10, at: at(-1)), "nothing slept yet; this only reads the count")
        c.willSleep(bat(80), at: at(0))
        c.willSleep(bat(78), at: at(2))   // between them a dark wake, which says nothing
        XCTAssertTrue(c.fullWake(bat(76), darkWakes: 13, at: at(8)))
        XCTAssertFalse(c.fullWake(bat(76), darkWakes: 13, at: at(8.1)), "the second message of one wake")
        XCTAssertEqual(c.sleeps, [SleepRecord(from: at(0), to: at(8), lost: 4, darkWakes: 3)])
    }

    func testOnPowerThereIsNoLoss() {
        func lost(_ a: Charge?, _ b: Charge?) -> Double? {
            var c = SleepCost(); c.willSleep(a, at: at(0)); _ = c.fullWake(b, darkWakes: nil, at: at(8)); return c.sleeps[0].lost
        }
        XCTAssertEqual(lost(bat(80), bat(70)), 10)
        XCTAssertNil(lost(ac(80), ac(79)))
        XCTAssertNil(lost(bat(80), ac(70)))
        XCTAssertNil(lost(ac(80), bat(70)))
        XCTAssertNil(lost(bat(50), bat(90)), "charged on the way")
        XCTAssertNil(lost(nil, nil), "no battery")
    }

    func testACountFromAfterARestartIsNotANumber() {
        var c = SleepCost()
        _ = c.fullWake(nil, darkWakes: 200, at: at(-1))
        c.willSleep(nil, at: at(0))
        _ = c.fullWake(nil, darkWakes: 2, at: at(8))
        XCTAssertNil(c.sleeps[0].darkWakes)
        XCTAssertEqual(SleepCost.darkWakes("Sleep Count:220\nDark Wake Count:216\nUser Wake Count:12\n"), 216)
        XCTAssertNil(SleepCost.darkWakes("nothing"))
    }

    func testTheLastSleepIsTheNightAndNotTheNapAfterIt() throws {
        var c = SleepCost()
        for (a, b) in [(0.0, 8.0), (9.0, 9.1)] { c.willSleep(bat(50), at: at(a)); _ = c.fullWake(bat(49), darkWakes: 1, at: at(b)) }
        XCTAssertEqual(c.last(now: at(10))?.from, at(0))
        XCTAssertNil(c.last(now: at(60)), "last week is not the last sleep")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-sleep-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        c.save(to: url)
        XCTAssertEqual(SleepCost.load(from: url).sleeps, c.sleeps)
        XCTAssertEqual(SleepCost.load(from: url.appendingPathExtension("none")), SleepCost())
    }

    func testChargeOfABatteryAndOfNone() {
        let d: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 45, "Max Capacity": 90, "Power Source State": "Battery Power"]
        XCTAssertEqual(Charge.parse(d), bat(50))
        XCTAssertEqual(Charge.parse(d.merging(["Power Source State": "AC Power"]) { $1 })?.onBattery, false)
        XCTAssertNil(Charge.parse(d.merging(["Type": "UPS"]) { $1 }))
        XCTAssertNil(Charge.parse([:]))
    }

    func testHealthOnlyMindsWhatCosts() {
        let held = [AwakeHolder(name: "Player", kind: .app, reason: "audio", since: t0.addingTimeInterval(-2 * h), pids: [50])]
        let fresh = [AwakeHolder(name: "Player", kind: .app, reason: "audio", since: t0.addingTimeInterval(-0.5 * h), pids: [50])]
        func states(_ holders: [AwakeHolder]?, _ c: Charge?, _ cost: SleepCost = SleepCost()) -> [HealthState] {
            HealthRules.sleep(holders: holders, charge: c, cost: cost, now: t0).map(\.state)
        }
        XCTAssertEqual(states(held, bat(50)), [.attention])
        XCTAssertEqual(states(fresh, bat(50)), [.ok])
        XCTAssertEqual(states(held, ac(50)), [.ok])
        XCTAssertEqual(states(held, nil), [.ok])
        XCTAssertEqual(states(nil, nil), [.unknown])
        func slept(_ hours: Double, _ lost: Double, ago: Double = 1) -> SleepCost {
            var c = SleepCost()
            c.willSleep(bat(90), at: at(-ago - hours)); _ = c.fullWake(bat(90 - lost), darkWakes: nil, at: at(-ago)); return c
        }
        XCTAssertEqual(states([], ac(50), slept(8, 12)), [.ok, .attention])
        XCTAssertEqual(states([], ac(50), slept(8, 10)), [.ok])
        XCTAssertEqual(states([], ac(50), slept(3.9, 20)), [.ok])
        XCTAssertEqual(states([], ac(50), slept(8, 30, ago: 80)), [.ok], "over three days ago")
    }
}
