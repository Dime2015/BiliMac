import AppKit
import AVFoundation
import Compression
import SwiftUI

struct Danmaku {
    let time: Double
    let mode: Int        // 1–3 scrolling, 4 bottom, 5 top
    let size: Double
    let color: UInt32
    let text: String
    /// Sender's hashed mid (for blocking a user).
    var sender = ""
    /// bilibili's 0–10 quality weight (屏蔽等级 hides those below the level); 10 when the list doesn't say.
    var weight = 10

    static func load(cid: Int) async throws -> [Danmaku] {
        var data = try await BiliAPI.shared.danmaku(cid: cid)
        if data.first != UInt8(ascii: "<"), let inflated = inflateRaw(data) { data = inflated }
        let p = DanmakuParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.items.sorted { $0.time < $1.time }
    }

    /// Danmaku density across the video, smoothed and scaled to 0…1. Stands in for bilibili's
    /// 高能进度条, whose endpoint (pbp/data) now returns 404 — it was danmaku density too.
    static func heat(_ list: [Danmaku], duration: Double) -> [Double] {
        guard duration > 30, list.count >= 40 else { return [] }
        let bins = min(max(Int(duration / 5), 60), 150)
        var counts = [Double](repeating: 0, count: bins)
        for d in list where d.time >= 0 && d.time < duration {
            counts[min(Int(d.time / duration * Double(bins)), bins - 1)] += 1
        }
        let kernel = [0.05, 0.12, 0.2, 0.26, 0.2, 0.12, 0.05]
        let smooth = counts.indices.map { i in
            kernel.indices.reduce(0.0) { acc, j in
                let x = i + j - kernel.count / 2
                return acc + (counts.indices.contains(x) ? counts[x] * kernel[j] : 0)
            }
        }
        // Scale between the quietest stretch and the 97th percentile so one spike doesn't flatten the rest.
        // The opening seconds (前排 / 打卡 danmaku) are left out of the scale; they just clamp to the top.
        let sorted = smooth.dropFirst(3).sorted()
        let low = sorted[sorted.count / 20], high = sorted[Int(Double(sorted.count - 1) * 0.97)]
        guard high - low > 0.01 else { return [] }
        return smooth.map { min(max(($0 - low) / (high - low), 0), 1) }
    }

    private static func inflateRaw(_ d: Data) -> Data? {
        let cap = max(d.count * 12, 1 << 20)
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { o in
            d.withUnsafeBytes { i in
                compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          i.bindMemory(to: UInt8.self).baseAddress!, d.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? out.prefix(n) : nil
    }
}

private final class DanmakuParser: NSObject, XMLParserDelegate {
    var items: [Danmaku] = []
    private var attrs: [String]?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        if name == "d" { attrs = attributes["p"]?.components(separatedBy: ","); text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if attrs != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "d", let a = attrs, a.count >= 4 else { attrs = nil; return }
        attrs = nil
        let mode = Int(a[1]) ?? 1
        guard [1, 2, 3, 4, 5].contains(mode), !text.isEmpty else { return }
        // p = time, mode, size, colour, ctime, pool, sender hash, dmid, weight
        items.append(Danmaku(time: Double(a[0]) ?? 0, mode: mode, size: Double(a[2]) ?? 25,
                             color: UInt32(a[3]) ?? 0xFFFFFF, text: text,
                             sender: a.count > 6 ? a[6] : "", weight: a.count > 8 ? Int(a[8]) ?? 10 : 10))
    }
}

/// 屏蔽设定: which danmaku to leave out.
struct DanmakuFilter: Equatable {
    var scroll = false, top = false, bottom = false, color = false
    var level = 0
    var rules: [String] = []

    init(_ s: AppSettings) {
        scroll = s.danmakuBlockScroll; top = s.danmakuBlockTop; bottom = s.danmakuBlockBottom; color = s.danmakuBlockColor
        level = s.danmakuLevel; rules = s.danmakuBlocklist
    }

    /// Rules split by kind, regexes compiled once per change.
    struct Compiled {
        let filter: DanmakuFilter
        let words: [String]
        let regexes: [NSRegularExpression]
        let senders: Set<String>

        init(_ f: DanmakuFilter) {
            filter = f
            var w: [String] = [], r: [NSRegularExpression] = [], u = Set<String>()
            for rule in f.rules {
                if let hash = DanmakuFilter.sender(rule) { u.insert(hash) }
                else if let pattern = DanmakuFilter.regex(rule) {
                    if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) { r.append(re) }
                } else if !rule.isEmpty { w.append(rule) }
            }
            words = w; regexes = r; senders = u
        }

        func allows(_ d: Danmaku) -> Bool {
            switch d.mode {
            case 4: if filter.bottom { return false }
            case 5: if filter.top { return false }
            default: if filter.scroll { return false }
            }
            if filter.color, d.color & 0xFFFFFF != 0xFFFFFF { return false }
            if filter.level > 0, d.weight < filter.level { return false }
            if !senders.isEmpty, senders.contains(d.sender) { return false }
            for w in words where d.text.range(of: w, options: .caseInsensitive) != nil { return false }
            let range = NSRange(d.text.startIndex..., in: d.text)
            for re in regexes where re.firstMatch(in: d.text, range: range) != nil { return false }
            return true
        }
    }

    static func regex(_ rule: String) -> String? {
        rule.count > 2 && rule.hasPrefix("/") && rule.hasSuffix("/") ? String(rule.dropFirst().dropLast()) : nil
    }
    static func sender(_ rule: String) -> String? { rule.hasPrefix("u:") ? String(rule.dropFirst(2)) : nil }
}

/// Lays danmaku out into lanes (time-based, so seeking just works) and draws them on a Canvas.
final class DanmakuEngine {
    private struct Placed {
        let index: Int
        let start: Double
        let lane: Int
        let width: CGFloat
        let kind: Int          // 0 scroll, 1 top, 2 bottom
    }

    private struct Key: Equatable {
        let count: Int, first: Double, width: CGFloat, height: CGFloat, scale: Double, speed: Double, area: Double, filter: DanmakuFilter
    }

    private var key: Key?
    private var placed: [Placed] = []
    private var laneHeight: CGFloat = 30
    private var duration: Double = 8
    private var images: [Int: CGImage] = [:]
    private var imageScale: Double = 0
    private let fixedDuration = 4.0

    private func font(_ d: Danmaku, _ scale: Double) -> NSFont {
        let base = 22 * scale * (d.size >= 30 ? 1.2 : d.size <= 20 ? 0.8 : 1)
        return NSFont.systemFont(ofSize: base, weight: .semibold)
    }

    private func layout(_ list: [Danmaku], size: CGSize, s: AppSettings) {
        let k = Key(count: list.count, first: list.first?.time ?? 0, width: size.width, height: size.height,
                    scale: s.danmakuScale, speed: s.danmakuSpeed, area: s.danmakuArea, filter: DanmakuFilter(s))
        guard k != key else { return }
        if imageScale != s.danmakuScale { images.removeAll(); imageScale = s.danmakuScale }
        key = k
        let filter = DanmakuFilter.Compiled(k.filter)
        duration = 8 / max(s.danmakuSpeed, 0.25)
        laneHeight = ceil(22 * s.danmakuScale * 1.4)
        let lanes = max(1, Int(size.height * s.danmakuArea / laneHeight))
        let fixedLanes = max(1, Int(size.height * 0.5 / laneHeight))
        let W = size.width
        var scrollLast = [(start: Double, w: CGFloat, v: CGFloat)?](repeating: nil, count: lanes)
        var topLast = [Double](repeating: -100, count: fixedLanes)
        var bottomLast = [Double](repeating: -100, count: fixedLanes)
        var out: [Placed] = []
        out.reserveCapacity(list.count)
        for (i, d) in list.enumerated() {
            guard filter.allows(d) else { continue }
            let w = (d.text as NSString).size(withAttributes: [.font: font(d, s.danmakuScale)]).width + 4
            if d.mode == 4 || d.mode == 5 {
                if d.mode == 5, let l = topLast.firstIndex(where: { d.time >= $0 + fixedDuration }) {
                    topLast[l] = d.time
                    out.append(Placed(index: i, start: d.time, lane: l, width: w, kind: 1))
                } else if d.mode == 4, let l = bottomLast.firstIndex(where: { d.time >= $0 + fixedDuration }) {
                    bottomLast[l] = d.time
                    out.append(Placed(index: i, start: d.time, lane: l, width: w, kind: 2))
                }
                continue
            }
            let v = (W + w) / CGFloat(duration)
            let gap: CGFloat = 24
            let lane = scrollLast.firstIndex { prev in
                guard let p = prev else { return true }
                let entered = CGFloat(d.time - p.start) * p.v >= p.w + gap
                let noCatchUp = CGFloat(p.start + duration - d.time) * v <= W
                return entered && noCatchUp
            }
            if let lane {
                scrollLast[lane] = (d.time, w, v)
                out.append(Placed(index: i, start: d.time, lane: lane, width: w, kind: 0))
            }
        }
        placed = out
    }

    private func image(_ i: Int, _ d: Danmaku, scale: Double) -> CGImage? {
        if let img = images[i] { return img }
        let f = font(d, scale)
        let c = NSColor(red: CGFloat((d.color >> 16) & 0xFF) / 255, green: CGFloat((d.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(d.color & 0xFF) / 255, alpha: 1)
        let str = d.text as NSString
        let sz = str.size(withAttributes: [.font: f])
        let px: CGFloat = 2
        let w = Int(ceil(sz.width + 4) * px), h = Int(ceil(sz.height + 4) * px)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: px, y: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let isDark = (c.redComponent * 0.3 + c.greenComponent * 0.59 + c.blueComponent * 0.11) < 0.25
        let stroke: NSColor = isDark ? .white.withAlphaComponent(0.8) : .black.withAlphaComponent(0.75)
        str.draw(at: CGPoint(x: 2, y: 2), withAttributes: [.font: f, .strokeColor: stroke, .strokeWidth: 4])
        str.draw(at: CGPoint(x: 2, y: 2), withAttributes: [.font: f, .foregroundColor: c])
        NSGraphicsContext.restoreGraphicsState()
        let img = ctx.makeImage()
        images[i] = img
        if images.count > 3000 { images.removeAll() }
        return img
    }

    func draw(_ gc: inout GraphicsContext, size: CGSize, time t: Double, list: [Danmaku], settings s: AppSettings) {
        guard !list.isEmpty, size.width > 50, t.isFinite else { return }
        layout(list, size: size, s: s)
        gc.opacity = s.danmakuOpacity
        // First item that could still be on screen.
        var lo = 0, hi = placed.count
        let earliest = t - max(duration, fixedDuration)
        while lo < hi {
            let m = (lo + hi) / 2
            if placed[m].start < earliest { lo = m + 1 } else { hi = m }
        }
        var i = lo
        while i < placed.count, placed[i].start <= t {
            let p = placed[i]
            i += 1
            let d = list[p.index]
            let age = t - p.start
            var pt: CGPoint
            switch p.kind {
            case 0:
                guard age <= duration else { continue }
                let v = (size.width + p.width) / CGFloat(duration)
                pt = CGPoint(x: size.width - CGFloat(age) * v, y: CGFloat(p.lane) * laneHeight + 4)
            case 1:
                guard age <= fixedDuration else { continue }
                pt = CGPoint(x: (size.width - p.width) / 2, y: CGFloat(p.lane) * laneHeight + 4)
            default:
                guard age <= fixedDuration else { continue }
                pt = CGPoint(x: (size.width - p.width) / 2, y: size.height - CGFloat(p.lane + 1) * laneHeight - 56)
            }
            guard let img = image(p.index, d, scale: s.danmakuScale) else { continue }
            gc.draw(Image(decorative: img, scale: 2), at: pt, anchor: .topLeading)
        }
    }
}

struct DanmakuOverlay: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var masker: PersonMasker
    @State private var engine = DanmakuEngine()

    init(controller: PlayerController) {
        self.controller = controller
        self.clock = controller.clock
        masker = controller.masker
    }

    private var avoiding: Bool { settings.danmakuOn && settings.danmakuAvoidPeople && !controller.danmaku.isEmpty }

    var body: some View {
        Group {
            if settings.danmakuOn, !controller.danmaku.isEmpty {
                TimelineView(.animation(minimumInterval: nil, paused: !clock.playing)) { _ in
                    Canvas { gc, size in
                        let _ = masker.version
                        // Own layer, so cutting out the people only clears danmaku pixels.
                        gc.drawLayer { layer in
                            engine.draw(&layer, size: size, time: controller.player.currentTime().seconds,
                                        list: controller.danmaku, settings: settings)
                            if avoiding, let m = masker.mask {
                                layer.opacity = 1
                                layer.blendMode = .destinationOut
                                layer.draw(Image(decorative: m, scale: 1), in: pictureRect(in: size))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { masker.setActive(avoiding) }
        .onDisappear { masker.setActive(false) }
        .onChange(of: avoiding) { _, on in masker.setActive(on) }
    }

    /// Where the picture sits inside the overlay (the layer letterboxes with resizeAspect).
    private func pictureRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard let v = controller.video, v.width > 0, v.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: CGSize(width: v.width, height: v.height), insideRect: bounds)
    }
}
