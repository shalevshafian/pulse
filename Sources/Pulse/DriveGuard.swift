import AppKit
import IOKit
import IOKit.pwr_mgt
import PulseCore

/// Listens to the kernel's own sleep messages, for the menu bar app only. The sleep waits for
/// `IOAllowPowerChange`, which is sent on every path.
final class DriveGuard {
    private let queue = DispatchQueue(label: "pulse.drives", qos: .userInitiated)
    private let ops = DiskArbitrationOps()
    private let engine: SleepDrives
    private let lock = NSLock()
    private var wanted: [SleepDrive] = []
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    /// Grows on every sleep, so retries of an older wake stop.
    private var round = 0
    private var observers: [NSObjectProtocol] = []

    var onRefused: (([SleepDrives.Refusal]) -> Void)?
    var onStillOut: (([SleepDrive]) -> Void)?
    var onChange: (() -> Void)?

    init() { engine = SleepDrives(ops: ops) }

    func setWanted(_ list: [SleepDrive]) { lock.lock(); wanted = list; lock.unlock() }

    func start() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(me, &port, { context, _, message, argument in
            guard let context else { return }
            Unmanaged<DriveGuard>.fromOpaque(context).takeUnretainedValue().heard(message, Int(bitPattern: argument))
        }, &notifier)
        guard root != 0, let port else { return log("could not register for power messages") }
        IONotificationPortSetDispatchQueue(port, queue)
        log("listening for sleep")
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.connect(after: [0, 3, 8]) }
            })
        // What an earlier run disconnected and did not get to connect.
        queue.async { self.connect(after: [0, 3]) }
    }

    // iokit_common_msg() is a macro Swift does not import.
    private static let canSleep: UInt32 = 0xE000_0270, willSleep: UInt32 = 0xE000_0280, poweredOn: UInt32 = 0xE000_0300

    /// On `queue`.
    private func heard(_ message: UInt32, _ id: Int) {
        switch message {
        case Self.canSleep:
            IOAllowPowerChange(root, id)
        case Self.willSleep:
            round += 1
            lock.lock(); let list = wanted; lock.unlock()
            if !list.isEmpty {
                let began = Date()
                let refused = engine.willSleep(list)
                log("sleep: \(list.count) ticked, \(refused.count) stayed connected, "
                    + String(format: "%.1f s", Date().timeIntervalSince(began)) + refused.map { "; \($0.drive.name): \($0.holders)" }.joined())
                if !refused.isEmpty { onRefused?(refused) }
                onChange?()
            }
            IOAllowPowerChange(root, id)
        case Self.poweredOn:
            connect(after: [1, 3, 6, 12, 20])
        default: break
        }
    }

    /// The drive itself may take seconds to come back after a wake.
    private func connect(after delays: [Double]) {
        guard !engine.waiting.isEmpty else { return }
        let mine = round
        for (i, d) in delays.enumerated() {
            queue.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self, self.round == mine, !self.engine.waiting.isEmpty, PowerState.mayConnect() else { return }
                let before = self.engine.waiting
                let last = i == delays.count - 1
                let left = self.engine.reconnect(last: last)
                if left != before { self.log("wake: settled \(before.filter { !left.contains($0) }.map(\.name))") }
                self.onChange?()
                if last, !left.isEmpty {
                    self.log("wake: still out \(left.map(\.name))")
                    self.onStillOut?(left)
                }
            }
        }
    }

    struct Row: Identifiable {
        var id: String, name: String
        var bytes: UInt64?
        var mounted: Bool
        var attached: Bool
        var holders: [String]
    }

    /// What is plugged in, what is ticked, and who uses each one right now.
    func rows(_ ticked: [SleepDrive], _ done: @escaping ([Row], [SleepDrive]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let seen = self.ops.volumes()
            var out = seen.map { v in
                Row(id: v.id, name: v.name, bytes: v.bytes, mounted: v.path != nil, attached: true,
                    holders: v.path.map { self.ops.holders(of: $0) } ?? [])
            }
            for t in ticked where !seen.contains(where: { $0.id == t.id }) {
                out.append(Row(id: t.id, name: t.name, bytes: nil, mounted: false, attached: false, holders: []))
            }
            let waiting = self.engine.waiting
            DispatchQueue.main.async { done(out, waiting) }
        }
    }

    /// The user pressed "connect" on a row Pulse disconnected.
    func connectNow() {
        queue.async {
            let left = self.engine.reconnect()
            self.log("by hand: still out \(left.map(\.name))")
            self.onChange?()
        }
    }

    private func log(_ line: String) {
        let url = DriveLedger.defaultURL.deletingLastPathComponent().appendingPathComponent("drives.log")
        let text = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        var old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if old.utf8.count > 64_000 { old = String(old.suffix(16_000)) }
        try? (old + text).write(to: url, atomically: true, encoding: .utf8)
    }
}
