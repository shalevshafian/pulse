import Darwin
import Foundation

public struct ProcInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// What it holds: the footprint, compressed and swapped pages included, for the user's own
    /// processes. The kernel refuses that for everyone else's, and those keep what is resident.
    public var rssBytes: UInt64
    public var cpu: Double
    /// `ps lstart` under LC_ALL=C and TZ=UTC, whitespace-normalised: "Sun Nov 22 11:20:22 2026".
    public var lstart: String
    public var command: String
    /// `ps comm`: the executable alone, whole even when its path has spaces. "" when unknown.
    public var exec: String = ""

    /// Where the program lives, for naming and grouping. The command line is only a
    /// fallback: cut at the first space it turns ".../iOS 26.4.simruntime/..." into "iOS".
    public var program: String { exec.isEmpty ? (command.split(separator: " ").first.map(String.init) ?? command) : exec }
}

public struct ProcTable: Sendable {
    public let all: [ProcInfo]
    public let byPid: [Int32: ProcInfo]
    public let children: [Int32: [Int32]]

    public init(_ procs: [ProcInfo]) {
        all = procs
        byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var kids: [Int32: [Int32]] = [:]
        for p in procs { kids[p.ppid, default: []].append(p.pid) }
        children = kids
    }

    /// The process and everything it spawned (MCP servers, shells, helpers).
    public func tree(of root: Int32) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var stack = [root]
        var seen = Set<Int32>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let p = byPid[pid] else { continue }
            out.append(p)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return out
    }

    public static func parse(_ text: String, execs: String = "", footprint: (Int32) -> UInt64? = { _ in nil }) -> ProcTable {
        var execByPid: [Int32: String] = [:]
        for line in execs.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]) { execByPid[pid] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        var procs: [ProcInfo] = []
        for line in text.split(separator: "\n") {
            // pid ppid rss(KB) %cpu  Www Mmm dd hh:mm:ss yyyy  command...
            let parts = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard parts.count == 10,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let rssKB = UInt64(parts[2]), let cpu = Double(parts[3]) else { continue }
            procs.append(ProcInfo(
                pid: pid, ppid: ppid, rssBytes: footprint(pid) ?? rssKB * 1024, cpu: cpu,
                lstart: parts[4...8].joined(separator: " "),
                command: parts[9].trimmingCharacters(in: .whitespaces), exec: execByPid[pid] ?? ""))
        }
        return ProcTable(procs)
    }

    public static func live() -> ProcTable {
        parse(Shell.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,pcpu=,lstart=,command="]),
              execs: Shell.run("/bin/ps", ["-axo", "pid=,comm="]), footprint: Footprint.read)
    }
}

/// The figure Activity Monitor and `top` call memory.
enum Footprint {
    static func read(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 && info.ri_phys_footprint > 0 ? info.ri_phys_footprint : nil
    }
}

public enum StartTime {
    public static func normalize(_ s: String) -> String {
        // All whitespace: `ps -o lstart= -p` pads the value and ends it with a newline.
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func date(_ lstart: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: normalize(lstart))
    }
}

enum Shell {
    /// Runs a tool that needs the user's own environment (HOME, the Xcode selection).
    /// Returns true when it exits 0 inside the timeout.
    static func succeeds(_ path: String, _ args: [String], timeout: TimeInterval = 30) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    /// Both streams of a tool, or nil when it could not be started or did not finish in time.
    /// The exit code is not judged: `tmutil` says "no destinations" with success, others do not.
    static func output(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = ["LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        var late = false
        let stop = DispatchWorkItem { late = true; p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        return late ? nil : String(decoding: data, as: UTF8.self)
    }

    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // lstart and %cpu must not be localised, and Claude Code records a
        // session's procStart in UTC, so `ps` has to print UTC to compare.
        p.environment = ["LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Memory grouped by the outermost .app bundle a process runs from.
public struct AppGroup: Codable, Sendable, Identifiable {
    public var name: String
    public var bundlePath: String
    public var rssBytes: UInt64
    public var cpu: Double
    public var processCount: Int
    public var id: String { bundlePath }
}

public enum AppGroups {
    static func bundlePath(of command: String) -> String? {
        // A simulator's own apps live inside the runtime, not on this Mac.
        guard !command.contains(".simruntime/"), let r = command.range(of: ".app/") else { return nil }
        return String(command[..<r.lowerBound]) + ".app"
    }

    public static func build(_ table: ProcTable, excluding: Set<Int32> = []) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for p in table.all where !excluding.contains(p.pid) {
            guard let path = bundlePath(of: p.program) else { continue }
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            var g = groups[path] ?? AppGroup(name: name, bundlePath: path, rssBytes: 0, cpu: 0, processCount: 0)
            g.rssBytes += p.rssBytes
            g.cpu += p.cpu
            g.processCount += 1
            groups[path] = g
        }
        return groups.values.sorted { $0.rssBytes > $1.rssBytes }
    }
}
