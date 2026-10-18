import AppKit
import CoreImage
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension Theme {
    static let ground = Color.black
    static let panel = Color(hex: 0x121212)
    static let elevated = Color(hex: 0x1F1F1F)
    static let raised = Color(hex: 0x242424)
    static let chip = Color(hex: 0x2A2A2A)
    static let line = Color(hex: 0x535353)
    static let text2 = Color(hex: 0xB3B3B3)
    static let text3 = Color(hex: 0x7A7A7A)
    static let defaultTint = Color(hex: 0x5B2A43)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
}

// MARK: - Cover colour (Spotify-style header tint)

@MainActor
final class TintCache {
    static let shared = TintCache()
    private var cache: [URL: Color] = [:]
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    func tint(for url: URL?) async -> Color? {
        guard let url else { return nil }
        if let c = cache[url] { return c }
        guard let img = await ImageCache.shared.load(thumbnail(url, width: 160) ?? url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        ns.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        let c = Color(hue: h, saturation: min(max(s * 1.25, 0.25), 0.62), brightness: 0.36)
        cache[url] = c
        return c
    }
}

/// Panel with the tinted top fade used by the home and video pages.
struct TintedPanel<Content: View>: View {
    var tint: Color = Theme.defaultTint
    var height: CGFloat = 340
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .top) {
            Theme.panel
            LinearGradient(colors: [tint, tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .animation(.easeOut(duration: 0.6), value: tint)
            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Buttons

struct CircleIconButton: View {
    let icon: String
    var label: String
    var size: CGFloat = 34
    var enabled = true
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(enabled ? .white : Theme.text3)
                .frame(width: size, height: size)
                .background(Color.black.opacity(hover && enabled ? 0.75 : 0.55), in: Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ChipButton: View {
    let title: String
    let selected: Bool
    var style: ChipStyle = .pink
    var action: () -> Void
    enum ChipStyle { case pink, white }
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 13).padding(.vertical, 6)
                .background(selected ? (style == .pink ? Theme.pink : .white) : Color.white.opacity(hover ? 0.16 : 0.1), in: Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

struct PillButton: View {
    let title: String
    var icon: String?
    var filled = false
    var tint: Color = Theme.pink
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 13.5, weight: filled ? .bold : .medium)).monospacedDigit()
            }
            .foregroundStyle(filled ? .black : .white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(filled ? tint.opacity(hover ? 0.9 : 1) : Color.white.opacity(hover ? 0.06 : 0), in: Capsule())
            .overlay(Capsule().strokeBorder(filled ? .clear : (hover ? .white : Theme.line), lineWidth: 1))
            .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.pressable)
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
    }
}

/// Pink switch from the settings design.
struct PinkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.pink : Theme.line).frame(width: 40, height: 22)
                    Circle().fill(configuration.isOn ? Color.black : Theme.panel).frame(width: 16, height: 16).padding(3)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

struct DropdownLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 13.5))
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Covers & cards

struct Cover: View {
    let url: URL?
    var width = 480
    var radius: CGFloat = 6
    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RemoteImage(url: thumbnail(url, width: width)))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct DurationBadge: View {
    let seconds: Int?
    var body: some View {
        if let s = seconds, s > 0 {
            Text(formatDuration(s))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
    }
}

struct ProgressLine: View {
    let card: VideoCard
    var body: some View {
        if let p = card.progress, let d = card.duration, d > 0, p != 0 {
            GeometryReader { g in
                Rectangle().fill(Theme.pink).frame(width: g.size.width * (p < 0 ? 1 : min(1, CGFloat(p) / CGFloat(d))))
            }
            .frame(height: 3)
        }
    }
}

/// Grid card: cover with shadow, hover reveals a pink play button.
struct ShelfCard: View {
    let card: VideoCard
    var meta: String?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Cover(url: card.cover, width: 560)
                .overlay(alignment: .bottomTrailing) { DurationBadge(seconds: card.duration) }
                .overlay(alignment: .bottom) { ProgressLine(card: card) }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Theme.pink, in: Circle())
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        .padding(.trailing, 8).padding(.bottom, 26)
                        .scaleEffect(hover ? 1 : 0.55)
                        .opacity(hover ? 1 : 0)
                        .offset(y: hover ? 0 : 6)
                }
                // Shadow only while lifted: always-on shadows on every cover make page switches and scrolling heavy.
                .shadow(color: .black.opacity(hover ? 0.55 : 0), radius: hover ? 16 : 0, y: hover ? 10 : 0)
                .offset(y: hover ? -3 : 0)
            Text(card.title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(2)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                .foregroundStyle(.white)
            Text(meta ?? defaultMeta)
                .font(.system(size: 12.5))
                .foregroundStyle(Color(hex: 0xA7A7A7))
                .lineLimit(1)
        }
        .padding(10)
        .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
    }

    private var defaultMeta: String {
        var parts = [card.owner]
        if let r = card.reason { parts = [r] + parts }
        if let v = card.views { parts.append(Lf("%@ 播放", "\(formatCount(v))")) }
        if let d = card.viewedAt { parts.append(formatRelativeDate(d)) } else if let d = card.pubdate { parts.append(formatRelativeDate(d)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 2×3 "继续观看" tile.
struct QuickTile: View {
    let card: VideoCard
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 112, height: 64)
                .overlay(RemoteImage(url: thumbnail(card.cover, width: 240)))
                .overlay(alignment: .bottom) { ProgressLine(card: card) }
                .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                Text(remaining).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.black)
                .frame(width: 32, height: 32).background(Theme.pink, in: Circle()).padding(.trailing, 10)
                .scaleEffect(hover ? 1 : 0.5).opacity(hover ? 1 : 0)
        }
        .frame(height: 64)
        .background(Color.white.opacity(hover ? 0.16 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
    }

    private var remaining: String {
        guard let p = card.progress, let d = card.duration, d > 0 else { return card.owner }
        if p < 0 { return L("已看完") }
        let left = max(0, d - p)
        return left >= 3600 ? Lf("剩余 %@ 小时 %@ 分", "\(left / 3600)", "\(left / 60 % 60)") : Lf("剩余 %@ 分钟", "\(max(1, left / 60))")
    }
}

struct LibraryRow: View {
    let cover: URL?
    let title: String
    let meta: String
    var progress: VideoCard? = nil
    var selected = false
    var placeholderIcon: String? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let placeholderIcon {
                    Image(systemName: placeholderIcon).font(.system(size: 16)).foregroundStyle(Theme.text2)
                        .frame(width: 76, height: 43).background(Theme.raised)
                } else {
                    Color.clear.frame(width: 76, height: 43)
                        .overlay(RemoteImage(url: thumbnail(cover, width: 160)))
                        .overlay(alignment: .bottom) { if let progress { ProgressLine(card: progress) } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5)).lineLimit(1).foregroundStyle(selected ? Theme.pink : .white)
                Text(meta).font(.system(size: 12)).lineLimit(1).foregroundStyle(Color(hex: 0xA7A7A7))
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(selected ? Theme.raised : (hover ? Color(hex: 0x1A1A1A) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct CardMenu: View {
    let card: VideoCard
    var removeAction: ((VideoCard) -> Void)?
    var body: some View {
        Button(L("打开")) { AppModel.shared.open(card) }
        Button(L("在底部播放")) { AppModel.shared.playInBackground(card) }
        if AppModel.shared.account.loggedIn {
            Button(L("添加到稍后再看")) { AppModel.shared.addToWatchLater(card) }
        }
        if let removeAction { Button(L("从列表中移除")) { removeAction(card) } }
        Divider()
        Button(L("复制链接")) { AppModel.shared.copyLink(card) }
        Button(L("在浏览器中打开")) { NSWorkspace.shared.open(card.url) }
    }
}

/// Favourite-folder picker used by the video page and 精选.
struct FavPopover: View {
    @ObservedObject var actions: VideoActions
    let close: () -> Void
    @State private var original: [FavFolder] = []
    @State private var edited: [FavFolder] = []
    @State private var loading = true

    var body: some View {
        MenuSurface(width: 280) {
            MenuHeader(text: L("添加到收藏夹"))
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
            } else {
                ForEach($edited) { $f in
                    FolderRow(folder: $f)
                }
            }
            MenuDivider()
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: L("取消")) { close() }
                PillButton(title: L("完成"), filled: true) { actions.applyFavorites(original: original, edited: edited); close() }
                    .disabled(loading)
            }
            .padding(6)
        }
        .task {
            original = await actions.folders()
            edited = original
            loading = false
        }
    }
}

private struct FolderRow: View {
    @Binding var folder: FavFolder
    @State private var hover = false
    var body: some View {
        Button { withAnimation(Motion.press) { folder.contains.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: folder.contains ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(folder.contains ? Theme.pink : Theme.text3)
                    .contentTransition(.symbolEffect(.replace))
                Text(folder.title).font(.system(size: 13.5))
                Spacer()
                Text("\(folder.count)").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(hover ? Color(hex: 0x3E3E3E) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

/// Simple wrapping layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x)
        }
        return CGSize(width: min(width, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Thin white bar slider (volume).
struct ThinSlider: View {
    @Binding var value: Double
    @State private var hover = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(hover ? Theme.pink : .white).frame(width: g.size.width * value)
                Circle().fill(.white).frame(width: 12, height: 12).offset(x: g.size.width * value - 6).opacity(hover ? 1 : 0)
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = min(max(v.location.x / max(g.size.width, 1), 0), 1)
            })
            .onHover { hover = $0 }
        }
        .frame(height: 14)
    }
}

/// 投币 choice.
struct CoinPopover: View {
    @ObservedObject var actions: VideoActions
    let close: () -> Void
    var body: some View {
        MenuSurface(width: 220) {
            MenuHeader(text: actions.relation.coin > 0 ? Lf("投币 · 已投 %@ 枚", "\(actions.relation.coin)") : L("投币 · 同时点赞"))
            MenuRow(title: L("投 1 枚硬币"), icon: "bitcoinsign.circle", enabled: actions.relation.coin < 2) { actions.coin(1); close() }
            MenuRow(title: L("投 2 枚硬币"), icon: "bitcoinsign.circle.fill", enabled: actions.relation.coin < 1) { actions.coin(2); close() }
        }
    }
}

/// Grey dropdown from the settings design.
struct Dropdown<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @State private var open = false
    @State private var id = UUID().uuidString
    var body: some View {
        Button { withAnimation(Motion.pop) { open.toggle() } } label: {
            DropdownLabel(text: options.first { $0.0 == selection }?.1 ?? "")
        }
        .buttonStyle(.pressable)
        .floatingPanel(id: "dropdown-\(id)", isPresented: $open, placement: .below(.trailing)) {
            MenuSurface {
                ForEach(options, id: \.0) { v, t in
                    MenuRow(title: t, selected: v == selection) {
                        selection = v
                        open = false
                    }
                }
            }
            .frame(minWidth: 200)
        }
    }
}

/// The ".fill" variant of an SF Symbol when one exists (some, like dot.radiowaves, have none).
func filledSymbol(_ name: String) -> String {
    NSImage(systemSymbolName: name + ".fill", accessibilityDescription: nil) != nil ? name + ".fill" : name
}
