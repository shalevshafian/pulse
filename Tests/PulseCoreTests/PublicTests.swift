import XCTest
@testable import PulseCore

/// What has to hold on a Mac that is not the one Pulse was written on.
final class PublicTests: XCTestCase {
    let now = StartTime.date("Sun Nov 22 12:00:00 2026")!

    // A LaunchAgent has launchd as its parent, exactly like a process whose session has ended.
    func testAServiceThatLaunchdRunsIsNotALeftover() {
        XCTAssertEqual(LaunchdJobs.parse("PID\tStatus\tLabel\n310\t0\tcom.example.mcp\n-\t0\tcom.example.off\n"), [310])
        let t = ProcTable.parse("310 1 2048 0.0 Sat Nov 21 08:00:00 2026 /usr/local/bin/notes-mcp-server\n311 1 2048 0.0 Sat Nov 21 08:00:00 2026 /usr/local/bin/other-mcp-server")
        let out = Suggestions.build(system: .empty, sessions: [], apps: [], table: t, sessionPids: [], launchdJobs: [310], now: now)
        XCTAssertEqual(out.map(\.pid), [311])
        XCTAssertTrue(out.allSatisfy { !Settings().preselects($0) }, "not ticked until the user asks for it")
    }

    func testThisMacsLaunchdListIsReadable() {
        XCTAssertFalse(LaunchdJobs.live().isEmpty)
    }

    func testOldBuildsAreLookedForOnlyInCodeFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let real = try XCTUnwrap(realpath(dir.path, nil)); defer { free(real) }
        let home = String(cString: real), tag = "Signature: 8a477f597d28d172789f06886806bc55\n# created by cargo.\n"
        let old = now.addingTimeInterval(-30 * 86400)
        for place in ["Projects/app", "Documents/app", "Developer/app"] {
            let path = home + "/\(place)/target"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            try tag.write(toFile: path + "/CACHEDIR.TAG", atomically: true, encoding: .utf8)
            for p in [path + "/CACHEDIR.TAG", path] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: p) }
        }
        XCTAssertEqual(Cleanup.codeFolders(home: home), [home + "/Developer", home + "/Projects"])
        func moves(_ place: String) -> Bool {
            Cleanup.trash(CleanupItem(title: "t", detail: "", path: home + "/\(place)/target", bytes: 1), home: home, table: ProcTable([]), settings: Settings(), now: now) { _ in }
        }
        XCTAssertTrue(moves("Projects/app"))
        XCTAssertFalse(moves("Documents/app"), "macOS guards Documents, and Pulse stays out of it")
    }

    func testBatteryOfAnOlderIntelMac() {
        XCTAssertEqual(HealthRules.battery(["MaxCapacity": 4300, "DesignCapacity": 5000]).map(\.title), ["Battery health 86%"])
        XCTAssertEqual(HealthRules.battery(["MaxCapacity": 100, "DesignCapacity": 5000]).map(\.state), [.unknown], "a percentage is not a capacity")
        XCTAssertEqual(HealthRules.battery([:]).map(\.title), ["This Mac has no battery"])
    }

    func testAReportFromAnotherVersionIsDroppedAndItsHistoryKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-store-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var s = HealthStore()
        s.ignored = ["firewall"]
        s.absorb(HealthReport(takenAt: now, checks: []), diskFree: 1, now: now)
        s.rules = nil
        s.save(to: url)
        let back = HealthStore.load(from: url)
        XCTAssertNil(back.report)
        XCTAssertEqual(back.ignored, ["firewall"])
        XCTAssertEqual(back.history.count, 1)
        s.rules = HealthStore.currentRules
        s.save(to: url)
        XCTAssertNotNil(HealthStore.load(from: url).report)
    }

    func testWelcomeIsShownOnlyToSomeoneNew() throws {
        XCTAssertFalse(Settings().welcomed)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).welcomed, "a file from before the welcome existed")
    }

    func testCoreOfMacOSIsNeverClosed() {
        for name in ["Finder", "Dock", "WindowServer", "loginwindow", "ControlCenter", "Pulse"] {
            XCTAssertFalse(Actions.mayClose(Consumer(kind: .app, name: name, rssBytes: 0, cpuPercent: 0, processCount: 1), settings: Settings()), name)
        }
        XCTAssertTrue(Actions.mayClose(Consumer(kind: .app, name: "Safari", rssBytes: 0, cpuPercent: 0, processCount: 1), settings: Settings()))
    }

    // The app is English and left to right, with no text-direction marks and no emoji in its source.
    func testSourcesArePlainEnglish() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10)
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for u in text.unicodeScalars where (0x0590...0x05FF).contains(u.value) || (0x200E...0x200F).contains(u.value) || (0x2066...0x2069).contains(u.value) || u.properties.isEmojiPresentation {
                XCTFail("U+\(String(u.value, radix: 16)) in \(f.lastPathComponent)")
            }
            XCTAssertFalse(text.contains("\\u{2066}") || text.contains("\\u{2068}"), f.lastPathComponent)
        }
    }
}
