// Shrinks the artwork inside the generated tile, refilling the margin with the tile's own gradient:
// swift inset-art.swift <source.png> <out.png> [scale] [flat]  (flat: no rim, for the full-bleed iOS icon)
import AppKit
import CoreImage
let src = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))!
let k = CommandLine.arguments.count > 3 ? CGFloat(Double(CommandLine.arguments[3])!) : 0.86
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = cg.width, h = cg.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// Tile region (top-left origin) and the same rect in CG's bottom-left space.
let tileTL = CGRect(x: 118, y: 130, width: 788, height: 754)
let tile = CGRect(x: tileTL.minX, y: CGFloat(h) - tileTL.maxY, width: tileTL.width, height: tileTL.height)
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

// Content shrunk about the tile centre, faded out at its edges.
let inner = CGRect(x: tile.midX - tile.width * k / 2, y: tile.midY - tile.height * k / 2, width: tile.width * k, height: tile.height * k)
let maskCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
maskCtx.setFillColor(gray: 0, alpha: 1); maskCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
maskCtx.setFillColor(gray: 1, alpha: 1)
let soft = inner.insetBy(dx: 40, dy: 40)
maskCtx.addPath(CGPath(roundedRect: soft, cornerWidth: 110, cornerHeight: 110, transform: nil)); maskCtx.fillPath()
let ci = CIContext()
let blurred = CIImage(cgImage: maskCtx.makeImage()!).clampedToExtent()
    .applyingGaussianBlur(sigma: 14).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
let mask = ci.createCGImage(blurred, from: blurred.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!

let shrunk = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
shrunk.interpolationQuality = .high
shrunk.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask)
let full = CGRect(x: 0, y: 0, width: w, height: h)
shrunk.draw(cg, in: CGRect(x: tile.midX - (tile.midX - full.minX) * k, y: tile.midY - (tile.midY - full.minY) * k,
                           width: CGFloat(w) * k, height: CGFloat(h) * k))

let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: full)
// Repaint the tile interior with its lighting: lighter top-left, warmer bottom-right.
ctx.saveGState()
let flat = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "flat"
ctx.clip(to: flat ? full : tile.insetBy(dx: 6, dy: 6))
let grad = CGGradient(colorsSpace: space, colors: [rgb(253, 249, 238), rgb(246, 240, 230), rgb(235, 229, 219)] as CFArray,
                      locations: [0, 0.45, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: tile.minX + 60, y: tile.maxY - 60), end: CGPoint(x: tile.maxX - 60, y: tile.minY + 60), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()
ctx.draw(shrunk.makeImage()!, in: full)
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
