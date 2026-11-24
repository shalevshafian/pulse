import AppKit
import PulseCore
import SwiftUI

/// The Mac drawn as a body of dots. Calm, it is a slow halftone sphere whose surface
/// moves with the processor. A check sweeps a band over it. The result is written by the
/// same dots. A sick area is a raised patch: pale for attention, orange for urgent.
///
/// The drawing is a pure function of time, so it can be rendered frame by frame without
/// a window.
struct BodyScene {
    enum Shape: Equatable { case scatter, sphere, text(String), tick, burst }

    var shape: Shape = .sphere
    var previous: Shape = .scatter
    var changedAt: Double = 0
    /// When a check started, or nil.
    var checkingSince: Double?
    /// 0...1, with the last value and when it changed: the surface never jumps.
    var load: Double = 0, loadBefore: Double = 0, loadAt: Double = 0
    var areas: [HealthState] = Array(repeating: .ok, count: 8)
    /// The area the pointer is on in the legend.
    var focus: Int?
    var angle: Double = 0, angleAt: Double = 0
    var target: Double?
    /// The pointer over the body, in -1...1 of its radius.
    var pointer: CGPoint?
    var pointerStrength = 1.0
    /// Where the dots were when a change of shape was cut short by another.
    private var from: [Dot]?
    private var lastFocus: Int?, focusAt = -10.0
    private var checkEnded = -10.0, checkSpeed = 0.0, checkPhase = 0.0

    struct Dot { var x, y, r, light: Double; var hot: Double }

    static let count = 420
    static let spin = 0.5
    static let morph = 0.55
    /// How much later the last dot leaves than the first.
    static let spread = 0.14
    /// Room around the body, so a crest or a burst is not cut at the edge.
    static let inset = 0.93

    /// Even points on a sphere.
    private static let points: [(x: Double, y: Double, z: Double)] = (0..<count).map { (i: Int) -> (x: Double, y: Double, z: Double) in
        let y = 1 - 2 * (Double(i) + 0.5) / Double(count), a = Double(i) * 2.399963229728653
        let r = (1 - y * y).squareRoot()
        return (x: cos(a) * r, y: y, z: sin(a) * r)
    }
    /// A fixed random number per dot.
    private static let noise: [Double] = (0..<count).map { i in
        let v = sin(Double(i) * 127.1 + 311.7) * 43758.5453
        return v - v.rounded(.down)
    }
    /// The centres of the eight areas, spread around the body in two staggered rows.
    static let centres: [(lon: Double, lat: Double)] = (0..<8).map { (k: Int) -> (lon: Double, lat: Double) in
        (lon: Double(k) * Double.pi / 4, lat: k % 2 == 0 ? 0.42 : -0.38)
    }

    private static let directions: [(x: Double, y: Double, z: Double)] = centres.map { (c) -> (x: Double, y: Double, z: Double) in
        (x: cos(c.lon) * cos(c.lat), y: -sin(c.lat), z: sin(c.lon) * cos(c.lat))
    }

    private static func smooth(_ x: Double) -> Double { let v = min(max(x, 0), 1); return v * v * (3 - 2 * v) }
    /// Past the goal a little, and back: the dots arrive, they do not stop dead.
    private static func settle(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return 1 + 2.2 * pow(v - 1, 3) + 1.2 * pow(v - 1, 2)
    }

    func angle(at t: Double) -> Double {
        let free = angle + (t - angleAt) * Self.spin
        guard let target else { return free }
        let d = (target - angle).truncatingRemainder(dividingBy: 2 * .pi)
        let near = d > .pi ? d - 2 * .pi : d < -.pi ? d + 2 * .pi : d
        return angle + near * Self.smooth((t - angleAt) / 0.45)
    }

    mutating func go(_ next: Shape, at t: Double) {
        guard next != shape else { return }
        // Cut short: leave from where the dots are, not from where they were going.
        from = t - changedAt < Self.morph + Self.spread ? dots(at: t, rest: true) : nil
        previous = shape; shape = next; changedAt = t
    }

    /// The extra turning during a check.
    private static let turnRate = 2.4, coast = 0.5
    private func checkTurn(_ t: Double) -> Double {
        if let since = checkingSince { return Self.smooth((t - since) / 0.6) * max(0, t - since) * Self.turnRate }
        // After a check the body coasts to its own speed.
        return checkSpeed * Self.coast * (1 - exp(-max(0, t - checkEnded) / Self.coast))
    }
    private func sweep(_ t: Double) -> Double {
        if let since = checkingSince { return Self.smooth((t - since) / 0.3) }
        return checkSpeed == 0 ? 0 : 1 - Self.smooth((t - checkEnded) / 0.35)
    }

    mutating func startCheck(at t: Double) {
        angle = angle(at: t) + checkTurn(t); angleAt = t
        checkSpeed = 0
        checkingSince = t
    }

    /// Ends the sweep where it stands: the body does not jump back.
    mutating func endCheck(at t: Double) {
        guard let since = checkingSince else { return }
        angle = angle(at: t) + checkTurn(t); angleAt = t
        checkPhase = since; checkEnded = t; checkSpeed = Self.turnRate * Self.smooth((t - since) / 0.6)
        checkingSince = nil
    }

    mutating func setLoad(_ v: Double, at t: Double) {
        loadBefore = currentLoad(t); load = v; loadAt = t
    }

    mutating func setFocus(_ i: Int?, at t: Double) {
        guard i != focus else { return }
        // What is left of a check's turning is taken in, so the area really ends up in front.
        angle = angle(at: t) + (checkingSince == nil ? checkTurn(t) : 0); angleAt = t
        if checkingSince == nil { checkSpeed = 0 }
        lastFocus = focus; focusAt = t
        focus = i
        // Facing the viewer is +z; a point at longitude `lon` gets there at this angle.
        target = i.map { Double.pi / 2 - Self.centres[$0].lon }
    }

    private func currentLoad(_ t: Double) -> Double { loadBefore + (load - loadBefore) * Self.smooth((t - loadAt) / 1.2) }

    // MARK: Where a dot wants to be

    private struct Place { var x, y, r, light: Double; var hot = 0.0 }

    private func place(_ i: Int, _ s: Shape, _ t: Double) -> Place {
        let n = Self.noise[i], p = Self.points[i]
        switch s {
        case .sphere: return onSphere(i, t)
        case .scatter:
            let a = n * 2 * .pi + t * 0.05, d = 1.15 + Self.noise[(i * 7 + 3) % Self.count] * 0.5
            return Place(x: cos(a) * d, y: sin(a) * d, r: 0.006, light: 0.25)
        case .burst:
            let a = atan2(p.y, p.x) + (n - 0.5) * 0.5, d = 0.75 + n * 0.75
            return Place(x: cos(a) * d, y: sin(a) * d, r: 0.012 + 0.01 * n, light: 0.5)
        case .text(let text): return onMask(i, Self.mask(text), t)
        case .tick: return onMask(i, Self.tickMask, t)
        }
    }

    private func onSphere(_ i: Int, _ t: Double) -> Place {
        let p = Self.points[i], load = currentLoad(t)
        // The surface: two slow waves, taller when the processor works.
        let wave = sin(p.x * 3.1 + t * 2.0) * sin(p.y * 2.7 - t * 1.4) + 0.5 * sin(p.z * 5.3 + t * 3.0)
        var radius = 0.86 + 0.012 * sin(t * 1.25) + wave * (0.012 + 0.12 * load)

        // Patches of the areas that need care.
        var lift = 0.0, hot = 0.0
        let enter = Self.smooth((t - focusAt) / 0.3)
        for k in 0..<Self.centres.count {
            let state = k < areas.count ? areas[k] : .ok
            let sick = state == .attention || state == .urgent
            let attention = focus == k ? enter : lastFocus == k ? 1 - enter : 0
            guard sick || attention > 0 else { continue }
            let c = Self.directions[k]
            let dot = p.x * c.x + p.y * c.y + p.z * c.z
            let reach = (sick ? 0.36 : 0.2) + attention * (sick ? 0.16 : 0.32)
            guard dot > cos(reach) else { continue }
            let d = acos(min(dot, 1))
            let w = Self.smooth(1 - d / reach) * (sick ? 1 : attention)
            let beat = 0.5 + 0.5 * sin(t * (state == .urgent ? 4.2 : 2.4) - d * 5)
            lift = max(lift, w * (0.55 + 0.45 * beat))
            if state == .urgent { hot = max(hot, Self.smooth(w * 4)) }
        }
        radius += lift * 0.07

        let a = angle(at: t) + checkTurn(t)
        let x = p.x * cos(a) - p.z * sin(a), z = p.x * sin(a) + p.z * cos(a)
        // Leaning a little toward the viewer.
        let tilt = 0.32
        let y = p.y * cos(tilt) - z * sin(tilt), depth = p.y * sin(tilt) + z * cos(tilt)

        let front = (depth + 1) / 2
        var size = 0.005 + 0.0245 * pow(front, 2.2)
        var light = 0.12 + 0.88 * pow(front, 2.0)
        // Crests swell under load, so work is seen as texture too.
        size *= (1 + max(0, wave) * 0.7 * load) * (1 + lift * 0.75)
        light = min(1, light + lift * 0.35 * front)

        let sweep = sweep(t)
        if sweep > 0 {
            // Two bands of light pass over the body, one after the other.
            let since = checkingSince ?? checkPhase
            let phase = ((t - since) * 1.0).truncatingRemainder(dividingBy: 1)
            for shift in [0.0, 0.5] {
                let band = -1.25 + 2.5 * (phase + shift).truncatingRemainder(dividingBy: 1)
                let g = exp(-pow((y - band) / 0.13, 2)) * sweep
                size *= 1 + g * 1.1
                light = min(1, light + g * 0.6)
                radius += g * 0.035
            }
        }
        return Place(x: x * radius, y: y * radius, r: size, light: light, hot: hot)
    }

    /// Dots share the filled cells of the mask; the rest circle it as a faint ring.
    private func onMask(_ i: Int, _ cells: [CGPoint], _ t: Double) -> Place {
        let order = (i * 239) % Self.count
        if order < cells.count {
            let c = cells[order]
            let shimmer = 0.5 + 0.5 * sin(t * 2 + c.x * 4 + c.y * 3)
            return Place(x: c.x, y: c.y, r: 0.026 + 0.004 * shimmer, light: 0.92 + 0.08 * shimmer)
        }
        let a = Double(order - cells.count) / Double(Self.count - cells.count) * 2 * .pi + t * 0.16
        let d = 0.93 + 0.025 * sin(a * 6 + t * 1.5) + (Self.noise[i] - 0.5) * 0.06
        return Place(x: cos(a) * d, y: sin(a) * d, r: 0.008, light: 0.34)
    }

    // MARK: Dot letters

    private static let digits: [Character: [String]] = [
        "0": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"], "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00110", "01000", "10000", "11111"], "3": ["01110", "10001", "00001", "00110", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"], "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"], "7": ["11111", "00001", "00010", "00100", "00100", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"], "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
    ]

    /// Each lit cell of the 5 by 7 letters becomes four dots.
    static func mask(_ text: String) -> [CGPoint] {
        let glyphs = text.compactMap { digits[$0] }
        guard !glyphs.isEmpty else { return [] }
        let columns = Double(glyphs.count * 6 - 1), step = min(1.36 / columns, 1.0 / 7)
        var out: [CGPoint] = []
        for (g, rows) in glyphs.enumerated() {
            for (r, row) in rows.enumerated() {
                for (c, bit) in row.enumerated() where bit == "1" {
                    for (dx, dy) in [(-0.25, -0.25), (0.25, -0.25), (-0.25, 0.25), (0.25, 0.25)] {
                        out.append(CGPoint(x: (Double(g * 6 + c) - (columns - 1) / 2 + dx) * step, y: (Double(r) - 3 + dy) * step))
                    }
                }
            }
        }
        return out
    }

    static let tickMask: [CGPoint] = {
        var out: [CGPoint] = []
        func line(_ a: CGPoint, _ b: CGPoint, _ n: Int) {
            for k in 0..<n {
                let f = Double(k) / Double(n - 1), x = a.x + (b.x - a.x) * f, y = a.y + (b.y - a.y) * f
                let len = hypot(b.x - a.x, b.y - a.y), nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
                for w in [-0.066, 0, 0.066] { out.append(CGPoint(x: x + nx * w, y: y + ny * w)) }
            }
        }
        line(CGPoint(x: -0.46, y: 0.03), CGPoint(x: -0.13, y: 0.36), 8)
        line(CGPoint(x: -0.13, y: 0.36), CGPoint(x: 0.5, y: -0.34), 15)
        return out
    }()

    // MARK: A frame

    func dots(at t: Double, rest: Bool = false) -> [Dot] {
        (0..<Self.count).map { i in
            // Dots leave one after another, so a change of shape runs through the body.
            let wait = Self.noise[(i * 13 + 5) % Self.count] * Self.spread
            let raw = (t - changedAt - wait) / Self.morph
            var p = place(i, shape, t)
            if raw < 1 {
                let q = from.map { Place(x: $0[i].x, y: $0[i].y, r: $0[i].r, light: $0[i].light, hot: $0[i].hot) } ?? place(i, previous, t)
                let k = Self.settle(raw), soft = Self.smooth(raw)
                // Travelling on an arc rather than a straight line.
                let arc = sin(min(max(raw, 0), 1) * .pi) * 0.22 * (Self.noise[i] - 0.5) * 2
                let dx = p.x - q.x, dy = p.y - q.y
                p = Place(x: q.x + dx * k - dy * arc, y: q.y + dy * k + dx * arc,
                          r: q.r + (p.r - q.r) * soft, light: q.light + (p.light - q.light) * soft, hot: q.hot + (p.hot - q.hot) * soft)
            }
            if !rest, pointerStrength > 0.01, let m = pointer {
                // The dots make room for the pointer.
                let dx = p.x - m.x, dy = p.y - m.y, d = max(hypot(dx, dy), 0.001)
                if d < 0.42 {
                    let push = pow(1 - d / 0.42, 2) * 0.16 * pointerStrength
                    p.x += dx / d * push; p.y += dy / d * push
                    p.r *= 1 + push * 2.4
                }
            }
            return Dot(x: p.x, y: p.y, r: max(p.r, 0), light: min(max(p.light, 0), 1), hot: p.hot)
        }
    }

    func draw(_ context: inout GraphicsContext, size: CGSize, at t: Double) {
        let half = min(size.width, size.height) / 2 * Self.inset, cx = size.width / 2, cy = size.height / 2
        // One path per shade: a frame is a couple of dozen fills, not hundreds.
        let shades = 10
        var cool = [Path](repeating: Path(), count: shades + 1), hot = cool
        for d in dots(at: t) where d.light > 0.02 {
            let r = d.r * half
            let rect = CGRect(x: cx + d.x * half - r, y: cy + d.y * half - r, width: r * 2, height: r * 2)
            let k = Int((d.light * Double(shades)).rounded())
            if d.hot > 0.5 { hot[k].addEllipse(in: rect) } else { cool[k].addEllipse(in: rect) }
        }
        for k in 1...shades {
            let o = Double(k) / Double(shades)
            if !cool[k].isEmpty { context.fill(cool[k], with: .color(BodyScene.paper.opacity(o))) }
            if !hot[k].isEmpty { context.fill(hot[k], with: .color(Ink.hot.opacity(o))) }
        }
    }

    static let paper = Color(red: 0.965, green: 0.965, blue: 0.970)
}

/// Frames of every movement side by side, for looking at motion without a window.
struct BodyStrip: View {
    private var rows: [(String, [(BodyScene, Double)])] {
        var sick = BodyScene()
        sick.areas = [.urgent, .attention, .attention, .ok, .ok, .attention, .ok, .ok]
        sick.changedAt = 0
        var open = sick; open.previous = .scatter; open.shape = .sphere
        var check = sick; check.changedAt = -5; check.startCheck(at: 0)
        var score = sick; score.previous = .sphere; score.shape = .text("61")
        var fixed = sick; fixed.previous = .sphere; fixed.shape = .burst
        var tick = fixed; tick.previous = .burst; tick.shape = .tick
        var busy = sick; busy.changedAt = -5; busy.load = 0.95; busy.loadBefore = 0.95
        var focus = sick; focus.changedAt = -5; focus.setFocus(0, at: 0)
        let t = [0.1, 0.35, 0.6, 0.9, 1.5]
        return [("open", t.map { (open, $0) }), ("check", [0.4, 0.8, 1.2, 1.6, 2.0].map { (check, $0) }), ("score", t.map { (score, $0) }),
                ("fixed", [(fixed, 0.3), (fixed, 0.7), (tick, 0.4), (tick, 0.8), (tick, 1.6)]), ("load", [0, 0.5, 1, 1.5, 2].map { (busy, $0) }),
                ("focus", [0, 0.2, 0.4, 0.7, 1.4].map { (focus, $0) })]
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    ForEach(0..<row.1.count, id: \.self) { i in
                        Canvas { c, s in row.1[i].0.draw(&c, size: s, at: row.1[i].1) }
                            .frame(width: 190, height: 190)
                            .background(Ink.base)
                    }
                    Text(row.0).font(.system(size: 12)).frame(width: 50)
                }
            }
        }
        .padding(8)
    }
}

/// Every movement in order, frame by frame, as PNG files: the real drawing code, no window.
@MainActor func renderFilm(to dir: String, seconds: Double = 13, fps: Double = 60) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var s = BodyScene()
    s.areas = [.urgent, .attention, .attention, .ok, .ok, .attention, .ok, .ok]
    s.go(.sphere, at: 0); s.shape = .sphere; s.previous = .scatter
    s.setLoad(0.1, at: 0)
    var steps: [(Double, (inout BodyScene, Double) -> Void)] = [
        (1.6, { $0.setLoad(0.95, at: $1) }), (3.6, { $0.setLoad(0.1, at: $1) }),
        (4.4, { $0.startCheck(at: $1) }), (6.0, { $0.endCheck(at: $1); $0.go(.text("62"), at: $1) }),
        (7.8, { $0.go(.sphere, at: $1) }), (8.8, { $0.setFocus(0, at: $1) }), (10.0, { $0.setFocus(nil, at: $1) }),
        (10.4, { $0.go(.burst, at: $1) }), (10.9, { $0.go(.tick, at: $1) }),
    ]
    for frame in 0..<Int(seconds * fps) {
        let t = Double(frame) / fps
        while let next = steps.first, t >= next.0 { next.1(&s, t); steps.removeFirst() }
        let now = s
        guard let body = BodyRenderer.image(now, at: t, side: 720) else { continue }
        let r = ImageRenderer(content: Image(decorative: body, scale: 1).padding(20).background(Ink.base))
        guard let image = r.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: dir + String(format: "/f%04d.png", frame)))
    }
}
