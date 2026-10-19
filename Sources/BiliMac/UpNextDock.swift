import AppKit
import SwiftUI

/// 精选's 「接下来」: one panel in the top-right corner that morphs between a strip of small thumbnails and the full
/// list. It is a single view whose sizes animate (not two views swapped), so hovering never flickers: the
/// thumbnails themselves grow, the titles fade in under them, and everything shrinks back the same way.
struct UpNextDock: View {
    @ObservedObject var feed: FeaturedModel
    let expanded: Bool
    /// Room below the top edge, so the panel never runs into the controls.
    let maxHeight: CGFloat

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)

    private var thumb: CGSize { expanded ? CGSize(width: 248, height: 140) : CGSize(width: 104, height: 58) }
    /// As many as fit: full cards take far more room than the strip.
    private var shown: [VideoCard] {
        let per = thumb.height + (expanded ? 46 : 6)
        let fixed: CGFloat = expanded ? 100 : 36
        return Array(feed.upNext.prefix(max(1, Int((maxHeight - fixed) / per))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 6) {
            Text(L("接下来"))
                .font(.system(size: 13, weight: .bold))
                .scaleEffect(expanded ? 1 : 0.82, anchor: .leading)
                .foregroundStyle(.white.opacity(expanded ? 0.85 : 0.7))
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .trailing)
            ForEach(shown) { c in
                Item(card: c, size: thumb, expanded: expanded) { feed.jump(to: c) }
            }
            if expanded {
                HStack(spacing: 8) {
                    Button { feed.previous() } label: {
                        Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .disabled(feed.index == 0)
                    .help(L("上一个 ↑"))
                    Button { feed.next() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background(Theme.pink, in: Capsule())
                    }
                    .help(L("下一个 ↓"))
                }
                .buttonStyle(.pressable)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(expanded ? 12 : 8)
        .frame(width: thumb.width + (expanded ? 24 : 16))
        .background {
            RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous)
                .fill(.black.opacity(expanded ? 0.66 : 0.42))
                .overlay(RoundedRectangle(cornerRadius: expanded ? 16 : 11, style: .continuous).strokeBorder(.white.opacity(0.09)))
                .shadow(color: .black.opacity(expanded ? 0.45 : 0.25), radius: expanded ? 24 : 10, y: expanded ? 10 : 4)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .animation(Self.spring, value: expanded)
    }

    private struct Item: View {
        let card: VideoCard
        let size: CGSize
        let expanded: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 7) {
                    Color.clear
                        .frame(width: size.width, height: size.height)
                        .overlay(RemoteImage(url: thumbnail(card.cover, width: 500)))
                        .overlay(alignment: .bottomTrailing) {
                            DurationBadge(seconds: card.duration)
                                .opacity(expanded ? 1 : 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: expanded ? 10 : 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: expanded ? 10 : 6, style: .continuous)
                            .strokeBorder(.white.opacity(hover ? 0.35 : 0.1)))
                        .brightness(hover ? 0.05 : 0)
                    if expanded {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            if !card.owner.isEmpty {
                                Text(card.owner).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: size.width, alignment: .leading)
                        // Text arrives once the picture has mostly grown, and leaves first.
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCard)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
            .help(expanded ? "" : card.title)
        }
    }
}


/// Pointer enter / exit through an AppKit tracking area. SwiftUI's onHover never fires for views floating over
/// the player (its video views take the pointer events); a tracking area works whatever is underneath.
struct PointerTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let v = TrackingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: TrackingView, context: Context) { v.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var inside = false
        private var watch: Timer?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // Rebuilt on every resize (the panel grows under the pointer): say whether the pointer is already
            // inside, or AppKit never sends the "exited" for this area.
            let here = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
            var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
            if here { options.insert(.assumeInside) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
            set(here)
        }

        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseMoved(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the buttons above

        private func set(_ on: Bool) {
            guard on != inside else { return }
            inside = on
            onChange?(on)
            // While inside, also check the pointer's position: an "exited" can still go missing (the panel moves
            // or resizes under it), and the panel must never stay open with the pointer gone.
            watch?.invalidate()
            watch = nil
            if on {
                watch = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let w = self.window, w.isVisible else { self.set(false); return }
                        if !self.bounds.contains(self.convert(w.mouseLocationOutsideOfEventStream, from: nil)) { self.set(false) }
                    }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { watch?.invalidate(); watch = nil }
        }
    }
}
