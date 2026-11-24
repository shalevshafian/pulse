import Foundation
import IOKit

// Apple publishes no temperature API. These are the HID thermal sensors the system
// itself reads; they need no admin rights. If a macOS update removes them, the
// readings come back nil and the panel simply hides the line.
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ s: AnyObject, _ t: Int64, _ o: Int32, _ x: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ e: AnyObject, _ f: Int32) -> Double

public struct Temperatures: Sendable {
    /// Hottest point on the chip.
    public var chip: Double?
    public var ssd: Double?
    public var battery: Double?
}

public final class ThermalSensors {
    private let client: AnyObject
    private var services: [(name: String, service: AnyObject)] = []

    public init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        services = all.map {
            (IOHIDServiceClientCopyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String ?? "", $0)
        }
    }

    public func read() -> Temperatures {
        var named: [(String, Double)] = []
        for (name, service) in services {
            guard let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0)?.takeRetainedValue() else { continue }
            named.append((name, IOHIDEventGetFloatValue(event, 15 << 16)))
        }
        return Self.pick(named)
    }

    /// Sensors that are not wired up report nonsense (around -9200), so anything
    /// outside a believable range is dropped before picking.
    static func pick(_ named: [(String, Double)]) -> Temperatures {
        let ok = named.filter { $0.1 > 0 && $0.1 < 130 }
        func hottest(_ match: (String) -> Bool) -> Double? { ok.filter { match($0.0) }.map(\.1).max() }
        return Temperatures(
            chip: hottest { $0.hasPrefix("PMU tdie") } ?? hottest { $0.lowercased().contains("soc") || $0.hasPrefix("pACC") || $0.hasPrefix("eACC") },
            ssd: hottest { $0.hasPrefix("NAND") },
            battery: hottest { $0.lowercased().contains("battery") })
    }
}
