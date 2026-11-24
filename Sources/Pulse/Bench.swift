import AppKit
import PulseCore
import SwiftUI

/// Counts frames of the body and gaps between display refreshes, in a real window.
/// Opens a window, so it only runs with PULSE_WINDOW_BENCH=1.
final class FrameMeter: NSObject {
    static var drawn: [Double] = []
    static let lock = NSLock()
    static func mark() { 
        lock.lock(); defer { lock.unlock() }
        if on, drawn.count < 20_000 { drawn.append(CACurrentMediaTime()) }
    }
    /// The last opening of the real panel, measured: frame times only, in one small file.
    static func begin() { lock.lock(); drawn = []; on = true; lock.unlock() }
    static func end() {
        lock.lock(); on = false; let times = drawn; lock.unlock()
        let url = HealthStore.defaultURL.deletingLastPathComponent().appendingPathComponent("last-open.txt")
        try? (line("body", times) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    static var on = false
    var refreshes: [Double] = []
    @objc func tick(_ link: CADisplayLink) { refreshes.append(CACurrentMediaTime()) }

    static func line(_ name: String, _ times: [Double]) -> String {
        guard times.count > 2 else { return "\(name): \(times.count) frames" }
        let gaps = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.filter { $0 < 400 }.sorted()  // longer is time spent on a page without the body
        guard !gaps.isEmpty else { return "\(name): no frames" }
        func p(_ q: Double) -> Double { gaps[min(Int(Double(gaps.count) * q), gaps.count - 1)] }
        return String(format: "%@: %.0f fps, median %.1f ms, p95 %.1f, p99 %.1f, worst %.1f, over 25 ms: %d", name,
                      Double(times.count - 1) / (times.last! - times.first!), p(0.5), p(0.95), p(0.99), gaps.last!, gaps.filter { $0 > 25 }.count)
    }
}

@MainActor func benchWindow() {
    guard ProcessInfo.processInfo.environment["PULSE_WINDOW_BENCH"] == "1" else {
        print("opens a window; set PULSE_WINDOW_BENCH=1"); exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = Model(live: true, writes: false)
    let host = NSHostingView(rootView: PanelView(model: model))
    let panel = NSPanel(contentRect: NSRect(x: 40, y: 60, width: 320, height: 440), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = host
    panel.level = .floating
    panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    let meter = FrameMeter()
    let link = panel.displayLink(target: meter, selector: #selector(FrameMeter.tick(_:)))
    link.add(to: .main, forMode: .common)
    func segment(_ name: String, _ seconds: Double, _ act: () -> Void) async {
        try? await Task.sleep(for: .seconds(0.3))
        FrameMeter.drawn = []; meter.refreshes = []; FrameMeter.on = true
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        act()
        try? await Task.sleep(for: .seconds(seconds))
        FrameMeter.on = false
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let cpu = s(after.ru_utime) + s(after.ru_stime) - s(before.ru_utime) - s(before.ru_stime)
        print("[\(name)] screen \(panel.screen?.maximumFramesPerSecond ?? 0) Hz, cpu \(Int(cpu / seconds * 100))% of a core")
        print("  " + FrameMeter.line("body", FrameMeter.drawn))
        print("  " + FrameMeter.line("main thread", meter.refreshes))
    }
    // Inside the app's own event loop: that is what tells a window whether it is on screen.
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(0.4))
        print("opening: from \(model.scene.previous) to \(model.scene.shape), began \(Int((Model.clock - model.scene.changedAt) * 1000)) ms ago")
        func find(_ v: NSView) -> BodyNSView? { (v as? BodyNSView) ?? v.subviews.lazy.compactMap(find).first }
        if let b = find(host) { print("drawable \((b.layer as! CAMetalLayer).drawableSize) for \(b.bounds.size) points") }
        print("window \(panel.windowNumber)"); fflush(stdout)
        await segment("open and idle", 6) {}
        await segment("check", 5) { model.runHealthCheck(shown: true) }
        for p in [Page.health, .overview, .processes, .overview] {
            await segment("to \(p.rawValue)", 0.8) { NotificationCenter.default.post(name: PanelView.goTo, object: p.rawValue) }
        }
        panel.orderOut(nil)
        await segment("closed", 10) {}
        link.invalidate()
        exit(0)
    }
    app.run()
}

/// Milliseconds of the main thread for a new page, and for a new reading on the same page. Opens no window
/// on screen and needs no display, so it can be run anywhere.
@MainActor func benchLayout() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let model = Model(live: false)
    model.loadOnce()
    model.checkOnce()
    let host = NSHostingView(rootView: PanelView(model: model, page: .overview))
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    func time(_ act: () -> Void) -> Double {
        let t = CACurrentMediaTime()
        act()
        RunLoop.main.run(until: Date().addingTimeInterval(0.0005))
        host.layoutSubtreeIfNeeded()
        return (CACurrentMediaTime() - t) * 1000
    }
    for p in [Page.overview, .processes, .sessions, .care, .health, .settings] {
        var turn: [Double] = [], fresh: [Double] = []
        for _ in 0..<15 {
            NotificationCenter.default.post(name: PanelView.goTo, object: (p == .settings ? Page.care : .settings).rawValue)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            turn.append(time { NotificationCenter.default.post(name: PanelView.goTo, object: p.rawValue) })
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            fresh.append(time { model.snap = model.snap; model.system.cpuPercent += 0.1 })
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        turn.sort(); fresh.sort()
        print(String(format: "%@: page median %.1f ms, worst %.1f; reading median %.1f ms, worst %.1f", p.rawValue, turn[7], turn[14], fresh[7], fresh[14]))
    }
    print("rows \(model.snap?.consumers.count ?? 0)")
}
