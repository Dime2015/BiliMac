import AppKit
import QuartzCore

/// Debug: counts frames the window missed while something animates. A display-link tick that arrives
/// more than one refresh after the previous one means the main thread didn't get a frame out in time.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, dropped = 0
    private var worst: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var stalls: [String] = []
    /// Debug marks ("detail", "comments"…) with their time since `begin`, logged alongside the stalls.
    static var current: FrameMeter?
    private var marks: [String] = []
    static func mark(_ what: String) {
        guard let m = current, m.link != nil else { return }
        m.marks.append(String(format: "%@@+%.0f", what, (CACurrentMediaTime() - m.started) * 1000))
    }

    func begin(_ view: NSView) {
        frames = 0; dropped = 0; worst = 0; last = 0; stalls = []; marks = []
        Self.current = self
        started = CACurrentMediaTime()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.timestamp
        if last > 0 {
            let dt = t - last
            let interval = max(l.duration, 1.0 / 240)
            dropped += max(0, Int((dt / interval).rounded()) - 1)
            worst = max(worst, dt)
            if dt > 0.025 { stalls.append(String(format: "%.0f@+%.0f", dt * 1000, (last - started) * 1000)) }
        }
        frames += 1
        last = t
    }

    /// "dropped 12 of 96 (13%), worst 83 ms"
    func end() -> String {
        link?.invalidate(); link = nil
        let total = frames + dropped
        return String(format: "dropped %d of %d (%.0f%%), worst %.0f ms", dropped, total,
                      total > 0 ? Double(dropped) / Double(total) * 100 : 0, worst * 1000)
            + (stalls.isEmpty ? "" : " | stalls ms@+ms " + stalls.joined(separator: " "))
            + (marks.isEmpty ? "" : " | " + marks.joined(separator: " "))
    }
}

extension AppModel {
    /// BILIMAC_PERFBENCH=1: page switches, opening videos and a fast scroll, each with a dropped-frame count.
    /// =pages, =video, =scroll, =scrollplaying or =featured runs just that part (=video opens 6 videos, =featured goes 首页 ↔ 精选 4 times).
    func perfBench() async {
        let mode = ProcessInfo.processInfo.environment["BILIMAC_PERFBENCH"] ?? "1"
        if mode == "menus" { await menuCheck(); return }
        // Parts can be combined with "+", e.g. =video+scroll.
        let parts = Set(mode.split(separator: "+").map(String.init))
        let all = parts.isDisjoint(with: ["pages", "video", "scroll", "featured", "scrollplaying"])
        func want(_ p: String) -> Bool { all || parts.contains(p) }
        try? await Task.sleep(for: .seconds(6))
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let root = win.contentView else { return }
        // Frontmost like a window someone is using; in the background, updates can wait for other activity.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        let meter = FrameMeter()
        func measure(_ label: String, seconds: Double, _ action: () -> Void) async {
            meter.begin(root)
            action()
            Self.nudge()
            try? await Task.sleep(for: .seconds(seconds))
            log("bench \(label): \(meter.end())")
            try? await Task.sleep(for: .seconds(0.6))
        }

        // Page switches (each page once cold, then warm).
        var pages: [(String, Route)] = [("动态", .dynamics), ("首页", .home), ("历史", .history), ("稍后再看", .watchLater),
                                        ("首页", .home), ("精选", .featured), ("首页", .home), ("动态", .dynamics), ("首页", .home)]
        if parts.contains("featured") {
            for _ in 0..<4 {
                await measure("page→精选", seconds: 1.5) { go(.featured) }
                await measure("page→首页", seconds: 0.9) { go(.home) }
            }
            go(.featured)
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<4 { await measure("精选 next", seconds: 1.5) { featured.next() } }
        }
        // BILIMAC_BENCH_PAGES=dynamics,home,… replaces the page list (names: home dynamics history watchLater featured).
        if let custom = ProcessInfo.processInfo.environment["BILIMAC_BENCH_PAGES"] {
            let byName: [String: (String, Route)] = ["home": ("首页", .home), "dynamics": ("动态", .dynamics), "history": ("历史", .history),
                                                     "watchLater": ("稍后再看", .watchLater), "featured": ("精选", .featured)]
            pages = custom.split(separator: ",").compactMap { byName[String($0)] }
        }
        if want("pages") { for (name, r) in pages { await measure("page→\(name)", seconds: 0.9) { go(r) } } }

        // Opening videos from the home feed, then back.
        let cards = Array(list(for: homeTab.key).items.prefix(parts == ["video"] ? 6 : 3))
        for (i, c) in cards.enumerated() where want("video") {
            await measure("open video \(i + 1)", seconds: 1.5) {
                open(c)
                // Keep the benchmark quiet.
                Task { for _ in 0..<15 { nowPlaying?.player.isMuted = true; try? await Task.sleep(for: .milliseconds(100)) } }
            }
            await measure("back from video \(i + 1)", seconds: 0.9) { goBack() }
        }

        // =scrollplaying: the same scroll with a video playing in the bottom bar.
        if parts.contains("scrollplaying"), let c = list(for: homeTab.key).items.first {
            open(c)
            for _ in 0..<30 { nowPlaying?.player.isMuted = true; try? await Task.sleep(for: .milliseconds(100)) }
            goBack()
        }

        // Fast scroll down and back up the home feed, ~7000 pt/s.
        go(.home)
        try? await Task.sleep(for: .seconds(1))
        if want("scroll") || parts.contains("scrollplaying"), let sv = Self.visibleScrollView(in: root) {
            log("bench scroll starting")
            for (dir, label) in [(1.0, "scroll down"), (-1.0, "scroll up")] {
                meter.begin(root)
                for _ in 0..<90 {
                    let clip = sv.contentView
                    var o = clip.bounds.origin
                    let maxY = max(0, (sv.documentView?.frame.height ?? 0) - clip.bounds.height)
                    o.y = min(max(0, o.y + dir * 60), maxY)
                    clip.scroll(to: o)
                    sv.reflectScrolledClipView(clip)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                log("bench \(label): \(meter.end())")
                try? await Task.sleep(for: .seconds(0.6))
            }
        }
        log("bench done")
    }

    /// =menus: opens the search panel (as ⌘F does) and logs where floating panels landed, for a screenshot.
    private func menuCheck() async {
        try? await Task.sleep(for: .seconds(5))
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let f = w.contentView?.firstDescendant(of: SearchNSTextField.self) else { log("bench menus: no search field"); return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        SearchNSTextField.focusRequested = true
        w.makeFirstResponder(f)
        try? await Task.sleep(for: .seconds(1.5))
        let field = f.convert(f.bounds, to: nil)
        log(String(format: "bench menus: window %d, field x %.0f–%.0f, top %.0f from window top", w.windowNumber,
                   field.minX, field.maxX, w.contentView!.bounds.height - field.maxY))
        for i in FloatingCenter.shared.items {
            log(String(format: "bench menus: %@ at x %.0f y %.0f w %.0f h %.0f", i.id, i.rect.minX, i.rect.minY, i.rect.width, i.rect.height))
        }
        log("bench menus ready")
    }

    /// A click's state changes are applied when the event finishes; a change made from a Task in a
    /// background window can sit until something else wakes the app. Post an event like a click would.
    private static func nudge() {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// The scroll view under the middle of the window. Kept-alive pages sit underneath, invisible but the
    /// same size, so "the largest scroll view" could be a hidden one; they don't take clicks, so a hit test can't.
    private static func visibleScrollView(in root: NSView) -> NSScrollView? {
        var v = root.hitTest(NSPoint(x: root.bounds.midX, y: root.bounds.midY))
        while let cur = v { if let s = cur as? NSScrollView { return s }; v = cur.superview }
        return nil
    }
}
