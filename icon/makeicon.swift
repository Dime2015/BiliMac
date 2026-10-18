import AppKit
import CoreGraphics

let src = CommandLine.arguments[1], out = CommandLine.arguments[2]
guard let img = NSImage(contentsOfFile: src), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("load") }
let w = cg.width, h = cg.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i+1]), Int(px[i+2])) }
// The knit is busy texture; the backdrop and its shadow are smooth. Find the tile by local contrast.
func lum(_ x: Int, _ y: Int) -> Int { let c = rgb(x, y); return (c.0 * 3 + c.1 * 6 + c.2) / 10 }
func textured(_ x: Int, _ y: Int) -> Bool {
    guard x > 1, y > 1, x < w - 2, y < h - 2 else { return false }
    return abs(lum(x + 2, y) - lum(x - 2, y)) + abs(lum(x, y + 2) - lum(x, y - 2)) > 22
}
func colHit(_ x: Int) -> Bool { var n = 0; for y in stride(from: 0, to: h, by: 2) where textured(x, y) { n += 1 }; return n > h / 12 }
func rowHit(_ y: Int) -> Bool { var n = 0; for x in stride(from: 0, to: w, by: 2) where textured(x, y) { n += 1 }; return n > w / 12 }
let cols = (0..<w).filter(colHit), rows = (0..<h).filter(rowHit)
var box = CGRect(x: cols.first!, y: rows.first!, width: cols.last! - cols.first!, height: rows.last! - rows.first!)
print("tile box (top-left origin)", box)
// Make it square around its centre and pull in a little so the mask lands on knit, not on the soft edge.
// Optional manual framing: centre x, centre y, side (source pixels) — used to centre the TV in the tile.
var side = min(box.width, box.height) - 24
var cx = box.midX, cy = box.midY
if CommandLine.arguments.count >= 6 {
    cx = CGFloat(Double(CommandLine.arguments[3])!); cy = CGFloat(Double(CommandLine.arguments[4])!)
    side = CGFloat(Double(CommandLine.arguments[5])!)
}
box = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
// CGImage cropping uses top-left origin.
let crop = cg.cropping(to: box.integral)!

// Apple icon grid: 1024 canvas, 824 body, continuous corners (~185 radius), soft shadow below.
let S = 1024, body: CGFloat = 824, inset = (CGFloat(S) - body) / 2
let o = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rect = CGRect(x: inset, y: inset + 6, width: body, height: body)   // nudged up to leave room for the shadow
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185).cgPath
o.saveGState()
o.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.32).cgColor)
o.addPath(path); o.setFillColor(NSColor.white.cgColor); o.fillPath()
o.restoreGState()
o.saveGState()
o.addPath(path); o.clip()
o.interpolationQuality = .high
o.draw(crop, in: rect)
// A whisper of top light and edge definition so it reads as a tile at small sizes.
o.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor); o.setLineWidth(3); o.addPath(path); o.strokePath()
o.restoreGState()
let rep = NSBitmapImageRep(cgImage: o.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
