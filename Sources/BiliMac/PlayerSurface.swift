import AppKit
import Combine
import AVFoundation
import SwiftUI

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct VideoLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        return v
    }
    func updateNSView(_ v: PlayerLayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
    static func dismantleNSView(_ v: PlayerLayerNSView, coordinator: ()) { v.playerLayer.player = nil }
}

/// Decides when the player's chrome (controls, info strip, scrims, overlays) is shown.
/// Shown while the pointer moves, while paused or buffering, while the pointer rests on the controls,
/// or while one of its menus is open; fades out together after 2.5 s of stillness during playback.
@MainActor
final class PlayerChrome: ObservableObject {
    @Published private(set) var visible = true
    var hoveringControls = false { didSet { if hoveringControls { show() } else { schedule() } } }
    var hoveringSurface = false
    private var lastActivity = Date()
    private var task: Task<Void, Never>?
    private var playingSub: AnyCancellable?
    /// Play/pause changes count as activity (pausing shows the chrome, resuming starts the idle timer).
    weak var clock: PlaybackClock? {
        didSet {
            guard clock !== oldValue else { return }
            playingSub = clock?.$playing.dropFirst().removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.activity() }
            }
        }
    }

    func activity() {
        lastActivity = Date()
        show()
        schedule()
    }

    func pointerLeft() {
        hoveringSurface = false
        lastActivity = .distantPast
        schedule(after: 0.5)
    }

    private func show() {
        task?.cancel()
        if !visible { withAnimation(Motion.pop) { visible = true } }
    }

    private func schedule(after secs: Double = 2.5) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func evaluate() {
        if Env.pinChrome { return }
        let mustShow = !(clock?.playing ?? false) || (clock?.waiting ?? false) || hoveringControls || FloatingCenter.shared.isOpen
        if mustShow { schedule(); return }
        guard Date().timeIntervalSince(lastActivity) >= 2.4 else { schedule(after: 0.5); return }
        withAnimation(.easeOut(duration: 0.4)) { visible = false }
        if hoveringSurface { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

/// Video + danmaku + chrome. `overlay` gets whether the chrome is showing, so page-specific
/// layers (精选's title and actions) fade in step and always sit *under* the controls.
struct PlayerSurface<Overlay: View>: View {
    enum Chrome { case full, none }
    @ObservedObject var controller: PlayerController
    var chrome: Chrome = .full
    var mode: PlayerMode = .normal
    var onAppFull: (() -> Void)? = nil
    var onScreenFull: (() -> Void)? = nil
    var onMiniPlayer: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil
    /// Room kept clear at the top (精选's title row, traffic lights) and right (精选's up-next column).
    var topInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// Title / channel shown at the top-left of the player (outside layout).
    var header: PlayerHeader? = nil
    /// Room for the window's traffic lights at the top-left.
    var headerLeadingInset: CGFloat = 0
    /// Size the picture area to 16:9 (inline player) instead of filling the space given.
    var fitVideo = false
    /// Extra controls in the bottom bar (精选's like / coin / … buttons).
    var barAccessory: AnyView? = nil
    @ViewBuilder var overlay: (Bool) -> Overlay
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var ui = PlayerChrome()

    var body: some View {
        if chrome == .full && settings.chromeLayout == .outside { outsideBody } else { overlayBody }
    }

    // MARK: Outside layout — nothing covers the picture, so nothing needs to hide.

    private var outsideBody: some View {
        VStack(spacing: 0) {
            PlayerTopBar(controller: controller, header: header, leadingInset: headerLeadingInset,
                         showStrip: settings.infoOverlay != .off)
            ZStack {
                Color.black
                VideoLayer(player: controller.player)
                DanmakuOverlay(controller: controller)
                PhaseOverlay(controller: controller)
                FlashView(controller: controller)
                if settings.showStats {
                    StatsPanel(controller: controller)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
                overlay(true)
            }
            .modifier(PictureSizing(fit: fitVideo))
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    ui.hoveringSurface = true
                    ui.activity()
                case .ended: ui.pointerLeft()
                }
            }
            .gesture(TapGesture(count: 2).onEnded { (onDoubleClick ?? onAppFull)?() }.exclusively(before: TapGesture().onEnded {
                controller.togglePlay()
            }))
            ControlsBar(controller: controller, mode: mode, onAppFull: onAppFull, onScreenFull: onScreenFull,
                        onMiniPlayer: onMiniPlayer, accessory: barAccessory, solid: true)
        }
        .background(Color.black)
        .onAppear {
            ui.clock = controller.clock
            ui.activity()
        }
        .animation(Motion.page, value: settings.showStats)
    }

    // MARK: Overlay layout — chrome over the picture, fading out while you watch.

    @ViewBuilder private var overlayBody: some View {
        let show = chrome == .full && ui.visible
        let stripShown = chrome == .full && (settings.infoOverlay == .always || (settings.infoOverlay == .auto && show))
        ZStack {
            Color.black
            VideoLayer(player: controller.player)
            DanmakuOverlay(controller: controller)

            // Scrims live under every piece of chrome, never above it.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120 + topInset)
                    .opacity(stripShown || show ? 1 : 0)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                    .opacity(show ? 1 : 0)
            }
            .allowsHitTesting(false)

            overlay(show)
            PhaseOverlay(controller: controller)
            FlashView(controller: controller)
            if chrome == .full, let header {
                PlayerHeaderView(header: header)
                    .padding(.leading, 16 + headerLeadingInset)
                    .padding(.top, topInset + 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(show ? 1 : 0)
            }

            if chrome == .full {
                if settings.showStats {
                    StatsPanel(controller: controller)
                        .padding(.leading, 16)
                        .padding(.top, topInset + 52)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                }
                InfoStrip(controller: controller)
                    .padding(.top, topInset + 14)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(stripShown ? 1 : 0)
                    .allowsHitTesting(false)
                ControlsBar(controller: controller, mode: mode, onAppFull: onAppFull, onScreenFull: onScreenFull,
                            onMiniPlayer: onMiniPlayer, accessory: barAccessory, solid: false)
                    .onHover { ui.hoveringControls = $0 }
                    .padding(.trailing, trailingInset)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(show ? 1 : 0)
                    .offset(y: show ? 0 : 10)
                    .allowsHitTesting(show)
                // While the chrome rests, a hairline keeps progress visible.
                MiniProgress(clock: controller.clock)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(show ? 0 : 1)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                ui.hoveringSurface = true
                ui.activity()
            case .ended: ui.pointerLeft()
            }
        }
        .gesture(TapGesture(count: 2).onEnded { (onDoubleClick ?? onAppFull)?() }.exclusively(before: TapGesture().onEnded {
            controller.togglePlay()
            ui.activity()
        }))
        .onAppear {
            ui.clock = controller.clock
            ui.activity()
        }
        .animation(Motion.page, value: settings.showStats)
    }
}

extension PlayerSurface where Overlay == EmptyView {
    init(controller: PlayerController, chrome: Chrome = .full, mode: PlayerMode = .normal,
         onAppFull: (() -> Void)? = nil, onScreenFull: (() -> Void)? = nil, onMiniPlayer: (() -> Void)? = nil,
         onDoubleClick: (() -> Void)? = nil, topInset: CGFloat = 0, trailingInset: CGFloat = 0,
         header: PlayerHeader? = nil, headerLeadingInset: CGFloat = 0, fitVideo: Bool = false) {
        self.init(controller: controller, chrome: chrome, mode: mode, onAppFull: onAppFull, onScreenFull: onScreenFull,
                  onMiniPlayer: onMiniPlayer, onDoubleClick: onDoubleClick, topInset: topInset, trailingInset: trailingInset,
                  header: header, headerLeadingInset: headerLeadingInset, fitVideo: fitVideo) { _ in EmptyView() }
    }
}

struct PlayerHeader {
    let title: String
    let owner: String
    var face: URL? = nil
    var onTap: (() -> Void)? = nil
}

/// Avatar · channel · title — top-left, away from burned-in subtitles.
struct PlayerHeaderView: View {
    let header: PlayerHeader
    var body: some View {
        HStack(spacing: 8) {
            if let face = header.face { Avatar(url: face, size: 22) }
            if !header.owner.isEmpty {
                Text(header.owner).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    .fixedSize()
            }
            Button { header.onTap?() } label: {
                Text(header.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(header.onTap == nil)
            .help(header.onTap == nil ? header.title : L("打开视频页"))
        }
    }
}

/// The strip above the picture: who/what on the left, technical readout on the right.
struct PlayerTopBar: View {
    @ObservedObject var controller: PlayerController
    let header: PlayerHeader?
    let leadingInset: CGFloat
    let showStrip: Bool
    var body: some View {
        HStack(spacing: 16) {
            if let header { PlayerHeaderView(header: header).layoutPriority(0) }
            Spacer(minLength: 12)
            if showStrip { InfoStrip(controller: controller, plain: true).layoutPriority(1) }
        }
        .padding(.leading, 14 + leadingInset)
        .padding(.trailing, 14)
        .frame(height: 38)
        .background(Color.black)
    }
}

private struct MiniProgress: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Theme.pink)
                .frame(width: clock.duration > 0 ? g.size.width * min(1, clock.time / clock.duration) : 0)
        }
        .frame(height: 2)
    }
}

private struct PhaseOverlay: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var clock: PlaybackClock
    init(controller: PlayerController) { self.controller = controller; clock = controller.clock }

    var body: some View {
        switch controller.phase {
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 26))
                Text(msg).multilineTextAlignment(.center).frame(maxWidth: 420).font(.system(size: 13.5))
                PillButton(title: L("重试"), filled: true, tint: .white) { controller.retry() }
            }
            .padding(24)
        case .loading:
            ProgressView().controlSize(.large).tint(.white)
        default:
            if clock.waiting { ProgressView().tint(.white) }
        }
    }
}

// MARK: - Controls

private struct ChromeIcon: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Theme.pink : .white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(hover ? 0.16 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct ControlsBar: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject var clock: PlaybackClock
    @ObservedObject private var settings = AppSettings.shared
    let mode: PlayerMode
    let onAppFull: (() -> Void)?
    let onScreenFull: (() -> Void)?
    let onMiniPlayer: (() -> Void)?
    let accessory: AnyView?
    /// Solid bar under the picture (outside layout) rather than floating over it.
    let solid: Bool

    init(controller: PlayerController, mode: PlayerMode, onAppFull: (() -> Void)?, onScreenFull: (() -> Void)?, onMiniPlayer: (() -> Void)?,
         accessory: AnyView? = nil, solid: Bool = false) {
        self.controller = controller
        clock = controller.clock
        self.mode = mode
        self.onAppFull = onAppFull
        self.onScreenFull = onScreenFull
        self.onMiniPlayer = onMiniPlayer
        self.accessory = accessory
        self.solid = solid
    }

    var body: some View {
        VStack(spacing: 6) {
            Scrubber(time: clock.time, duration: clock.duration, buffered: clock.buffered, style: .player,
                     preview: { controller.previewImage(at: $0) }, onHoverStart: { controller.loadShotsIfNeeded() }) { controller.seek(to: $0) }
            HStack(spacing: 6) {
                ChromeIcon(icon: clock.playing ? "pause.fill" : "play.fill", help: clock.playing ? L("暂停 空格") : L("播放 空格")) {
                    controller.togglePlay()
                }
                .contentTransition(.symbolEffect(.replace))
                Text("\(formatTime(clock.time)) / \(formatTime(clock.duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.leading, 4)
                if let accessory { accessory.padding(.leading, 12) }
                Spacer()
                QualityPicker(controller: controller)
                SpeedPicker(controller: controller).padding(.trailing, 4)
                ChromeIcon(icon: settings.danmakuOn ? "text.bubble.fill" : "text.bubble", help: L("弹幕 D"), active: settings.danmakuOn) {
                    settings.danmakuOn.toggle()
                }
                ChromeIcon(icon: "chart.xyaxis.line", help: L("统计信息 I"), active: settings.showStats) { settings.showStats.toggle() }
                VolumeBar(player: controller).padding(.horizontal, 4)
                if let onMiniPlayer, mode == .normal {
                    ChromeIcon(icon: "pip.enter", help: L("小窗：返回浏览，在底部继续播放"), action: onMiniPlayer)
                }
                if let onAppFull {
                    ChromeIcon(icon: mode == .appFull ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward",
                               help: mode == .appFull ? L("退出应用内全屏 T") : L("应用内全屏 T"), active: mode == .appFull, action: onAppFull)
                }
                if let onScreenFull {
                    ChromeIcon(icon: mode == .screenFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: mode == .screenFull ? L("退出全屏 F") : L("屏幕全屏 F"), active: mode == .screenFull, action: onScreenFull)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, solid ? 8 : 10)
        .padding(.top, solid ? 4 : 28)
        .background(solid ? Color.black : .clear)
        .contentShape(Rectangle())
    }
}

private struct PickerPill: View {
    let title: String
    var accent = false
    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12.5, weight: .bold))
            Image(systemName: "chevron.up").font(.system(size: 8, weight: .heavy)).opacity(0.7)
        }
        .foregroundStyle(accent ? Theme.pink : .white)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.white.opacity(0.14), in: Capsule())
        .contentShape(Capsule())
    }
}

struct QualityPicker: View {
    @ObservedObject var controller: PlayerController
    @State private var open = false
    var body: some View {
        Button { withAnimation(Motion.pop) { open.toggle() } } label: {
            PickerPill(title: controller.video.map { shortQuality($0.id) } ?? L("画质"), accent: true)
        }
        .buttonStyle(.pressable)
        .help(L("清晰度"))
        .floatingPanel(id: "quality-\(ObjectIdentifier(controller).hashValue)", isPresented: $open, placement: .above(.center)) {
            MenuSurface(width: 230) {
                MenuHeader(text: controller.manualQuality ? L("清晰度 · 手动选择") : Lf("清晰度 · 按「%@」策略自动选择", "\(AppSettings.shared.qualityPreset.label)"))
                ForEach(controller.info?.options ?? []) { o in
                    MenuRow(title: o.label, detail: o.available ? nil : (o.qn > 80 ? L("大会员") : L("需登录")),
                            selected: controller.video?.id == o.qn, enabled: o.available) {
                        controller.setQuality(o.qn)
                        open = false
                    }
                }
            }
        }
    }
}

struct SpeedPicker: View {
    @ObservedObject var controller: PlayerController
    @State private var open = false
    var body: some View {
        Button { withAnimation(Motion.pop) { open.toggle() } } label: {
            PickerPill(title: controller.rate == 1 ? L("倍速") : String(format: "%gx", controller.rate))
        }
        .buttonStyle(.pressable)
        .help(L("播放速度"))
        .floatingPanel(id: "speed-\(ObjectIdentifier(controller).hashValue)", isPresented: $open, placement: .above(.center)) {
            MenuSurface(width: 150) {
                MenuHeader(text: L("播放速度"))
                ForEach([3.0, 2.0, 1.5, 1.25, 1.0, 0.75, 0.5], id: \.self) { r in
                    MenuRow(title: r == 1 ? L("正常") : String(format: "%gx", r), selected: abs(Double(controller.rate) - r) < 0.01) {
                        controller.rate = Float(r)
                        open = false
                    }
                }
            }
        }
    }
}

/// One compact line above the video: quality, picture, codecs, and live download speed per CDN host.
struct InfoStrip: View {
    @ObservedObject var controller: PlayerController
    var plain = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let chips = controller.infoChips()
            if !chips.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Text("  ·  ").foregroundStyle(.white.opacity(0.3)) }
                        Text(c.label + " ").foregroundStyle(.white.opacity(0.55))
                        Text(c.value).foregroundStyle(c.accent ? Theme.pink : .white)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, plain ? 0 : 12).frame(height: 26)
                .background(plain ? .clear : .black.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(plain ? 0 : 0.08)))
            }
        }
    }
}

struct Scrubber: View {
    enum Style { case player, bar }
    let time: Double
    let duration: Double
    let buffered: Double
    var style: Style = .player
    /// Hover thumbnail for a time (YouTube-style storyboard); called when hovering starts too.
    var preview: ((Double) -> NSImage?)? = nil
    var onHoverStart: (() -> Void)? = nil
    let onSeek: (Double) -> Void
    @State private var hoverX: CGFloat?
    @State private var dragX: CGFloat?

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let frac = { (t: Double) in duration > 0 ? CGFloat(min(max(t / duration, 0), 1)) : 0 }
            let played = dragX.map { min(max($0 / w, 0), 1) } ?? frac(time)
            let active = hoverX != nil || dragX != nil
            let base: Color = style == .bar ? Theme.line : .white.opacity(0.25)
            let fill: Color = style == .bar ? (active ? Theme.pink : .white) : Theme.pink
            ZStack(alignment: .leading) {
                Capsule().fill(base)
                Capsule().fill(.white.opacity(style == .bar ? 0.25 : 0.4)).frame(width: w * frac(buffered))
                Capsule().fill(fill).frame(width: w * played)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .offset(x: w * played - 6)
                    .opacity(active ? 1 : 0)
                    .shadow(radius: 2)
                if style == .player, let x = hoverX ?? dragX, duration > 0 {
                    let t = Double(min(max(x / w, 0), 1)) * duration
                    let thumb = preview?(t)
                    VStack(spacing: 4) {
                        if let thumb {
                            Image(nsImage: thumb).resizable().aspectRatio(16 / 9, contentMode: .fill)
                                .frame(width: 176, height: 99)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                                .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
                        }
                        Text(formatTime(t))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .fixedSize()
                    .frame(width: thumb == nil ? 60 : 176)
                    .offset(x: min(max(x - (thumb == nil ? 30 : 88), 0), w - (thumb == nil ? 60 : 176)),
                            y: thumb == nil ? -22 : -72)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: active ? (style == .player ? 6 : 5) : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { p in
                if case .active(let pt) = p {
                    if hoverX == nil { onHoverStart?() }
                    hoverX = pt.x
                } else { hoverX = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragX = $0.location.x }
                .onEnded { v in
                    onSeek(Double(min(max(v.location.x / w, 0), 1)) * duration)
                    dragX = nil
                })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 14)
    }
}

// MARK: - Stats

struct StatsPanel: View {
    @ObservedObject var controller: PlayerController
    var closable = true
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let s = controller.stats()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("统计信息")).font(.system(size: 12, weight: .bold))
                    Spacer()
                    if closable {
                        Button { settings.showStats = false } label: {
                            Text(L("按 I 关闭")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(s.rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).foregroundStyle(Color(hex: 0x8A8A8A)).gridColumnAlignment(.leading)
                            Text(r.1).foregroundStyle(r.0 == L("下载速度") ? Theme.pink : .white).textSelection(.enabled)
                        }
                    }
                }
                Sparkline(values: s.history)
                    .frame(height: 36)
                    .overlay(alignment: .topTrailing) {
                        Text(Lf("近 60 秒 · 峰值 %@", "\(formatBitrate(s.history.max() ?? 0))"))
                            .font(.system(size: 9)).foregroundStyle(Theme.text3)
                    }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 360, alignment: .leading)
            .background(Color(hex: 0x0A0A0A, alpha: 0.8), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        Canvas { gc, size in
            guard values.count > 1, let mx = values.max(), mx > 0 else { return }
            let step = size.width / CGFloat(max(values.count - 1, 1))
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(v / mx) * (size.height - 2))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            var fill = p
            fill.addLine(to: CGPoint(x: CGFloat(values.count - 1) * step, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            gc.fill(fill, with: .color(Theme.pink.opacity(0.16)))
            gc.stroke(p, with: .color(Theme.pink), lineWidth: 1.5)
        }
    }
}

/// Brief centre-of-picture confirmation for play/pause, seeking, volume and speed.
private struct FlashView: View {
    @ObservedObject var controller: PlayerController
    @State private var shown: PlayerController.Flash?
    @State private var visible = false

    var body: some View {
        ZStack {
            if let f = shown, visible {
                VStack(spacing: 6) {
                    Image(systemName: f.icon).font(.system(size: 26, weight: .semibold))
                    if let t = f.text { Text(t).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit() }
                }
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(.black.opacity(0.55), in: Circle())
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .id(f.id)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: controller.flash) { _, f in
            guard let f else { return }
            shown = f
            withAnimation(Motion.pop) { visible = true }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                if shown?.id == f.id { withAnimation(.easeOut(duration: 0.25)) { visible = false } }
            }
        }
    }
}

/// Inline players size the picture 16:9 from the width; full-size players fill what they're given.
private struct PictureSizing: ViewModifier {
    let fit: Bool
    func body(content: Content) -> some View {
        if fit { content.aspectRatio(16 / 9, contentMode: .fit) }
        else { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
