import AppKit
import Carbon.HIToolbox
import Combine
import PulseCore
import SwiftUI

/// Opening Pulse again, from Finder or Spotlight, shows the panel in a window. The menu bar
/// item can be out of sight, behind the notch or on a full bar. The first launch does the same.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var hotKey: HotKey?
    private var watching: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !Model.shared.settings.welcomed { show(.welcome) }
        watching = Model.shared.$settings.map(\.shortcut).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] k in
            self?.hotKey = nil
            self?.hotKey = HotKey(k) { MainActor.assumeIsolated { self?.toggle() } }
            if k != .off, self?.hotKey == nil { Model.shared.notice = "Another app holds that key" }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show(Model.shared.settings.welcomed ? .overview : .welcome)
        return false
    }

    /// The key again puts it away.
    @MainActor private func toggle() {
        if let w = window, w.isKeyWindow { w.close() } else { show(Model.shared.settings.welcomed ? .overview : .welcome) }
    }

    @MainActor private func show(_ page: Page) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Pulse"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Ink.base)
            w.appearance = NSAppearance(named: .darkAqua)
            w.delegate = self
            let host = NSHostingView(rootView: PanelView(model: .shared, page: page, inWindow: true))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        Model.shared.closed()
    }
}

/// One key for the whole system. Needs no permission: macOS tells Pulse of this key only, and of no other.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(_ key: PulseCore.Settings.Shortcut, action: @escaping () -> Void) {
        self.action = action
        let modifiers: Int
        switch key {
        case .off: return nil
        case .controlOptionP: modifiers = controlKey | optionKey
        case .optionCommandP: modifiers = optionKey | cmdKey
        }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            data.map { Unmanaged<HotKey>.fromOpaque($0).takeUnretainedValue().action() }
            return noErr
        }, 1, &kind, me, &handler)
        guard RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(modifiers), EventHotKeyID(signature: 0x504C5345, id: 1), GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct PulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // CPU · memory. The panel names them.
            Image(systemName: model.system.memPressureLevel >= 2 ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
            Text(model.barText)
        }
        .menuBarExtraStyle(.window)
    }
}

func pageArg() -> Page {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: "--page"), i + 1 < a.count else { return .overview }
    return Page(rawValue: a[i + 1]) ?? .overview
}

/// Draws the panel into a PNG without showing a window, for checking the layout. With `--demo`
/// everything in it is made up, so the picture can be shown to anyone.
func renderPanel(to path: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = Model(live: false)
    let demo = CommandLine.arguments.contains("--demo")
    if demo {
        model.loadDemo()
    } else {
        model.loadOnce()
        // A check of this Mac, not stored. The body is drawn at rest.
        model.checkOnce()
    }
    model.scene.changedAt = Model.clock - 10
    if !demo, pageArg() == .drives || pageArg() == .care { model.loadDrivesOnce(demo: false) }
    if !demo { model.ports = Ports.read() }
    snapshotView(PanelView(model: model, page: pageArg()), to: path)
}

/// With `--2x` it draws text as a Retina display would, on any display or none.
private final class RenderWindow: NSWindow {
    override var backingScaleFactor: CGFloat { CommandLine.arguments.contains("--2x") ? 2 : 1 }
}

func snapshotView<V: View>(_ view: V, to path: String) {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    host.frame = NSRect(origin: .zero, size: size)
    let window = RenderWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let scale = Int(window.backingScaleFactor)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: path))
    print("rendered \(Int(size.width))x\(Int(size.height)) -> \(path)")
}

let args = CommandLine.arguments
if args.contains("--mcp") {
    // Started inside a session's folder: staying there would hold an external drive open.
    FileManager.default.changeCurrentDirectoryPath("/")
    MCPServer().run()
} else if args.contains("--snapshot") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    let snap = Snapshot.take(system: SystemSampler().sampleBlocking())
    print(String(decoding: (try? enc.encode(snap)) ?? Data(), as: UTF8.self))
} else if let i = args.firstIndex(of: "--body"), i + 1 < args.count {
    NSApplication.shared.setActivationPolicy(.prohibited)
    snapshotView(BodyStrip(), to: args[i + 1])
} else if let i = args.firstIndex(of: "--film"), i + 1 < args.count {
    NSApplication.shared.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { renderFilm(to: args[i + 1]) }
} else if args.contains("--bench-window") {
    MainActor.assumeIsolated { benchWindow() }
} else if args.contains("--bench-layout") {
    MainActor.assumeIsolated { benchLayout() }
} else if args.contains("--health") {
    // One check, printed and not stored.
    let report = HealthProbe.take(system: SystemSampler().sampleBlocking(), store: .load(), settings: .load())
    for c in report.checks { print("\(c.state.rawValue)\t\(c.area.rawValue)\t\(c.title)\t\(c.detail)") }
    for c in report.cleanup { print("cleanup\t\(Fmt.bytes(c.bytes))\t\(c.title)\t\(c.blockedBy ?? "")\t\(c.path)") }
} else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
    renderPanel(to: args[i + 1])
} else if let odd = args.dropFirst().first(where: { $0.hasPrefix("--") }) {
    FileHandle.standardError.write(Data("unknown option \(odd)\n".utf8))
    exit(2)
} else {
    PulseApp.main()
}
