// Renders the app icon to an .iconset directory: swift Support/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.96, green: 0.93, blue: 0.86, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.97, blue: 0.92, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.88, blue: 0.78, alpha: 1)])!.draw(in: shape, angle: -90)

    // Open book: two pages
    let cx = rect.midX, cy = rect.midY - s * 0.02
    let pw = rect.width * 0.30, ph = rect.height * 0.42
    let ink = NSColor(srgbRed: 0.33, green: 0.22, blue: 0.15, alpha: 1)
    for side in [-1.0, 1.0] {
        let p = NSBezierPath()
        let x0 = cx, x1 = cx + CGFloat(side) * pw
        p.move(to: NSPoint(x: x0, y: cy - ph / 2))
        p.curve(to: NSPoint(x: x1, y: cy - ph / 2 + s * 0.03), controlPoint1: NSPoint(x: x0 + CGFloat(side) * pw * 0.4, y: cy - ph / 2 - s * 0.02),
                controlPoint2: NSPoint(x: x1 - CGFloat(side) * pw * 0.3, y: cy - ph / 2 + s * 0.02))
        p.line(to: NSPoint(x: x1, y: cy + ph / 2 + s * 0.03))
        p.curve(to: NSPoint(x: x0, y: cy + ph / 2), controlPoint1: NSPoint(x: x1 - CGFloat(side) * pw * 0.3, y: cy + ph / 2 + s * 0.02),
                controlPoint2: NSPoint(x: x0 + CGFloat(side) * pw * 0.4, y: cy + ph / 2 - s * 0.02))
        p.close()
        NSColor.white.setFill(); p.fill()
        ink.setStroke(); p.lineWidth = s * 0.014; p.lineJoinStyle = .round; p.stroke()
        // text lines
        for i in 0..<5 {
            let y = cy + ph / 2 - s * 0.075 - CGFloat(i) * ph * 0.17
            let l = NSBezierPath()
            let a = cx + CGFloat(side) * pw * 0.18, b = cx + CGFloat(side) * pw * (i == 4 ? 0.6 : 0.82)
            l.move(to: NSPoint(x: min(a, b), y: y)); l.line(to: NSPoint(x: max(a, b), y: y))
            l.lineWidth = s * 0.016; l.lineCapStyle = .round
            if side > 0 && (i == 1 || i == 2) {
                NSColor(srgbRed: 1, green: 0.8, blue: 0.16, alpha: 0.85).setStroke()
                let hl = NSBezierPath(); hl.move(to: NSPoint(x: min(a, b) - s * 0.01, y: y)); hl.line(to: NSPoint(x: max(a, b) + s * 0.01, y: y))
                hl.lineWidth = s * 0.05; hl.lineCapStyle = .round; hl.stroke()
            }
            ink.withAlphaComponent(0.55).setStroke(); l.stroke()
        }
    }
    // Sparkle (Claude) in the corner
    let sc = NSPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY - rect.height * 0.2)
    let r = rect.width * 0.085
    let star = NSBezierPath()
    for i in 0..<8 {
        let ang = CGFloat(i) * .pi / 4 + .pi / 2
        let rad = i % 2 == 0 ? r : r * 0.28
        let pt = NSPoint(x: sc.x + cos(ang) * rad, y: sc.y + sin(ang) * rad)
        i == 0 ? star.move(to: pt) : star.line(to: pt)
    }
    star.close()
    NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill(); star.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
