import DiskArbitration
import Foundation
import IOKit

/// A drive the user ticked: disconnected before sleep, connected again after.
public struct SleepDrive: Codable, Equatable, Sendable, Identifiable {
    /// The volume's UUID. A name can change and a `diskN` number changes on every connection.
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One volume on a physical external drive.
public struct DriveVolume: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var bytes: UInt64
    /// nil when the drive is plugged in and the volume is not mounted.
    public var path: String?
    public init(id: String, name: String, bytes: UInt64, path: String?) {
        self.id = id; self.name = name; self.bytes = bytes; self.path = path
    }
}

public enum DriveRules {
    /// From Disk Arbitration's description of one medium. Installers, simulator runtimes and
    /// every other disk image are not drives; neither are the Mac's own disk and the network.
    public static func volume(_ d: [String: Any], uuid: String?) -> DriveVolume? {
        func yes(_ k: CFString) -> Bool { d[k as String] as? Bool ?? false }
        let proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? ""
        let model = d[kDADiskDescriptionDeviceModelKey as String] as? String ?? ""
        guard yes(kDADiskDescriptionVolumeMountableKey), !yes(kDADiskDescriptionVolumeNetworkKey),
              !proto.isEmpty, proto != "Virtual Interface", model != "Disk Image" else { return nil }
        // Said outright, or a card in the Mac's own slot. Missing is not "external".
        let external = d[kDADiskDescriptionDeviceInternalKey as String] as? Bool == false || proto == "Secure Digital"
        guard external else { return nil }
        let name = d[kDADiskDescriptionVolumeNameKey as String] as? String ?? ""
        let content = d[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
        guard !name.isEmpty, content.uppercased() != "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" else { return nil }
        return DriveVolume(id: uuid ?? "\(name):\(size)", name: name, bytes: size,
                           path: (d[kDADiskDescriptionVolumePathKey as String] as? URL)?.path)
    }

    /// `lsof -F pc`: the program names, each once.
    public static func holders(_ lsof: String) -> [String] {
        var out: [String] = []
        for line in lsof.split(separator: "\n") where line.hasPrefix("c") {
            let name = String(line.dropFirst())
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// The lid is shut and that puts the Mac to sleep: it is about to sleep again, so a drive
    /// connected now would be pulled. A shut lid with a display attached is a Mac in use.
    public static func mayConnect(lidShut: Bool, lidSleeps: Bool, graphics: Bool) -> Bool {
        graphics && !(lidShut && lidSleeps)
    }
}

/// What the engine may do to drives. There is no eject and no force here on purpose: an
/// ejected drive needs its cable pulled, and a forced one can lose what is being written.
public protocol DriveOps {
    func volumes() -> [DriveVolume]
    func unmount(_ id: String, timeout: TimeInterval) -> Bool
    func mount(_ id: String, timeout: TimeInterval) -> Bool
    func holders(of path: String) -> [String]
}

/// What was disconnected and must come back. On disk, so it survives Pulse being closed.
public struct DriveLedger: Codable, Equatable {
    public var out: [SleepDrive] = []
    public init() {}

    public static var defaultURL: URL { Settings.defaultURL.deletingLastPathComponent().appendingPathComponent("drives.json") }

    public static func load(from url: URL = defaultURL) -> DriveLedger {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(DriveLedger.self, from: $0) } ?? DriveLedger()
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Before sleep: unmount the ticked drives, inside a deadline. After a full wake: mount back
/// exactly those. Called from one serial queue.
public final class SleepDrives {
    public struct Refusal: Equatable {
        public var drive: SleepDrive
        public var holders: [String]
    }

    /// macOS gives 30 seconds before it sleeps anyway.
    public static let budget: TimeInterval = 20
    let ops: DriveOps
    let ledgerURL: URL
    let now: () -> Date

    public init(ops: DriveOps, ledgerURL: URL = DriveLedger.defaultURL, now: @escaping () -> Date = Date.init) {
        self.ops = ops; self.ledgerURL = ledgerURL; self.now = now
    }

    /// Returns what stayed connected and who held it. Only `wanted` is ever touched.
    public func willSleep(_ wanted: [SleepDrive], budget: TimeInterval = SleepDrives.budget) -> [Refusal] {
        guard !wanted.isEmpty else { return [] }
        let end = now().addingTimeInterval(budget)
        var refused: [Refusal] = []
        let ids = Set(wanted.map(\.id))
        for v in ops.volumes() where ids.contains(v.id) {
            guard let path = v.path else { continue }
            let drive = SleepDrive(id: v.id, name: v.name)
            let left = end.timeIntervalSince(now())
            guard left > 1 else { refused.append(Refusal(drive: drive, holders: [])); continue }
            // Written first: if Pulse dies in the middle, the next launch still connects it.
            var ledger = DriveLedger.load(from: ledgerURL)
            if !ledger.out.contains(where: { $0.id == v.id }) { ledger.out.append(drive); ledger.save(to: ledgerURL) }
            if ops.unmount(v.id, timeout: min(left, 8)) { continue }
            // Refused, or no answer in time. A late success stays in the ledger and comes back.
            if ops.volumes().contains(where: { $0.id == v.id && $0.path != nil }) {
                refused.append(Refusal(drive: drive, holders: end.timeIntervalSince(now()) > 3 ? ops.holders(of: path) : []))
            }
        }
        return refused
    }

    /// One try. Returns what is still out: not plugged in yet, or would not mount. On the last
    /// try an absent drive is let go: it left with its cable, and macOS mounts it when it is back.
    @discardableResult
    public func reconnect(last: Bool = false) -> [SleepDrive] {
        var ledger = DriveLedger.load(from: ledgerURL)
        guard !ledger.out.isEmpty else { return [] }
        let seen = ops.volumes()
        let left = ledger.out.filter { d in
            guard let v = seen.first(where: { $0.id == d.id }) else { return !last }
            return v.path == nil && !ops.mount(d.id, timeout: 6)
        }
        if left != ledger.out { ledger.out = left; ledger.save(to: ledgerURL) }
        return left
    }

    public var waiting: [SleepDrive] { DriveLedger.load(from: ledgerURL).out }
}

/// The real disks, through Disk Arbitration.
public final class DiskArbitrationOps: DriveOps {
    private let session: DASession?
    private let queue = DispatchQueue(label: "pulse.diskarbitration", qos: .userInitiated)
    /// Tests of real unmounting work on a disk image they made, which the rules leave out.
    private let alsoAccept: (String) -> DriveVolume?

    public init(alsoAccept: @escaping (String) -> DriveVolume? = { _ in nil }) {
        self.alsoAccept = alsoAccept
        session = DASessionCreate(kCFAllocatorDefault)
        if let session { DASessionSetDispatchQueue(session, queue) }
    }

    deinit { if let session { DASessionSetDispatchQueue(session, nil) } }

    private func disks() -> [(DADisk, DriveVolume)] {
        guard let session else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [(DADisk, DriveVolume)] = []
        while case let media = IOIteratorNext(it), media != 0 {
            defer { IOObjectRelease(media) }
            guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
                  let d = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            let uuid = d[kDADiskDescriptionVolumeUUIDKey as String].flatMap { value -> String? in
                let ref = value as CFTypeRef
                guard CFGetTypeID(ref) == CFUUIDGetTypeID() else { return nil }
                return CFUUIDCreateString(nil, (ref as! CFUUID)) as String?
            }
            if let v = DriveRules.volume(d, uuid: uuid) {
                out.append((disk, v))
            } else if let uuid, var v = alsoAccept(uuid) {
                v.path = (d[kDADiskDescriptionVolumePathKey as String] as? URL)?.path
                out.append((disk, v))
            }
        }
        return out
    }

    public func volumes() -> [DriveVolume] { disks().map(\.1).sorted { $0.name < $1.name } }

    private final class Answer {
        let done = DispatchSemaphore(value: 0)
        var ok = false
    }

    private static let callback: DADiskUnmountCallback = { _, dissenter, context in
        guard let context else { return }
        let a = Unmanaged<Answer>.fromOpaque(context).takeRetainedValue()
        a.ok = dissenter == nil
        a.done.signal()
    }

    private func wait(_ timeout: TimeInterval, _ start: (UnsafeMutableRawPointer) -> Void) -> Bool {
        let a = Answer()
        start(Unmanaged.passRetained(a).toOpaque())
        return a.done.wait(timeout: .now() + timeout) == .success && a.ok
    }

    public func unmount(_ id: String, timeout: TimeInterval) -> Bool {
        guard let disk = disks().first(where: { $0.1.id == id && $0.1.path != nil })?.0 else { return false }
        // Default options: not forced, this volume only, and never an eject.
        return wait(timeout) { DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), Self.callback, $0) }
    }

    public func mount(_ id: String, timeout: TimeInterval) -> Bool {
        guard let disk = disks().first(where: { $0.1.id == id })?.0 else { return false }
        return wait(timeout) { DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), Self.callback, $0) }
    }

    public func holders(of path: String) -> [String] {
        DriveRules.holders(Shell.output("/usr/sbin/lsof", ["-w", "-F", "pc", path], timeout: 2) ?? "")
    }
}

/// The lid and the wake, as the kernel's power domain reports them.
public enum PowerState {
    public static func mayConnect() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return true }
        defer { IOObjectRelease(root) }
        func value(_ key: String) -> Any? { IORegistryEntryCreateCFProperty(root, key as CFString, nil, 0)?.takeRetainedValue() }
        // Bit 2 is graphics: off in a dark wake, when the Mac wakes for a moment with nobody there.
        let caps = (value("System Capabilities") as? NSNumber)?.intValue
        return DriveRules.mayConnect(lidShut: value("AppleClamshellState") as? Bool ?? false,
                                     lidSleeps: value("AppleClamshellCausesSleep") as? Bool ?? false,
                                     graphics: caps.map { $0 & 2 != 0 } ?? true)
    }
}
