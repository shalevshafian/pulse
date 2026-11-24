import XCTest
@testable import PulseCore

final class DiskWearTests: XCTestCase {
    func w(_ used: Int = 0, warning: UInt8 = 0, errors: UInt64 = 0, spare: Int = 99) -> DiskWear {
        DiskWear(criticalWarning: warning, spare: spare, spareThreshold: 99, percentUsed: used, bytesWritten: 9_100_000_000_000, mediaErrors: errors)
    }

    // What a new Apple disk reports: spare 99, threshold 99.
    func testANewAppleDiskIsFine() {
        let c = HealthRules.wear(w())
        XCTAssertEqual(c.state, .ok)
        XCTAssertEqual(c.title, "Disk wear 0%")
        XCTAssertEqual(c.detail, "9.1 TB written")
        XCTAssertEqual(HealthRules.wear(w(spare: 50)).state, .ok, "the disk itself says when its spare is too low")
    }

    func testWearAndFaults() {
        XCTAssertEqual([79, 80, 99, 100, 255].map { HealthRules.wear(w($0)).state }, [.ok, .attention, .attention, .urgent, .urgent])
        XCTAssertEqual([1, 4, 8, 16].map { HealthRules.wear(w(warning: $0)).state }, [.urgent, .urgent, .urgent, .urgent])
        XCTAssertEqual(HealthRules.wear(w(warning: 2)).title, "The disk is too hot")
        XCTAssertEqual(HealthRules.wear(w(errors: 1)).title, "The disk lost data 1 time")
        XCTAssertEqual(HealthRules.wear(w(100, errors: 1)).state, .urgent, "the worse of two")
        XCTAssertEqual(HealthRules.wear(w(errors: .max)).state, .attention)
    }

    func testTheOldReadingStaysWhereThereIsNoLog() {
        func smart(_ text: String?, _ wear: DiskWear?) -> HealthCheck? {
            HealthRules.disk(free: 500, total: 1000, smart: text, wear: wear, history: []).first { $0.id == "smart" }
        }
        XCTAssertEqual(smart("SMART Status: Verified", nil)?.title, "Disk hardware is fine")
        XCTAssertEqual(smart(nil, nil)?.state, .unknown)
        XCTAssertEqual(smart(nil, w(3))?.title, "Disk wear 3%")
        XCTAssertEqual(smart("SMART Status: Failing", w(3))?.state, .urgent, "macOS says it is failing, whatever the log says")
    }

    func testWearIsKeptForATrendAndOldDaysStillLoad() throws {
        var s = HealthStore()
        var r = HealthReport(takenAt: Date(), checks: []); r.wear = 7
        s.absorb(r, diskFree: 1, now: Date())
        XCTAssertEqual(s.history.last?.wear, 7)
        let old = try JSONDecoder().decode(HealthDay.self, from: Data(#"{"day":"2026-11-20","score":80,"diskFreeBytes":5}"#.utf8))
        XCTAssertNil(old.wear)
    }

    // A virtual machine has no such disk and an answer is not owed; one that is given must make sense.
    func testThisMac() {
        guard let d = DiskWear.read() else { return }
        XCTAssertLessThanOrEqual(d.percentUsed, 255)
        XCTAssertGreaterThan(d.bytesWritten, 0)
        XCTAssertLessThanOrEqual(d.spare, 100)
        print("WEAR used=\(d.percentUsed) written=\(Double(d.bytesWritten) / 1e12) spare=\(d.spare)/\(d.spareThreshold) warning=\(d.criticalWarning) errors=\(d.mediaErrors)")
    }
}
