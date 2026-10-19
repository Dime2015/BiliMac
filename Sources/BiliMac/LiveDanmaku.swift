import AppKit
import SwiftUI

/// Scrolling danmaku for live rooms. Unlike a video's list, live danmaku only ever arrive: each one gets its
/// lane once, when it arrives, and keeps it, so nothing on screen jumps when more come in. Text is drawn to an
/// image once; every frame only moves images. Not observable: nothing here makes SwiftUI rebuild the page.
@MainActor
final class LiveDanmakuLayer {
    private struct Item {
        let image: CGImage
        let width: CGFloat
        let lane: Int
        let start: Double
        let speed: CGFloat
    }

    private var items: [Item] = []
    private var size: CGSize = .zero
    private var filter: DanmakuFilter.Compiled?

    private var settings: AppSettings { AppSettings.shared }
    private var duration: Double { 8 / max(settings.danmakuSpeed, 0.25) }
    private var laneHeight: CGFloat { ceil(22 * settings.danmakuScale * 1.4) }

    func add(_ text: String, color: UInt32, at now: Double) {
        guard size.width > 50 else { return }
        let f = DanmakuFilter(settings)
        if filter?.filter != f { filter = DanmakuFilter.Compiled(f) }
        guard filter?.allows(Danmaku(time: 0, mode: 1, size: 25, color: color, text: text)) ?? true,
              let (image, width) = Self.render(text, color: color, scale: settings.danmakuScale) else { return }
        let W = size.width
        let speed = (W + width) / CGFloat(duration)
        let lanes = max(1, Int(size.height * settings.danmakuArea / laneHeight))
        // First lane whose last item has fully come in and that this one won't catch up with before it leaves.
        var lastInLane = [Item?](repeating: nil, count: lanes)
        for it in items where it.lane < lanes { lastInLane[it.lane] = it }
        let gap: CGFloat = 24
        guard let lane = lastInLane.indices.first(where: { l in
            guard let p = lastInLane[l] else { return true }
            let entered = CGFloat(now - p.start) * p.speed >= p.width + gap
            let noCatchUp = CGFloat(p.start + duration - now) * speed <= W
            return entered && noCatchUp
        }) else { return }   // a full screen: drop it rather than pile up
        items.append(Item(image: image, width: width, lane: lane, start: now, speed: speed))
    }

    func draw(_ gc: inout GraphicsContext, size: CGSize, now: Double) {
        self.size = size
        gc.opacity = settings.danmakuOpacity
        items.removeAll { CGFloat(now - $0.start) * $0.speed > size.width + $0.width }
        for it in items {
            let x = size.width - CGFloat(now - it.start) * it.speed
            gc.draw(Image(decorative: it.image, scale: 2), at: CGPoint(x: x, y: CGFloat(it.lane) * laneHeight + 4), anchor: .topLeading)
        }
    }

    func clear() { items.removeAll() }

    private static func render(_ text: String, color: UInt32, scale: Double) -> (CGImage, CGFloat)? {
        let font = NSFont.systemFont(ofSize: 22 * scale, weight: .semibold)
        let c = NSColor(red: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                        blue: CGFloat(color & 0xFF) / 255, alpha: 1)
        let str = text as NSString
        let sz = str.size(withAttributes: [.font: font])
        let px: CGFloat = 2
        let w = Int(ceil(sz.width + 4) * px), h = Int(ceil(sz.height + 4) * px)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: px, y: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let dark = (c.redComponent * 0.3 + c.greenComponent * 0.59 + c.blueComponent * 0.11) < 0.25
        str.draw(at: CGPoint(x: 2, y: 2), withAttributes: [.font: font, .strokeColor: dark ? NSColor.white.withAlphaComponent(0.8)
                                                                                           : NSColor.black.withAlphaComponent(0.75), .strokeWidth: 4])
        str.draw(at: CGPoint(x: 2, y: 2), withAttributes: [.font: font, .foregroundColor: c])
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, sz.width + 4)
    }
}

/// Draws the layer every display frame; reads nothing observable, so only this canvas redraws.
struct LiveDanmakuCanvas: View {
    let layer: LiveDanmakuLayer
    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, size in
                layer.draw(&gc, size: size, now: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }
}
