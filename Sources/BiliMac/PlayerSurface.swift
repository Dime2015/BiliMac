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
    /// How far HDR may go above the interface's white (nil = system decides).
    var dynamicRange: HDRBrightness? = nil
    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        apply(v)
        return v
    }
    func updateNSView(_ v: PlayerLayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        apply(v)
    }
    private func apply(_ v: PlayerLayerNSView) {
        guard #available(macOS 26.0, *), let r = dynamicRange else { return }
        let want: CALayer.DynamicRange
        switch r {
        case .full, .auto: want = .high
        case .soft: want = .constrainedHigh
        case .sdr: want = .standard
        }
        if v.playerLayer.preferredDynamicRange != want { v.playerLayer.preferredDynamicRange = want }
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
    private var holdUntil = Date.distantPast
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

    /// Keep the chrome up for at least `secs` (a new video's intro).
    func hold(_ secs: Double) {
        holdUntil = Date().addingTimeInterval(secs)
        show()
        schedule(after: secs)
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
        let held = holdUntil.timeIntervalSinceNow
        if held > 0 { schedule(after: held + 0.05); return }
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
    /// Controls at the far top-left (the video page's back button): in the top bar, or over the picture.
    var topLeading: AnyView? = nil
    /// Room for the window's traffic lights at the top-left.
    var headerLeadingInset: CGFloat = 0
    /// Size the picture area to 16:9 (inline player) instead of filling the space given.
    var fitVideo = false
    /// Extra controls in the bottom bar (精选's like / coin / … buttons).
    var barAccessory: AnyView? = nil
    /// Outside layout: the header opens into a card over the picture's top-left (avatar, follow,
    /// counts, full title) while the chrome is up, and folds back into the black bar otherwise.
    var expandingHeader = false
    /// Seconds the chrome (and the header card) stays up when this surface appears.
    var introHold: Double = 0
    @ViewBuilder var overlay: (Bool) -> Overlay
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var ui = PlayerChrome()
    @Namespace private var headerNS

    var body: some View {
        Group {
            if chrome == .full && settings.chromeLayout == .outside { outsideBody } else { overlayBody }
        }
        // The player is always dark, whatever the app's appearance.
        .environment(\.colorScheme, .dark)
    }

    // MARK: Outside layout — nothing covers the picture, so nothing needs to hide.

    private var cardOpen: Bool { expandingHeader && header != nil && ui.visible }

    private var outsideBody: some View {
        VStack(spacing: 0) {
            PlayerTopBar(controller: controller, leading: topLeading, header: cardOpen ? nil : header, leadingInset: headerLeadingInset,
                         showStrip: settings.infoOverlay != .off, ns: expandingHeader ? headerNS : nil)
            ZStack {
                Color.black
                PlayerPicture(controller: controller, mode: mode)
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
                InteractiveOverlay(controller: controller)
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
        // Legibility scrim, then the card on top of it.
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .padding(.top, 38)
                .opacity(cardOpen ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if cardOpen, let header {
                PlayerHeaderCard(header: header, ns: headerNS)
                    .onHover { ui.hoveringControls = $0 }
                    .padding(.leading, 18).padding(.top, 38 + 14)
                    .transition(.opacity)
            }
        }
        .animation(cardOpen ? .spring(response: 0.45, dampingFraction: 0.86) : .easeInOut(duration: 0.45), value: cardOpen)
        .onAppear {
            ui.clock = controller.clock
            ui.activity()
            if introHold > 0 { ui.hold(introHold) }
        }
        .animation(Motion.page, value: settings.showStats)
    }

    // MARK: Overlay layout — chrome over the picture, fading out while you watch.

    @ViewBuilder private var overlayBody: some View {
        let show = chrome == .full && ui.visible
        let stripShown = chrome == .full && (settings.infoOverlay == .always || (settings.infoOverlay == .auto && show))
        ZStack {
            Color.black
            PlayerPicture(controller: controller, mode: mode)
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
            InteractiveOverlay(controller: controller)
            PhaseOverlay(controller: controller)
            FlashView(controller: controller)
            if chrome == .full, let topLeading {
                topLeading
                    .padding(.leading, 10 + headerLeadingInset)
                    .padding(.top, topInset + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(show ? 1 : 0)
                    .allowsHitTesting(show)
            }
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
         header: PlayerHeader? = nil, topLeading: AnyView? = nil, headerLeadingInset: CGFloat = 0, fitVideo: Bool = false) {
        self.init(controller: controller, chrome: chrome, mode: mode, onAppFull: onAppFull, onScreenFull: onScreenFull,
                  onMiniPlayer: onMiniPlayer, onDoubleClick: onDoubleClick, topInset: topInset, trailingInset: trailingInset,
                  header: header, topLeading: topLeading, headerLeadingInset: headerLeadingInset, fitVideo: fitVideo) { _ in EmptyView() }
    }
}

struct PlayerHeader {
    let title: String
    let owner: String
    var face: URL? = nil
    var onTap: (() -> Void)? = nil
    // For the expanded card.
    var fans: Int? = nil
    var likes: Int? = nil
    /// nil = no follow button.
    var following: Bool? = nil
    var onFollow: (() -> Void)? = nil
    var onOwnerTap: (() -> Void)? = nil
    var desc: String? = nil
}

private extension View {
    @ViewBuilder func matched(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: id, in: ns) } else { self }
    }
}

/// Avatar · channel · title — top-left, away from burned-in subtitles.
struct PlayerHeaderView: View {
    let header: PlayerHeader
    var ns: Namespace.ID? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let face = header.face { Avatar(url: face, size: 22).matched("face", ns) }
            if !header.owner.isEmpty {
                Text(header.owner).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    .fixedSize()
                    .matched("owner", ns)
            }
            Button { header.onTap?() } label: {
                Text(header.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .matched("title", ns)
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
    var leading: AnyView? = nil
    let header: PlayerHeader?
    let leadingInset: CGFloat
    let showStrip: Bool
    var ns: Namespace.ID? = nil
    var body: some View {
        HStack(spacing: 16) {
            if let leading { leading }
            if let header { PlayerHeaderView(header: header, ns: ns).layoutPriority(0) }
            Spacer(minLength: 12)
            if showStrip { InfoStrip(controller: controller, plain: true).layoutPriority(1) }
        }
        .padding(.leading, (leading == nil ? 14 : 6) + leadingInset)
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

struct ChromeIcon: View {
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
                     heat: controller.heat, heatMode: settings.heatMode, pictureGap: solid ? 4 : 0,
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
                        // Narrow players: the volume slider shrinks, then it and 统计信息 go, then the enhancement pill and
                // the audio mark's label, then 弹幕设置 and 小窗 — so the fullscreen buttons are never cut off.
                ViewThatFits(in: .horizontal) {
                    rightControls(level: 0)
                    rightControls(level: 1)
                    rightControls(level: 2)
                    rightControls(level: 3)
                    rightControls(level: 4)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.bottom, solid ? 8 : 10)
        .padding(.top, solid ? 4 : 28)
        // No background here even when solid: an opaque bar would turn the heat curve, which pokes
        // up over the picture, black. The outside layout paints black behind the whole player.
        .contentShape(Rectangle())
    }

    private func rightControls(level: Int) -> some View {
        HStack(spacing: 6) {
            if level < 3 { EnhancementButton(controller: controller).padding(.trailing, 2) }
            AudioBadge(controller: controller, compact: level >= 3)
            QualityPicker(controller: controller)
            SpeedPicker(controller: controller).padding(.trailing, 4)
            ChromeIcon(icon: settings.danmakuOn ? "text.bubble.fill" : "text.bubble", help: L("弹幕 D"), active: settings.danmakuOn) {
                settings.danmakuOn.toggle()
            }
            if level < 4 { DanmakuSettingsButton() }
            DanmakuSendButton(controller: controller)
            if level < 2 {
                ChromeIcon(icon: "chart.xyaxis.line", help: L("统计信息 I"), active: settings.showStats) { settings.showStats.toggle() }
            }
            VolumeBar(player: controller, sliderWidth: level == 0 ? 90 : level == 1 ? 50 : 0).padding(.horizontal, 4)
            if let onMiniPlayer, mode == .normal, level < 4 {
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
        .fixedSize()
    }
}

/// Hi-Res 无损 / 杜比全景声 mark, shown when the video has such a track; click to switch it on or off.
private struct AudioBadge: View {
    @ObservedObject var controller: PlayerController
    var compact = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let info = controller.info, info.flac != nil || info.dolby != nil {
            let kind = controller.audioKind
            // What the badge stands for: the track playing, else the one a click would turn on.
            let dolby = kind == .dolby || (kind == .standard && (info.flac == nil || settings.audioPref == .dolby && info.dolby != nil))
            let on = kind != .standard
            Button {
                if on { settings.audioPref = .standard } else { settings.audioPref = dolby ? .dolby : .hiRes }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: dolby ? "hifispeaker.2.fill" : "waveform").font(.system(size: 11, weight: .bold))
                    if !compact { Text(dolby ? L("杜比全景声") : L("Hi-Res 无损")).font(.system(size: 12, weight: .bold)) }
                }
                .foregroundStyle(on ? Theme.pink : .white.opacity(0.5))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .help(on ? Lf("正在播放%@音轨（%@），点击切回标准音质", dolby ? L("杜比全景声") : L("Hi-Res 无损"), controller.audio.map { "\($0.codecName) \($0.bandwidth / 1000) kbps" } ?? "")
                     : Lf("这个视频有%@音轨，点击开启", dolby ? L("杜比全景声") : L("Hi-Res 无损")))
        }
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
            if !controller.infoChips().isEmpty {
                // Show as much as fits: drop detail level by level rather than truncating with "…".
                ViewThatFits(in: .horizontal) {
                    row(controller.infoChips(compact: 0))
                    row(controller.infoChips(compact: 1))
                    row(controller.infoChips(compact: 2))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, plain ? 0 : 12).frame(height: 26)
                .background(plain ? .clear : .black.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(plain ? 0 : 0.08)))
            }
        }
    }

    private func row(_ chips: [InfoChip]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(chips.enumerated()), id: \.offset) { i, c in
                if i > 0 { Text("  ·  ").foregroundStyle(.white.opacity(0.3)) }
                Text(c.label + " ").foregroundStyle(.white.opacity(0.55))
                Text(c.value).foregroundStyle(c.accent ? Theme.pink : .white)
            }
        }
        .fixedSize()
    }
}

/// Bottom-bar pill for the enhancements: what's on (pink = working now, grey = standing by),
/// and a panel to switch each one.
struct EnhancementButton: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject private var settings = AppSettings.shared
    @State private var open = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let badges = controller.enhancementBadges()
            Button { withAnimation(Motion.pop) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    if badges.isEmpty {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        Text(L("增强")).font(.system(size: 12.5, weight: .bold))
                    } else {
                        ForEach(badges, id: \.icon) { b in
                            HStack(spacing: 3) {
                                Image(systemName: b.icon).font(.system(size: 11, weight: .semibold))
                                if let v = b.value { Text(v).font(.system(size: 11.5, weight: .semibold, design: .monospaced)) }
                            }
                            .foregroundStyle(b.active ? Theme.pink : .white.opacity(0.45))
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(.white.opacity(open ? 0.22 : 0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
            .help(badges.isEmpty ? L("画质与音效增强") : badges.map(\.help).joined(separator: "\n"))
        }
        .floatingPanel(id: "enhance-\(ObjectIdentifier(controller).hashValue)", isPresented: $open, placement: .above(.center)) {
            EnhancementPanel(controller: controller).environment(\.colorScheme, .dark)
        }
    }
}

private struct EnhancementPanel: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let badges = Dictionary(uniqueKeysWithValues: controller.enhancementBadges().map { ($0.icon, $0) })
            MenuSurface(width: 320) {
                MenuHeader(text: L("画质与音效增强"))
                row("sparkles", L("画质增强（超分辨率）"), badges["sparkles"], $settings.superResolution)
                row("speaker.wave.2.fill", L("响度均衡"), badges["speaker.wave.2.fill"], $settings.audioLoudness)
                row("person.wave.2.fill", L("人声增强"), badges["person.wave.2.fill"], $settings.audioVoice)
                row("person.fill.viewfinder", L("防挡人物"), badges["person.fill.viewfinder"], $settings.danmakuAvoidPeople)
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ badge: EnhancementBadge?, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(badge?.active == true ? Theme.pink : Theme.text3).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let badge {
                    let detail = badge.help.components(separatedBy: L("：")).dropFirst().joined(separator: L("："))
                    Text(detail.isEmpty ? L("工作中") : detail).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).toggleStyle(PinkToggleStyle()).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

struct Scrubber: View {
    enum Style { case player, bar }
    let time: Double
    let duration: Double
    let buffered: Double
    var style: Style = .player
    /// Danmaku-density curve drawn above the track (0…1 per bin).
    var heat: [Double] = []
    var heatMode: HeatMode = .off
    /// Gap between the top of the scrubber and the picture's bottom edge (outside layout's bar padding).
    var pictureGap: CGFloat = 0
    /// Hover thumbnail for a time (YouTube-style storyboard); called when hovering starts too.
    var preview: ((Double) -> NSImage?)? = nil
    var onHoverStart: (() -> Void)? = nil
    let onSeek: (Double) -> Void
    @State private var hoverX: CGFloat?
    @State private var dragX: CGFloat?

    private let hitHeight: CGFloat = 14
    private let heatHeight: CGFloat = 22
    /// "Always" keeps room for the curve so it never covers the picture.
    private var reservesHeat: Bool { style == .player && heatMode == .always }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width, 1)
            let midY = g.size.height - hitHeight / 2
            let frac = { (t: Double) in duration > 0 ? CGFloat(min(max(t / duration, 0), 1)) : 0 }
            let played = dragX.map { min(max($0 / w, 0), 1) } ?? frac(time)
            let loaded = frac(buffered)
            let hover = hoverX ?? (style == .player ? Env.scrubHover.map { w * $0 } : nil)
            let active = hover != nil || dragX != nil
            let trackH: CGFloat = active ? (style == .player ? 6 : 5) : 4
            let base: Color = style == .bar ? Theme.line : .white.opacity(0.25)
            let fill: Color = style == .bar ? (active ? Theme.pink : Theme.text) : Theme.pink
            let showHeat = style == .player && !heat.isEmpty && (heatMode == .always || (heatMode == .hover && active))
            // Hover: the curve stands on the picture's bottom edge, so no black strip shows between them.
            // Always: it lives in the reserved black space above the track.
            let heatBottom = reservesHeat ? midY - 5 : -pictureGap
            ZStack(alignment: .topLeading) {
                if showHeat {
                    ZStack(alignment: .leading) {
                        HeatShape(values: heat).fill(.white.opacity(active ? 0.18 : 0.16))
                        // Clip rather than .mask: a mask over the video layer leaves the masked-out part black.
                        HeatShape(values: heat).fill(Theme.pink.opacity(0.4))
                            .frame(width: w, height: heatHeight)
                            .frame(width: w * played, alignment: .leading)
                            .clipped()
                    }
                    .frame(width: w, height: heatHeight)
                    .position(x: w / 2, y: heatBottom - heatHeight / 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                Capsule().fill(base).frame(width: w, height: trackH).position(x: w / 2, y: midY)
                Capsule().fill(style == .bar ? Theme.text.opacity(0.25) : .white.opacity(0.4))
                    .frame(width: w * loaded, height: trackH).position(x: w * loaded / 2, y: midY)
                Capsule().fill(fill).frame(width: w * played, height: trackH).position(x: w * played / 2, y: midY)
                Circle().fill(style == .bar ? Theme.text : .white).frame(width: 12, height: 12)
                    .shadow(radius: 2)
                    .opacity(active ? 1 : 0)
                    .position(x: w * played, y: midY)
                if style == .player, let x = dragX ?? hover, duration > 0 {
                    let t = Double(min(max(x / w, 0), 1)) * duration
                    let thumb = preview?(t)
                    let width: CGFloat = thumb == nil ? 60 : 176
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
                    // Zero-height frame anchored at the bottom: the preview grows upward and never affects layout.
                    .frame(width: width, height: 0, alignment: .bottom)
                    .position(x: min(max(x, width / 2), w - width / 2),
                              y: (showHeat ? heatBottom - heatHeight : midY - trackH / 2) - 8)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: g.size.height)
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
            .onAppear {
                if style == .player, Env.scrubHover != nil { onHoverStart?() }
            }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: hitHeight + (reservesHeat ? heatHeight + 4 : 0))
    }
}

/// Smooth area chart of `values` (0…1), filled down to the bottom edge.
struct HeatShape: Shape {
    let values: [Double]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let n = CGFloat(values.count)
        let pts = values.enumerated().map { i, v in
            CGPoint(x: r.minX + (CGFloat(i) + 0.5) / n * r.width, y: r.maxY - (1.5 + CGFloat(v) * (r.height - 1.5)))
        }
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: pts[0].y))
        p.addLine(to: pts[0])
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        p.addLine(to: pts[pts.count - 1])
        p.addLine(to: CGPoint(x: r.maxX, y: pts[pts.count - 1].y))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
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
            .environment(\.colorScheme, .dark)
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

/// The expanded header: avatar, channel, follow, counts and the full title, like the official app's
/// feed card. Shares geometry with the one-line header so it grows out of / folds into the black bar.
struct PlayerHeaderCard: View {
    let header: PlayerHeader
    let ns: Namespace.ID
    @State private var showDesc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { header.onOwnerTap?() } label: {
                    Avatar(url: header.face, size: 48)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .matchedGeometryEffect(id: "face", in: ns)
                }
                .buttonStyle(.pressable)
                .disabled(header.onOwnerTap == nil)
                .help(L("查看 UP 主主页"))
                VStack(alignment: .leading, spacing: 3) {
                    Button { header.onOwnerTap?() } label: {
                        Text(header.owner).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                            .matchedGeometryEffect(id: "owner", in: ns)
                    }
                    .buttonStyle(.plain)
                    .disabled(header.onOwnerTap == nil)
                    if let counts {
                        Text(counts).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .fixedSize()
                if let following = header.following {
                    Button { header.onFollow?() } label: {
                        Text(following ? L("已关注") : L("+ 关注"))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(following ? 0.75 : 1))
                            .padding(.horizontal, 16).frame(height: 32)
                            .background(following ? Color.white.opacity(0.18) : Theme.pink.opacity(0.85),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.leading, 6)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { header.onTap?() } label: {
                    Text(header.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .matchedGeometryEffect(id: "title", in: ns)
                }
                .buttonStyle(.plain)
                .disabled(header.onTap == nil)
                .help(L("打开视频页"))
                if let d = header.desc, !d.isEmpty {
                    Button { withAnimation(Motion.pop) { showDesc.toggle() } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                            .rotationEffect(.degrees(showDesc ? 180 : 0))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .help(L("简介"))
                }
            }
            if showDesc, let d = header.desc {
                Text(d).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8)).lineSpacing(3)
                    .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
    }

    private var counts: String? {
        let parts = [header.fans.map { Lf("%@ 粉丝", formatCount($0)) }, header.likes.map { Lf("%@ 点赞", formatCount($0)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
