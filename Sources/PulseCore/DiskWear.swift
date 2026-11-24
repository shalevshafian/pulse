import Foundation
import PulseSMART

/// What the Mac's own SSD says about itself.
public struct DiskWear: Codable, Equatable, Sendable {
    public var criticalWarning: UInt8
    public var spare: Int
    public var spareThreshold: Int
    /// Of its writing life. Goes on past 100.
    public var percentUsed: Int
    public var bytesWritten: UInt64
    public var mediaErrors: UInt64

    /// Nil where there is no NVMe disk inside, or it does not answer.
    public static func read() -> DiskWear? {
        var d = pulse_smart()
        guard pulse_smart_internal(&d) == 0 else { return nil }
        let (bytes, over) = d.units_written.multipliedReportingOverflow(by: 512_000)
        return DiskWear(criticalWarning: d.critical_warning, spare: Int(d.spare), spareThreshold: Int(d.spare_threshold), percentUsed: Int(d.percent_used),
                        bytesWritten: over ? 0 : bytes, mediaErrors: d.media_errors)
    }
}

extension HealthRules {
    /// The spare and its threshold are not compared: Apple's own disks report 99 and 99 when new. The
    /// disk says itself when its spare is too low, in the first bit of the warning.
    static func wear(_ w: DiskWear) -> HealthCheck {
        let written = String(format: "%.1f TB written", Double(w.bytesWritten) / 1e12)
        let life = "How much of the disk's writing life is used."
        func check(_ state: HealthState, _ title: String, _ detail: String, _ weight: Int, _ fix: HealthFix?) -> HealthCheck {
            .init("smart", .storage, state, title, detail, weight: weight, fix: fix)
        }
        // Spare too low, unreliable, read only, its backup power failed. Heat is the second bit.
        if w.criticalWarning & 0b11101 != 0 { return check(.urgent, "The disk reports a fault", "Back up now.", 30, .timeMachine) }
        if w.percentUsed >= 100 { return check(.urgent, "Disk wear \(w.percentUsed)%", life + " It can fail without warning. Back up now.", 15, .timeMachine) }
        if w.mediaErrors > 0 { return check(.attention, "The disk lost data \(Plural.count(Int(clamping: w.mediaErrors), "time"))", "It could not read back what was written. Keep a backup.", 10, .timeMachine) }
        if w.percentUsed >= 80 { return check(.attention, "Disk wear \(w.percentUsed)%", life + " " + written + ".", 8, .timeMachine) }
        if w.criticalWarning & 0b10 != 0 { return check(.attention, "The disk is too hot", "It slows itself down.", 5, nil) }
        return check(.ok, "Disk wear \(w.percentUsed)%", written, 0, nil)
    }
}
