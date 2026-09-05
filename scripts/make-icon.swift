// Draws the VibeJuice app icon with CoreGraphics and writes build/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }
    let s = size
    // macOS icon grid: the squircle sits inside ~10% padding.
    let pad = s * 0.1
    let rect = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let squircle = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil)

    // Shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Tile: deep plum to warm orange, the "juice" palette.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let colors = [NSColor(red: 0.16, green: 0.09, blue: 0.28, alpha: 1).cgColor,
                  NSColor(red: 0.55, green: 0.15, blue: 0.45, alpha: 1).cgColor,
                  NSColor(red: 0.98, green: 0.45, blue: 0.20, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Glass: a tall rounded tumbler, slightly tapered, drawn as a white outline.
    let gw = rect.width * 0.42, gh = rect.height * 0.56
    let gx = rect.midX - gw / 2, gy = rect.minY + rect.height * 0.20
    let glass = CGMutablePath()
    glass.move(to: CGPoint(x: gx, y: gy + gh))
    glass.addLine(to: CGPoint(x: gx + gw * 0.10, y: gy + gh * 0.06))
    glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.18, y: gy), control: CGPoint(x: gx + gw * 0.11, y: gy))
    glass.addLine(to: CGPoint(x: gx + gw * 0.82, y: gy))
    glass.addQuadCurve(to: CGPoint(x: gx + gw * 0.90, y: gy + gh * 0.06), control: CGPoint(x: gx + gw * 0.89, y: gy))
    glass.addLine(to: CGPoint(x: gx + gw, y: gy + gh))
    glass.closeSubpath()

    // Juice level inside the glass, three stacked bands like the quota meters.
    ctx.saveGState()
    ctx.addPath(glass); ctx.clip()
    let levels: [(CGFloat, NSColor)] = [
        (0.62, NSColor(red: 1.0, green: 0.80, blue: 0.30, alpha: 0.95)),
        (0.40, NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 0.95)),
        (0.20, NSColor(red: 1.0, green: 0.42, blue: 0.30, alpha: 0.95)),
    ]
    for (level, color) in levels {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: gx, y: gy, width: gw, height: gh * level))
    }
    // Highlight streak on the glass.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.fill(CGRect(x: gx + gw * 0.16, y: gy + gh * 0.08, width: gw * 0.10, height: gh * 0.86))
    ctx.restoreGState()

    ctx.addPath(glass)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(s * 0.028)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Straw.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.03)
    ctx.move(to: CGPoint(x: gx + gw * 0.62, y: gy + gh * 0.55))
    ctx.addLine(to: CGPoint(x: gx + gw * 0.92, y: gy + gh * 1.28))
    ctx.strokePath()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let base = drawIcon(size: 1024)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try png(base, pixels: px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try png(base, pixels: 1024).write(to: root.appendingPathComponent("docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
