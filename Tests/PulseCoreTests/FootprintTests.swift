import XCTest
@testable import PulseCore

final class FootprintTests: XCTestCase {
    func testTheFootprintStandsInForResidentMemoryWhereItIsReadable() {
        let t = ProcTable.parse("""
          100 1 814080 1.5 Sun Nov 22 11:20:22 2026 /Applications/Big.app/Contents/MacOS/Big
          101 1 204800 1.5 Sun Nov 22 11:20:22 2026 /usr/libexec/rootd
        """, footprint: { $0 == 100 ? 6418 << 20 : nil })
        XCTAssertEqual(t.byPid[100]?.rssBytes, 6418 << 20)
        XCTAssertEqual(t.byPid[101]?.rssBytes, 204_800 * 1024, "root's processes keep what ps says")
        XCTAssertEqual(AppGroups.build(t).first?.rssBytes, 6418 << 20, "and the rows follow")
    }

    func testReadsThisProcessAndIsRefusedForLaunchd() throws {
        // Pages that are touched count: 64 MB more than before.
        let before = try XCTUnwrap(Footprint.read(getpid()))
        let p = UnsafeMutableRawPointer.allocate(byteCount: 64 << 20, alignment: 16384); defer { p.deallocate() }
        p.initializeMemory(as: UInt8.self, repeating: 7, count: 64 << 20)
        let after = try XCTUnwrap(Footprint.read(getpid()))
        XCTAssertGreaterThan(after, before + (48 << 20))
        XCTAssertNil(Footprint.read(1))
        XCTAssertNil(Footprint.read(-5))
    }

    // Most processes stand still between two readings, and ps never gives the same bytes.
    func testTheLiveTableHoldsFootprints() {
        let mine = ProcTable.live().all.compactMap { p in Footprint.read(p.pid).map { (p.rssBytes, $0) } }
        XCTAssertGreaterThan(mine.count, 3)
        XCTAssertGreaterThan(mine.filter { $0.0 == $0.1 }.count, mine.count / 4)
    }
}
