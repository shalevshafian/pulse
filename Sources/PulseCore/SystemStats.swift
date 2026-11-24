import Darwin
import Foundation

public struct SystemStats: Codable, Sendable {
    public var cpuPercent: Double
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    public var memPressureLevel: Int
    public var swapUsedBytes: UInt64
    public var diskFreeBytes: UInt64
    public var diskTotalBytes: UInt64
    public var thermal: String
    /// Hottest point on the chip, in °C. Nil when the sensors are not readable.
    public var chipTempC: Double? = nil
    public var ssdTempC: Double? = nil
    public var batteryTempC: Double? = nil
    public var gpuPercent: Double? = nil
    /// Bytes a second over the last reading. Nil until there are two.
    public var netDown: Double? = nil
    public var netUp: Double? = nil

    public var memPercent: Double {
        memTotalBytes == 0 ? 0 : Double(memUsedBytes) / Double(memTotalBytes) * 100
    }
    public var diskUsedPercent: Double {
        diskTotalBytes == 0 ? 0 : Double(diskTotalBytes - min(diskFreeBytes, diskTotalBytes)) / Double(diskTotalBytes) * 100
    }

    public static let empty = SystemStats(
        cpuPercent: 0, memUsedBytes: 0, memTotalBytes: 0, memPressureLevel: 1,
        swapUsedBytes: 0, diskFreeBytes: 0, diskTotalBytes: 0, thermal: "nominal")
}

struct CPUTicks {
    var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    var busy: UInt64 { user + system + nice }
    var total: UInt64 { busy + idle }
}

/// Holds the previous CPU tick reading, so CPU load is a delta between two samples.
public final class SystemSampler {
    private var last: CPUTicks?
    private let sensors = ThermalSensors()
    private var lastNet: (counts: NetCounts, at: TimeInterval)?

    public init() {}

    /// The first call has nothing to diff against and reports CPU as 0.
    public func sample() -> SystemStats {
        var stats = SystemStats.empty
        if let now = Self.readTicks() {
            if let last, now.total > last.total {
                stats.cpuPercent = Double(now.busy - last.busy) / Double(now.total - last.total) * 100
            }
            last = now
        }
        Self.fillMemory(&stats)
        Self.fillDisk(&stats)
        let temps = sensors.read()
        stats.chipTempC = temps.chip
        stats.ssdTempC = temps.ssd
        stats.batteryTempC = temps.battery
        stats.gpuPercent = GPU.read()
        if let net = NetCounts.read() {
            let at = ProcessInfo.processInfo.systemUptime
            if let lastNet, let r = net.rate(since: lastNet.counts, seconds: at - lastNet.at) { stats.netDown = r.down; stats.netUp = r.up }
            lastNet = (net, at)
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: stats.thermal = "nominal"
        case .fair: stats.thermal = "fair"
        case .serious: stats.thermal = "serious"
        case .critical: stats.thermal = "critical"
        @unknown default: stats.thermal = "unknown"
        }
        return stats
    }

    /// For one-shot callers (the MCP server). The kernel's tick counters advance in
    /// steps, so wait until they have actually moved instead of trusting a fixed sleep.
    public func sampleBlocking(timeout: TimeInterval = 2) -> SystemStats {
        _ = sample()
        let start = last?.total ?? 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            if let now = Self.readTicks(), now.total >= start + 20 { break }
        }
        return sample()
    }

    static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    static func fillMemory(_ stats: inout SystemStats) {
        stats.memTotalBytes = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            // Same sum Activity Monitor calls "Memory Used": app memory + wired + compressed.
            let app = UInt64(vm.internal_page_count) - min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
            stats.memUsedBytes = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            stats.memPressureLevel = Int(level)
        }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            stats.swapUsedBytes = swap.xsu_used
        }
    }

    static func fillDisk(_ stats: inout SystemStats) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        if let v = try? url.resourceValues(forKeys: keys) {
            stats.diskTotalBytes = UInt64(v.volumeTotalCapacity ?? 0)
            stats.diskFreeBytes = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0))
        }
    }
}
