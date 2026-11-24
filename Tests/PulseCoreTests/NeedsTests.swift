import IOKit.pwr_mgt
import XCTest
@testable import PulseCore

final class NeedsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func system(pressure: Int = 1, thermal: String = "nominal") -> SystemStats {
        var s = SystemStats.empty
        s.memPressureLevel = pressure; s.thermal = thermal
        return s
    }

    private func session(_ pid: Int32, _ status: String, cpu: Double = 0, name: String = "Same name") -> ClaudeSession {
        ClaudeSession(pid: pid, sessionId: "a-1", name: name, cwd: "/Users/me/x", status: status, entrypoint: "cli", procStart: "",
                      statusSince: now.addingTimeInterval(-300), rssBytes: 1 << 20, cpu: cpu, processCount: 1)
    }

    private func snap(_ s: SystemStats, sessions: [ClaudeSession] = [], top: [Consumer] = []) -> Snapshot {
        Snapshot(system: s, sessions: sessions, apps: [], topCPU: top, topMemory: top, consumers: top, suggestions: [])
    }

    private func store(_ checks: [HealthCheck], cleanup: [CleanupItem] = []) -> HealthStore {
        var h = HealthStore()
        h.report = HealthReport(takenAt: now, checks: checks, cleanup: cleanup)
        return h
    }

    private func item(_ title: String, gb: UInt64, blocked: String? = nil) -> CleanupItem {
        CleanupItem(title: title, detail: "", path: "/tmp/" + title, bytes: gb << 30, blockedBy: blocked)
    }

    func testTheCostliestComesFirst() {
        let health = store([
            .init("updates", .updates, .attention, "Update", weight: 8, fix: .softwareUpdate),
            .init("backup", .backup, .urgent, "No backup", weight: 15, fix: .timeMachine),
        ], cleanup: [item("cache", gb: 6)])
        let ids = Needs.build(snap: snap(system(pressure: 2), sessions: [session(7, "waiting")]), health: health, now: now).map(\.id)
        XCTAssertEqual(ids, ["memory", "wait:7", "health:backup", "health:updates", "cleanup"])
    }

    func testNothingIsNothing() {
        XCTAssertEqual(Needs.build(snap: snap(system(), sessions: [session(1, "busy"), session(2, "idle")]), health: store([]), now: now), [])
        XCTAssertEqual(Needs.build(snap: nil, health: HealthStore(), now: now), [])
    }

    /// A check is up to six hours old; what is read every few seconds is right.
    func testAnOldFindingDoesNotOutliveTheReading() {
        let health = store([.init("memory", .performance, .attention, "Memory is under pressure", weight: 8, fix: .plan),
                            .init("thermal", .performance, .attention, "Hot", weight: 5)])
        XCTAssertEqual(Needs.build(snap: snap(system()), health: health, now: now), [])
        XCTAssertEqual(Needs.build(snap: snap(system(pressure: 4, thermal: "serious")), health: health, now: now).map(\.id), ["memory", "heat"])
    }

    func testNotTodayIsOneDayAndNeverForWhatHappensNow() {
        let health = store([.init("updates", .updates, .attention, "Update", weight: 8)])
        func ids(_ hidden: [String: Date]) -> [String] { Needs.build(snap: snap(system(pressure: 2)), health: health, hidden: hidden, now: now).map(\.id) }
        XCTAssertEqual(ids(["health:updates": now.addingTimeInterval(-23 * 3600)]), ["memory"])
        XCTAssertEqual(ids(["health:updates": now.addingTimeInterval(-25 * 3600)]), ["memory", "health:updates"])
        XCTAssertEqual(ids(["memory": now]), ["memory", "health:updates"])
    }

    func testOnlyWhatMayBeClearedIsOffered() {
        XCTAssertEqual(Needs.build(snap: nil, health: store([], cleanup: [item("a", gb: 4), item("b", gb: 9, blocked: "Xcode")]), now: now), [])
        var settings = Settings()
        settings.neverTouch = ["keep"]
        XCTAssertEqual(Needs.build(snap: nil, health: store([], cleanup: [item("keep", gb: 9)]), settings: settings, now: now), [])
        var ignored = store([], cleanup: [item("a", gb: 9)])
        XCTAssertEqual(Needs.build(snap: nil, health: ignored, now: now).map(\.id), ["cleanup"])
        ignored.ignored = ["cleanup"]
        XCTAssertEqual(Needs.build(snap: nil, health: ignored, now: now), [])
    }

    func testThePlanSpeaksFromNinety() {
        func plan(_ p: Double) -> [PlanUsage] { [PlanUsage(tool: "Claude", readAt: now, limits: [.init(name: "week", percent: p, resetsAt: now.addingTimeInterval(9000))])] }
        XCTAssertEqual(Needs.build(snap: nil, health: HealthStore(), plan: plan(89), now: now), [])
        XCTAssertEqual(Needs.build(snap: nil, health: HealthStore(), plan: plan(90), now: now).map(\.id), ["limit:Claude"])
    }

    /// Two sessions with one name are two rows: closing one must never reach the other.
    func testTwoSessionsWithOneNameAreTwoRows() {
        let table = ProcTable([7, 8].map { ProcInfo(pid: $0, ppid: 1, rssBytes: 1, cpu: 0, lstart: "x", command: "claude") })
        let rows = Consumers.build(table: table, sessions: [session(7, "idle"), session(8, "idle")])
        XCTAssertEqual(Set(rows.map(\.id)), ["session:7", "session:8"])
    }

    // MARK: Receipts

    private func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func testPutBackOverwritesNothing() throws {
        let d = try folder(), fm = FileManager.default
        let bin = d.appendingPathComponent("bin").path, home = d.appendingPathComponent("home").path
        fm.createFile(atPath: bin, contents: Data("old".utf8))
        fm.createFile(atPath: home, contents: Data("new".utf8))
        XCTAssertFalse(Receipts.putBack(from: bin, to: home))
        XCTAssertEqual(fm.contents(atPath: home), Data("new".utf8))
        try fm.removeItem(atPath: home)
        // A link to nowhere takes the place too.
        try fm.createSymbolicLink(atPath: home, withDestinationPath: d.path + "/nowhere")
        XCTAssertFalse(Receipts.putBack(from: bin, to: home))
        try fm.removeItem(atPath: home)
        XCTAssertTrue(Receipts.putBack(from: bin, to: home))
        XCTAssertEqual(fm.contents(atPath: home), Data("old".utf8))
        XCTAssertFalse(Receipts.putBack(from: bin, to: home), "gone from the Trash")
        XCTAssertFalse(Receipts.putBack(from: home, to: d.path + "/no/such/place"))
    }

    func testReceiptsAreKeptAndCapped() throws {
        let url = try folder().appendingPathComponent("receipts.json")
        var r = Receipts()
        for i in 0..<120 { r.add(Receipt(at: now, title: "\(i)", detail: "", back: i % 2 == 0 ? .app(path: "/A.app") : .trash(from: "/a", to: "/b"))) }
        XCTAssertEqual(r.list.count, 100)
        XCTAssertEqual(r.list[0].title, "119")
        r.markUndone(r.list[3].id)
        r.save(to: url)
        XCTAssertEqual(Receipts.load(from: url), r)
        XCTAssertTrue(Receipts.load(from: url).list[3].undone)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(Receipts.load(from: url), Receipts())
    }

    func testTheResumeCommandCannotCarryAnother() {
        XCTAssertEqual(Receipts.resume(cwd: "/Users/me/my code", id: "ab-12"), "cd '/Users/me/my code' && claude --resume ab-12")
        XCTAssertEqual(Receipts.resume(cwd: "/a'; rm -rf x; '", id: "a"), "cd '/a'\\''; rm -rf x; '\\''' && claude --resume a")
        XCTAssertNil(Receipts.resume(cwd: "/a", id: "a; rm x"))
        XCTAssertNil(Receipts.resume(cwd: "/a", id: ""))
    }

    func testTrashSaysWhereItWent() throws {
        let home = try folder().resolvingSymlinksInPath().path
        let real = realpath(home, nil)!
        defer { free(real) }
        let root = String(cString: real), path = root + "/.npm/_cacache"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let i = CleanupItem(title: "npm cache", detail: "", path: path, bytes: 1, blockedBy: nil)
        XCTAssertEqual(Cleanup.trashed(i, home: root, table: ProcTable([]), settings: Settings()) { _ in URL(fileURLWithPath: "/bin-of-tests/x") }, "/bin-of-tests/x")
        let npm = ProcTable([ProcInfo(pid: 5, ppid: 1, rssBytes: 1, cpu: 0, lstart: "", command: "npm install", exec: "npm")])
        XCTAssertNil(Cleanup.trashed(i, home: root, table: npm, settings: Settings()) { _ in XCTFail("in use"); return nil })
    }

    // MARK: Ports, meters, awake

    func testPortsAreReadPerProgramAndAddress() {
        let text = "p10\ncnode\nf20\nn127.0.0.1:3000\nf21\nn[::1]:3000\nf22\nn*:8080\np11\ncMy\\x20App\nf5\nn[::]:5000\nf6\nn192.168.1.4:99\nnbroken\n"
        XCTAssertEqual(Ports.parse(text), [
            OpenPort(port: 99, program: "My App", pid: 11, network: true), OpenPort(port: 3000, program: "node", pid: 10, network: false),
            OpenPort(port: 5000, program: "My App", pid: 11, network: true), OpenPort(port: 8080, program: "node", pid: 10, network: true),
        ])
        XCTAssertEqual(Ports.parse(""), [])
    }

    func testOneAddressOnTheNetworkIsEnough() {
        XCTAssertEqual(Ports.parse("p1\ncx\nn*:80\nn127.0.0.1:80\n").map(\.network), [true])
    }

    func testTheNetworkCountsRealPortsOnceAndGoesRound() throws {
        XCTAssertTrue(NetCounts.counts("en0"))
        for n in ["utun3", "lo0", "bridge0", "awdl0", "ipsec0"] { XCTAssertFalse(NetCounts.counts(n), n) }
        let was = NetCounts(down: ["en0": UInt32.max - 99], up: ["en0": 10])
        let r = try XCTUnwrap(NetCounts(down: ["en0": 100, "en7": 5_000_000], up: ["en0": 30, "en7": 9]).rate(since: was, seconds: 2))
        XCTAssertEqual(r.down, 100)
        XCTAssertEqual(r.up, 10)
        XCTAssertNil(was.rate(since: was, seconds: 0))
    }

    func testGraphicsLoad() {
        XCTAssertEqual(GPU.percent(["Device Utilization %": 65]), 65)
        XCTAssertEqual(GPU.percent(["GPU Activity(%)": 12]), 12)
        XCTAssertEqual(GPU.percent(["Device Utilization %": 140]), 100)
        XCTAssertNil(GPU.percent([:]))
    }

    /// For real: macOS lists it under this process, and no longer after.
    func testKeepAwakeIsHeldAndLetGo() {
        func held() -> Bool {
            var ref: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess, let d = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
            return (d[NSNumber(value: getpid())] ?? []).contains { $0["AssertName"] as? String == "Kept awake from Pulse" }
        }
        let k = KeepAwake()
        XCTAssertFalse(held())
        XCTAssertTrue(k.start(60))
        XCTAssertTrue(held())
        XCTAssertTrue(k.isOn())
        XCTAssertFalse(k.isOn(now: Date().addingTimeInterval(61)))
        k.stop()
        XCTAssertFalse(held())
        XCTAssertFalse(k.isOn())
        // The system's own timeout, should Pulse hang.
        XCTAssertTrue(k.start(1))
        let end = Date().addingTimeInterval(6)
        while held(), Date() < end { usleep(100_000) }
        XCTAssertFalse(held())
        var other: KeepAwake? = KeepAwake()
        other?.start(60)
        XCTAssertTrue(held())
        other = nil
        XCTAssertFalse(held())
    }

    func testAWeakChargerDrainsWhilePluggedIn() {
        func ids(_ amps: Int64, plugged: Bool = true, charge: Int = 60) -> [String] {
            HealthRules.battery(["AppleRawMaxCapacity": 8000, "DesignCapacity": 8500, "CycleCount": 10, "ExternalConnected": plugged, "IsCharging": false,
                                 "CurrentCapacity": charge, "Amperage": NSNumber(value: UInt64(bitPattern: amps)), "AdapterDetails": ["Watts": 30]]).map(\.id)
        }
        XCTAssertTrue(ids(-900).contains("charger"))
        XCTAssertFalse(ids(-900, plugged: false).contains("charger"))
        XCTAssertFalse(ids(-120).contains("charger"))
        XCTAssertFalse(ids(0).contains("charger"))
        XCTAssertFalse(ids(-900, charge: 100).contains("charger"))
    }

    func testTheTwelveHoursOfOneRow() {
        var h = LoadHistory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ s: Double) -> [Consumer] {
            [Consumer(kind: .process, name: "x", rssBytes: 1, cpuPercent: 0, processCount: 1, times: [ProcTime(pid: 5, lstart: "a", seconds: s)])]
        }
        h.add(row(10), at: start)
        h.add(row(40), at: start.addingTimeInterval(60))
        // Two buckets of one part.
        h.add(row(42), at: start.addingTimeInterval(3600))
        h.add(row(45), at: start.addingTimeInterval(3900))
        let s = h.series("process:x", parts: 48, now: start.addingTimeInterval(3900))
        XCTAssertEqual(s.count, 48)
        XCTAssertEqual(s[47], 5)
        XCTAssertEqual(s.compactMap { $0 }.reduce(0, +), 35)
        XCTAssertNil(s[0], "not running is not idle")
        XCTAssertEqual(h.series("process:y", parts: 48, now: start.addingTimeInterval(3900))[47], 0)
    }

    func testAShortcutFromANewerVersionLosesNothing() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"shortcut":"hyperQ","neverTouch":["Docker"],"hidden":7}"#.utf8))
        XCTAssertEqual(s.shortcut, .off)
        XCTAssertEqual(s.neverTouch, ["Docker"])
        XCTAssertEqual(s.hidden, [:])
    }

    /// An agent sees the list and the ports. It is offered nothing that changes either.
    func testAgentsReadTheList() throws {
        let health = store([.init("updates", .updates, .attention, "Update", weight: 8)])
        let server = MCPServer(provider: { self.snap(self.system(), sessions: [self.session(7, "waiting")]) }, healthStore: { health }, settings: { Settings() },
                               plan: { XCTFail("not ticked"); return [] }, ports: { [OpenPort(port: 1, program: "p", pid: 2, network: true)] })
        XCTAssertTrue(try XCTUnwrap(server.call("needs_attention")).contains("wait:7"))
        XCTAssertTrue(try XCTUnwrap(server.call("open_ports")).contains("\"port\":1"))
    }
}
