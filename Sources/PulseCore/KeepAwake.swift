import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake for a while, on the user's press. It always ends: by its time, by the user,
/// or with Pulse itself, because the system drops what a process held when it goes.
public final class KeepAwake {
    private var id: IOPMAssertionID = 0
    public private(set) var until: Date?

    public init() {}
    deinit { stop() }

    /// The system ends it at its time even if Pulse is busy.
    @discardableResult
    public func start(_ seconds: TimeInterval, now: Date = Date()) -> Bool {
        stop()
        let wanted: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertPreventUserIdleSystemSleep,
            kIOPMAssertionNameKey: "Kept awake from Pulse",
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionTimeoutKey: seconds,
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionRelease,
        ]
        guard IOPMAssertionCreateWithProperties(wanted as CFDictionary, &id) == kIOReturnSuccess else { id = 0; return false }
        until = now.addingTimeInterval(seconds)
        return true
    }

    public func stop() {
        if id != 0 { IOPMAssertionRelease(id) }
        id = 0
        until = nil
    }

    public func isOn(now: Date = Date()) -> Bool { until.map { $0 > now } ?? false }
}
