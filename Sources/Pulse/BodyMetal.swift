import AppKit
import Metal
import PulseCore
import QuartzCore
import SwiftUI

/// The scene, written on the main thread and read by the drawing thread.
final class SceneBox: @unchecked Sendable {
    private let lock = NSLock()
    private var scene = BodyScene()
    func get() -> BodyScene { lock.lock(); defer { lock.unlock() }; return scene }
    func set(_ s: BodyScene) { lock.lock(); scene = s; lock.unlock() }
}

/// Draws the dots with Metal on a thread of its own, at the display's own rate. Nothing
/// the panel does on the main thread can make it stutter.
final class BodyRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Dot { float2 at; float r; float light; float hot; float pad; };
    struct View { float2 size; float half_; float px; };
    struct Out { float4 position [[position]]; float2 uv; float r; float light; float hot; };
    vertex Out v(uint vid [[vertex_id]], uint iid [[instance_id]], constant Dot *dots [[buffer(0)]], constant View &view [[buffer(1)]]) {
        Dot d = dots[iid];
        float2 corner = float2(vid & 1 ? 1 : -1, vid & 2 ? 1 : -1);
        float r = d.r * view.half_;
        float2 p = view.size / 2 + d.at * view.half_ + corner * (r + 1);
        Out o;
        o.position = float4(p.x / view.size.x * 2 - 1, 1 - p.y / view.size.y * 2, 0, 1);
        o.uv = corner * (r + 1); o.r = r; o.light = d.light; o.hot = d.hot;
        return o;
    }
    fragment float4 f(Out in [[stage_in]]) {
        // One device pixel of soft edge: dots glide between pixels instead of hopping.
        float a = in.light * clamp(in.r - length(in.uv) + 0.5, 0.0, 1.0);
        float3 c = mix(float3(0.965, 0.965, 0.970), float3(1.0, 0.420, 0.110), in.hot);
        return float4(c * a, a);
    }
    """
    private struct GPUDot { var x, y, r, light, hot, pad: Float }
    private struct GPUView { var w, h, half, px: Float }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let lib = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "v"); d.fragmentFunction = lib.makeFunction(name: "f")
        let a = d.colorAttachments[0]!
        a.pixelFormat = .bgra8Unorm; a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    static var available: Bool { pipeline != nil }

    private let box: SceneBox
    private let queue: MTLCommandQueue
    private let buffers: [MTLBuffer]
    private var turn = 0
    private var link: CAMetalDisplayLink?
    private let lock = NSLock()
    private var stopped = false
    var still = false
    // The pointer as the dots feel it: it eases in, follows and eases out.
    private var feel = CGPoint.zero, strength = 0.0, lastTime = 0.0

    init?(layer: CAMetalLayer, box: SceneBox) {
        guard let device = Self.device, Self.pipeline != nil, let queue = device.makeCommandQueue() else { return nil }
        let length = MemoryLayout<GPUDot>.stride * BodyScene.count
        buffers = (0..<3).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
        guard buffers.count == 3 else { return nil }
        self.box = box; self.queue = queue
        super.init()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameLatency = 1
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        self.link = link
        let thread = Thread { [weak self] in
            link.add(to: .current, forMode: .default)
            while let self, !self.isStopped { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25)) }
            link.invalidate()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "pulse.body"
        thread.start()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var paused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        FrameMeter.mark()
        let drawable = update.drawable
        var scene = box.get()
        // Drawn for the moment it will be on the glass, not the moment it was computed.
        let now = update.targetPresentationTimestamp
        let dt = min(max(now - lastTime, 0), 0.1)
        lastTime = now
        if let p = scene.pointer, !still {
            if strength < 0.02 { feel = p }
            let k = 1 - exp(-dt * 18)
            feel.x += (p.x - feel.x) * k; feel.y += (p.y - feel.y) * k
            strength += (1 - strength) * (1 - exp(-dt * 10))
        } else {
            strength *= exp(-dt * 8)
        }
        scene.pointer = feel
        scene.pointerStrength = strength
        let dots = scene.dots(at: still ? scene.changedAt + 5 : now)

        turn = (turn + 1) % buffers.count
        guard let commands = queue.makeCommandBuffer() else { return }
        Self.encode(dots, into: drawable.texture, buffer: buffers[turn], commands: commands)
        commands.present(drawable)
        commands.commit()
    }

    private static func encode(_ dots: [BodyScene.Dot], into texture: MTLTexture, buffer: MTLBuffer, commands: MTLCommandBuffer) {
        let width = Float(texture.width), height = Float(texture.height)
        let out = buffer.contents().bindMemory(to: GPUDot.self, capacity: BodyScene.count)
        for (i, d) in dots.enumerated() {
            out[i] = GPUDot(x: Float(d.x), y: Float(d.y), r: Float(d.r), light: Float(d.light), hot: Float(d.hot), pad: 0)
        }
        var view = GPUView(w: width, h: height, half: min(width, height) / 2 * Float(BodyScene.inset), px: 1)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let pipeline, let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&view, length: MemoryLayout<GPUView>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: dots.count)
        encoder.endEncoding()
    }

    /// The same Metal drawing into an image, for looking at it and for the film.
    static func image(_ scene: BodyScene, at t: Double, side: Int) -> CGImage? {
        guard let device, let queue = filmQueue else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d), let commands = queue.makeCommandBuffer(),
              let buffer = device.makeBuffer(length: MemoryLayout<GPUDot>.stride * BodyScene.count, options: .storageModeShared) else { return nil }
        encode(scene.dots(at: t), into: texture, buffer: buffer, commands: commands)
        commands.commit(); commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        texture.getBytes(&bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)?.makeImage()
        }
    }
    private static let filmQueue = device?.makeCommandQueue()
}

/// Hosts the drawing, follows the pointer, and draws only while its window is on screen.
final class BodyNSView: NSView {
    private let box: SceneBox
    private var renderer: BodyRenderer?
    private var observer: NSObjectProtocol?
    var onVisible: (Bool) -> Void = { _ in }
    var onPointer: (CGPoint?) -> Void = { _ in }
    private var visible = false

    init(box: SceneBox) {
        self.box = box
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    private var metal: CAMetalLayer { layer as! CAMetalLayer }
    override var isFlipped: Bool { true }
    // The press belongs to the button around the body.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else {
            renderer?.stop(); renderer = nil
            return
        }
        resize()
        if renderer == nil { renderer = BodyRenderer(layer: metal, box: box) }
        renderer?.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.sync() }
        sync()
    }

    private func sync() {
        let now = window?.occlusionState.contains(.visible) ?? false
        renderer?.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderer?.paused = !now
        if now != visible { visible = now; onVisible(now) }
    }

    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); resize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); resize() }
    private func resize() {
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metal.drawableSize != size { metal.drawableSize = size }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), half = min(bounds.width, bounds.height) / 2 * BodyScene.inset
        guard half > 0 else { return }
        onPointer(CGPoint(x: (p.x - bounds.midX) / half, y: (p.y - bounds.midY) / half))
    }
    override func mouseExited(with event: NSEvent) { onPointer(nil) }

    deinit {
        renderer?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct BodyView: View {
    let model: Model

    var body: some View {
        Group {
            if model.drawsLive, BodyRenderer.available {
                Live(model: model)
            } else {
                // Headless renders, and a Mac without Metal: one still frame.
                Canvas { context, size in model.scene.draw(&context, size: size, at: model.scene.changedAt + 5) }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }

    private struct Live: NSViewRepresentable {
        let model: Model
        func makeNSView(context: Context) -> BodyNSView {
            let v = BodyNSView(box: model.sceneBox)
            v.onVisible = { [weak model] on in
                // After the current view update, never inside it.
                DispatchQueue.main.async { model?.bodyVisible(on) }
            }
            v.onPointer = { [weak model] p in model?.scene.pointer = p }
            return v
        }
        func updateNSView(_ v: BodyNSView, context: Context) {}
        static func dismantleNSView(_ v: BodyNSView, coordinator: ()) { v.onPointer(nil) }
    }
}
