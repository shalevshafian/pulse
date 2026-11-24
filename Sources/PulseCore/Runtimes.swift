import Foundation

/// A development runtime that keeps a lot of memory while nobody looks at it: a booted
/// iOS simulator, an Android emulator, a Gradle or Kotlin build daemon. Each is one
/// process tree, found in the `ps` table alone (no `simctl list`, no `adb devices`).
public struct DevRuntime: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case simulator, emulator, buildDaemon }
    public var kind: Kind
    /// As shown: "iPhone 17 simulator", "Pixel_8 emulator", "Gradle 8.11.1".
    public var name: String
    /// What the shutdown command needs: the simulator's UDID, the emulator's serial, or "".
    public var handle: String
    public var rssBytes: UInt64
    /// Share of the whole machine, 0...100.
    public var cpuPercent: Double
    /// Percent of one core, the whole tree. A build or a test run shows here, not in the machine share.
    public var corePercent: Double = 0
    /// Building or running something right now: closing it would break that work.
    public var working: Bool { corePercent >= ClaudeSession.workingCPU }
    public var processCount: Int
    public var upSeconds: TimeInterval
    public var root: ProcRef
    /// Executable of the root, to find `adb` beside the emulator.
    public var rootExec: String
    public var members: [ProcRef]
    public var id: String { "runtime:\(root.pid)" }
}

public enum Runtimes {
    public static func detect(
        table: ProcTable, cores: Int = ProcessInfo.processInfo.activeProcessorCount, now: Date = Date(),
        simulatorName: (String) -> String? = Runtimes.simulatorName
    ) -> [DevRuntime] {
        var out: [DevRuntime] = []
        var taken = Set<Int32>()

        func add(_ kind: DevRuntime.Kind, _ name: String, _ handle: String, _ p: ProcInfo) {
            let tree = table.tree(of: p.pid).filter { !taken.contains($0.pid) }
            taken.formUnion(tree.map(\.pid))
            out.append(DevRuntime(
                kind: kind, name: name, handle: handle,
                rssBytes: tree.reduce(0) { $0 + $1.rssBytes },
                cpuPercent: tree.reduce(0) { $0 + $1.cpu } / Double(max(cores, 1)),
                corePercent: tree.reduce(0) { $0 + $1.cpu },
                processCount: tree.count,
                upSeconds: StartTime.date(p.lstart).map { max(0, now.timeIntervalSince($0)) } ?? 0,
                root: ProcRef(pid: p.pid, lstart: p.lstart), rootExec: p.exec,
                members: tree.map { ProcRef(pid: $0.pid, lstart: $0.lstart) }))
        }

        // The program itself must be java: a shell whose command line merely quotes the
        // class name (a grep, a script) is not a daemon and must not get a close control.
        func isJava(_ p: ProcInfo) -> Bool { (p.program as NSString).lastPathComponent == "java" }

        // Gradle first: its Kotlin daemon is its child and belongs to the same row.
        for p in table.all where isJava(p) && p.command.contains("org.gradle.launcher.daemon.bootstrap.GradleDaemon") {
            add(.buildDaemon, "Gradle" + (gradleVersion(p.command).map { " " + $0 } ?? ""), "", p)
        }
        for p in table.all where !taken.contains(p.pid) {
            let words = p.command.split(separator: " ").map(String.init)
            let program = ((p.exec.isEmpty ? words.first ?? "" : p.exec) as NSString).lastPathComponent
            if program == "launchd_sim", let udid = simulatorUDID(p.command) {
                add(.simulator, (simulatorName(udid) ?? String(udid.prefix(8))) + " simulator", udid, p)
            } else if program.hasPrefix("qemu-system-"), let avd = value(after: "-avd", in: words) {
                add(.emulator, avd + " emulator", value(after: "-port", in: words).map { "emulator-" + $0 } ?? "", p)
            } else if isJava(p), p.command.contains("org.jetbrains.kotlin.daemon.KotlinCompileDaemon") {
                add(.buildDaemon, "Kotlin daemon", "", p)
            }
        }
        return out.sorted { $0.rssBytes > $1.rssBytes }
    }

    static func value(after flag: String, in words: [String]) -> String? {
        guard let i = words.firstIndex(of: flag), i + 1 < words.count else { return nil }
        return words[i + 1]
    }

    static func simulatorUDID(_ command: String) -> String? {
        guard let r = command.range(of: "/CoreSimulator/Devices/") else { return nil }
        let id = command[r.upperBound...].prefix { $0 != "/" }
        return id.count == 36 ? String(id) : nil
    }

    static func gradleVersion(_ command: String) -> String? {
        guard let r = command.range(of: "gradle-daemon-main-") else { return nil }
        let v = command[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        let trimmed = v.hasSuffix(".") ? v.dropLast() : v
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    /// The name the user gave the simulator, from its own `device.plist`.
    public static func simulatorName(_ udid: String) -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/device.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["name"] as? String
    }

    /// How a runtime is shut down when the user asks: its own tool where there is one
    /// (the simulator and emulator save their state), a plain SIGTERM otherwise.
    public enum Shutdown: Equatable {
        case command(path: String, args: [String])
        case signal
    }

    public static func shutdown(for r: DevRuntime, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Shutdown {
        switch r.kind {
        case .simulator where !r.handle.isEmpty:
            return .command(path: "/usr/bin/xcrun", args: ["simctl", "shutdown", r.handle])
        case .emulator where !r.handle.isEmpty:
            // <sdk>/emulator/qemu/<arch>/qemu-system-…  →  <sdk>/platform-tools/adb
            var sdk = URL(fileURLWithPath: r.rootExec)
            for _ in 0..<4 { sdk.deleteLastPathComponent() }
            let adb = sdk.appendingPathComponent("platform-tools/adb").path
            return fileExists(adb) ? .command(path: adb, args: ["-s", r.handle, "emu", "kill"]) : .signal
        default:
            return .signal
        }
    }
}
