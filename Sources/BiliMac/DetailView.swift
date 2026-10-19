import Combine
import SwiftUI

@MainActor
final class DetailModel: ObservableObject {
    let card: VideoCard
    let player: PlayerController
    let actions: VideoActions
    @Published var detail: VideoDetail?
    @Published var error: String?
    @Published var page: VideoPage?
    @Published var tint = Theme.tint(hex: 0x1F3B5C, light: 0xDDE6F0)
    /// The uploader's space card, for the banner above their name.
    @Published var ownerSpace: SpaceInfo?
    let comments = CommentsModel()
    private var started = false
    private let adopted: Bool
    private var bag: Set<AnyCancellable> = []

    init(card: VideoCard) {
        self.card = card
        let app = AppModel.shared
        actions = app.nowActions
        if let p = app.nowPlaying, app.nowCard?.bvid == card.bvid {
            player = p
            adopted = true
        } else {
            player = PlayerController()
            adopted = false
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        Task { if let t = await TintCache.shared.tint(for: card.cover) { tint = t } }
        do {
            let d: VideoDetail
            if let nd = AppModel.shared.nowDetail, nd.bvid == card.bvid { d = nd } else { d = try await BiliAPI.shared.detail(bvid: card.bvid) }
            detail = d
            actions.detail = d
            Task { self.ownerSpace = try? await BiliAPI.shared.space(mid: d.ownerMid) }
            if card.cover == nil, let t = await TintCache.shared.tint(for: d.cover) { tint = t }
            if adopted, player.phase != .idle {
                if case .failed = player.phase { player.retry() } else { player.play() }
            } else {
                let cid = d.pages.first { $0.cid == card.cid }?.cid ?? d.cid
                player.load(bvid: d.bvid, cid: cid, aid: d.aid)
            }
            AppModel.shared.setNowPlaying(player, card: card, context: .video)
            player.$cid.receive(on: RunLoop.main).sink { [weak self] cid in
                self?.page = self?.detail?.pages.first { $0.cid == cid }
            }.store(in: &bag)
            comments.reset(aid: d.aid, upMid: d.ownerMid, total: d.stat.reply)
            await comments.reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ p: VideoPage) {
        guard let d = detail, p.cid != player.cid else { return }
        player.load(bvid: d.bvid, cid: p.cid, aid: d.aid, resume: false)
    }

}

struct VideoScreen: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.playerNamespace) private var playerNS
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model: DetailModel

    init(card: VideoCard) { _model = StateObject(wrappedValue: DetailModel(card: card)) }

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 1100
            HStack(spacing: 8) {
                TintedPanel(tint: model.tint, height: 440) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            let outside = settings.chromeLayout == .outside
                            Group {
                                if app.immersive {
                                    Color.black.aspectRatio(16 / 9, contentMode: .fit)   // the full-window player is showing this video
                                } else {
                                    PlayerSurface(controller: model.player, chrome: .full, mode: .normal,
                                                  onAppFull: { app.toggleAppFull() }, onScreenFull: { app.toggleScreenFull() },
                                                  onMiniPlayer: { app.canBack ? app.goBack() : app.go(.home) },
                                                  onDoubleClick: { app.playerDoubleClick() }, topLeading: AnyView(backBar),
                                                  fitVideo: outside)
                                        .matchedPlayer(playerNS)
                                }
                            }
                                .modifier(SixteenNine(enabled: !outside))
                                // Outside layout adds ~100 pt of bars above/below the picture.
                                .frame(maxWidth: max(520, (g.size.height - (outside ? 240 : 140)) * 16 / 9))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                // In dark mode the black player meets a near-black page and its edge disappears
                                // (the shadow can't show on black either), so trace it with a hairline.
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.dyn(0xFFFFFF, 0x000000, darkAlpha: 0.1, lightAlpha: 0), lineWidth: 1)
                                    .allowsHitTesting(false))
                                // One shadow for the whole player, not one per layer (the heat curve would cast its own).
                                .compositingGroup()
                                .shadow(color: Theme.shadow, radius: 24, y: 16)
                            if let e = model.error {
                                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.text2)
                            }
                            if let d = model.detail {
                                VideoInfo(model: model, actions: model.actions, detail: d)
                                if !wide { SidePanel(model: model, actions: model.actions).padding(.vertical, 10) }
                                CommentsSection(model: model.comments)
                            } else if model.error == nil {
                                ProgressView().frame(maxWidth: .infinity).padding(40)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, settings.railAutoHide ? 26 : 16)   // clear the traffic lights when the rail is hidden
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if wide {
                    ScrollView { SidePanel(model: model, actions: model.actions).padding(16) }
                        .frame(width: 340)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .task { await model.start() }
    }

    /// Back + 分区, at the top-left of the player instead of a row of its own.
    private var backBar: some View {
        HStack(spacing: 6) {
            ChromeIcon(icon: "chevron.left", help: L("返回")) { app.canBack ? app.goBack() : app.go(.home) }
            if let p = model.detail?.partition, !p.isEmpty {
                Text(p).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
    }
}

private struct VideoInfo: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: DetailModel
    @ObservedObject var actions: VideoActions
    let detail: VideoDetail
    @State private var expanded = false
    @State private var showFav = false
    @State private var showCoin = false

    var body: some View {
        let d = actions.detail?.bvid == detail.bvid ? actions.detail! : detail
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(d.title).font(.system(size: 26, weight: .black)).lineSpacing(3).textSelection(.enabled)
                HStack(spacing: 16) {
                    Text(Lf("%@ 播放", "\(formatCount(d.stat.view))"))
                    Text(Lf("%@ 弹幕", "\(formatCount(d.stat.danmaku))"))
                    if let p = d.pubdate { Text(p.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())) }
                    Text(d.bvid).textSelection(.enabled)
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.text2)
            }
            HStack(spacing: 12) {
                PillButton(title: actions.relation.like ? Lf("已赞 %@", "\(formatCount(d.stat.like))") : Lf("点赞 %@", "\(formatCount(d.stat.like))"),
                           icon: actions.relation.like ? "hand.thumbsup.fill" : "hand.thumbsup",
                           filled: actions.relation.like) { actions.toggleLike() }
                Button {
                    if app.account.loggedIn { showCoin = true } else { app.showLogin = true }
                } label: {
                    PillLabel(title: actions.relation.coin > 0 ? Lf("已投 %@ · %@", "\(actions.relation.coin)", "\(formatCount(d.stat.coin))") : Lf("投币 %@", "\(formatCount(d.stat.coin))"),
                              icon: "bitcoinsign.circle", active: actions.relation.coin > 0)
                }
                .buttonStyle(.pressable)
                .floatingPanel(id: "coin-detail", isPresented: $showCoin, placement: .below(.leading)) {
                    CoinPopover(actions: actions) { showCoin = false }
                }
                PillButton(title: actions.relation.favorite ? Lf("已收藏 %@", "\(formatCount(d.stat.favorite))") : Lf("收藏 %@", "\(formatCount(d.stat.favorite))"),
                           icon: actions.relation.favorite ? "star.fill" : "star") {
                    if app.account.loggedIn { showFav = true } else { app.showLogin = true }
                }
                .floatingPanel(id: "fav-detail", isPresented: $showFav, placement: .below(.leading)) {
                    FavPopover(actions: actions) { showFav = false }
                }
                RoundOutlineButton(icon: "text.badge.plus", label: L("稍后再看")) { actions.watchLater() }
                RoundOutlineButton(icon: "link", label: L("复制链接（右键：在浏览器中打开）")) { app.copyLink(model.card) }
                    .contextMenu { Button(L("在浏览器中打开")) { NSWorkspace.shared.open(model.card.url) } }
            }
            if !d.desc.isEmpty && d.desc != "-" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(d.desc)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(Color.dyn(0xD0D0D0, 0x3B3F45))
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                    if d.desc.count > 90 || d.desc.filter({ $0 == "\n" }).count > 2 {
                        Button(expanded ? L("收起") : L("展开")) { expanded.toggle() }
                            .buttonStyle(.pressable).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
            if !d.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(d.tags, id: \.self) { t in
                        Text(t).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(Theme.chip, in: Capsule())
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
    }
}

private struct PillLabel: View {
    let title: String
    let icon: String
    let active: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(active ? Theme.pink : Theme.text)
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(Capsule().strokeBorder(active ? Theme.pink : Theme.line))
    }
}

private struct RoundOutlineButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(hover ? Theme.text : Theme.line))
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(label)
    }
}

private struct SidePanel: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: DetailModel
    @ObservedObject var actions: VideoActions
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if let base = model.detail {
            let d = actions.detail?.bvid == base.bvid ? actions.detail! : base
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    // The uploader's own banner; their cover tint shows while it loads (or if they have none).
                    Color.clear.frame(height: 96)
                        .overlay(RemoteImage(url: model.ownerSpace?.banner))
                        .background(model.tint)
                        .clipped()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .bottom) {
                            Button { app.go(.space(d.ownerMid)) } label: {
                                Avatar(url: d.ownerFace, size: 56)
                                    .overlay(Circle().strokeBorder(Theme.elevated, lineWidth: 3))
                            }
                            .buttonStyle(.pressable)
                            .help(L("查看 UP 主主页"))
                            Spacer()
                            Button { actions.toggleFollow() } label: {
                                Text(d.following ? L("已关注") : L("+ 关注"))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(d.following ? Theme.text : Theme.onPrimary)
                                    .padding(.horizontal, 16).frame(height: 32)
                                    .background(d.following ? Theme.chip : Theme.primary, in: Capsule())
                            }
                            .buttonStyle(.pressable)
                        }
                        .padding(.top, -38)
                        HStack(spacing: 8) {
                            Button { app.go(.space(d.ownerMid)) } label: {
                                HStack(spacing: 4) {
                                    Text(d.ownerName).font(.system(size: 16, weight: .bold)).lineLimit(1)
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text3)
                                }
                            }
                            .buttonStyle(.pressable)
                            .help(L("查看 UP 主主页"))
                            LiveBadge(uid: d.ownerMid)
                        }
                        Text(Lf("%@ 粉丝 · %@ 投稿", "\(formatCount(d.follower))", "\(formatCount(d.archiveCount))"))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .background(Theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contextMenu {
                    Button(L("查看 UP 主主页")) { app.go(.space(d.ownerMid)) }
                }


                if d.pages.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("选集")).font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text("\((model.page.flatMap { d.pages.firstIndex(of: $0) } ?? 0) + 1) / \(d.pages.count)")
                                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        }
                        .padding(.horizontal, 4).padding(.bottom, 4)
                        ForEach(d.pages) { p in
                            Button { model.select(p) } label: {
                                HStack(spacing: 10) {
                                    Text("P\(p.page)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text3)
                                        .frame(width: 34, alignment: .leading)
                                    Text(p.part).lineLimit(1)
                                    Spacer()
                                    Text(formatDuration(p.duration)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text3)
                                }
                                .font(.system(size: 13))
                                .foregroundStyle(p == model.page ? Theme.pink : Theme.text)
                                .padding(.horizontal, 10).frame(height: 36)
                                .background(p == model.page ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }

                if !d.related.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("相关推荐")).font(.system(size: 15, weight: .bold))
                            Spacer()
                            Button { settings.detailAutoNext.toggle() } label: {
                                Text(Lf("自动连播 %@", "\(settings.detailAutoNext ? L("开") : L("关"))"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(settings.detailAutoNext ? Theme.pink : Theme.text2)
                            }
                            .buttonStyle(.pressable)
                        }
                        .padding(.horizontal, 4).padding(.bottom, 4)
                        ForEach(d.related) { r in
                            Button { app.open(r) } label: { RelatedRow(card: r) }
                                .buttonStyle(.pressableCard)
                                .contextMenu { CardMenu(card: r) }
                        }
                    }
                }
            }
        }
    }
}

private struct RelatedRow: View {
    let card: VideoCard
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 120, height: 68)
                .overlay(RemoteImage(url: thumbnail(card.cover, width: 260)))
                .overlay(alignment: .bottomTrailing) { DurationBadge(seconds: card.duration).scaleEffect(0.9) }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.system(size: 13)).lineLimit(2).lineSpacing(1)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    OwnerLink(name: card.owner, mid: card.ownerMid, font: .system(size: 11.5))
                    Text(" · " + Lf("%@ 播放", "\(formatCount(card.views))")).font(.system(size: 11.5)).foregroundStyle(Theme.meta).lineLimit(1)
                }
            }
            .frame(height: 68, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private struct SixteenNine: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.aspectRatio(16 / 9, contentMode: .fit) } else { content }
    }
}
