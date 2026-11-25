import XCTest
@testable import PulseCore

final class LargeFoldersTests: XCTestCase {
    func home() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = try XCTUnwrap(realpath(dir.path, nil)); defer { free(real) }
        let path = String(cString: real)
        addTeardownBlock {
            chmod(path + "/Library/Application Support/Closed", 0o700)
            try? FileManager.default.removeItem(atPath: path)
        }
        return path
    }

    func fill(_ path: String, kb: Int) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(repeating: 7, count: kb * 1024).write(to: URL(fileURLWithPath: path + "/data"))
    }

    func testSortedAndOnlyOverTheMinimumInRealFolders() throws {
        let h = try home(), support = h + "/Library/Application Support"
        try fill(support + "/Small", kb: 60)
        try fill(support + "/Middle שלום", kb: 300)
        try fill(h + "/Library/Logs/Big", kb: 900)
        let f = LargeFolders.find(home: h, minimum: 200 << 10)
        XCTAssertEqual(f.folders.map(\.name), ["Big", "Middle שלום"])
        XCTAssertEqual(f.folders.first?.place, "Logs")
        XCTAssertEqual(Double(f.folders.first?.bytes ?? 0), 900 * 1024, accuracy: 64 * 1024)
        XCTAssertEqual(f.refused, 0)
        XCTAssertEqual(f.unfinished, [])
        XCTAssertTrue(LargeFolders.find(home: h).folders.isEmpty, "nothing here is over 1 GB")
    }

    // Not zero, and not silently missing.
    func testARefusedFolderIsCountedAndHasNoSize() throws {
        let h = try home(), closed = h + "/Library/Application Support/Closed"
        try fill(closed, kb: 900)
        XCTAssertEqual(chmod(closed, 0), 0)
        let f = LargeFolders.find(home: h, minimum: 0)
        XCTAssertEqual(f.refused, 1)
        XCTAssertFalse(f.folders.contains { $0.name == "Closed" })
        let text = "4\t/a b/x\ndu: /a b/x: Operation not permitted\ndu: /a b/y: Permission denied\n88\t/a b/z\tq\n"
        XCTAssertEqual(LargeFolders.parse(text).refused, ["/a b/x", "/a b/y"])
        XCTAssertEqual(LargeFolders.parse(text).sizes, ["/a b/z\tq": UInt64(88 * 1024)])
    }

    func testLinksAndGuardedNamesAndWhatIsOfferedAboveAreNeverEntered() throws {
        let h = try home(), support = h + "/Library/Application Support"
        try fill(h + "/Pictures", kb: 900)
        for name in ["Containers", "Group Containers", "Mobile Documents", "Desktop", "Documents", "Downloads"] { try fill(support + "/" + name, kb: 900) }
        try fill(h + "/Library/Caches/Homebrew", kb: 900)
        try fill(support + "/Plain", kb: 300)
        try FileManager.default.createSymbolicLink(atPath: support + "/Link", withDestinationPath: h + "/Pictures")
        var asked: [String] = []
        let f = LargeFolders.find(home: h, minimum: 0) { asked += $0; return Shell.output("/usr/bin/du", ["-skx", "--"] + $0) }
        XCTAssertEqual(asked, [support + "/Plain"])
        XCTAssertEqual(f.folders.map(\.name), ["Plain"])
    }

    func testAPlaceThatDidNotFinishIsSaid() throws {
        let h = try home()
        try fill(h + "/Library/Logs/Big", kb: 10)
        let f = LargeFolders.find(home: h, minimum: 0) { _ in nil }
        XCTAssertEqual(f.unfinished, ["Logs"])
        XCTAssertEqual(f.folders, [])
    }

    func testAtMostEight() throws {
        let h = try home()
        let names = (1...12).map { "F\($0)" }
        for n in names { try FileManager.default.createDirectory(atPath: h + "/Library/Logs/" + n, withIntermediateDirectories: true) }
        let f = LargeFolders.find(home: h, minimum: 0) { $0.enumerated().map { "\($0 + 1)\t\($1)" }.joined(separator: "\n") }
        XCTAssertEqual(f.folders.map(\.bytes), (5...12).reversed().map { UInt64($0) * 1024 })
    }

    // Never a place that holds work, history or settings.
    func testCleanupPlacesStayCaches() {
        let allowed = ["Library/Caches/", "Library/Developer/Xcode/DerivedData", ".gradle/caches", ".gradle/wrapper", ".npm/_cacache", ".cargo/registry/cache"]
        for p in Cleanup.places { XCTAssertTrue(allowed.contains { p.path.hasPrefix($0) }, p.path) }
        XCTAssertFalse(Cleanup.places.contains { $0.users.isEmpty })
    }
}
