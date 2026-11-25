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
        "claude mcp add --scope user pulse -- \"\(executable)\" --mcp"
    }

    static var executable: String { Bundle.main.executablePath ?? "/Applications/Pulse.app/Contents/MacOS/Pulse" }

    /// For Codex: its own file, ~/.codex/config.toml. TOML strings take the path as it is, quoted.
    static var codexConfig: String {
        "[mcp_servers.pulse]\ncommand = \"\(executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nargs = [\"--mcp\"]\n"
    }

    static var mcpJSON: String {
        let server: [String: Any] = ["command": executable, "args": ["--mcp"]]
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["pulse": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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
    @Published var plan: [PlanUsage] = []
    /// The last twelve hours, while the panel is open. The history itself belongs to `queue`.
    @Published var past: [LoadHistory.Row] = []
    @Published var pastSince: Date?
    /// The row whose page is open, and its CPU time over the twelve hours.
    @Published var series: [Double?] = []
    private var seriesOf: String?
    private var history = LoadHistory()
    /// What the optimizer learned: habits, choices, how promises came out. Belongs to `queue`.
    private var learned = OptimizerMemory()
    /// The state of memory with its minute of readings. Main thread.
    private var tracker = PressureTracker()
    private var noteSaved = Date.distantPast
    private var noteState = MemoryState.calm
    /// What the optimizer says about the newest snapshot.
    @Published var verdict: Verdict?
    /// Compressed memory per process and programs with clients, read when the plan opens. Belong to `queue`.
    private var compressed: (at: Date, map: [Int32: UInt64]?)?
    private var served: Set<Int32>?
    /// The last few readings of memory in use, for a before that one moment cannot skew.
    private var usedRecent: [UInt64] = []
    private var historySaved = Date()
    private var appNames: [String: String] = [:]
    @Published var lastSleep: SleepRecord?
    /// Programs that listen, read when a page that shows them opens.
    @Published var ports: [OpenPort]?
    @Published private(set) var receipts = Receipts()
    @Published private(set) var awakeUntil: Date?
    private let awake = KeepAwake()
    private var chosenHours = 0.0
    /// The last two minutes, as fractions 0...1, for the graphs.
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var tempHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    /// Against the busiest moment of the last two minutes: a network has no full.
    var netHistory: [Double] {
        let top = max(netRates.max() ?? 0, 100_000)
        return netRates.map { $0 / top }
    }
    @Published private var netRates: [Double] = []
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
        refreshPlan()
        refreshDrives()
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
        if canNotify { queue.async { self.history = LoadHistory.load(); self.learned = OptimizerMemory.load() } }
        if writes { receipts = Receipts.load() }
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
        usedRecent = Array((usedRecent + [system.memUsedBytes]).suffix(30))
        if let vm = reading.vm { tracker.add(vm, level: reading.memPressureLevel, at: ProcessInfo.processInfo.systemUptime) }
        // For the MCP server: a minute's state, written when it changes and once a minute.
        if canNotify, tracker.state != noteState || Date().timeIntervalSince(noteSaved) >= 60 {
            noteState = tracker.state
            noteSaved = Date()
            let note = self.note
            queue.async { note.save() }
        }
        if let t = system.chipTempC { push(&tempHistory, Self.tempFraction(t)) }
        if let g = system.gpuPercent { push(&gpuHistory, g / 100) }
        if let d = system.netDown, let u = system.netUp { netRates = Array((netRates + [d + u]).suffix(60)) }
        if let until = awakeUntil, until <= Date() { awakeUntil = nil; awake.stop() }
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
        let open = panelOpen, keep = canNotify, wanted = seriesOf
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path, note = self.note
        queue.async {
            var snap = Snapshot.take(system: system, settings: settings)
            let now = Date()
            self.history.add(snap.consumers, at: now)
            self.learned.returns.tick(uptime: ProcessInfo.processInfo.systemUptime)
            Optimizer.observe(snap, frontmost: front, into: &self.learned.returns, now: now)
            // What was read when the plan opened holds for a minute: the pids are the same.
            let cmprs = self.compressed.flatMap { now.timeIntervalSince($0.at) < 60 ? $0.map : nil }
            let verdict = Optimizer.plan(&snap, compressed: cmprs, served: cmprs == nil ? nil : self.served, frontmost: front,
                                         memory: self.learned, note: note, history: self.history, now: now)
            // The installed app only: a bench must not write over its history.
            if keep, now.timeIntervalSince(self.historySaved) >= 600 {
                self.historySaved = now
                self.history.save(to: LoadHistory.defaultURL)
                self.learned.save()
            }
            let past = open ? (self.history.rows(now: now), self.history.since(now: now)) : nil
            let series = wanted.map { self.history.series($0, parts: 48, now: now) }
            DispatchQueue.main.async {
                if let series, wanted == self.seriesOf { self.series = series }
                if let past { self.past = past.0; self.pastSince = past.1 }
                self.snap = snap
                self.verdict = verdict
                self.refreshing = false
                self.checkAlerts(snap)
            }
        }
    }

    /// Sessions are kept in the history by their name.
    func showSeries(of c: Consumer?) {
        guard live else { return }
        seriesOf = c.map { "\($0.kind.rawValue):\($0.name)" }
        series = []
        guard let wanted = seriesOf else { return }
        queue.async {
            let found = self.history.series(wanted, parts: 48, now: Date())
            DispatchQueue.main.async { if self.seriesOf == wanted { self.series = found } }
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
        past = Demo.past()
        pastSince = Date().addingTimeInterval(-11.5 * 3600)
        settings.planUsage = true
        plan = Demo.plan()
        syncScene()
        ports = Demo.ports
        series = (0..<48).map { (i: Int) -> Double? in i < 3 ? nil : i < 10 || (i > 20 && i < 26) ? 4 : 240 + 200 * sin(Double(i) / 2.3) }
        func wave(_ base: Double, _ size: Double, _ slow: Double, spike: Int = 0, _ high: Double = 0) -> [Double] {
            (0..<60).map { (i: Int) -> Double in
                let top: Double = spike > 0 && i % spike == 0 ? high : 0
                return base + size * sin(Double(i) / slow) + top
            }
        }
        netRates = wave(300_000, 260_000, 4, spike: 17, 900_000)
        cpuHistory = wave(0.2, 0.12, 5, spike: 23, 0.3)
        memHistory = wave(0.56, 0.03, 20)
        gpuHistory = wave(0.14, 0.1, 3)
        loadDrivesOnce(demo: true)
        for r in Demo.receipts() { receipts.add(r) }
        result = OptimizeResult(receipts: Set(receipts.list.prefix(4).map(\.id)), memBefore: 19 << 30, memAfter: 18 << 30)
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

    func changeHealth(_ change: (inout HealthStore) -> Void) {
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
                s.acceptStartup()
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
        result = OptimizeResult(cleared: true, running: true)
        let settings = self.settings
        healthQueue.async {
            let table = ProcTable.live()
            var moved = Set<String>()
            let done = items.map { i -> Receipt in
                let at = Cleanup.trashed(i, table: table, settings: settings)
                if at != nil { moved.insert(i.path) }
                return Receipt(at: Date(), title: i.title, detail: at == nil ? "Not moved, in use or changed" : "Moved to the Trash", bytes: i.bytes, ok: at != nil,
                               back: at.flatMap { $0.isEmpty ? nil : .trash(from: $0, to: i.path) })
            }
            DispatchQueue.main.async {
                self.cleaning = false
                self.changeHealth { s in s.report?.cleanup.removeAll { moved.contains($0.path) } }
                self.changeReceipts { $0.add(done) }
                self.result = OptimizeResult(receipts: Set(done.map(\.id)), cleared: true)
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

    func refreshPlan() {
        guard live, settings.planUsage else { return }
        DispatchQueue.global(qos: .utility).async {
            let plan = PlanUsage.read()
            DispatchQueue.main.async { self.plan = plan }
        }
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

    /// What the last press of a main button did. The rows themselves are receipts.
    struct OptimizeResult {
        var receipts: Set<UUID> = []
        var cleared = false
        var memBefore: UInt64 = 0
        var memAfter: UInt64?
        /// Shutting a simulator down takes seconds; the page says so meanwhile.
        var running = false
        /// What the closed rows were expected to give back, and whether memory is still being watched.
        var promised: UInt64 = 0
        var measuring = false
        var stateAfter: MemoryState?
    }

    /// The rows the plan starts with ticked, by the user's rules.
    func defaultSelection() -> Set<String> {
        Set((snap?.suggestions ?? []).filter { settings.preselects($0) }.map(\.id))
    }

    func changeReceipts(_ change: (inout Receipts) -> Void) {
        change(&receipts)
        if live, writes { receipts.save() }
    }

    /// For a closed session: the conversation is on disk, and this goes on with it.
    private func back(ofSession pid: Int32?) -> Receipt.Back? {
        snap?.sessions.first { $0.pid == pid }.flatMap { $0.sessionId.isEmpty ? nil : .session(cwd: $0.cwd, id: $0.sessionId) }
    }

    /// The state of memory as the menu bar app follows it.
    var note: PressureNote {
        PressureNote(state: tracker.state, swapinRate: tracker.swapinRate, forecastMinutes: tracker.forecastMinutes(), at: Date())
    }

    /// When the plan opens: what of each program is compressed, and what has clients. Half a second, off the main thread.
    func preparePlan() {
        guard live else { return }
        queue.async {
            if let c = self.compressed, Date().timeIntervalSince(c.at) < 20 { return }
            self.compressed = (Date(), Compressed.read())
            self.served = Ports.served()
            DispatchQueue.main.async { self.refreshSnapshot() }
        }
    }

    /// Learns from what the user changed in the plan. Rows nobody touched teach nothing beyond a little.
    private func learnChoices(chosen: [Suggestion], shown: [Suggestion], defaults: Set<String>) {
        guard writes else { return }
        let picked = Set(chosen.map(\.id)), now = Date()
        let changes = shown.compactMap { s -> (Taste.Choice, String, CandidateKind)? in
            let on = picked.contains(s.id), was = defaults.contains(s.id)
            let choice: Taste.Choice? = on && !was ? .ticked : !on && was ? .unticked : on ? .acceptedAsIs : nil
            return choice.map { ($0, Optimizer.key(s), Optimizer.kind(s)) }
        }
        queue.async { for (c, key, kind) in changes { self.learned.taste.learn(c, key: key, kind: kind, now: now) } }
    }

    private static func median(_ xs: ArraySlice<UInt64>) -> UInt64 {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    func run(_ items: [Suggestion], shown: [Suggestion] = [], defaults: Set<String> = []) {
        guard live else { return }
        learnChoices(chosen: items, shown: shown, defaults: defaults)
        // Three readings, not one: memory moves by itself from second to second.
        let before = Self.median(usedRecent.suffix(3))
        let quiet = usedRecent.suffix(30)
        let noise = (quiet.max() ?? 0) - (quiet.min() ?? 0)
        let stateBefore = tracker.state
        let runtimes = snap?.runtimes ?? []
        let settings = self.settings
        let backs = Dictionary(items.filter { $0.kind == .idleSession }.map { ($0.id, back(ofSession: $0.pid)) }, uniquingKeysWith: { a, _ in a })
        result = OptimizeResult(memBefore: before, running: true)
        // Off the main thread: `simctl shutdown` and `adb emu kill` take seconds, and quitting apps may take longer.
        DispatchQueue.global(qos: .userInitiated).async {
            self.perform(items, runtimes: runtimes, settings: settings, backs: backs, before: before, noise: noise, stateBefore: stateBefore)
        }
    }

    private func perform(_ items: [Suggestion], runtimes: [DevRuntime], settings: PulseCore.Settings, backs: [String: Receipt.Back?],
                         before: UInt64, noise: UInt64, stateBefore: MemoryState) {
        var asked: [(s: Suggestion, ok: Bool, said: String, way: Receipt.Back?)] = []
        for s in items {
            switch s.kind {
            case .idleSession:
                let ok = s.pid.map { Actions.closeIdleSession(pid: $0) } ?? false
                asked.append((s, ok, ok ? "Session closed" : "Not closed, no longer idle", backs[s.id] ?? nil))
            case .orphan:
                let ok = (s.pid != nil && s.procStart != nil) && Actions.terminate(pid: s.pid!, expectedStart: s.procStart!)
                asked.append((s, ok, ok ? "Leftover closed" : "Not closed, the process changed", nil))
            case .runtime:
                let r = runtimes.first { $0.id == s.runtimeID }
                // Idle when the plan was made, building now: the tick was for something that is no longer so.
                if let r, !s.stillWorking, Runtimes.isWorking(r) {
                    asked.append((s, false, "Not shut down, it started working", nil))
                    continue
                }
                let ok = r.map { Actions.close($0, settings: settings) } ?? false
                asked.append((s, ok, ok ? "Shut down" : "Not shut down, it changed or failed", nil))
            case .heavyApp:
                let ok = DispatchQueue.main.sync { self.quitApp(at: s.bundlePath) }
                asked.append((s, ok, ok ? "Quit" : "Not found", s.bundlePath.map { .app(path: $0) }))
            case .advice:
                continue
            }
        }
        // Asking is not closing: wait until each has really gone, half a minute at most.
        let deadline = Date().addingTimeInterval(30)
        func alive(_ s: Suggestion) -> Bool {
            switch s.kind {
            case .heavyApp: return DispatchQueue.main.sync { self.isRunning(s.bundlePath) }
            case .runtime: return runtimes.first { $0.id == s.runtimeID }.map { Actions.isSame(pid: $0.root.pid, expectedStart: $0.root.lstart) } ?? false
            default: return s.pid.flatMap { pid in s.procStart.map { Actions.isSame(pid: pid, expectedStart: $0) } } ?? false
            }
        }
        while Date() < deadline, asked.contains(where: { $0.ok && alive($0.s) }) { usleep(500_000) }
        let done = asked.map { a -> Receipt in
            let still = a.ok && alive(a.s)
            let said = !still ? a.said : a.s.kind == .heavyApp ? "Did not quit. It may be asking to save." : "Asked to close, still running"
            var r = Receipt(at: Date(), title: a.s.title, detail: said, bytes: a.s.score?.ramBack ?? a.s.reclaimBytes, ok: a.ok && !still,
                            back: a.ok && !still ? a.way : nil)
            r.key = Optimizer.key(a.s)
            return r
        }
        let promised = done.filter(\.ok).reduce(0) { $0 + $1.bytes }
        let kinds = Array(Set(zip(asked, done).filter { $0.1.ok }.map { Optimizer.kind($0.0.s).rawValue })).sorted()
        DispatchQueue.main.async {
            self.changeReceipts { $0.add(done) }
            self.result = OptimizeResult(receipts: Set(done.map(\.id)), memBefore: before, promised: promised, measuring: promised > 0)
            // What memory did: three readings, ten to sixteen seconds after the last one went.
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
                let after = Self.median(self.usedRecent.suffix(3))
                self.result?.memAfter = after
                self.result?.measuring = false
                self.result?.stateAfter = self.tracker.state
                let outcome = Calibration.Outcome(at: Date(), kinds: kinds, promised: promised, fell: Int64(before) - Int64(after),
                                                  noise: noise, stateBefore: stateBefore, stateAfter: self.tracker.state)
                if promised > 0, self.writes { self.queue.async { self.learned.calibration.record(outcome); self.learned.save() } }
                self.refreshSnapshot()
            }
        }
    }

    /// Everything the optimizer learned, gone. It starts again from what is typical.
    func forgetLearned() {
        guard live else { return }
        queue.async {
            self.learned = OptimizerMemory()
            if self.writes { self.learned.save() }
            DispatchQueue.main.async { self.notice = "Forgotten"; self.refreshSnapshot() }
        }
    }

    private func isRunning(_ bundlePath: String?) -> Bool {
        guard let bundlePath else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == bundlePath && !$0.isTerminated }
    }

    /// The user opened again what Pulse closed: such a thing is not offered again for a day, and counts as kept.
    func learnOpenedAgain(_ r: Receipt) {
        guard writes, let key = r.key else { return }
        let now = Date()
        let kind: CandidateKind = key.hasPrefix("app:") ? .app : key.hasPrefix("session:") ? .session : key.hasPrefix("leftover:") ? .leftover : .simulator
        queue.async {
            self.learned.reopened[key] = now
            self.learned.taste.learn(.openedAgain, key: key, kind: kind, now: now)
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
                    self.changeReceipts { $0.add(Receipt(at: Date(), title: c.name, detail: ok ? "Shut down" : "Not shut down", bytes: c.rssBytes, ok: ok)) }
                    self.notice = ok ? "Shut down: \(c.name)" : "Not shut down: \(c.name) (changed, or it failed)"
                    self.refreshSnapshot()
                }
            }
            return
        }
        if c.kind == .app, quitApp(at: c.bundlePath) {
            notice = "Asked to quit: \(c.name)"
            changeReceipts { $0.add(Receipt(at: Date(), title: c.name, detail: "Asked to quit", bytes: c.rssBytes, back: c.bundlePath.map { .app(path: $0) })) }
        } else {
            let way = c.kind == .session ? back(ofSession: c.members.first?.pid) : nil
            let n = Actions.close(c, settings: settings)
            notice = n == 0 ? "Not closed: \(c.name) (no permission, or it changed)"
                : n == 1 ? "Closed: \(c.name)" : "Closed \(n) processes of \(c.name)"
            changeReceipts { $0.add(Receipt(at: Date(), title: c.name, detail: n == 0 ? "Not closed" : "Closed", bytes: c.rssBytes, ok: n > 0, back: n > 0 ? way : nil)) }
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

    /// Reading the ports takes a twentieth of a second, off the main thread.
    func refreshPorts() {
        guard live else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Ports.read()
            DispatchQueue.main.async { self.ports = found ?? self.ports ?? [] }
        }
    }

    /// One of the page's choices while it is on.
    var awakeHours: Double { awakeUntil == nil ? 0 : chosenHours }

    func keepAwake(hours: Double) {
        guard live else { return }
        chosenHours = hours
        if hours == 0 { awake.stop() } else if !awake.start(hours * 3600) { notice = "macOS refused" }
        awakeUntil = awake.until
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshSnapshot() }
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

    /// No decimals from ten up: for a narrow cell.
    static func short(_ b: UInt64) -> String {
        let gb = Double(b) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : bytes(b)
    }

    static func rate(_ b: Double) -> String {
        b >= 1e6 ? String(format: "%.1f MB/s", b / 1e6) : String(format: "%.0f KB/s", b / 1e3)
    }

    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        return s < 60 ? "just now" : duration(s) + " ago"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(m, 1)) min" }
        let h = m / 60
        if h < 48 { return "\(h) h" }
        return "\(h / 24) days"
    }
}
