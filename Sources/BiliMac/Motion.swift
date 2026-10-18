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
