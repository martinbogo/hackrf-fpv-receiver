// Renders the app icon: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)])!.draw(in: shape, angle: -90)
    // screen with PAL colour bars
    let screen = NSRect(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.2,
                        width: rect.width * 0.68, height: rect.width * 0.51)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: s * 0.02, yRadius: s * 0.02).addClip()
    let bars: [NSColor] = [.white, .systemYellow, .systemTeal, .systemGreen, .systemPink, .systemRed, .systemBlue]
    for (i, c) in bars.enumerated() {
        c.setFill()
        NSRect(x: screen.minX + screen.width * CGFloat(i) / 7, y: screen.minY,
               width: screen.width / 7 + 1, height: screen.height).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    // radio waves above the screen
    NSColor.white.setStroke()
    let c = NSPoint(x: rect.midX, y: screen.maxY + rect.height * 0.02)
    for (i, r) in [0.07, 0.13, 0.19].enumerated() {
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: rect.width * r, startAngle: 40, endAngle: 140)
        p.lineWidth = s * 0.028
        p.lineCapStyle = .round
        NSColor.white.withAlphaComponent(1 - 0.22 * CGFloat(i)).setStroke()
        p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
