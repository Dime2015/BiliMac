import SwiftUI

/// 「精选」: one video at a time, ↑/↓ or scroll to move, autoplay through an endless feed.
struct FeaturedView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var feed: FeaturedModel
    @ObservedObject var actions: VideoActions
    @ObservedObject private var settings = AppSettings.shared
    @State private var showFav = false
    @State private var showCoin = false
    /// Comments in a panel on the right (the picture shrinks to make room).
    @State private var showComments = false
    @StateObject private var comments = CommentsModel()
    /// 「接下来」 lives in the player's chrome layer with the title card: it shows and hides with it (mouse
    /// moves, pause, a new video) and grows into the full list while hovered.
    @State private var nextExpanded = false
    @State private var nextHover = false
    @State private var hoverTask: Task<Void, Never>?

    /// The copy rendered by RootView when the player fills the window.
    var fullBleed = false
    /// Title and actions stay up for the first seconds of every video, then follow the chrome.
    @State private var introUntil = Date.distantPast
    /// The creator's total likes (from their space card), for the header card.
    @State private var ownerLikes: (mid: Int, likes: Int)?
    @State private var introTick = 0

    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > 980
            let placeholder = !fullBleed && app.playerMode != .normal
            let nextOn = wide && !placeholder && !showComments
            let outside = settings.chromeLayout == .outside
            let showNext = false
            let lights = (fullBleed ? app.playerMode == .appFull : settings.railAutoHide) ? 64.0 : 0.0
            HStack(spacing: 0) {
                ZStack {
                    Color(hex: 0x0B0B0B)
                    if placeholder {
                        Color.black
                    } else if let c = feed.current {
                        PlayerSurface(controller: c, chrome: .full, mode: app.playerMode,
                                      onAppFull: { app.toggleAppFull() }, onScreenFull: { app.toggleScreenFull() },
                                      onDoubleClick: { app.playerDoubleClick() },
                                      topInset: outside ? 0 : 44, trailingInset: showNext ? 280 : 0,
                                      header: outside ? header : nil, headerLeadingInset: lights,
                                      barAccessory: outside ? AnyView(barActions) : nil,
                                      expandingHeader: outside, introHold: outside ? 4 : 0,
                                      cornerAccessory: nextOn ? AnyView(UpNextDock(feed: feed, expanded: nextExpanded,
                                                                                  maxHeight: g.size.height - (outside ? 52 : 96) - (outside ? 84 : 16))) : nil,
                                      onCornerHover: { nextHoverChanged($0) }) { chromeShown in
                            if !outside { featuredOverlay(chromeShown: chromeShown, showNext: showNext) }
                        }
                        .id(ObjectIdentifier(c))
                        .transition(.asymmetric(
                            insertion: .move(edge: feed.direction > 0 ? .bottom : .top),
                            removal: .move(edge: feed.direction > 0 ? .top : .bottom)
                                .combined(with: .scale(scale: 0.9))
                                .combined(with: .opacity)))
                    } else if let e = feed.error {
                        VStack(spacing: 12) {
                            Text(L("精选加载失败")).font(.system(size: 18, weight: .bold))
                            Text(e).foregroundStyle(Theme.text2)
                            PillButton(title: L("重试"), filled: true, tint: .white) { Task { await feed.take() } }
                        }
                    } else {
                        ProgressView().controlSize(.large).tint(.white)
                    }

                }
                if showComments && !placeholder {
                    commentsPanel
                        .frame(width: min(420, max(320, g.size.width * 0.32)))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.page, value: showComments)
            .clipShape(RoundedRectangle(cornerRadius: fullBleed ? 0 : 10, style: .continuous))
            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: feed.current.map(ObjectIdentifier.init))
        }
        .environment(\.colorScheme, .dark)   // 精选 is a player page: always dark
        .task { await feed.take() }
        .onAppear { newVideo() }
        .onChange(of: feed.current.map(ObjectIdentifier.init)) { newVideo() }
        // Comments follow the video being played, fetched only while the panel is open.
        .task(id: showComments ? actions.detail?.aid : nil) {
            guard showComments, let d = actions.detail, d.bvid == feed.currentItem?.bvid else { return }
            comments.reset(aid: d.aid, upMid: d.ownerMid, total: d.stat.reply)
            if comments.comments.isEmpty && !comments.end { await comments.reload() }
        }
        .task(id: actions.detail?.ownerMid) {
            guard let mid = actions.detail?.ownerMid, mid > 0, ownerLikes?.mid != mid,
                  let info = try? await BiliAPI.shared.space(mid: mid) else { return }
            ownerLikes = (mid, info.likes)
        }
    }

    private func newVideo() {
        nextExpanded = false
        introUntil = Date().addingTimeInterval(4)
        Task {
            try? await Task.sleep(for: .seconds(4.1))
            introTick += 1   // re-evaluate once the intro window has passed
        }
    }

    @ViewBuilder private func featuredOverlay(chromeShown: Bool, showNext: Bool) -> some View {
        let visible = chromeShown || Date() < introUntil
        let _ = introTick
        ZStack {
            topBar.frame(maxHeight: .infinity, alignment: .top)
            if let item = feed.currentItem {
                HStack(alignment: .bottom, spacing: 24) {
                    if settings.showFeaturedInfo { info(item) } else { Spacer() }
                    rail
                }
                .padding(.leading, 28)
                .padding(.trailing, showNext ? 300 : 20)
                .padding(.bottom, 88)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(visible)
            }
        }
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 8)
        .animation(visible ? Motion.pop : .easeOut(duration: 0.4), value: visible)
    }

    /// A short delay each way, so brushing past the panel doesn't make it jump.
    private func nextHoverChanged(_ inside: Bool) {
        nextHover = inside
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 60 : 220))
            guard !Task.isCancelled, nextHover == inside else { return }
            withAnimation(UpNextDock.spring) { nextExpanded = inside }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(L("精选")).font(.system(size: 20, weight: .black))
            Text(L("↑ ↓ 或滑动切换 · 播完自动下一个")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.65))
            Spacer()
        }
        .padding(.leading, (fullBleed ? app.playerMode == .appFull : settings.railAutoHide) ? 84 : 20)
        .padding(.trailing, 20)
        .padding(.top, 16)
        .allowsHitTesting(false)
    }

    private func info(_ item: VideoCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let face = actions.detail?.ownerFace {
                    Avatar(url: face, size: 34)
                } else {
                    Text(String(item.owner.prefix(1))).font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34).background(Color(hex: 0x3D5A73), in: Circle())
                }
                OwnerLink(name: item.owner, mid: actions.detail?.ownerMid ?? item.ownerMid, font: .system(size: 15, weight: .bold),
                          color: .white, hoverColor: .white)
                if let d = actions.detail {
                    Button(d.following ? L("已关注") : L("关注")) { actions.toggleFollow() }
                        .buttonStyle(.pressable)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.5)))
                }
            }
            Button { app.open(item) } label: {
                Text(item.title)
                    .font(.system(size: 26, weight: .black))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.pressable)
            .hoverCursor()
            .help(L("打开视频页"))
            HStack(spacing: 16) {
                Text(Lf("%@ 播放", "\(formatCount(item.views))"))
                Text(Lf("%@ 弹幕", "\(formatCount(item.danmaku))"))
                if let d = item.pubdate { Text(formatRelativeDate(d)) }
                if let p = actions.detail?.partition, !p.isEmpty { Text(p) }
                Text("\(feed.index + 1) / \(feed.items.count)").monospacedDigit()
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.72))
        }
        .shadow(color: .black.opacity(0.5), radius: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rail: some View {
        let s = actions.detail?.stat
        return VStack(spacing: 16) {
            RoundAction(icon: actions.relation.like ? "hand.thumbsup.fill" : "hand.thumbsup", text: s.map { formatCount($0.like) } ?? L("点赞"),
                        active: actions.relation.like) { actions.toggleLike() }
            RoundAction(icon: "bitcoinsign.circle", text: s.map { formatCount($0.coin) } ?? L("投币"), active: actions.relation.coin > 0) {
                if app.account.loggedIn { showCoin = true } else { app.showLogin = true }
            }
            .floatingPanel(id: "coin-featured", isPresented: $showCoin, placement: .left) { CoinPopover(actions: actions) { showCoin = false } }
            RoundAction(icon: actions.relation.favorite ? "star.fill" : "star", text: s.map { formatCount($0.favorite) } ?? L("收藏"),
                        active: actions.relation.favorite) {
                if app.account.loggedIn { showFav = true } else { app.showLogin = true }
            }
            .floatingPanel(id: "fav-featured", isPresented: $showFav, placement: .left) { FavPopover(actions: actions) { showFav = false } }
            RoundAction(icon: showComments ? "bubble.right.fill" : "bubble.right", text: s.map { formatCount($0.reply) } ?? L("评论"),
                        active: showComments) { showComments.toggle() }
            RoundAction(icon: "text.badge.plus", text: L("稍后看"), active: false) { actions.watchLater() }
        }
    }

    private var commentsPanel: some View {
        ScrollView {
            CommentsSection(model: comments) { showComments = false }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
        }
        .scrollIndicators(.automatic)
        .background(Color(hex: 0x141414))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
        .foregroundStyle(.white)
    }

    /// Avatar · channel · title for the bar above the picture.
    private var header: PlayerHeader? {
        guard let item = feed.currentItem else { return nil }
        let d = actions.detail?.bvid == item.bvid ? actions.detail : nil
        let mid = d?.ownerMid ?? item.ownerMid
        return PlayerHeader(
            title: item.title, owner: item.owner, face: d?.ownerFace ?? item.ownerFace,
            onTap: { leavePlayerMode(); app.open(item) },
            fans: d?.follower,
            likes: ownerLikes.flatMap { $0.mid == mid ? $0.likes : nil },
            following: d?.following,
            onFollow: { actions.toggleFollow() },
            onOwnerTap: mid.map { m in { leavePlayerMode(); app.go(.space(m)) } },
            desc: d?.desc)
    }

    private func leavePlayerMode() { if app.playerMode != .normal { app.exitPlayerMode() } }


    /// 精选's own controls, living in the bottom bar instead of floating over the picture.
    /// Counts, then the position and 稍后看, give way when the bar is narrow (counts never wrap).
    private var barActions: some View {
        ViewThatFits(in: .horizontal) {
            barActionRow(counts: true, extras: true)
            barActionRow(counts: false, extras: true)
            barActionRow(counts: false, extras: false)
        }
    }

    private func barActionRow(counts: Bool, extras: Bool) -> some View {
        let s = counts ? actions.detail?.stat : nil
        return HStack(spacing: 2) {
            BarAction(icon: "chevron.up", help: L("上一个 ↑")) { feed.previous() }.disabled(feed.index == 0)
            BarAction(icon: "chevron.down", help: L("下一个 ↓")) { feed.next() }
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 8)
            BarAction(icon: actions.relation.like ? "hand.thumbsup.fill" : "hand.thumbsup", help: L("点赞"),
                      count: s.map { formatCount($0.like) }, active: actions.relation.like) { actions.toggleLike() }
            BarAction(icon: "bitcoinsign.circle", help: L("投币"), count: s.map { formatCount($0.coin) }, active: actions.relation.coin > 0) {
                if app.account.loggedIn { withAnimation(Motion.pop) { showCoin.toggle() } } else { app.showLogin = true }
            }
            .floatingPanel(id: "coin-bar", isPresented: $showCoin, placement: .above(.center)) { CoinPopover(actions: actions) { showCoin = false } }
            BarAction(icon: actions.relation.favorite ? "star.fill" : "star", help: L("收藏"),
                      count: s.map { formatCount($0.favorite) }, active: actions.relation.favorite) {
                if app.account.loggedIn { withAnimation(Motion.pop) { showFav.toggle() } } else { app.showLogin = true }
            }
            .floatingPanel(id: "fav-bar", isPresented: $showFav, placement: .above(.center)) { FavPopover(actions: actions) { showFav = false } }
            BarAction(icon: showComments ? "bubble.right.fill" : "bubble.right", help: L("评论"),
                      count: s.map { formatCount($0.reply) }, active: showComments) { showComments.toggle() }
            if extras {
                BarAction(icon: "text.badge.plus", help: L("稍后看")) { actions.watchLater() }
                Text("\(feed.index + 1) / \(feed.items.count)").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45)).padding(.leading, 8).lineLimit(1).fixedSize()
            }
        }
        .fixedSize()
    }

}

private struct RoundActionLabel: View {
    let icon: String
    let text: String
    let active: Bool
    var hover = false
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? Theme.pink : .white)
                .frame(width: 46, height: 46)
                .background(.white.opacity(hover ? 0.24 : 0.14), in: Circle())
            Text(text).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.35), radius: 3)
    }
}

private struct RoundAction: View {
    let icon: String
    let text: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) { RoundActionLabel(icon: icon, text: text, active: active, hover: hover) }
            .buttonStyle(.pressable)
            .onHover { hover = $0 }
    }
}

/// Icon (+ optional count) button for the player's bottom bar.
private struct BarAction: View {
    let icon: String
    let help: String
    var count: String? = nil
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                if let count { Text(count).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1).fixedSize() }
            }
            .foregroundStyle(active ? Theme.pink : .white)
            .padding(.horizontal, 8).frame(height: 30)
            .background(.white.opacity(hover ? 0.14 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(help)
    }
}
