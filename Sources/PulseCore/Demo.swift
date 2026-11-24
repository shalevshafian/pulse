import Foundation

/// A made-up Mac, for screenshots and for looking at pages that would be empty on this one.
/// Nothing in it is read from the machine.
public enum Demo {
    public static let system = SystemStats(
        cpuPercent: 23, memUsedBytes: 19 << 30, memTotalBytes: 32 << 30, memPressureLevel: 1, swapUsedBytes: 0,
        diskFreeBytes: 412_000_000_000, diskTotalBytes: 994_000_000_000, thermal: "nominal",
        chipTempC: 54, ssdTempC: 38, batteryTempC: 31)

    public static func snapshot(now: Date = Date()) -> Snapshot {
        func session(_ pid: Int32, _ name: String, _ project: String, _ from: String, idle hours: Double?, _ mb: UInt64, cpu: Double, child: String? = nil) -> ClaudeSession {
            ClaudeSession(pid: pid, sessionId: "\(pid)", name: name, cwd: "/Users/me/Code/" + project, status: hours == nil ? "busy" : "idle",
                          entrypoint: from, procStart: "", statusSince: hours.map { now.addingTimeInterval(-$0 * 3600) },
                          rssBytes: mb << 20, cpu: cpu, processCount: 3, busyChild: child, busyChildCPU: child == nil ? 0 : cpu)
        }
        let sessions = [
            session(1, "Checkout page", "storefront", "cli", idle: nil, 612, cpu: 96),
            session(2, "Flaky upload test", "api", "cli", idle: nil, 438, cpu: 41),
            session(3, "Parser rewrite", "compiler", "claude-desktop", idle: 2, 301, cpu: 74, child: "python3"),
            session(4, "Release notes", "docs", "cli", idle: 14, 318, cpu: 0),
            session(5, "Icon set", "storefront", "claude-desktop", idle: 19, 263, cpu: 0),
        ]
        let root = ProcRef(pid: 90, lstart: "")
        func runtime(_ kind: DevRuntime.Kind, _ name: String, _ mb: UInt64, _ hours: Double, _ pid: Int32) -> DevRuntime {
            DevRuntime(kind: kind, name: name, handle: "demo", rssBytes: mb << 20, cpuPercent: 0.4, corePercent: 4, processCount: 9,
                       upSeconds: hours * 3600, root: ProcRef(pid: pid, lstart: ""), rootExec: "", members: [])
        }
        let runtimes = [runtime(.simulator, "iPhone 17 simulator", 5_240, 16, 91), runtime(.buildDaemon, "Gradle 8.11.1", 2_310, 3, 92)]
        func row(_ kind: Consumer.Kind, _ name: String, _ mb: UInt64, _ cpu: Double, _ n: Int = 1) -> Consumer {
            Consumer(kind: kind, name: name, rssBytes: mb << 20, cpuPercent: cpu, processCount: n, members: [root])
        }
        var consumers = [
            row(.process, "rustc", 1_480, 9.2, 4), row(.session, "Checkout page", 612, 4.8), row(.app, "Safari", 3_120, 3.1, 14),
            row(.session, "Parser rewrite", 301, 2.6), row(.session, "Flaky upload test", 438, 1.9), row(.app, "Xcode", 2_640, 1.4, 6),
            row(.process, "node", 940, 0.9, 5), row(.app, "Mail", 410, 0.3, 2), row(.app, "Music", 380, 0.6), row(.process, "WindowServer", 690, 1.2),
            row(.app, "Finder", 210, 0.2), row(.process, "mds_stores", 180, 0.1), row(.session, "Release notes", 318, 0), row(.session, "Icon set", 263, 0),
            row(.app, "Notes", 240, 0), row(.app, "Terminal", 160, 0.1),
        ]
        consumers += runtimes.map { Consumer(kind: .runtime, name: $0.name, rssBytes: $0.rssBytes, cpuPercent: $0.cpuPercent, processCount: 9, members: [], runtimeID: $0.id) }
        func offer(_ kind: Suggestion.Kind, _ title: String, _ mb: UInt64, hours: Double?, pid: Int32?) -> Suggestion {
            Suggestion(kind: kind, title: title, detail: "", reclaimBytes: mb << 20, pid: pid, procStart: nil,
                       bundlePath: kind == .heavyApp ? "/Applications/\(title).app" : nil, idleSeconds: hours.map { $0 * 3600 })
        }
        var offers = [
            offer(.idleSession, "Icon set", 263, hours: 19, pid: 5), offer(.idleSession, "Release notes", 318, hours: 14, pid: 4),
            offer(.idleSession, "Parser rewrite", 301, hours: 2, pid: 3), offer(.orphan, "node server.js", 42, hours: 5, pid: 6),
            offer(.runtime, "iPhone 17 simulator", 5_240, hours: 16, pid: 91), offer(.runtime, "Gradle 8.11.1", 2_310, hours: 3, pid: 92),
            offer(.heavyApp, "Safari", 3_120, hours: nil, pid: nil),
        ]
        offers[2].stillWorking = true; offers[2].busyChild = "python3"; offers[2].cpuPercent = 7
        offers[4].runtimeKind = .simulator; offers[4].cpuPercent = 0.4
        offers[5].runtimeKind = .buildDaemon
        var snap = Snapshot(system: system, sessions: sessions, apps: [], topCPU: Consumers.topCPU(consumers, 8), topMemory: Consumers.topMemory(consumers, 8),
                            consumers: consumers, runtimes: runtimes, suggestions: offers)
        snap.headline = Insights.headline(snap)
        return snap
    }

    public static func health(now: Date = Date()) -> HealthStore {
        var s = HealthStore()
        s.history = [HealthDay(day: HealthStore.day(now.addingTimeInterval(-5 * 86400)), score: 78, diskFreeBytes: 420_000_000_000)]
        let checks: [HealthCheck] = [
            .init("backup", .backup, .attention, "Last backup was 12 days ago", "Connect the backup disk.", weight: 8, fix: .timeMachine),
            .init("update-macos", .updates, .attention, "Update waiting: macOS 26.7.3", "26.4 is installed. Offered 8 days ago.", weight: 8, fix: .softwareUpdate),
        ] + HealthRules.protection(fileVault: "FileVault is On.", sip: "status: enabled", gatekeeper: "assessments enabled", firewall: "Firewall is enabled.")
            + HealthRules.battery(["AppleRawMaxCapacity": 8110, "DesignCapacity": 8579, "CycleCount": 112])
            + HealthRules.disk(free: system.diskFreeBytes, total: system.diskTotalBytes, smart: "SMART Status: Verified", history: [])
            + HealthRules.stability([], bootedAt: now.addingTimeInterval(-4 * 86400), now: now)
            + HealthRules.performance(system)
            + HealthRules.startup([StartupItem(label: "com.example.helper", program: "/bin/ls", missing: false)], known: nil)
        let cleanup = [
            CleanupItem(title: "Xcode builds", detail: "Rebuilt on the next build", path: "/Users/me/Library/Developer/Xcode/DerivedData", bytes: 18 << 30, blockedBy: "Xcode"),
            CleanupItem(title: "Old build: compiler", detail: "Untouched for 41 days", path: "/Users/me/Code/compiler/target", bytes: 7 << 30, blockedBy: nil),
            CleanupItem(title: "Gradle cache", detail: "Downloaded again on the next build", path: "/Users/me/.gradle/caches", bytes: 4 << 30, blockedBy: nil),
            CleanupItem(title: "npm cache", detail: "Downloaded again on the next install", path: "/Users/me/.npm/_cacache", bytes: 2 << 30, blockedBy: nil),
        ]
        let report = HealthReport(takenAt: now.addingTimeInterval(-40 * 60), checks: checks,
                                  startup: [StartupItem(label: "com.example.helper", program: "/bin/ls", missing: false)], cleanup: cleanup)
        s.absorb(report, diskFree: system.diskFreeBytes, now: now)
        return s
    }
}
