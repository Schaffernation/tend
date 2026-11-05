// Draw Tend's app icon and write app/AppIcon.icns.
// Usage: swift app/make-icon.swift
//
// The icon is a terminal prompt whose cursor is a sprout: a session you tend.
// It follows the macOS icon grid: an 824-point rounded square on a
// 1024-point canvas.

import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Tile with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Dark green-to-charcoal gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(srgbRed: 0.10, green: 0.30, blue: 0.22, alpha: 1).cgColor,
            NSColor(srgbRed: 0.07, green: 0.11, blue: 0.12, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Prompt chevron.
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(64)
    ctx.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor)
    ctx.move(to: CGPoint(x: 270, y: 640))
    ctx.addLine(to: CGPoint(x: 430, y: 512))
    ctx.addLine(to: CGPoint(x: 270, y: 384))
    ctx.strokePath()

    // Sprout in place of the cursor: a soil line, a stem, and two leaves.
    let green = NSColor(srgbRed: 0.45, green: 0.86, blue: 0.52, alpha: 1).cgColor
    ctx.setStrokeColor(green)
    ctx.setFillColor(green)
    ctx.setLineWidth(56)
    ctx.move(to: CGPoint(x: 520, y: 330))
    ctx.addLine(to: CGPoint(x: 760, y: 330))
    ctx.strokePath()

    ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: 640, y: 340))
    ctx.addCurve(to: CGPoint(x: 640, y: 560),
                 control1: CGPoint(x: 632, y: 420), control2: CGPoint(x: 648, y: 490))
    ctx.strokePath()

    func leaf(from base: CGPoint, to tip: CGPoint, bulge: CGFloat) {
        let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
        let dx = tip.x - base.x, dy = tip.y - base.y
        let len = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / len * bulge, ny = dx / len * bulge
        ctx.move(to: base)
        ctx.addQuadCurve(to: tip, control: CGPoint(x: mid.x + nx, y: mid.y + ny))
        ctx.addQuadCurve(to: base, control: CGPoint(x: mid.x - nx, y: mid.y - ny))
        ctx.fillPath()
    }
    leaf(from: CGPoint(x: 640, y: 500), to: CGPoint(x: 770, y: 610), bulge: 62)
    leaf(from: CGPoint(x: 636, y: 450), to: CGPoint(x: 520, y: 540), bulge: 52)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Tend.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try draw(1024).representation(using: .png, properties: [:])!
    .write(to: here.appendingPathComponent("AppIcon.png"))

let out = here.appendingPathComponent("AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")
