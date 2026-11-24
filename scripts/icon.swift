// Draws Resources/Pulse.icns: the body of dots on near-black.   swift scripts/icon.swift
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Pulse.icns")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Pulse-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext, s = CGFloat(side)
    // Apple's grid: the plate is 824 of 1024, with a radius of 185.
    let plate = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: plate, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    c.addPath(path); c.setFillColor(CGColor(red: 0.031, green: 0.031, blue: 0.035, alpha: 1)); c.fillPath()
    c.addPath(path); c.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14)); c.setLineWidth(max(s / 512, 0.5)); c.strokePath()
    // Fewer, larger dots on the small sizes: a few hundred would be grey mush there.
    let count = side <= 32 ? 46 : side <= 64 ? 110 : side <= 128 ? 220 : 420
    let half = plate.width * 0.36, dot = 1.3 / Double(count).squareRoot()
    let tilt = 0.5, turn = 0.6
    for i in 0..<count {
        let y = 1 - 2 * (Double(i) + 0.5) / Double(count), a = Double(i) * 2.399963229728653 + turn, r = (1 - y * y).squareRoot()
        let x = cos(a) * r, z = sin(a) * r
        let y2 = y * cos(tilt) - z * sin(tilt), z2 = y * sin(tilt) + z * cos(tilt)
        guard z2 > -0.1 else { continue }
        let light = 0.18 + 0.82 * max(0, z2 * 0.75 + x * -0.25 + y2 * 0.35)
        let size = dot * (0.35 + 0.65 * max(0, z2)) * Double(half)
        c.setFillColor(CGColor(red: 0.965, green: 0.965, blue: 0.97, alpha: min(light, 1)))
        c.fillEllipse(in: CGRect(x: Double(plate.midX) + x * Double(half) - size, y: Double(plate.midY) + y2 * Double(half) - size, width: size * 2, height: size * 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
exit(p.terminationStatus)
