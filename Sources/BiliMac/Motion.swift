import SwiftUI

/// One motion vocabulary for the whole app: springs (velocity + settle) instead of linear fades.
enum Motion {
    /// Page / section changes: quick start, soft landing.
    static let page = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Selection indicators sliding between items.
    static let slide = Animation.spring(response: 0.3, dampingFraction: 0.78)
    /// Hover lift and pops: a little overshoot.
    static let pop = Animation.spring(response: 0.26, dampingFraction: 0.62)
    /// Press feedback: must feel instant.
    static let press = Animation.spring(response: 0.16, dampingFraction: 0.72)
    /// Leaving content gets out of the way fast.
    static let exit = Animation.easeOut(duration: 0.12)
}

/// Shrinks on mouse-down so every click answers immediately, then springs back.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static var pressableCard: PressableStyle { PressableStyle(scale: 0.975) }
}

/// First-screen cards rise in with a short stagger, once per list.
struct Entrance: ViewModifier {
    let index: Int
    let id: String
    let list: PagedList?
    @State private var shown = false

    func body(content: Content) -> some View {
        let animate = index < 16 && !(list?.revealed.contains(id) ?? false)
        content
            .opacity(animate && !shown ? 0 : 1)
            .offset(y: animate && !shown ? 14 : 0)
            .onAppear {
                guard animate else { return }
                withAnimation(Motion.page.delay(Double(index % 16) * 0.022)) { shown = true }
                list?.revealed.insert(id)
            }
    }
}

extension View {
    func entrance(_ index: Int, id: String, list: PagedList?) -> some View {
        modifier(Entrance(index: index, id: id, list: list))
    }
}

/// Chip row whose selected pill slides between options.
struct SlidingChips<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var style: ChipButton.ChipStyle = .pink
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { v, t in
                let on = v == selection
                Button {
                    withAnimation(Motion.slide) { selection = v }
                } label: {
                    Text(t)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onPrimary : Theme.text)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background {
                            if on {
                                Capsule().fill(style == .pink ? Theme.pink : Theme.primary)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            } else {
                                Capsule().fill(Theme.text.opacity(0.07))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

/// When the user last scrolled (wheel, trackpad or momentum), set by `InputRouter`.
@MainActor
enum ScrollActivity {
    static var last = Date.distantPast
    static var active: Bool { Date().timeIntervalSince(last) < 0.15 }
}

/// Hover lift for grid cards. While a list is scrolling, cards passing under a still pointer don't lift:
/// each lift is a spring with a shadow, and a fast scroll set one off for every card it passed. A card the
/// pointer is resting on when scrolling stops lifts then.
private struct CardHover: ViewModifier {
    @Binding var hover: Bool
    @State private var inside = false

    func body(content: Content) -> some View {
        content.onHover { h in
            inside = h
            guard h else {
                if hover { withAnimation(Motion.pop) { hover = false } }
                return
            }
            guard ScrollActivity.active else { withAnimation(Motion.pop) { hover = true }; return }
            Task { @MainActor in
                while ScrollActivity.active { try? await Task.sleep(for: .milliseconds(100)) }
                if inside { withAnimation(Motion.pop) { hover = true } }
            }
        }
    }
}

extension View {
    func cardHover(_ hover: Binding<Bool>) -> some View { modifier(CardHover(hover: hover)) }
}

// MARK: - Layouts that don't measure their children
//
// A stack asks every child how big it wants to be whenever anything inside any child re-lays out. Next to a
// player that ticks (time, bitrate) or a list that scrolls or grows, that measured the other side every time:
// 精选's comment rows were measured again on every chrome update, and the player's bars on every scroll step.

/// Main content on the left, a fixed-width panel on the right, each told its size outright.
struct SideBySide: Layout {
    var panelWidth: CGFloat
    var spacing: CGFloat = 8
    /// 0…1: how far the panel is in (animatable, so the content shrinks as the panel slides in).
    var shown: CGFloat = 1
    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let inset = (panelWidth + spacing) * shown
        subviews.first?.place(at: b.origin, anchor: .topLeading, proposal: ProposedViewSize(width: b.width - inset, height: b.height))
        for s in subviews.dropFirst() {
            s.place(at: CGPoint(x: b.maxX - inset + spacing, y: b.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: panelWidth, height: b.height))
        }
    }
}

/// Children on top of each other, each given the full size (a ZStack that never asks them how big they want to be).
struct FillStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: b.origin, anchor: .topLeading, proposal: ProposedViewSize(b.size)) }
    }
}

/// The first of `levels` variants that fits the width it's given (variant 0 the fullest), trailing-aligned. Unlike
/// ViewThatFits it builds only the variant it shows: the player's control row has five, and every player that
/// appears (entering or leaving 应用内全屏 makes one) built all five — 200–300 ms of a frozen switch.
/// Each variant's width is remembered once seen, so widening steps back without trying variants that don't fit.
struct AdaptiveRow<Content: View>: View {
    let levels: Int
    let height: CGFloat
    @ViewBuilder let content: (Int) -> Content
    @State private var level = 0
    @State private var widths: [Int: CGFloat] = [:]
    @State private var available: CGFloat = .infinity

    var body: some View {
        let shown = level
        let fits = (widths[shown] ?? 0) <= available + 0.5 || shown == levels - 1
        // Over a placeholder that takes the space left: the row's own changes never re-lay out the bar around it.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .trailing) {
                content(shown)
                    .fixedSize()
                    // A fresh view per variant, so a width is always filed under the variant it was measured from
                    // (a reused one reported the next variant's width under the previous level, and the row overlapped).
                    .id(shown)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                        widths[shown] = w
                        settle()
                    }
                    .opacity(fits ? 1 : 0)   // a variant found too wide is hidden for the moment it takes to step down
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                available = w
                settle()
            }
    }

    private func settle() {
        if let w = widths[level], w > available + 0.5, level < levels - 1 { level += 1; return }
        if level > 0, widths[level - 1].map({ $0 <= available + 0.5 }) ?? true { level -= 1 }
    }
}
