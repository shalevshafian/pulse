import Darwin
import Foundation
import IOKit

/// The graphics chip and the network, for the live strip.
enum GPU {
    /// 0...100, or nil where the driver does not say.
    static func read() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double?
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            guard let d = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let v = percent(d) else { continue }
            best = max(best ?? 0, v)
        }
        return best
    }

    static func percent(_ d: [String: Any]) -> Double? {
        guard let v = (d["Device Utilization %"] as? NSNumber ?? d["GPU Activity(%)"] as? NSNumber)?.doubleValue, v >= 0 else { return nil }
        return min(v, 100)
    }
}

struct NetCounts: Equatable {
    /// Per interface, as the kernel counts: 32 bits that go round.
    var down: [String: UInt32] = [:], up: [String: UInt32] = [:]

    /// The real network ports only. A VPN's tunnel carries the same bytes a second time.
    static func counts(_ name: String) -> Bool { name.hasPrefix("en") }

    static func read() -> NetCounts? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var out = NetCounts()
        var at = first
        while let p = at {
            defer { at = p.pointee.ifa_next }
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = p.pointee.ifa_data else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard counts(name) else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            out.down[name] = d.ifi_ibytes
            out.up[name] = d.ifi_obytes
        }
        return out
    }

    /// Bytes a second since the earlier reading. An interface that was not there before counts from now.
    func rate(since was: NetCounts, seconds: TimeInterval) -> (down: Double, up: Double)? {
        guard seconds > 0.2 else { return nil }
        func sum(_ now: [String: UInt32], _ then: [String: UInt32]) -> Double {
            now.reduce(0) { t, e in t + (then[e.key].map { Double(e.value &- $0) } ?? 0) } / seconds
        }
        return (sum(down, was.down), sum(up, was.up))
    }
}
