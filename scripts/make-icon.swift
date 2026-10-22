import AppKit
import Foundation

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let s = CGFloat(size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    // Original geometric artwork: an M above two concentric cooling rings.
    // All paths are drawn here; no system symbols, fonts, or external assets.
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let tile = NSBezierPath(roundedRect: rect, xRadius: s * 0.20, yRadius: s * 0.20)
    NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.81, blue: 0.77, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.42, alpha: 1))!
        .draw(in: tile, angle: -65)

    let inset = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.018, dy: s * 0.018),
                             xRadius: s * 0.184, yRadius: s * 0.184)
    NSColor.white.withAlphaComponent(0.17).setStroke()
    inset.lineWidth = s * 0.008
    inset.stroke()

    // The wide, notched M is a custom polygon, rather than a font glyph.
    let monogram = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (0.22, 0.39), (0.22, 0.77), (0.33, 0.77), (0.50, 0.57),
        (0.67, 0.77), (0.78, 0.77), (0.78, 0.39), (0.66, 0.39),
        (0.66, 0.59), (0.50, 0.41), (0.34, 0.59), (0.34, 0.39)
    ]
    monogram.move(to: NSPoint(x: points[0].0 * s, y: points[0].1 * s))
    for point in points.dropFirst() {
        monogram.line(to: NSPoint(x: point.0 * s, y: point.1 * s))
    }
    monogram.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.15)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.016
    shadow.set()
    NSColor(calibratedRed: 0.95, green: 1, blue: 1, alpha: 1).setFill()
    monogram.fill()
    NSGraphicsContext.restoreGraphicsState()

    for centerX: CGFloat in [0.34, 0.66] {
        let center = NSPoint(x: s * centerX, y: s * 0.255)
        let radius = s * 0.072
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        NSColor(calibratedRed: 0.43, green: 0.97, blue: 0.94, alpha: 0.95).setStroke()
        ring.lineWidth = s * 0.025
        ring.stroke()

        let innerRadius = s * 0.028
        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                               width: innerRadius * 2, height: innerRadius * 2))
        NSColor(calibratedRed: 0.72, green: 1, blue: 0.98, alpha: 1).setFill()
        inner.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
