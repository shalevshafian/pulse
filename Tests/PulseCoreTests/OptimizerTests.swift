import XCTest
@testable import PulseCore

final class OptimizerTests: XCTestCase {
    static let gb: UInt64 = 1 << 30
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A 32 GB Mac. `ratio` is the share of non-wired memory the compressor does not hold.
    func vm(ratio: Double, swapins: UInt64 = 0, swapouts: UInt64 = 0) -> VMReading {
        let available = 28 * Self.gb
        let compressor = UInt64(Double(available) * (1 - ratio))
        let rest = available - compressor
        return VMReading(active: rest / 2, inactive: rest / 4, free: rest - rest / 2 - rest / 4, compressor: compressor, stored: compressor * 3,
                         swapins: swapins, swapouts: swapouts, total: 32 * Self.gb)
    }

    // MARK: Pressure

    func testUsedMemoryAloneIsCalm() {
        // 3 GB of swap and 90% used, but the compressor holds little: the state of this Mac at rest.
        var t = PressureTracker()
        for i in 0..<60 { t.add(vm(ratio: 0.95), level: 1, at: Double(i * 2)) }
        XCTAssertEqual(t.state, .calm)
        XCTAssertEqual(PressureTracker.target(t.last, state: t.state), 0)
    }

    func testWarningMustLastTenSecondsAndLeavesSlowly() {
        var t = PressureTracker()
        t.add(vm(ratio: 0.45), level: 2, at: 0)
        XCTAssertLessThan(t.state, .strained, "one reading is not a state")
        for i in 1...6 { t.add(vm(ratio: 0.45), level: 2, at: Double(i * 2)) }
        XCTAssertEqual(t.state, .strained)
        // Back to normal: two minutes before it says so.
        for i in 7...60 { t.add(vm(ratio: 0.66), level: 1, at: Double(i * 2)) }
        XCTAssertEqual(t.state, .strained)
        for i in 61...140 { t.add(vm(ratio: 0.66), level: 1, at: Double(i * 2)) }
        XCTAssertEqual(t.state, .tight, "0.66 is above the line to leave strained, below the line to leave tight")
        for i in 141...260 { t.add(vm(ratio: 0.8), level: 1, at: Double(i * 2)) }
        XCTAssertEqual(t.state, .calm)
    }

    func testThrashingIsStrainedWithoutTheWarning() {
        var t = PressureTracker()
        let page = UInt64(sysconf(_SC_PAGESIZE))
        var ins: UInt64 = 0, outs: UInt64 = 0
        for i in 0..<60 {
            // About 300 MB a minute in and out of a 32 GB Mac whose active memory is 6 GB: far over 0.2% of it.
            ins += 5 * (1 << 20) * 2 / page; outs += 5 * (1 << 20) * 2 / page
            t.add(vm(ratio: 0.8, swapins: ins, swapouts: outs), level: 1, at: Double(i * 2))
        }
        XCTAssertEqual(t.state, .strained)
        XCTAssertGreaterThan(PressureTracker.target(t.last, state: t.state, swapinRate: t.swapinRate), 0)
    }

    func testASleepForgetsTheRates() {
        var t = PressureTracker()
        let page = UInt64(sysconf(_SC_PAGESIZE))
        t.add(vm(ratio: 0.8), level: 1, at: 0)
        t.add(vm(ratio: 0.8, swapins: 10_000_000 / page * 100, swapouts: 1), level: 1, at: 2)
        XCTAssertGreaterThan(t.swapinRate, 0)
        t.add(vm(ratio: 0.8, swapins: 10_000_000 / page * 200, swapouts: 2), level: 1, at: 4000)
        XCTAssertEqual(t.swapinRate, 0)
    }

    func testTargetBringsTheRatioBackWithRoom() {
        let r = vm(ratio: 0.45)
        let target = PressureTracker.target(r, state: .strained)
        let after = Double(r.compressor - target) / Double(r.available)
        XCTAssertEqual(after, 0.38, accuracy: 0.001)
        XCTAssertEqual(PressureTracker.target(r, state: .tight), 0, "tight is watched, not acted on")
    }

    func testForecastNeedsASteadyRiseAndIgnoresOneJump() {
        let r = vm(ratio: 0.62)
        let base = Double(r.compressor)
        let rising: [(at: TimeInterval, bytes: Double)] = (0..<12).map { i in
            let step = Double(11 - i) * 400e6
            return (Double(i) * 300, base - step)
        }
        XCTAssertNotNil(PressureTracker.forecast(rising, now: r))
        var jump: [(at: TimeInterval, bytes: Double)] = (0..<12).map { i in (Double(i) * 300, base) }
        jump[11].bytes += 4e9
        XCTAssertNil(PressureTracker.forecast(jump, now: r), "Theil-Sen: one jump is no trend")
    }

    // MARK: Returns

    func testPriorSaysAnOldPauseIsLessLikelyToEnd() {
        let r = Returns()
        let hour = r.comeBack("app:A", kind: .app, idle: 3600, horizon: Optimizer.horizon).p
        let day = r.comeBack("app:A", kind: .app, idle: 86400, horizon: Optimizer.horizon).p
        XCTAssertGreaterThan(hour, day)
        XCTAssertEqual(hour, 0.6, accuracy: 0.15, "the prior is what was set for an app idle an hour")
    }

    func testAHabitMovesTheChanceFromThePrior() {
        var r = Returns()
        // Used every three hours, ten times: a pause of three hours always ends.
        r.used("app:Mail", now: now)
        for _ in 0..<10 {
            r.clock += 3 * 3600
            r.used("app:Mail", now: now)
        }
        let learned = r.comeBack("app:Mail", kind: .app, idle: 2 * 3600, horizon: 4 * 3600)
        let typical = Returns().comeBack("app:Mail", kind: .app, idle: 2 * 3600, horizon: 4 * 3600)
        XCTAssertGreaterThan(learned.p, typical.p)
        XCTAssertGreaterThanOrEqual(learned.seen, 9)

        // Never back within a day: the chance falls below the prior.
        var q = Returns()
        q.used("app:Old", now: now)
        for _ in 0..<10 { q.clock += 30 * 3600; q.used("app:Old", now: now) }
        XCTAssertLessThan(q.comeBack("app:Old", kind: .app, idle: 2 * 3600, horizon: 4 * 3600).p, typical.p)
    }

    func testTheClockStandsStillInSleep() {
        var r = Returns()
        r.tick(uptime: 100); r.tick(uptime: 160)
        XCTAssertEqual(r.clock, 60)
        r.tick(uptime: 9000)
        XCTAssertEqual(r.clock, 60, "a gap is sleep or Pulse not running")
    }

    func testOldHabitsFade() {
        var r = Returns()
        r.used("k", now: now)
        for _ in 0..<8 { r.clock += 3600; r.used("k", now: now) }
        let fresh = r.habits["k"]!.pauses
        r.clock += 3600
        r.used("k", now: now.addingTimeInterval(28 * 86400))
        XCTAssertEqual(r.habits["k"]!.pauses, fresh / 4 + 1, accuracy: 0.01, "two half lives, then the new pause")
    }

    // MARK: Taste

    func testChoicesMoveTheCostWithinBounds() {
        var t = Taste()
        XCTAssertEqual(t.factor(key: "app:X", kind: .app, now: now), 1, accuracy: 1e-9)
        for _ in 0..<50 { t.learn(.unticked, key: "app:X", kind: .app, now: now) }
        XCTAssertEqual(t.factor(key: "app:X", kind: .app, now: now), 2, "bounded: it never makes a row untouchable")
        for _ in 0..<200 { t.learn(.ticked, key: "app:Y", kind: .simulator, now: now) }
        XCTAssertEqual(t.factor(key: "app:Y", kind: .simulator, now: now), 0.5)
        // The kind speaks for a name not seen yet, worth at most four choices.
        var u = Taste()
        u.learn(.ticked, key: "a", kind: .emulator, now: now)
        XCTAssertLessThan(u.factor(key: "b", kind: .emulator, now: now), 1)
        XCTAssertGreaterThan(u.factor(key: "b", kind: .emulator, now: now), 0.5)
    }

    // MARK: Selection

    func testCoverTakesTheCheapestSetThatReaches() {
        let items: [(relief: UInt64, cost: Double, id: String)] = [
            (4 * Self.gb, 10, "big"), (2 * Self.gb, 2, "a"), (2 * Self.gb, 2, "b"), (1 * Self.gb, 0.5, "c"),
        ]
        XCTAssertEqual(Set(Optimizer.cover(items, target: 4 * Self.gb).map { items[$0].id }), ["a", "b"])
        XCTAssertEqual(Optimizer.cover(items, target: 0), [])
        XCTAssertEqual(Optimizer.cover(items, target: 100 * Self.gb).count, 4, "short of the target: everything there is")
        // The order rows come in changes nothing.
        let shuffled = [items[2], items[0], items[3], items[1]]
        XCTAssertEqual(Set(Optimizer.cover(shuffled, target: 4 * Self.gb).map { shuffled[$0].id }), ["a", "b"])
        // Equal cost: the fewer rows.
        // The pair comes first in the pass, so only the rule can make the single row win.
        let ties: [(relief: UInt64, cost: Double, id: String)] = [(1 * Self.gb, 1, "a"), (1 * Self.gb, 1, "b"), (2 * Self.gb, 2, "z")]
        XCTAssertEqual(Optimizer.cover(ties, target: 2 * Self.gb).map { ties[$0].id }, ["z"])
    }

    func candidate(_ id: String, _ kind: CandidateKind, gb: UInt64, idle: Double, guards: [Guard] = []) -> Candidate {
        Candidate(id: id, key: "\(kind.rawValue):\(id)", kind: kind, title: id, footprint: gb * Self.gb, compressed: 0, idleHint: idle, guards: guards)
    }

    func testCalmSuggestsNothingAndSaysSo() {
        let v = Optimizer.decide(.init(candidates: [candidate("Sim", .simulator, gb: 6, idle: 86400)], vm: vm(ratio: 0.95), state: .calm,
                                       memUsed: 30 * Self.gb, now: now))
        XCTAssertEqual(v.advice, .nothing)
        XCTAssertEqual(v.title, "Nothing to do")
        XCTAssertTrue(v.suggested.isEmpty)
        XCTAssertTrue(v.detail.contains("not short of memory"))
    }

    func testStrainedPrefersWhatIsLeastLikelyWanted() {
        let rows = [
            candidate("fresh", .app, gb: 3, idle: 600),
            candidate("old", .simulator, gb: 3, idle: 30 * 3600),
            candidate("older", .session, gb: 3, idle: 40 * 3600),
        ]
        let v = Optimizer.decide(.init(candidates: rows, vm: vm(ratio: 0.45), state: .strained, now: now, target: 2 * Self.gb))
        XCTAssertEqual(v.advice, .now)
        XCTAssertFalse(v.suggested.contains("fresh"))
        XCTAssertFalse(v.suggested.isEmpty)
        XCTAssertGreaterThanOrEqual(v.covers, 2 * Self.gb)
    }

    /// Each guard, alone, keeps a row that would otherwise be the first pick out of the set.
    func testEveryGuardWins() {
        let guards: [Guard] = [.working("swift-build"), .inFront(minutes: 2), .keepsAwake("audio"), .servesClients, .couldNotCheck("connections"), .openedAgain]
        for g in guards {
            let rows = [candidate("guarded", .leftover, gb: 8, idle: 50 * 3600, guards: [g]), candidate("other", .app, gb: 1, idle: 3600)]
            let v = Optimizer.decide(.init(candidates: rows, vm: vm(ratio: 0.3), state: .critical, now: now, target: 1 * Self.gb))
            XCTAssertFalse(v.suggested.contains("guarded"), "\(g)")
            XCTAssertTrue(v.scores.first { $0.id == "guarded" }!.reasons.last!.hasPrefix("Not suggested"), "\(g)")
        }
        var memory = OptimizerMemory()
        memory.reopened["leftover:x"] = now.addingTimeInterval(-3600)
        let v = Optimizer.decide(.init(candidates: [candidate("x", .leftover, gb: 8, idle: 50 * 3600)], vm: vm(ratio: 0.3), state: .critical,
                                       memory: memory, now: now, target: Self.gb))
        XCTAssertTrue(v.suggested.isEmpty, "opened again within a day")
    }

    func testEverythingInUseIsNoGoodOption() {
        let rows = [candidate("a", .app, gb: 4, idle: 60, guards: [.inFront(minutes: 0)])]
        let v = Optimizer.decide(.init(candidates: rows, vm: vm(ratio: 0.45), state: .strained, now: now, target: Self.gb))
        XCTAssertEqual(v.advice, .noGoodOption)
    }

    func testReasonsCarryTheNumbersUsed() {
        var c = candidate("Sim", .simulator, gb: 9, idle: 9 * 3600)
        c.compressed = 8 * Self.gb
        let v = Optimizer.decide(.init(candidates: [c], vm: vm(ratio: 0.45), state: .strained, now: now, target: Self.gb))
        let s = v.scores[0]
        XCTAssertTrue(s.reasons[0].hasPrefix("Not seen in use for 9 h."))
        XCTAssertTrue(s.reasons[1].contains("most of it compressed"))
        XCTAssertTrue(s.reasons[1].contains(Optimizer.gb(s.ramBack)))
        // Mostly compressed: what comes back to RAM is far less than what is counted.
        XCTAssertLessThan(s.ramBack, 4 * Self.gb)
    }

    func testALeftoverUsingTheCPUIsSuggestedEvenWhenCalm() {
        var c = candidate("node server.js", .leftover, gb: 0, idle: 5 * 3600)
        c.cpuPercent = 14
        let v = Optimizer.decide(.init(candidates: [c], vm: vm(ratio: 0.95), state: .calm, now: now))
        XCTAssertEqual(v.suggested, [c.id])
        c.guards = [.servesClients]
        XCTAssertTrue(Optimizer.decide(.init(candidates: [c], vm: vm(ratio: 0.95), state: .calm, now: now)).suggested.isEmpty)
    }

    // MARK: Calibration

    func testCalibrationLearnsOnlyFromACleanCase() {
        var c = Calibration()
        let o = Calibration.Outcome(at: now, kinds: ["app"], promised: 4 * Self.gb, fell: Int64(2 * Self.gb), noise: 100 << 20, stateBefore: .strained, stateAfter: .calm)
        c.record(o)
        XCTAssertEqual(c.share(of: .app), 0.74, accuracy: 0.001)
        var noisy = o; noisy.noise = 2 * Self.gb
        var mixed = o; mixed.kinds = ["app", "session"]
        var small = o; small.promised = 100 << 20
        let before = c.share(of: .app)
        for x in [noisy, mixed, small] { c.record(x) }
        XCTAssertEqual(c.share(of: .app), before)
        XCTAssertEqual(c.outcomes.count, 4)
    }

    // MARK: Readings

    func testCompressedSizesFromTop() {
        let text = """
        Processes: 900 total
        PID    CMPRS
        99986  3488K
        99510  47M+
        417    0B
        12     1.5G
        bad    1M
        """
        let m = Compressed.parse(text)
        XCTAssertEqual(m[99986], 3488 * 1024)
        XCTAssertEqual(m[99510], 47 << 20)
        XCTAssertEqual(m[417], 0)
        XCTAssertEqual(m[12], UInt64(1.5 * 1_073_741_824))
        XCTAssertEqual(m.count, 4)
    }

    func testServedIsAListenerWithAClientOnItsOwnPort() {
        let text = """
        p100
        f5
        n*:3000
        TST=LISTEN
        f6
        n127.0.0.1:3000->127.0.0.1:52100
        TST=ESTABLISHED
        p200
        f5
        n*:8080
        TST=LISTEN
        f7
        n192.168.1.4:52200->17.0.0.1:443
        TST=ESTABLISHED
        """
        XCTAssertEqual(Ports.served(text), [100], "200 only has a connection of its own going out")
    }

    func testGrowthIsOnlyWhatOnlyGrows() {
        var h = LoadHistory()
        let start = now.addingTimeInterval(-24 * 300)
        for i in 0..<24 {
            let at = start.addingTimeInterval(Double(i) * 300)
            let grow = Consumer(kind: .app, name: "Leaky", rssBytes: Self.gb + UInt64(i) * (120 << 20), cpuPercent: 0, processCount: 1)
            let saw = Consumer(kind: .app, name: "Saw", rssBytes: (i % 6 < 5 ? UInt64(i % 6) : 0) * Self.gb, cpuPercent: 0, processCount: 1)
            h.add([grow, saw], at: at)
        }
        let g = h.growing(now: now)
        XCTAssertEqual(g.map(\.name), ["Leaky"])
        XCTAssertGreaterThan(g[0].perHour, Self.gb)
    }
}
