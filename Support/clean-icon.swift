// Re-masks Codex's icon onto a clean macOS icon canvas and writes an .iconset.
// swift Support/clean-icon.swift <source.png> <out.iconset>
import AppKit

let src = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// Inner tile region of the generated image (top-left origin, in source pixels).
let crop = cg.cropping(to: CGRect(x: 118, y: 130, width: 788, height: 754))!

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Apple grid: 824/1024 tile, ~185/824 corner radius.
    let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024 + s * 0.008, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(srgbRed: 0.95, green: 0.92, blue: 0.86, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.draw(crop, in: tile.insetBy(dx: -s * 0.004, dy: -s * 0.004))
    ctx.restoreGState()
    // Hairline edge for definition on light backgrounds.
    ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor); ctx.setLineWidth(max(1, s / 512)); ctx.strokePath()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
