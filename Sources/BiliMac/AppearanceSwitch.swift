import AppKit
import SwiftUI

/// Light · Dark · System, next to the avatar. Same height and frosted capsule as the round buttons
/// around it; the selected pill slides between icons and the window cross-fades to the new look.
struct AppearanceSwitch: View {
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var ns

    private let items: [(AppAppearance, String)] = [
        (.light, "sun.max.fill"),
        (.dark, "moon.fill"),
        (.system, "circle.lefthalf.filled"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { mode, icon in
                Segment(icon: icon, selected: settings.appearance == mode, ns: ns) { select(mode) }
                    .help(Lf("外观：%@", mode.label))
                    .accessibilityLabel(Lf("外观：%@", mode.label))
            }
        }
        .padding(3)
        .background(Theme.floatingButton, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.text.opacity(0.06)))
    }

    private func select(_ mode: AppAppearance) {
        guard settings.appearance != mode else { return }
        AppearanceTransition.crossfade {
            withAnimation(Motion.slide) { settings.appearance = mode }
        }
    }

    private struct Segment: View {
        let icon: String
        let selected: Bool
        let ns: Namespace.ID
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Theme.pink : (hover ? Theme.text : Theme.text3))
                    .symbolEffect(.bounce, value: selected)
                    .frame(width: 30, height: 30)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Theme.text.opacity(0.12))
                                .matchedGeometryEffect(id: "appearance", in: ns)
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .onHover { hover = $0 }
        }
    }
}

/// Snapshots the window, applies the change underneath, then fades the snapshot out, so an
/// appearance switch reads as one smooth transition instead of every colour snapping at once.
@MainActor
enum AppearanceTransition {
    static func crossfade(_ change: () -> Void) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            change()
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        let cover = NSImageView(frame: content.bounds)
        cover.image = image
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        cover.wantsLayer = true
        content.addSubview(cover)
        change()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cover.animator().alphaValue = 0
        } completionHandler: {
            cover.removeFromSuperview()
        }
    }
}
