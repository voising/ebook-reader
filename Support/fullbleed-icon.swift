// Renders the icon artwork edge to edge on an opaque square: swift fullbleed.swift <source.png> <out.png> [size]
import AppKit
let src = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let px = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 1024
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// The tile inside the generated image (top-left origin, in source pixels).
let crop = cg.cropping(to: CGRect(x: 118, y: 130, width: 788, height: 754))!
let s = CGFloat(px)
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high
// The tile's own cream, so its rounded corners disappear into the background.
ctx.setFillColor(NSColor(srgbRed: 0.953, green: 0.925, blue: 0.871, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
ctx.draw(crop, in: CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: -s * 0.012, dy: -s * 0.012))
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
