import DiskArbitration
import XCTest
@testable import PulseCore

final class FakeOps: DriveOps {
    var list: [DriveVolume]
    var busy: Set<String> = []
    var slow: TimeInterval = 0
    var clock = Date(timeIntervalSince1970: 0)
    var calls: [String] = []
    var failMount = false
    init(_ list: [DriveVolume]) { self.list = list }
    func volumes() -> [DriveVolume] { list }
    func unmount(_ id: String, timeout: TimeInterval) -> Bool {
        calls.append("unmount \(id)")
        clock += min(slow, timeout)
        guard !busy.contains(id), slow <= timeout else { return false }
        for i in list.indices where list[i].id == id { list[i].path = nil }
        return true
    }
    func mount(_ id: String, timeout: TimeInterval) -> Bool {
        calls.append("mount \(id)")
        guard !failMount else { return false }
        for i in list.indices where list[i].id == id { list[i].path = "/Volumes/\(list[i].name)" }
        return true
    }
    func holders(of path: String) -> [String] { ["FL Studio"] }
}

final class DriveTests: XCTestCase {
    let music = DriveVolume(id: "M", name: "Samples", bytes: 1, path: "/Volumes/Samples")
    let samples = DriveVolume(id: "S", name: "Samples", bytes: 1, path: "/Volumes/Samples")
    let ticked = [SleepDrive(id: "S", name: "Samples")]

    func ledger() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-drives-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func desc(_ proto: String?, _ model: String, internalDisk: Bool?, name: String = "X", content: String = "41504653-0000-11AA-AA11-00306543ECAC", mountable: Bool = true, network: Bool = false) -> [String: Any] {
        var d: [String: Any] = ["DAVolumeMountable": mountable, "DAVolumeNetwork": network, "DADeviceModel": model, "DAMediaSize": NSNumber(value: 500), "DAMediaContent": content,
                                "DAVolumePath": URL(fileURLWithPath: "/Volumes/\(name)")]
        if let proto { d["DADeviceProtocol"] = proto }
        if let internalDisk { d["DADeviceInternal"] = internalDisk }
        if !name.isEmpty { d["DAVolumeName"] = name }
        return d
    }

    /// The values are this Mac's on 2026-11-24.
    func testOnlyPhysicalExternalVolumesAreDrives() {
        let v = DriveRules.volume(desc("USB", " SanDisk 3.2 Gen", internalDisk: false, name: "Samples"), uuid: "2A4E")
        XCTAssertEqual(v, DriveVolume(id: "2A4E", name: "Samples", bytes: 500, path: "/Volumes/Samples"))
        XCTAssertNil(DriveRules.volume(desc("Virtual Interface", "Disk Image", internalDisk: nil, name: "FabFilter"), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("Virtual Interface", "", internalDisk: false), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "Disk Image", internalDisk: false), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("Apple Fabric", "APPLE SSD", internalDisk: true), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "SanDisk", internalDisk: false, name: "EFI", content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "SanDisk", internalDisk: false, name: ""), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "SanDisk", internalDisk: false, mountable: false), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "SanDisk", internalDisk: false, network: true), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc(nil, "x", internalDisk: false), uuid: "a"))
        XCTAssertNil(DriveRules.volume(desc("USB", "x", internalDisk: nil), uuid: "a"), "not known to be external")
        XCTAssertNotNil(DriveRules.volume(desc("Secure Digital", "SD", internalDisk: true), uuid: "a"))
    }

    func testOnlyTickedDrivesAreTouchedAndOnlyTheyComeBack() {
        let ops = FakeOps([music, samples]), e = SleepDrives(ops: ops, ledgerURL: ledger())
        XCTAssertEqual(e.willSleep(ticked), [])
        XCTAssertEqual(ops.calls, ["unmount S"])
        XCTAssertEqual(ops.list.map(\.path), ["/Volumes/Samples", nil])
        XCTAssertEqual(e.waiting, ticked)
        XCTAssertEqual(e.reconnect(), [])
        XCTAssertEqual(ops.calls, ["unmount S", "mount S"])
        XCTAssertEqual(e.waiting, [])
    }

    func testNothingTickedTouchesNothing() {
        let ops = FakeOps([music, samples]), e = SleepDrives(ops: ops, ledgerURL: ledger())
        XCTAssertEqual(e.willSleep([]), [])
        e.reconnect(last: true)
        XCTAssertEqual(ops.calls, [])
    }

    func testABusyDriveStaysAndItsHolderIsNamed() {
        let ops = FakeOps([samples]), e = SleepDrives(ops: ops, ledgerURL: ledger())
        ops.busy = ["S"]
        XCTAssertEqual(e.willSleep(ticked), [.init(drive: ticked[0], holders: ["FL Studio"])])
        XCTAssertEqual(e.reconnect(), [], "it never left")
        XCTAssertEqual(ops.calls, ["unmount S"])
    }

    func testADriveTheOwnerUnmountedIsNotMounted() {
        var off = samples
        off.path = nil
        let ops = FakeOps([off]), e = SleepDrives(ops: ops, ledgerURL: ledger())
        XCTAssertEqual(e.willSleep(ticked), [])
        e.reconnect()
        XCTAssertEqual(ops.calls, [])
    }

    func testTheDeadlineHoldsWithManySlowDrives() {
        let many = (0..<8).map { DriveVolume(id: "\($0)", name: "D\($0)", bytes: 1, path: "/Volumes/D\($0)") }
        let ops = FakeOps(many)
        ops.slow = 60
        let e = SleepDrives(ops: ops, ledgerURL: ledger(), now: { ops.clock })
        XCTAssertEqual(e.willSleep(many.map { SleepDrive(id: $0.id, name: $0.name) }).count, 8)
        XCTAssertLessThanOrEqual(ops.clock.timeIntervalSince1970, SleepDrives.budget)
        XCTAssertLessThan(ops.calls.count, 8)
    }

    func testADriveThatLeftWithItsCableIsLetGoOnTheLastTry() {
        let ops = FakeOps([samples]), e = SleepDrives(ops: ops, ledgerURL: ledger())
        _ = e.willSleep(ticked)
        ops.list = []
        XCTAssertEqual(e.reconnect(), ticked, "it may still be waking up")
        XCTAssertEqual(e.reconnect(last: true), [])
        XCTAssertEqual(e.waiting, [])
    }

    func testAFailedMountIsKeptForAnotherTryAndForTheNextLaunch() {
        let ops = FakeOps([samples]), url = ledger(), e = SleepDrives(ops: ops, ledgerURL: url)
        _ = e.willSleep(ticked)
        ops.failMount = true
        XCTAssertEqual(e.reconnect(last: true), ticked)
        ops.failMount = false
        let next = SleepDrives(ops: ops, ledgerURL: url)
        XCTAssertEqual(next.waiting, ticked)
        XCTAssertEqual(next.reconnect(), [])
        XCTAssertEqual(ops.list[0].path, "/Volumes/Samples")
    }

    func testConnectsOnlyWhenSomebodyIsThere() {
        XCTAssertTrue(DriveRules.mayConnect(lidShut: false, lidSleeps: true, graphics: true))
        XCTAssertTrue(DriveRules.mayConnect(lidShut: true, lidSleeps: false, graphics: true), "shut lid, external display")
        XCTAssertFalse(DriveRules.mayConnect(lidShut: true, lidSleeps: true, graphics: true))
        XCTAssertFalse(DriveRules.mayConnect(lidShut: false, lidSleeps: true, graphics: false), "dark wake")
    }

    func testSettingsStartEmptyAndSurviveAnOlderFile() throws {
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{\"barCPU\":false}".utf8)).sleepDrives, [])
        var s = Settings()
        s.sleepDrives = ticked
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).sleepDrives, ticked)
    }

    func testHolders() {
        XCTAssertEqual(DriveRules.holders("p1\ncFL Studio\nfcwd\np2\ncnode\np3\ncnode\n"), ["FL Studio", "node"])
    }

    /// A real volume on a throwaway image: unmounted, refused while a file is open, mounted back.
    func testUnmountsAndMountsARealVolume() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PULSE_DISK_TEST"] == "1", "set PULSE_DISK_TEST=1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("t.sparseimage").path
        let name = "PulseTest\(Int.random(in: 1000...9999))"
        XCTAssertTrue(Shell.succeeds("/usr/bin/hdiutil", ["create", "-size", "40m", "-fs", "APFS", "-type", "SPARSE", "-volname", name, image]))
        XCTAssertTrue(Shell.succeeds("/usr/bin/hdiutil", ["attach", image, "-noautoopen"]))
        var path = "/Volumes/\(name)"
        defer {
            let info = Shell.output("/usr/sbin/diskutil", ["info", name]) ?? ""
            if let node = info.split(separator: "\n").first(where: { $0.contains("Device Node") })?.split(separator: " ").last {
                _ = Shell.succeeds("/usr/bin/hdiutil", ["detach", String(node)])
            }
            try? FileManager.default.removeItem(at: dir)
        }
        let info = try XCTUnwrap(Shell.output("/usr/sbin/diskutil", ["info", path]))
        let uuid = String(try XCTUnwrap(info.split(separator: "\n").first { $0.contains("Volume UUID") }?.split(separator: " ").last))
        let ops = DiskArbitrationOps { $0 == uuid ? DriveVolume(id: uuid, name: name, bytes: 0, path: nil) : nil }
        XCTAssertFalse(DiskArbitrationOps().volumes().contains { $0.id == uuid }, "an image is never listed for the owner")
        let e = SleepDrives(ops: ops, ledgerURL: ledger())
        let want = [SleepDrive(id: uuid, name: name)]

        // Held open: stays, and the holder is this test.
        FileManager.default.createFile(atPath: path + "/held", contents: Data("x".utf8))
        let h = try XCTUnwrap(FileHandle(forReadingAtPath: path + "/held"))
        let refused = e.willSleep(want)
        XCTAssertEqual(refused.map(\.drive), want)
        XCTAssertTrue(refused.first?.holders.contains("xctest") == true, "\(refused)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/held"))
        try h.close()
        XCTAssertEqual(e.reconnect(), [])

        XCTAssertEqual(e.willSleep(want), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/held"))
        XCTAssertNil(ops.volumes().first { $0.id == uuid }?.path)
        XCTAssertNotNil(ops.volumes().first { $0.id == uuid }, "unmounted, still attached")
        XCTAssertEqual(e.reconnect(), [])
        path = try XCTUnwrap(ops.volumes().first { $0.id == uuid }?.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/held"), "the file is there after the round trip")
    }
}
