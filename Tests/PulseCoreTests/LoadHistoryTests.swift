import XCTest
@testable import PulseCore

final class LoadHistoryTests: XCTestCase {
    // A multiple of five minutes.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let old = "Sun Nov 1 09:00:00 2026"

    func row(_ name: String, _ times: [(Int32, Double)], mb: UInt64 = 100, start: String? = nil, kind: Consumer.Kind = .app) -> Consumer {
        Consumer(kind: kind, name: name, rssBytes: mb << 20, cpuPercent: 0, processCount: times.count,
                 times: times.map { ProcTime(pid: $0.0, lstart: start ?? old, seconds: $0.1) })
    }
    func seconds(_ h: LoadHistory, _ name: String, _ now: Date) -> Double { h.rows(now: now).first { $0.name == name }?.cpuSeconds ?? 0 }

    func testThreeReadingsGiveExactSums() {
        var h = LoadHistory()
        h.add([row("Big", [(1, 1000), (2, 50)]), row("node", [(3, 7)], kind: .process)], at: t0)
        XCTAssertTrue(h.rows(now: t0).isEmpty, "what was used before Pulse looked is in no bucket")
        h.add([row("Big", [(1, 1030), (2, 60)], mb: 900), row("node", [(3, 9)], kind: .process)], at: t0 + 20)
        h.add([row("Big", [(1, 1045), (2, 60)], mb: 300), row("node", [(3, 9)], kind: .process)], at: t0 + 320)
        XCTAssertEqual(h.buckets.count, 2)
        let r = h.rows(now: t0 + 320)
        XCTAssertEqual(r.map(\.name), ["Big", "node"])
        XCTAssertEqual(r.map(\.cpuSeconds), [55, 2])
        XCTAssertEqual(r.map(\.kind), [.app, .process])
        XCTAssertEqual(r[0].peakBytes, 900 << 20)
    }

    func testAReusedPidStartsAtZero() {
        var h = LoadHistory()
        let now = StartTime.date("Sun Nov 22 12:00:00 2026")!
        h.add([row("Old", [(1, 500)])], at: now)
        // The same number, another process, born ten seconds ago.
        h.add([row("New", [(1, 530)], start: "Sun Nov 22 12:00:10 2026")], at: now + 20)
        XCTAssertEqual(seconds(h, "New", now + 20), 530, "its own time, not the difference to another process")
        // Seen now and older than the last reading: how much of it is recent is not known.
        h.add([row("New", [(1, 530)], start: "Sun Nov 22 12:00:10 2026"), row("Late", [(9, 77)])], at: now + 40)
        XCTAssertEqual(seconds(h, "Late", now + 40), 0)
        // A counter that goes back counts nothing, and takes nothing from the one beside it.
        h.add([row("Pair", [(5, 100), (6, 100)])], at: now + 45)
        h.add([row("Pair", [(5, 70), (6, 110)])], at: now + 50)
        XCTAssertEqual(seconds(h, "Pair", now + 50), 10)
        h.add([row("New", [(1, 530)], start: "Sun Nov 22 12:00:10 2026")], at: now + 55)
        h = LoadHistory()
        h.add([row("New", [(1, 0)], start: "Sun Nov 22 12:00:10 2026")], at: now + 57)
        h.add([row("New", [(1, 530)], start: "Sun Nov 22 12:00:10 2026")], at: now + 58)
        h.add([row("New", [(1, 500)], start: "Sun Nov 22 12:00:10 2026")], at: now + 60)
        XCTAssertEqual(seconds(h, "New", now + 60), 530)
    }

    func testAClockThatJumpsAddsOnlyRealWork() {
        var h = LoadHistory()
        h.add([row("Big", [(1, 100)])], at: t0)
        h.add([row("Big", [(1, 103)])], at: t0 + 8 * 3600)
        XCTAssertEqual(seconds(h, "Big", t0 + 8 * 3600), 3, "eight hours of sleep and three seconds of work")
        h.add([row("Big", [(1, 108)])], at: t0 + 2 * 3600)
        XCTAssertEqual(seconds(h, "Big", t0 + 8 * 3600), 8, "a clock set back loses nothing and counts nothing twice")
        XCTAssertEqual(h.buckets.map(\.start), h.buckets.map(\.start).sorted())
    }

    func testTwelveHoursAndNoMore() {
        var h = LoadHistory()
        for i in 0...200 { h.add([row("Big", [(1, Double(i) * 2)])], at: t0 + Double(i) * 300) }
        let now = t0 + 200 * 300
        XCTAssertEqual(h.buckets.count, LoadHistory.count)
        XCTAssertEqual(seconds(h, "Big", now), 288)
        XCTAssertEqual(h.since(now: now), now - 143 * 300)
        XCTAssertTrue(h.rows(now: now + 13 * 3600).isEmpty, "after thirteen hours of sleep nothing in it is recent")
        XCTAssertNil(h.since(now: now + 13 * 3600))
    }

    func testAFullBucketKeepsTheHeaviestEight() {
        var h = LoadHistory()
        let many: (Double) -> [Consumer] = { k in (1...20).map { self.row("P\($0)", [(Int32($0), Double($0) * k)], mb: UInt64(21 - $0)) } }
        h.add(many(0), at: t0); h.add(many(2), at: t0 + 20)
        XCTAssertEqual(h.rows(now: t0 + 20).count, 20)
        h.add(many(2), at: t0 + 300)
        XCTAssertEqual(h.rows(now: t0 + 300).map(\.name), (13...20).reversed().map { "P\($0)" })
        XCTAssertEqual(h.buckets[0].memory.count, 8)
    }

    func testSurvivesTheDiskAndADamagedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-load-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var h = LoadHistory()
        h.add([row("a:b", [(1, 0)])], at: t0); h.add([row("a:b", [(1, 60)])], at: t0 + 20)
        h.save(to: url)
        var back = LoadHistory.load(from: url, now: t0 + 60)
        XCTAssertEqual(back.rows(now: t0 + 60), h.rows(now: t0 + 60))
        XCTAssertEqual(back.rows(now: t0 + 60).first?.name, "a:b", "a colon in a name is part of it")
        back.add([row("a:b", [(1, 900)])], at: t0 + 60)
        XCTAssertEqual(seconds(back, "a:b", t0 + 60), 60, "what it did while Pulse was closed is not counted")
        XCTAssertTrue(LoadHistory.load(from: url, now: t0 + 13 * 3600).buckets.isEmpty)
        XCTAssertTrue(LoadHistory.load(from: url, now: t0 - 3600).buckets.isEmpty, "from the future")
        try Data("{broken".utf8).write(to: url)
        XCTAssertTrue(LoadHistory.load(from: url).buckets.isEmpty)
    }

    func testReadsTheTimeColumnAndThePathAfterIt() {
        let line = "Sun Nov 22 11:00:00 2026"
        let t = ProcTable.parse("1 0 1 0.0 \(line) a\n2 1 1 0.0 \(line) b\n3 1 1 0.0 \(line) c",
                                execs: "    1 1463:23.52 /System/My Tools/launchd\n  2   0:00.10 -zsh\n  3 /usr/bin/plain path")
        XCTAssertEqual(t.byPid[1]?.cpuSeconds ?? 0, 1463 * 60 + 23.52, accuracy: 0.001)
        XCTAssertEqual(t.byPid[1]?.exec, "/System/My Tools/launchd")
        XCTAssertEqual(t.byPid[2]?.cpuSeconds ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(t.byPid[2]?.exec, "-zsh")
        XCTAssertNil(t.byPid[3]?.cpuSeconds, "where ps gave no time")
        XCTAssertEqual(t.byPid[3]?.exec, "/usr/bin/plain path")
        XCTAssertEqual(ProcTable.cpuTime("2:01:02.5"), 7262.5)
        for s in ["", ":", "a:b", "12", "1:", "/x:1"] { XCTAssertNil(ProcTable.cpuTime(Substring(s)), s) }
    }

    // Every process of a row is in it once, the simulator a session started among its own.
    func testLiveRowsHoldEveryProcessOnce() {
        let table = ProcTable.live()
        XCTAssertGreaterThan(table.all.filter { $0.cpuSeconds != nil }.count, table.all.count * 9 / 10)
        let runtimes = Runtimes.detect(table: table)
        let rows = Consumers.build(table: table, sessions: [], runtimes: runtimes)
        let pids = rows.flatMap { $0.times.map(\.pid) }
        XCTAssertEqual(pids.count, Set(pids).count)
        XCTAssertEqual(pids.count, table.all.filter { $0.cpuSeconds != nil }.count)
        XCTAssertFalse(String(decoding: try! JSONEncoder().encode(rows), as: UTF8.self).contains("\"times\""), "agents are not sent it")
        // What it adds to a reading: well under a hundredth of what the reading itself takes.
        var h = LoadHistory()
        let began = Date()
        for i in 0..<10 { h.add(rows, at: t0 + Double(i) * 20) }
        XCTAssertLessThan(Date().timeIntervalSince(began) / 10, 0.05)
        print("ADD", Date().timeIntervalSince(began) / 10 * 1000, "ms for", pids.count)
    }

    // MARK: What only grows

    func grows(_ gb: [Double], minutes: Double = 5) -> Bool {
        var g = Growth(), out = false
        for (i, v) in gb.enumerated() {
            out = !g.add([Consumer(kind: .app, name: "x", rssBytes: UInt64(v * 1024) << 20, cpuPercent: 0, processCount: 1)], at: t0 + Double(i) * minutes * 60).isEmpty
        }
        return out
    }

    func testOnlySteadyGrowthAlerts() {
        let steady = (0...12).map { 4 + Double($0) * 0.4 }
        XCTAssertTrue(grows(steady), "4 to 8.8 GB in an hour")
        XCTAssertFalse(grows(Array(steady.dropLast())), "fifty-five minutes")
        var saw = (0...12).map { 4 + Double($0) * 0.5 }
        for i in [3, 7, 11] { saw[i] = 4 }
        XCTAssertFalse(grows(saw), "a saw")
        XCTAssertFalse(grows((0...12).map { 10 + Double($0) * 0.7 }), "not doubled")
        XCTAssertFalse(grows((0...12).map { 1 + Double($0) * 0.3 }), "under 4 GB")
        var dip = steady; dip[6] = dip[5] * 0.95
        XCTAssertTrue(grows(dip), "a small dip is not giving back")
        let fast = (0...12).map { pow(1.3, Double($0)) }
        XCTAssertTrue(grows(fast, minutes: 10))
        XCTAssertFalse(grows(fast, minutes: 11), "gaps: the Mac slept in between")
    }

    func testTheAlertIsOffUntilAskedForAndSaysBoth() throws {
        func run(_ s: Settings) -> [PulseAlert] {
            var e = AlertEngine(), out: [PulseAlert] = []
            for i in 0...60 {
                let c = Consumer(kind: .app, name: "Leaky", rssBytes: (4 << 30) + UInt64(i) << 27, cpuPercent: 0, processCount: 1)
                out += e.evaluate(system: .empty, consumers: [c], settings: s, now: t0 + Double(i) * 60)
            }
            return out
        }
        XCTAssertEqual(run(Settings()), [])
        var on = Settings(); on.alertGrowth = true
        XCTAssertEqual(run(on).map(\.title), ["Leaky keeps growing"])
        XCTAssertEqual(run(on).first?.body, "From 4.0 to 11.5 GB in an hour, without giving any back.")
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(on)), on)
    }
}
