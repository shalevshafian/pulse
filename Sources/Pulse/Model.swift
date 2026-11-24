import AppKit
import Foundation
import QuartzCore
import PulseCore
import ServiceManagement
import UserNotifications

enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let site = URL(string: "https://github.com/shalevshafian/pulse")!
    static let releases = URL(string: "https://github.com/shalevshafian/pulse/releases")!

    /// How an agent reaches this copy of Pulse.
    static var mcpCommand: String {
        "claude mcp add --scope user pulse -- \"\(Bundle.main.executablePath ?? "/Applications/Pulse.app/Contents/MacOS/Pulse")\" --mcp"
    }

    /// Run from the disk image or Downloads, macOS may open it from a read-only copy that is gone tomorrow.
    static var isInApplications: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

final class Model: ObservableObject {
    /// The menu bar app's one model. Renders and the bench make their own.
    static let shared = Model()

    /// Without Claude Code on this Mac the panel does not speak about sessions.
    let hasClaude: Bool
    @Published var system = SystemStats.empty
    @Published var snap: Snapshot?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var result: OptimizeResult?
    /// One line of feedback after a manual close or a settings action.
    @Published var notice: String?
    @Published var settings: Settings {
        didSet {
            guard live, writes, settings != oldValue else { return }
            settings.save()
            driveGuard?.setWanted(settings.sleepDrives)
        }
    }
    /// External drives for the drives page, and what Pulse disconnected and still owes.
    @Published var drives: [DriveGuard.Row]?
    @Published var drivesOut: [SleepDrive] = []
    private var driveGuard: DriveGuard?
    /// The largest folders of the Library, kept for an hour.
    @Published var largest: LargeFolders?
    private var measuredAt = Date.distantPast
    private var measuring = false
    private var appNames: [String: String] = [:]
    @Published var lastSleep: SleepRecord?
    /// The last two minutes, as fractions 0...1, for the graphs.
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var tempHistory: [Double] = []
    @Published var notificationsAllowed: Bool?

    /// What the health checks found, and whether one is running.
    @Published var health = HealthStore.load()
    @Published var checking = false
    @Published var cleaning = false
    /// The body of dots. Not published: its view reads it every frame.
    let sceneBox = SceneBox()
    var scene: BodyScene {
        get { sceneBox.get() }
        set { sceneBox.set(newValue) }
    }
    var drawsLive: Bool { live }
    private var sceneStep = 0
    /// The display's own clock: what the drawing thread is told to draw for.
    static var clock: Double { CACurrentMediaTime() }

    /// While the panel is open the process list refreshes faster.
    private(set) var panelOpen = false
    private var openingDue = false

    /// The body's window came on screen or left it. This, not `onAppear`, says the panel is open.
    func bodyVisible(_ on: Bool) {
        if on {
            opened()
            // Once per opening: coming back from another page does not replay it.
            guard openingDue else { return }
            openingDue = false
            var s = scene
            s.shape = .scatter
            s.go(.sphere, at: Self.clock)
            scene = s
        } else {
            closed()
        }
    }

    func opened() {
        guard !panelOpen else { return }
        panelOpen = true
        openingDue = true
        if writes { FrameMeter.begin() }
        syncScene()
        refreshSnapshot()
    }

    func closed() {
        guard panelOpen else { return }
        panelOpen = false
        if writes { FrameMeter.end() }
        sceneStep += 1
        var s = scene
        s.pointer = nil
        s.setFocus(nil, at: Self.clock)
        if s.shape != .sphere { s.go(.sphere, at: Self.clock) }
        scene = s
    }

    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "pulse.snapshot", qos: .utility)
    private let healthQueue = DispatchQueue(label: "pulse.health", qos: .utility)
    private let sampleQueue = DispatchQueue(label: "pulse.sample", qos: .utility)
    private var sampling = false
    private var timer: Timer?
    private var ticks = 0
    private var refreshing = false
    private var alerts = AlertEngine()
    private let live: Bool

    /// Notifications need a real app bundle; the bare binary used by tests and `--render` has none.
    private var canNotify: Bool { live && writes && Bundle.main.bundleIdentifier != nil }

    /// False only in the frame bench: everything runs, nothing is stored or announced.
    private let writes: Bool

    init(live: Bool = true, writes: Bool = true) {
        self.live = live
        self.writes = writes
        settings = Settings.load()
        hasClaude = FileManager.default.fileExists(atPath: ClaudeSessions.defaultDir.path) || CommandLine.arguments.contains("--demo")
        _ = sampler.sample()
        guard live else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refreshSnapshot()
        startDriveGuard()
        if canNotify, settings.welcomed, settings.anyAlert || (hasClaude && settings.alertWaiting) { requestNotifications() }
    }

    /// Reading the sensors takes up to a tenth of a second: never on the main thread.
    private func tick() {
        guard !sampling else { return }
        sampling = true
        sampleQueue.async {
            let reading = self.sampler.sample()
            DispatchQueue.main.async {
                self.sampling = false
                self.apply(reading)
            }
        }
    }

    private func apply(_ reading: SystemStats) {
        system = reading
        push(&cpuHistory, system.cpuPercent / 100)
        push(&memHistory, system.memPercent / 100)
        if let t = system.chipTempC { push(&tempHistory, Self.tempFraction(t)) }
        scene.setLoad(system.cpuPercent / 100, at: Self.clock)
        ticks += 1
        // A minute after launch, then whenever the last check is six hours old.
        if ticks % 30 == 0, !checking, healthAge(now: Date()) >= Self.checkEvery { runHealthCheck() }
        // `ps` every 4s with the panel open, every 20s otherwise.
        if ticks % (panelOpen ? 2 : 10) == 0 { refreshSnapshot() }
    }

    private func push(_ list: inout [Double], _ value: Double) {
        list.append(min(max(value, 0), 1))
        if list.count > 60 { list.removeFirst(list.count - 60) }
    }

    /// 35° (cool, idle) to 100° (the chip starts throttling).
    static func tempFraction(_ c: Double) -> Double { min(max((c - 35) / 65, 0), 1) }

    func refreshSnapshot() {
        guard live, !refreshing else { return }
        refreshing = true
        let system = self.system
        let settings = self.settings
        queue.async {
            let snap = Snapshot.take(system: system, settings: settings)
            DispatchQueue.main.async {
                self.snap = snap
                self.refreshing = false
                self.checkAlerts(snap)
            }
        }
    }

    /// For `--render --demo`: nothing is read from this Mac.
    func loadDemo() {
        settings = Settings()
        settings.neverTouch = ["Docker", "qemu"]
        settings.includeLeftovers = true
        system = Demo.system
        snap = Demo.snapshot()
        health = Demo.health()
        lastSleep = Demo.lastSleep()
        largest = Demo.largest()
        syncScene()
        result = OptimizeResult(lines: [
            .init(text: "Closed: Icon set", ok: true), .init(text: "Closed: Release notes", ok: true),
            .init(text: "Not closed (the process changed): node server.js", ok: false),
        ], memBefore: 19 << 30, memAfter: 18 << 30)
    }

    /// The last page of the welcome.
    func finishWelcome(notify: Bool, atLogin: Bool) {
        if atLogin != launchAtLogin { setLaunchAtLogin(atLogin) }
        if notify { requestNotifications() } else {
            settings.alertCPU = false; settings.alertTemp = false; settings.alertMemory = false; settings.alertHealth = false; settings.alertWaiting = false
        }
        settings.welcomed = true
        runHealthCheck(shown: true)
    }

    /// For `--render`: one synchronous reading, no timers.
    func loadOnce() {
        system = sampler.sampleBlocking()
        snap = Snapshot.take(system: system, settings: settings)
    }

    // MARK: Health

    static let checkEvery: TimeInterval = 6 * 3600

    func healthAge(now: Date) -> TimeInterval { health.report.map { now.timeIntervalSince($0.takenAt) } ?? .infinity }

    func syncScene() { scene.areas = HealthArea.allCases.map { health.state(of: $0) } }

    private func changeHealth(_ change: (inout HealthStore) -> Void) {
        change(&health)
        if live, writes { health.save() }
        syncScene()
    }

    /// Reads the whole Mac off the main thread. `shown` is the user's own press: it ends
    /// with the score written in dots.
    func runHealthCheck(shown: Bool = false) {
        guard live, !checking else { return }
        checking = true
        scene.startCheck(at: Self.clock)
        sceneStep += 1
        if scene.shape != .sphere { scene.go(.sphere, at: Self.clock) }
        let system = self.system, store = health, settings = self.settings, started = Date()
        healthQueue.async {
            let report = HealthProbe.take(system: system, store: store, settings: settings)
            // Long enough to be seen when asked for; a check in the background does not wait.
            let rest = shown ? max(0, 1.5 - Date().timeIntervalSince(started)) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + rest) {
                self.changeHealth { $0.absorb(report, diskFree: system.diskFreeBytes, now: Date()) }
                self.checking = false
                self.scene.endCheck(at: Self.clock)
                if shown { self.play([(.text("\(self.health.score ?? 0)"), 2.0), (.sphere, 0)]) }
                self.announceHealth()
            }
        }
    }

    /// Shapes one after another, each held for its seconds. A newer sequence replaces an older one.
    private func play(_ steps: [(BodyScene.Shape, Double)]) {
        sceneStep += 1
        let mine = sceneStep
        var at = 0.0
        for (shape, hold) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                if self.sceneStep == mine { self.scene.go(shape, at: Self.clock) }
            }
            at += hold
        }
    }

    private func announceHealth() {
        var fresh: [HealthCheck] = []
        changeHealth { fresh = $0.takeNew(now: Date()) }
        guard settings.alertHealth, !fresh.isEmpty else { return }
        post(PulseAlert(key: "health", title: fresh.count == 1 ? fresh[0].title : "\(fresh.count) new findings on this Mac",
                        body: fresh.count == 1 ? fresh[0].detail : fresh.prefix(3).map(\.title).joined(separator: " · ")))
    }

    /// For `--render`: a check that is not stored.
    func checkOnce() {
        health.absorb(HealthProbe.take(system: system, store: health, settings: settings), diskFree: system.diskFreeBytes, now: Date())
        syncScene()
    }

    func ignore(_ c: HealthCheck, _ on: Bool) {
        changeHealth { s in
            s.ignored.removeAll { $0 == c.id }
            if on { s.ignored.append(c.id) }
        }
    }

    /// Opens the page in System Settings, or accepts what was found. Changes nothing on the Mac.
    func fix(_ f: HealthFix) {
        if let url = f.settingsURL.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        } else if f == .acceptStartup {
            changeHealth { s in
                s.knownStartup = s.report?.startup.map(\.label)
                s.report?.checks.removeAll { $0.id == "startup-new" }
                if let r = s.report, !r.checks.contains(where: { $0.area == .startup }) {
                    s.report?.checks.append(.init("startup", .startup, .ok, "Startup items unchanged", Plural.count(r.startup.count, "item")))
                }
            }
        }
    }

    /// Only from the cleanup page, only what was ticked there. Everything goes to the Trash.
    func clean(_ items: [CleanupItem]) {
        guard live, !cleaning, !items.isEmpty else { return }
        cleaning = true
        notice = nil
        let settings = self.settings
        healthQueue.async {
            let table = ProcTable.live()
            let moved = items.filter { Cleanup.trash($0, table: table, settings: settings) }
            DispatchQueue.main.async {
                self.cleaning = false
                self.changeHealth { s in s.report?.cleanup.removeAll { i in moved.contains { $0.path == i.path } } }
                let bytes = moved.reduce(0) { $0 + $1.bytes }
                self.notice = moved.count == items.count ? "\(Fmt.bytes(bytes)) moved. Empty the Trash to free the space."
                    : "\(moved.count) of \(items.count) moved to the Trash. The rest are in use or changed."
                if !moved.isEmpty { self.play([(.burst, 0.45), (.tick, 1.6), (.sphere, 0)]) }
            }
        }
    }

    /// When the cleanup page opens: ten seconds of reading folder sizes, off the main thread.
    func measureLibrary() {
        guard live, !measuring, Date().timeIntervalSince(measuredAt) > 3600 else { return }
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let found = LargeFolders.find()
            DispatchQueue.main.async {
                self.measuring = false
                self.measuredAt = Date()
                self.largest = found
            }
        }
    }

    /// The app a folder belongs to, when its name is a bundle identifier.
    func appName(ofFolder name: String) -> String? {
        guard live, name.contains(".") else { return nil }
        if let known = appNames[name] { return known.isEmpty ? nil : known }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
        appNames[name] = url?.deletingPathExtension().lastPathComponent ?? ""
        return url?.deletingPathExtension().lastPathComponent
    }

    // MARK: Menu bar text

    var barText: String {
        var parts: [String] = []
        if settings.barCPU { parts.append(String(format: "%.0f%%", system.cpuPercent)) }
        if settings.barMemory { parts.append(String(format: "%.0f%%", system.memPercent)) }
        if settings.barTemp, let t = system.chipTempC { parts.append(String(format: "%.0f°", t)) }
        if settings.barSessions { parts.append("#\(snap?.sessions.count ?? 0)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Optimize. Nothing runs before the user has seen the plan and pressed the button.

    struct ResultLine: Identifiable {
        let id = UUID()
        let text: String
        let ok: Bool
    }

    struct OptimizeResult {
        var lines: [ResultLine]
        var memBefore: UInt64
        var memAfter: UInt64?
        /// Shutting a simulator down takes seconds; the page says so meanwhile.
        var running = false
    }

    /// The rows the plan starts with ticked, by the user's rules.
    func defaultSelection() -> Set<String> {
        Set((snap?.suggestions ?? []).filter { settings.preselects($0) }.map(\.id))
    }

    func run(_ items: [Suggestion]) {
        let before = system.memUsedBytes
        let runtimes = snap?.runtimes ?? []
        let settings = self.settings
        result = OptimizeResult(lines: [], memBefore: before, memAfter: nil, running: true)
        // Off the main thread: `simctl shutdown` and `adb emu kill` take seconds.
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [ResultLine] = []
            for s in items {
                switch s.kind {
                case .idleSession:
                    let ok = s.pid.map { Actions.closeIdleSession(pid: $0) } ?? false
                    lines.append(ResultLine(text: ok ? "Closed: \(s.title)" : "Not closed (no longer idle): \(s.title)", ok: ok))
                case .orphan:
                    let ok = (s.pid != nil && s.procStart != nil) && Actions.terminate(pid: s.pid!, expectedStart: s.procStart!)
                    lines.append(ResultLine(text: ok ? "Closed: \(s.title)" : "Not closed (the process changed): \(s.title)", ok: ok))
                case .runtime:
                    let ok = runtimes.first { $0.id == s.runtimeID }.map { Actions.close($0, settings: settings) } ?? false
                    lines.append(ResultLine(text: ok ? "Shut down: \(s.title)" : "Not shut down (changed, or it failed): \(s.title)", ok: ok))
                case .heavyApp:
                    let ok = DispatchQueue.main.sync { self.quitApp(at: s.bundlePath) }
                    lines.append(ResultLine(text: ok ? "Asked to quit: \(s.title)" : "Not found: \(s.title)", ok: ok))
                case .advice:
                    break
                }
            }
            DispatchQueue.main.async {
                self.result = OptimizeResult(lines: lines, memBefore: before, memAfter: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.result?.memAfter = self.system.memUsedBytes
                    self.refreshSnapshot()
                }
            }
        }
    }

    // MARK: Manual close. Reached only from the second press on that row.

    func mayClose(_ c: Consumer) -> Bool { Actions.mayClose(c, settings: settings) }

    /// True when closing this app would take live Claude sessions down with it.
    func hostsSessions(_ c: Consumer) -> Bool {
        c.kind == .app && c.bundlePath.map { snap?.sessionHosts.contains($0) ?? false } == true
    }

    func close(_ c: Consumer) {
        guard mayClose(c) else {
            notice = "\(c.name) is protected and was not closed"
            return
        }
        if c.kind == .runtime {
            guard let r = snap?.runtimes.first(where: { $0.id == c.runtimeID }) else { return }
            let settings = self.settings
            notice = "Shutting down \(c.name)…"
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = Actions.close(r, settings: settings)
                DispatchQueue.main.async {
                    self.notice = ok ? "Shut down: \(c.name)" : "Not shut down: \(c.name) (changed, or it failed)"
                    self.refreshSnapshot()
                }
            }
            return
        }
        if c.kind == .app, quitApp(at: c.bundlePath) {
            notice = "Asked to quit: \(c.name)"
        } else {
            let n = Actions.close(c, settings: settings)
            notice = n == 0 ? "Not closed: \(c.name) (no permission, or it changed)"
                : n == 1 ? "Closed: \(c.name)" : "Closed \(n) processes of \(c.name)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.refreshSnapshot() }
    }

    private func quitApp(at bundlePath: String?) -> Bool {
        guard let bundlePath else { return false }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }?.terminate() ?? false
    }

    /// Brings the app a session runs in to the front. The app only: choosing the tab inside it
    /// would need permission to control that app. The system may refuse.
    func showHost(of s: ClaudeSession) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        guard let app = (s.hosts ?? []).lazy.compactMap({ path in apps.first { $0.bundleURL?.path == path } }).first else {
            notice = "Could not find the app it runs in"
            return
        }
        NSApp.yieldActivation(to: app)
        if !app.activate() { notice = "Could not open it" }
    }

    // MARK: Drives. Nothing is ticked until the user ticks it, and nothing is forced.

    private func startDriveGuard() {
        // The installed app only: a bench or a render must not answer the Mac's sleep.
        guard canNotify else { return }
        let g = DriveGuard()
        g.setWanted(settings.sleepDrives)
        g.onRefused = { [weak self] list in
            DispatchQueue.main.async {
                for r in list {
                    self?.post(PulseAlert(key: "drive:" + r.drive.id, title: "\(r.drive.name) was not disconnected",
                                          body: r.holders.isEmpty ? "Something is using it. Do not pull the cable." : "In use by \(r.holders.prefix(3).joined(separator: ", ")). Do not pull the cable."))
                }
            }
        }
        g.onStillOut = { [weak self] list in
            DispatchQueue.main.async {
                for d in list {
                    self?.post(PulseAlert(key: "driveout:" + d.id, title: "\(d.name) did not come back", body: "It is plugged in but did not mount. Try again on the drives page."))
                }
            }
        }
        g.onChange = { [weak self] in DispatchQueue.main.async { self?.refreshDrives() } }
        g.start()
        driveGuard = g
    }

    func refreshDrives() {
        driveGuard?.rows(settings.sleepDrives) { [weak self] rows, out in
            self?.drives = rows
            self?.drivesOut = out
        }
    }

    func refreshSleep() {
        guard live else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            // A desktop Mac has no charge to lose.
            let last = Charge.read() == nil ? nil : SleepCost.load().last(now: Date())
            DispatchQueue.main.async { self.lastSleep = last }
        }
    }

    func connectDrives() { driveGuard?.connectNow() }

    func setDrive(_ row: DriveGuard.Row, _ on: Bool) {
        settings.sleepDrives.removeAll { $0.id == row.id }
        if on {
            settings.sleepDrives.append(SleepDrive(id: row.id, name: row.name))
            requestNotifications()
        }
        refreshDrives()
    }

    /// For `--render`: reads the drives once and registers nothing.
    func loadDrivesOnce(demo: Bool) {
        if !demo {
            let ops = DiskArbitrationOps()
            drives = ops.volumes().map {
                .init(id: $0.id, name: $0.name, bytes: $0.bytes, mounted: $0.path != nil, attached: true, holders: $0.path.map(ops.holders) ?? [])
            }
            return
        }
        drives = [
            .init(id: "a", name: "Samples SSD", bytes: 2_000_000_000_000, mounted: true, attached: true, holders: []),
            .init(id: "b", name: "Projects", bytes: 1_000_000_000_000, mounted: true, attached: true, holders: ["Logic Pro"]),
            .init(id: "c", name: "Archive", bytes: 4_000_000_000_000, mounted: false, attached: true, holders: []),
            .init(id: "e", name: "Scratch", bytes: 500_000_000_000, mounted: true, attached: true, holders: []),
            .init(id: "d", name: "Travel", bytes: nil, mounted: false, attached: false, holders: []),
        ]
        settings.sleepDrives = ["a", "b", "c", "d"].map { SleepDrive(id: $0, name: $0) }
        drivesOut = [SleepDrive(id: "c", name: "Archive")]
    }

    // MARK: Alerts

    func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { ok, _ in
            DispatchQueue.main.async { self.notificationsAllowed = ok }
        }
    }

    private func checkAlerts(_ snap: Snapshot) {
        let due = alerts.evaluate(system: system, consumers: snap.consumers, sessions: snap.sessions, settings: settings, now: Date())
        due.forEach(post)
    }

    func sendTestAlert() {
        post(PulseAlert(key: "test", title: "Pulse", body: "This is how an alert looks."))
        notice = canNotify ? "Test alert sent" : "Alerts only work from the installed app"
    }

    private func post(_ alert: PulseAlert) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // No sound: alerts stay silent unless the user asks otherwise.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.key, content: content, trigger: nil))
    }

    // MARK: Login item

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = "Open at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    /// A drive's size as it is sold, in thousands.
    static func drive(_ b: UInt64) -> String {
        let gb = Double(b) / 1e9
        return gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb)
    }

    static func degrees(_ c: Double) -> String { String(format: "%.0f°C", c) }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1)) min" }
        let h = m / 60
        if h < 48 { return "\(h) h" }
        return "\(h / 24) days"
    }
}
