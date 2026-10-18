import AppKit
import SwiftUI

/// Places the window's close / minimise / zoom buttons on the app's grid instead of the system default,
/// which straddles the top edge of the sidebar panels: centred on the icon rail, or aligned with the
/// sidebar's logo. AppKit lays the buttons out again on resize and focus changes, so this re-applies
/// whenever they move.
@MainActor
final class TrafficLights {
    static let shared = TrafficLights()

    enum Placement: Equatable {
        /// System position (full-window player and full screen lay out around it).
        case system
        /// Centred on the 72 pt icon rail.
        case rail
        /// Left edge on the sidebar content's left edge.
        case sidebar
    }

    var placement: Placement = .system {
        didSet { if placement != oldValue { apply() } }
    }

    private weak var window: NSWindow?
    private var defaults: [NSPoint] = []
    private var observers: [NSObjectProtocol] = []
    private var applying = false

    /// Window padding (8) + rail centre (72 / 2).
    private let railCenterX: CGFloat = 8 + 36
    /// Window padding (8) + sidebar padding (12) + logo row padding (12).
    private let sidebarLeading: CGFloat = 32
    /// Distance from the window's top edge to the buttons' centre: inside the panels, which start at 8.
    private let centerFromTop: CGFloat = 20

    private var buttons: [NSButton] {
        guard let w = window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
    }

    func attach(_ w: NSWindow) {
        guard window !== w else { return }
        window = w
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        defaults = buttons.map(\.frame.origin)
        let nc = NotificationCenter.default
        for b in buttons {
            b.postsFrameChangedNotifications = true
            observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        apply()
    }

    private func apply() {
        guard !applying, let w = window, buttons.count == 3, defaults.count == 3 else { return }
        applying = true
        defer { applying = false }
        let bs = buttons
        if placement == .system || w.styleMask.contains(.fullScreen) {
            for (b, o) in zip(bs, defaults) where b.frame.origin != o { b.setFrameOrigin(o) }
            return
        }
        guard let bar = bs[0].superview else { return }
        let size = bs[0].frame.size
        let width = defaults[2].x + size.width - defaults[0].x
        let left = placement == .rail ? railCenterX - width / 2 : sidebarLeading
        // Keep the buttons inside the titlebar view, or AppKit clips them.
        let barHeight = bar.frame.height
        let top = min(centerFromTop - size.height / 2, barHeight - size.height - 1)
        for (b, o) in zip(bs, defaults) {
            let inWindow = NSPoint(x: left + (o.x - defaults[0].x), y: w.frame.height - top - size.height)
            var p = bar.convert(inWindow, from: nil)
            if bar.isFlipped { p.y -= size.height }
            p = NSPoint(x: p.x.rounded(), y: p.y.rounded())
            if b.frame.origin != p { b.setFrameOrigin(p) }
        }
    }
}

/// Hands the hosting NSWindow to `TrafficLights` once the view is in it.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            // Below this the layout can't fit and SwiftUI would centre an overflowing page, clipping both sides.
            w.contentMinSize = NSSize(width: RootView.minSize.width, height: RootView.minSize.height)
            MainActor.assumeIsolated { TrafficLights.shared.attach(w) }
        }
    }
}
