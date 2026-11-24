import XCTest
@testable import PulseCore

/// Every file here is made up. The account and the keys in them must never come out.
final class PlanUsageTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-24T20:00:00Z")!
    let secrets = ["sk-fake-key-123", "someone@example.com", "11111111-2222", "FAKE-ENV-TOKEN", "a secret question"]

    func claudeFile(minutesAgo: Double = 47, limits: String) -> Data {
        Data("""
        {"oauthAccount":{"emailAddress":"someone@example.com","accountUuid":"11111111-2222"},"primaryApiKey":"sk-fake-key-123",
         "mcpServers":{"x":{"env":{"TOKEN":"FAKE-ENV-TOKEN"}}},
         "cachedUsageUtilization":{"fetchedAtMs":\((now.timeIntervalSince1970 - minutesAgo * 60) * 1000),"accountUuid":"11111111-2222",
           "utilization":{"five_hour":null,"seven_day":{"utilization":62},"limits":[\(limits)]}}}
        """.utf8)
    }
    let week = #"{"kind":"weekly_all","group":"weekly","percent":62,"severity":"normal","resets_at":"2026-11-26T17:00:00.272080+00:00","scope":null}"#
    let scoped = #"{"kind":"weekly_scoped","group":"weekly","percent":91.5,"resets_at":"2026-11-26T17:00:00+00:00","scope":{"model":{"id":null,"display_name":"Opus"},"surface":null}}"#
    let past = #"{"kind":"session","group":"session","percent":9,"resets_at":"2026-11-24T19:00:00+00:00","scope":null}"#
    let nameless = #"{"kind":"weekly_scoped","group":"weekly","percent":5,"resets_at":"2026-11-26T17:00:00+00:00","scope":{"model":null,"surface":"web"}}"#
    let odd = #"{"kind":"lunar","group":"lunar","percent":5,"resets_at":"2026-11-26T17:00:00+00:00","scope":null}"#

    func testClaudeTakesWhatHolds() {
        let p = PlanUsage.claude(claudeFile(limits: [week, scoped, past, nameless, odd].joined(separator: ",")), now: now)
        XCTAssertEqual(p?.limits.map(\.name), ["week", "Opus"])
        XCTAssertEqual(p?.limits.map(\.percent), [62, 91.5])
        XCTAssertEqual(p?.readAt, now.addingTimeInterval(-47 * 60))
    }

    func testClaudeHidesWhatIsStaleOverOrBroken() {
        XCTAssertNotNil(PlanUsage.claude(claudeFile(minutesAgo: 359, limits: week), now: now))
        XCTAssertNil(PlanUsage.claude(claudeFile(minutesAgo: 361, limits: week), now: now))
        XCTAssertNil(PlanUsage.claude(claudeFile(minutesAgo: -60, limits: week), now: now), "from the future")
        XCTAssertNil(PlanUsage.claude(claudeFile(limits: past), now: now))
        XCTAssertNil(PlanUsage.claude(claudeFile(limits: ""), now: now))
        XCTAssertNil(PlanUsage.claude(claudeFile(limits: week.replacingOccurrences(of: "percent", with: "parcent")), now: now))
        XCTAssertNil(PlanUsage.claude(claudeFile(limits: week.replacingOccurrences(of: "2026-11-26T17:00:00.272080+00:00", with: "soon")), now: now))
        XCTAssertNil(PlanUsage.claude(Data(#"{"primaryApiKey":"sk-fake-key-123"}"#.utf8), now: now), "a Mac with a key and no plan")
        XCTAssertNil(PlanUsage.claude(Data("{broken".utf8), now: now))
        XCTAssertNil(PlanUsage.claude(nil, now: now))
    }

    func line(_ minutesAgo: Double, _ primary: String, secondary: String = "null", type: String = "token_count") -> String {
        let t = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60)).replacingOccurrences(of: "Z", with: ".773Z")
        return #"{"timestamp":"\#(t)","type":"event_msg","payload":{"type":"\#(type)","info":"a secret question","rate_limits":{"primary":\#(primary),"secondary":\#(secondary),"plan_type":"pro"}}}"#
    }
    func window(_ p: Double, _ minutes: Int = 10080, resetsIn hours: Double = 48) -> String {
        #"{"used_percent":\#(p),"window_minutes":\#(minutes),"resets_at":\#(now.timeIntervalSince1970 + hours * 3600)}"#
    }

    func testCodexTakesTheLastRealReading() {
        func read(_ lines: [String]) -> PlanUsage? { PlanUsage.codex(Data(lines.joined(separator: "\n").utf8), now: now) }
        let talk = #"{"timestamp":"x","payload":{"type":"message","text":"why is \"rate_limits\" null? a secret question"}}"#
        let p = read([line(40, window(20)), line(30, window(26), secondary: window(7, 300, resetsIn: 2)), line(20, "null"), talk])
        XCTAssertEqual(p?.limits.map(\.name), ["week", "5 hours"])
        XCTAssertEqual(p?.limits.map(\.percent), [26, 7])
        XCTAssertEqual(p?.readAt, now.addingTimeInterval(-30 * 60))
        XCTAssertNil(read([line(361, window(26))]), "stale")
        XCTAssertNil(read([line(30, window(26, resetsIn: -1))]), "its week is over")
        XCTAssertNil(read([line(30, window(26), type: "message")]), "a conversation that quotes a reading is not one")
        XCTAssertNil(read([line(30, #"{"used_percent":26}"#)]))
        XCTAssertNil(read(["", "{broken \"rate_limits\""]))
    }

    func testCodexReadsOnlyTheEndOfRecentFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-plan-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent(".codex/sessions/2026/11/24")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, minutesAgo: Double) throws {
            let f = day.appendingPathComponent(name)
            try Data(text.utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: f.path)
        }
        let filler = String(repeating: "x", count: 4000)
        try write("new.jsonl", line(9, window(99)) + "\n" + filler + "\n" + line(10, "null"), minutesAgo: 5)
        try write("older.jsonl", filler + "\n" + line(60, window(33)), minutesAgo: 60)
        try write("old.jsonl", line(30, window(50)), minutesAgo: 400)
        let folder = home.path + "/.codex/sessions"
        XCTAssertEqual(PlanUsage.codex(folder: folder, now: now, tail: 1000)?.limits.first?.percent, 33, "the start of the newest is never read")
        XCTAssertEqual(PlanUsage.codex(folder: folder, now: now)?.limits.first?.percent, 99)
        XCTAssertNil(PlanUsage.codex(folder: home.path + "/none", now: now))
        for n in ["new.jsonl", "older.jsonl"] { try FileManager.default.removeItem(at: day.appendingPathComponent(n)) }
        XCTAssertNil(PlanUsage.codex(folder: folder, now: now), "a file nobody wrote to for six hours is not opened")
    }

    // The account, the keys and the conversation stay in the files they are in.
    func testNothingElseComesOut() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-plan-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        try claudeFile(limits: week + "," + scoped).write(to: home.appendingPathComponent(".claude.json"))
        let f = home.appendingPathComponent(".codex/sessions/a.jsonl")
        try Data(line(10, window(26)).utf8).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: f.path)
        let found = PlanUsage.read(home: home.path, now: now)
        XCTAssertEqual(found.map(\.tool), ["Claude", "Codex"])
        let snap = Snapshot(system: .empty, sessions: [], apps: [], topCPU: [], topMemory: [], suggestions: [])
        var on = Settings(); on.planUsage = true
        let server = MCPServer(provider: { snap }, settings: { on }, plan: { found })
        let answer = try XCTUnwrap(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plan_usage"}}"#))
        XCTAssertTrue(answer.contains("62"))
        let all = answer + String(describing: found) + String(decoding: try JSONEncoder().encode(snap), as: UTF8.self)
        for s in secrets { XCTAssertFalse(all.contains(s), s) }
    }

    func testOffUntilTicked() throws {
        XCTAssertFalse(Settings().planUsage)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).planUsage)
        var s = Settings(); s.planUsage = true
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)), s)
        var asked = 0
        func reply(_ on: Bool, _ line: String) -> String {
            var s = Settings(); s.planUsage = on
            return MCPServer(provider: { Snapshot(system: .empty, sessions: [], apps: [], topCPU: [], topMemory: [], suggestions: []) },
                             settings: { s }, plan: { asked += 1; return [] }).handle(line) ?? ""
        }
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plan_usage"}}"#
        XCTAssertFalse(reply(false, list).contains("plan_usage"))
        XCTAssertTrue(reply(false, call).contains("error"))
        XCTAssertEqual(asked, 0, "unticked, the files are not even opened")
        XCTAssertTrue(reply(true, list).contains("plan_usage"))
        XCTAssertFalse(reply(true, call).contains("error"))
        XCTAssertEqual(asked, 1)
    }

    // Every tool that is listed answers.
    func testEveryListedToolAnswers() {
        let s = MCPServer(provider: { Snapshot(system: .empty, sessions: [], apps: [], topCPU: [], topMemory: [], suggestions: []) },
                          healthStore: { HealthStore() }, sleepCost: { SleepCost() }, settings: { Settings() }, plan: { [] })
        for t in s.offered { XCTAssertNotNil(s.call(t.name), t.name) }
    }

    func testWhenItResets() {
        func r(_ h: Double) -> String { PlanUsage.resets(now.addingTimeInterval(h * 3600), now: now, zone: TimeZone(identifier: "UTC")!) }
        XCTAssertEqual(r(2), "resets 22:00")
        XCTAssertEqual(r(45), "resets Thursday")
        XCTAssertEqual(r(24 * 7), "resets Dec 1", "the same weekday next week is a date")
    }
}
