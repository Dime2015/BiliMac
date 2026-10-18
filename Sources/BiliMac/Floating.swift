import SwiftUI

/// Self-drawn menus and panels, used instead of NSMenu / NSPopover so everything matches the app.
///
/// A view attaches `.floatingPanel(...)`; while presented it publishes its bounds and content as a
/// preference. `FloatingLayer` (applied once at the window root) draws the panel above everything,
/// so panels are never clipped by rounded page panels or scroll views.
enum FloatingPlacement {
    enum Align { case leading, center, trailing }
    case below(Align)
    case above(Align)
    /// To the left of the anchor, bottoms aligned (精选's action rail).
    case left
}

struct FloatingItem: Identifiable {
    let id: String
    let anchor: Anchor<CGRect>
    let placement: FloatingPlacement
    let content: AnyView
    let dismiss: () -> Void
}

struct FloatingKey: PreferenceKey {
    static var defaultValue: [FloatingItem] = []
    static func reduce(value: inout [FloatingItem], nextValue: () -> [FloatingItem]) { value += nextValue() }
}

@MainActor
final class FloatingCenter {
    static let shared = FloatingCenter()
    fileprivate var items: [FloatingItem] = []
    var isOpen: Bool { !items.isEmpty }
    func dismissAll() { items.forEach { $0.dismiss() } }
}

extension View {
    func floatingPanel<C: View>(id: String, isPresented: Binding<Bool>, placement: FloatingPlacement = .below(.leading),
                                @ViewBuilder content: @escaping () -> C) -> some View {
        anchorPreference(key: FloatingKey.self, value: .bounds) { a in
            isPresented.wrappedValue
                ? [FloatingItem(id: id, anchor: a, placement: placement, content: AnyView(content()),
                                dismiss: { withAnimation(Motion.exit) { isPresented.wrappedValue = false } })]
                : []
        }
    }

    /// Apply once at the window root.
    func floatingLayer() -> some View {
        overlayPreferenceValue(FloatingKey.self) { items in
            GeometryReader { geo in
                let _ = FloatingCenter.shared.items = items
                ZStack(alignment: .topLeading) {
                    if !items.isEmpty {
                        // Outside clicks close panels; the anchors themselves stay clickable (toggle buttons, search field).
                        let holes = items.map { geo[$0.anchor] }
                        Color.black.opacity(0.001)
                            .contentShape(Path { p in
                                p.addRect(CGRect(origin: .zero, size: geo.size))
                                for h in holes { p.addRect(h) }
                            }, eoFill: true)
                            .onTapGesture { items.forEach { $0.dismiss() } }
                    }
                    ForEach(items) { item in
                        FloatingPlaced(item: item, rect: geo[item.anchor], bounds: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct FloatingPlaced: View {
    let item: FloatingItem
    let rect: CGRect
    let bounds: CGSize
    @State private var shown = false
    private let gap: CGFloat = 8
    private let margin: CGFloat = 8

    var body: some View {
        item.content
            .fixedSize()
            .alignmentGuide(.leading) { d in -x(d.width) }
            .alignmentGuide(.top) { d in -y(d.height) }
            .scaleEffect(shown ? 1 : 0.94, anchor: scaleAnchor)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.pop) { shown = true } }
    }

    private func clampX(_ x: CGFloat, _ w: CGFloat) -> CGFloat { min(max(x, margin), bounds.width - margin - w) }
    private func clampY(_ y: CGFloat, _ h: CGFloat) -> CGFloat { min(max(y, margin), bounds.height - margin - h) }

    private func x(_ w: CGFloat) -> CGFloat {
        switch item.placement {
        case .below(let a), .above(let a):
            switch a {
            case .leading: return clampX(rect.minX, w)
            case .center: return clampX(rect.midX - w / 2, w)
            case .trailing: return clampX(rect.maxX - w, w)
            }
        case .left: return clampX(rect.minX - gap - w, w)
        }
    }

    private func y(_ h: CGFloat) -> CGFloat {
        switch item.placement {
        case .below: return clampY(rect.maxY + gap, h)
        case .above: return clampY(rect.minY - gap - h, h)
        case .left: return clampY(rect.maxY - h, h)
        }
    }

    private var scaleAnchor: UnitPoint {
        switch item.placement {
        case .below(let a): return a == .leading ? .topLeading : a == .trailing ? .topTrailing : .top
        case .above(let a): return a == .leading ? .bottomLeading : a == .trailing ? .bottomTrailing : .bottom
        case .left: return .bottomTrailing
        }
    }
}

// MARK: - Panel chrome and rows

struct MenuSurface<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(4)
            .frame(width: width, alignment: .leading)
            .background(Theme.menu, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.text.opacity(0.07)))
            .shadow(color: Theme.shadow, radius: 24, y: 12)
            .foregroundStyle(Theme.text)
    }
}

struct MenuRow: View {
    let title: String
    var icon: String? = nil
    var detail: String? = nil
    var selected = false
    var enabled = true
    var highlighted = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                        .foregroundStyle(enabled ? Theme.text2 : Theme.text3)
                }
                Text(title).font(.system(size: 13.5, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Theme.pink : (enabled ? Theme.text : Theme.text3))
                    .lineLimit(1)
                Spacer(minLength: 16)
                if let detail { Text(detail).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.pink) }
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.pink) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background((hover || highlighted) && enabled ? Theme.menuHover : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}

struct MenuDivider: View {
    var body: some View { Rectangle().fill(Theme.text.opacity(0.08)).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
}

struct MenuHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.text3)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }
}
