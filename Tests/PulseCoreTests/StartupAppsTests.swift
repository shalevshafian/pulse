import XCTest
@testable import PulseCore

final class StartupAppsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func apps() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-apps-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        func plist(_ path: String, _ d: [String: Any]) throws {
            try FileManager.default.createDirectory(atPath: (dir + path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: dir + path))
        }
        try plist("/Quiet.app/Contents/Library/LaunchAgents/a.plist", ["Label": "com.quiet.agent", "BundleProgram": "Contents/MacOS/agent"])
        try plist("/Quiet.app/Contents/Library/LaunchDaemons/d.plist", ["Label": "com.quiet.daemon", "ProgramArguments": ["/usr/local/bin/d", "-x"]])
        try plist("/Suite/Deep.app/Contents/Library/LoginItems/Helper.app/Contents/Info.plist", ["CFBundleIdentifier": "com.deep.helper"])
        try plist("/Odd.app/Contents/Library/LaunchAgents/none.plist", ["Program": "/x"])
        try plist("/Odd.app/Contents/Library/LaunchAgents/empty.plist", ["Label": "", "Program": "/x"])
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: dir + "/Odd.app/Contents/Library/LaunchAgents/broken.plist"))
        return dir
    }

    func testFindsWhatAppsCanRegister() throws {
        let dir = try apps()
        XCTAssertEqual(StartupApps.find(in: [dir, dir + "/none"]), [
            .init(label: "com.quiet.agent", app: "Quiet", program: dir + "/Quiet.app/Contents/MacOS/agent"),
            .init(label: "com.quiet.daemon", app: "Quiet", program: "/usr/local/bin/d"),
            .init(label: "com.deep.helper", app: "Deep", program: dir + "/Suite/Deep.app/Contents/Library/LoginItems/Helper.app"),
        ])
    }

    func testOnlyWhatIsLoadedIsListed() throws {
        let labels = try XCTUnwrap(LaunchdJobs.labels("PID\tStatus\tLabel\n12\t0\tcom.deep.helper\n-\t0\tcom.folder.on\n-\t0\tcom.some.Updater-ShipIt\n"))
        XCTAssertEqual(labels, ["com.deep.helper", "com.folder.on", "com.some.Updater-ShipIt"])
        let folders = [StartupItem(label: "com.folder.on", program: "/a", missing: false), StartupItem(label: "com.folder.off", program: "/b", missing: true)]
        let out = StartupApps.join(folders: folders, apps: StartupApps.find(in: [try apps()]), loaded: labels) { "Signed by " + ($0 as NSString).lastPathComponent }
        XCTAssertEqual(out.map(\.label), ["com.folder.on", "com.folder.off", "com.deep.helper"], "not loaded is not listed; loaded and nowhere is not either")
        XCTAssertEqual(out.map(\.loaded), [true, false, true])
        XCTAssertEqual(out.map(\.app), [nil, nil, "Deep"])
        XCTAssertEqual(out.map(\.signer), ["Signed by a", nil, "Signed by Helper.app"])
        XCTAssertTrue(out[1].missing)
        let same = StartupApps.join(folders: [StartupItem(label: "com.deep.helper", program: "", missing: false)], apps: StartupApps.find(in: [try apps()]), loaded: labels) { _ in nil }
        XCTAssertEqual(same.count, 1, "one that is in both is one item")
    }

    func testAnUnreadListIsUnknownAndNeverHealthy() {
        XCTAssertNil(LaunchdJobs.labels(nil)); XCTAssertNil(LaunchdJobs.labels("")); XCTAssertNil(LaunchdJobs.labels("PID\tStatus\tLabel\n"))
        XCTAssertEqual(HealthRules.startup([], known: [], knownInApps: [], readApps: false).map(\.state), [.unknown])
    }

    func item(_ label: String, in app: String? = nil) -> StartupItem { StartupItem(label: label, program: "", missing: false, app: app, loaded: true) }

    /// One check, the way the app makes it.
    func check(_ s: inout HealthStore, _ items: [StartupItem], read: Bool = true) -> [String] {
        var r = HealthReport(takenAt: now, checks: HealthRules.startup(items, known: s.knownStartup, knownInApps: s.knownInApps, readApps: read), startup: items)
        r.readApps = read
        s.absorb(r, diskFree: 1, now: now)
        return s.takeNew(now: now).map(\.detail)
    }

    func testAnUpgradeAnnouncesNothingAndOneAddedItemAnnouncesOnce() throws {
        // As version 1.0 wrote it: the folders only.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-old-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"rules":2,"history":[],"ignored":[],"notified":{},"knownStartup":["com.folder"],"report":{"takenAt":"2026-11-20T10:00:00Z","checks":[],"cleanup":[],"startup":[{"label":"com.folder","program":"/a","missing":false}]}}"#.utf8).write(to: url)
        var s = HealthStore.load(from: url)
        XCTAssertEqual(s.knownStartup, ["com.folder"])
        XCTAssertNil(s.knownInApps)
        let base = [item("com.folder"), item("com.quiet", in: "Quiet"), item("com.deep", in: "Deep")]
        XCTAssertEqual(check(&s, base), [])
        XCTAssertEqual(check(&s, base), [])
        let more = base + [item("com.new", in: "New")]
        XCTAssertEqual(check(&s, more), ["com.new in New"])
        XCTAssertEqual(check(&s, more), [], "once")
        s.acceptStartup()
        XCTAssertEqual(check(&s, more), [])
        XCTAssertEqual(check(&s, [item("com.folder")]), [], "an app that is not running now")
        XCTAssertEqual(check(&s, more), [], "and is back: it was known")
        XCTAssertEqual(check(&s, [item("com.folder"), item("com.third", in: "Third")]), ["com.third in Third"])
        s.acceptStartup()
        XCTAssertEqual(check(&s, more), [], "accepting one forgets none of the others")
        XCTAssertEqual(check(&s, more + [item("com.folder2")]), ["com.folder2"], "the folders are watched as before")
    }

    func testAFirstCheckThatCouldNotReadDoesNotBecomeTheBase() {
        var s = HealthStore()
        XCTAssertEqual(check(&s, [item("com.folder")], read: false), [])
        XCTAssertNil(s.knownInApps)
        XCTAssertEqual(check(&s, [item("com.folder"), item("com.quiet", in: "Quiet")]), [], "the first that can be read is the base")
        XCTAssertEqual(s.knownStartup, ["com.folder"])
        XCTAssertEqual(check(&s, [item("com.quiet", in: "Quiet"), item("com.new", in: "New")]), ["com.new in New"])
    }

    func testAcceptingAFolderItemThatLeftAndReturnedIsNewsAgain() {
        var s = HealthStore()
        _ = check(&s, [item("a"), item("b")])
        _ = check(&s, [item("a")])
        s.acceptStartup()
        XCTAssertEqual(check(&s, [item("a"), item("b")]), ["b"])
    }

    func testWhoSigned() throws {
        XCTAssertEqual(StartupApps.developer("Developer ID Application: Example Inc (ABCDE12345)"), "Example Inc")
        XCTAssertEqual(StartupApps.developer("Developer ID Application: Firma (Berlin) GmbH (ABCDE12345)"), "Firma (Berlin) GmbH")
        XCTAssertEqual(StartupApps.developer("Software Signing"), "Apple")
        XCTAssertEqual(StartupApps.signer(of: "/usr/libexec/trustd"), "Signed by Apple")
        XCTAssertNil(StartupApps.signer(of: "/bin/sh"), "a script is not signed by its shell")
        XCTAssertNil(StartupApps.signer(of: "/nowhere/x"))
        XCTAssertNil(StartupApps.signer(of: "node"))
        // Signed by nobody: a file of this test's own.
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-unsigned-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: f) }
        try Data("#!/bin/sh\n".utf8).write(to: f)
        XCTAssertEqual(StartupApps.signer(of: f.path), "Not signed by a known developer")
    }

    // Every label shown is one launchd has.
    func testThisMac() throws {
        let labels = try XCTUnwrap(LaunchdJobs.labels(Shell.output("/bin/launchctl", ["list"])))
        let began = Date()
        let out = StartupApps.join(folders: [], apps: StartupApps.find(in: ["/Applications", NSHomeDirectory() + "/Applications"]), loaded: labels, signer: StartupApps.signer)
        print("STARTUP", Date().timeIntervalSince(began), out.map { "\($0.label) \($0.app ?? "") \($0.signer ?? "-")" })
        XCTAssertTrue(out.allSatisfy { labels.contains($0.label) })
    }
}
