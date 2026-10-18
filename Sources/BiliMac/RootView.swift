import CoreImage.CIFilterBuiltins
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var playerNS

    /// 应用内全屏 / 屏幕全屏: the playing video fills the window.
    @ViewBuilder private var fullPlayer: some View {
        if app.route == .featured {
            FeaturedView(feed: app.featured, actions: app.nowActions, fullBleed: true)
        } else if let p = app.nowPlaying {
            PlayerSurface(controller: p, chrome: .full, mode: app.playerMode,
                          onAppFull: { app.toggleAppFull() }, onScreenFull: { app.toggleScreenFull() },
                          onDoubleClick: { app.playerDoubleClick() },
                          topInset: app.playerMode == .appFull ? 22 : 0,
                          header: app.nowCard.map { c in
                              PlayerHeader(title: c.title.isEmpty ? (app.nowDetail?.title ?? "") : c.title,
                                           owner: c.owner.isEmpty ? (app.nowDetail?.ownerName ?? "") : c.owner,
                                           face: app.nowDetail?.ownerFace)
                          },
                          headerLeadingInset: app.playerMode == .appFull ? 64 : 0)
                .matchedGeometryEffect(id: "player", in: playerNS)
                .background(.black)
                .environment(\.colorScheme, .dark)
        }
    }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            // The normal UI stays alive under the full-window player so pages keep their state.
            Group {
                VStack(spacing: 8) {
                    if app.route == .settings {
                        SettingsPage()
                    } else {
                        HStack(spacing: 8) {
                            if !app.route.usesRail { Sidebar().frame(width: 300) }
                            else if !settings.railAutoHide { IconRail() }
                            PageHost().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    if app.showsNowPlayingBar, let p = app.nowPlaying {
                        NowPlayingBar(player: p, actions: app.nowActions)
                            .frame(height: 84)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(8)
                .ignoresSafeArea()
                .animation(Motion.pop, value: app.showsNowPlayingBar)
            }
            .opacity(app.immersive ? 0 : 1)
            .allowsHitTesting(!app.immersive)
            .environment(\.playerNamespace, playerNS)

            if app.immersive {
                fullPlayer
                    .ignoresSafeArea()
                    .zIndex(5)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .leading) {
            // Hot zone starts at the window edge so flicking the pointer left reveals the rail.
            if !app.immersive, app.route.usesRail, settings.railAutoHide {
                AutoHideRail(bottomInset: app.showsNowPlayingBar ? 100 : 8)
            }
        }
        .floatingLayer()
        .overlay(alignment: .top) { toast }
        .sheet(isPresented: $app.showLogin) {
            LoginView { ok in
                app.showLogin = false
                if ok { Task { await app.didLogin() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            app.windowExitedFullScreen()
        }
        .frame(minWidth: 1040, minHeight: 640)
        .foregroundStyle(Theme.text)
        .background(WindowAccessor())
        .onChange(of: lightsPlacement, initial: true) { _, p in TrafficLights.shared.placement = p }
    }

    /// Where the window buttons go for the current layout.
    private var lightsPlacement: TrafficLights.Placement {
        if app.immersive { return .system }
        if app.route == .settings { return .sidebar }
        if app.route.usesRail { return settings.railAutoHide ? .system : .rail }
        return .sidebar
    }

    @ViewBuilder private var toast: some View {
        if let t = app.toast {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.panel)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Theme.text, in: Capsule())
                .shadow(color: Theme.shadow, radius: 12, y: 4)
                .padding(.top, 18)
                .transition(.move(edge: .top).combined(with: .scale(scale: 0.8)).combined(with: .opacity))
        }
    }
}

/// Keeps list pages alive between visits (switching back is just a visibility change, no rebuild),
/// and gives 精选 / video pages a directional spring transition.
private struct PageHost: View {
    @EnvironmentObject var app: AppModel
    @State private var alive: [Route] = []

    static func cacheable(_ r: Route) -> Bool {
        switch r {
        case .home, .dynamics, .history, .watchLater, .favorites, .search, .space, .collection: return true
        default: return false
        }
    }

    var body: some View {
        let current = app.route
        let routes = alive.contains(current) || !Self.cacheable(current) ? alive : alive + [current]
        ZStack {
            ForEach(routes, id: \.self) { r in
                let on = r == current
                PageContent(route: r)
                    .opacity(on ? 1 : 0)
                    .offset(y: on ? 0 : 12)
                    .allowsHitTesting(on)
                    .accessibilityHidden(!on)
                    .zIndex(on ? 1 : 0)
                    .animation(on ? Motion.page : Motion.exit, value: on)
            }
            if !Self.cacheable(current) {
                PageContent(route: current)
                    .id(current)
                    .zIndex(2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: app.navForward ? 32 : -32)),
                        removal: .opacity.animation(Motion.exit)))
            }
        }
        .onChange(of: current, initial: true) {
            guard Self.cacheable(current) else { return }
            alive.removeAll { $0 == current }
            alive.append(current)
            if alive.count > 6 { alive.removeFirst(alive.count - 6) }
        }
    }
}

private struct PageContent: View {
    @EnvironmentObject var app: AppModel
    let route: Route

    var body: some View {
        let r = route
        if r.needsLogin && !app.account.loggedIn {
            MainPanel { LoginPromptView(what: r == .messages ? L("消息") : L("动态、历史记录、稍后再看和收藏夹")) }
        } else {
            switch r {
            case .home: HomePage()
            case .featured: FeaturedView(feed: app.featured, actions: app.nowActions)
            case .dynamics:
                ListPage(kicker: L("关注"), title: L("动态"), subtitle: L("关注的 UP 主最新投稿"), key: "dynamics")
            case .history:
                ListPage(kicker: L("我的"), title: L("历史记录"), subtitle: L("在任意设备上看过的视频"), key: "history")
            case .watchLater:
                ListPage(kicker: L("我的"), title: L("稍后再看"), subtitle: nil, key: "watchLater") { app.removeFromWatchLater($0) }
            case .favorites(let id): FavoritesPage(folderID: id ?? app.favFolders.first?.id)
            case .search(let q):
                ListPage(kicker: L("搜索结果"), title: q, subtitle: nil, key: "search:\(q)", emptyText: L("没有找到相关视频"))
            case .video(let card): VideoScreen(card: card).id(card.bvid)
            case .space(let mid): SpacePage(mid: mid).id(mid)
            case .collection(let c):
                ListPage(kicker: c.kind == .season ? L("合集") : L("系列"), title: c.name, subtitle: nil, key: c.listKey,
                         tint: Theme.tint(hex: 0x3D2A5C, light: 0xE6DDF3))


            case .messages: MessagesPage()
            case .settings: EmptyView()
            }
        }
    }
}

// MARK: - Main panel + top bar

struct MainPanel<Content: View>: View {
    var tint: Color = Theme.defaultTint
    @ViewBuilder var content: () -> Content
    var body: some View {
        TintedPanel(tint: tint) {
            VStack(spacing: 0) {
                TopBar()
                content()
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            CircleIconButton(icon: "chevron.left", label: L("后退"), enabled: app.canBack) { app.goBack() }
            CircleIconButton(icon: "chevron.right", label: L("前进"), enabled: app.canForward) { app.goForward() }
            SearchBox(search: app.search).padding(.leading, 6)
            Spacer()
            AppearanceSwitch()
            CircleIconButton(icon: "gearshape", label: L("设置"), size: 36) { app.go(.settings) }
            AccountButton()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

struct AccountButton: View {
    @EnvironmentObject var app: AppModel
    @State private var open = false

    var body: some View {
        if app.account.loggedIn {
            Button { withAnimation(Motion.pop) { open.toggle() } } label: {
                Avatar(url: app.account.face, size: 30)
                    .padding(3)
                    .background(Theme.floatingButton, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .help(app.account.name ?? L("账号"))
            .floatingPanel(id: "account", isPresented: $open, placement: .below(.trailing)) { menu }
        } else {
            PillButton(title: L("登录"), filled: true, tint: Theme.primary) { app.showLogin = true }
        }
    }

    private var menu: some View {
        MenuSurface(width: 270) {
            HStack(spacing: 12) {
                Avatar(url: app.account.face, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.account.name ?? "").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(app.account.isVip ? Theme.pink : Theme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("LV\(app.account.level)").font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(hex: 0xF0A24A), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.black)
                        if let v = app.account.vipLabel {
                            Text(v).font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.pink, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Theme.onPrimary)
                        }
                        Text(Lf("硬币 %@", "\(Int(app.account.coins))")).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            MenuDivider()
            MenuRow(title: L("个人空间"), icon: "person.crop.circle") {
                open = false
                if let mid = app.account.mid { app.go(.space(mid)) }
            }
            MenuRow(title: L("设置"), icon: "gearshape") { open = false; app.go(.settings) }
            MenuDivider()
            MenuRow(title: L("退出登录"), icon: "rectangle.portrait.and.arrow.right") { open = false; Task { await app.logout() } }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var messages = MessageCenter.shared
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    LogoMark()
                    Text("BiliMac").font(.system(size: 18, weight: .black))
                }
                .padding(.horizontal, 12)
                .padding(.top, 34)
                .padding(.bottom, 12)
                NavRow(icon: "house", title: L("首页"), selected: app.route == .home, ns: ns) { app.go(.home) }
                NavRow(icon: "play.rectangle", title: L("精选"), selected: app.route == .featured, ns: ns) { app.go(.featured) }
                NavRow(icon: "dot.radiowaves.left.and.right", title: L("动态"), selected: app.route == .dynamics, ns: ns) { app.go(.dynamics) }
                NavRow(icon: "bell", title: L("消息"), selected: app.route == .messages, ns: ns, badge: messages.unread.total) { app.go(.messages) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            LibraryPanel()
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 30
    /// The knitted TV from the app icon; falls back to a pink tile when run outside the .app bundle.
    private static let logo: NSImage? = Bundle.main.url(forResource: "Logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var body: some View {
        if let logo = Self.logo {
            Image(nsImage: logo).resizable().interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: size, height: size)
                .background(Theme.pink, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        }
    }
}

private struct NavRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let ns: Namespace.ID
    var badge = 0
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: selected ? filledSymbol(icon) : icon).font(.system(size: 19, weight: .semibold)).frame(width: 24)
                Text(title).font(.system(size: 15, weight: .bold))
                Spacer()
                UnreadBadge(count: badge)
            }
            .foregroundStyle(selected || hover ? Theme.text : Theme.text2)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.raised).matchedGeometryEffect(id: "nav", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

private struct LibraryPanel: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical").font(.system(size: 18, weight: .semibold))
                Text(L("我的")).font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 12)

            if app.account.loggedIn {
                SlidingChips(options: LibraryFilter.allCases.map { ($0, L($0.rawValue)) }, selection: $app.libraryFilter, style: .white)
                    .padding(.horizontal, 12)
                ScrollView {
                    LazyVStack(spacing: 2) { rows }
                        .padding(.horizontal, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("登录后查看历史记录、稍后再看和收藏夹")).font(.system(size: 14, weight: .bold))
                    Text(L("用哔哩哔哩手机客户端扫码，个性化推荐和 1080P 以上画质也会一起解锁。"))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    PillButton(title: L("扫码登录"), filled: true, tint: Theme.primary) { app.showLogin = true }
                }
                .padding(16)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                Spacer()
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var rows: some View {
        switch app.libraryFilter {
        case .history:
            LibraryList(list: app.list(for: "history"), limit: 40, meta: { c in
                guard let p = c.progress else { return L("历史") }
                return p < 0 ? L("历史 · 已看完") : Lf("历史 · 看到 %@", "\(formatDuration(p))")
            }, footer: L("查看全部历史")) { app.go(.history) }
        case .watchLater:
            LibraryList(list: app.list(for: "watchLater"), limit: 100, meta: { Lf("稍后再看 · %@", "\(formatDuration($0.duration))") },
                        footer: L("打开稍后再看")) { app.go(.watchLater) }
        case .favorites:
            ForEach(app.favFolders) { f in
                Button { app.go(.favorites(f.id)) } label: {
                    LibraryRow(cover: nil, title: f.title, meta: Lf("收藏夹 · %@ 个视频", "\(f.count)"),
                               selected: app.route == .favorites(f.id), placeholderIcon: "star.fill")
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

private struct LibraryList: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var list: PagedList
    let limit: Int
    let meta: (VideoCard) -> String
    let footer: String
    let onFooter: () -> Void

    var body: some View {
        ForEach(list.items.prefix(limit)) { c in
            Button { app.open(c) } label: {
                LibraryRow(cover: c.cover, title: c.title, meta: meta(c), progress: c, selected: app.route == .video(c))
            }
            .buttonStyle(.pressable)
            .contextMenu { CardMenu(card: c) }
        }
        if list.loading && list.items.isEmpty { ProgressView().controlSize(.small).padding() }
        Button(action: onFooter) {
            Text(footer).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .buttonStyle(.pressable)
        .task { if list.isEmptyAndIdle { await list.loadMore() } }
    }
}

// MARK: - Icon rail (精选 / video page)

/// Rail that stays hidden until the pointer reaches the window's left edge.
private struct AutoHideRail: View {
    var bottomInset: CGFloat = 8
    @State private var shown = false
    @State private var hideTask: Task<Void, Never>?
    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 20)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { if $0 { show() } }
            if shown {
                IconRail()
                    .padding(.leading, 8).padding(.top, 8).padding(.bottom, bottomInset)
                    .shadow(color: Theme.shadow, radius: 18, x: 6)
                    .onHover { inside in inside ? show() : scheduleHide() }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
    }

    private func show() {
        hideTask?.cancel()
        shown = true
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(0.35))
            if !Task.isCancelled { shown = false }
        }
    }
}

private struct IconRail: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var messages = MessageCenter.shared
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var ns
    var body: some View {
        VStack(spacing: 6) {
            // 34 below the window top, like the sidebar's logo row: the same gap under the window buttons.
            LogoMark(size: 32).padding(.top, 34).padding(.bottom, 14)

            RailIcon(icon: "house", label: L("首页"), selected: app.route == .home, ns: ns) { app.go(.home) }
            RailIcon(icon: "play.rectangle", label: L("精选"), selected: app.route == .featured, ns: ns) { app.go(.featured) }
            RailIcon(icon: "dot.radiowaves.left.and.right", label: L("动态"), selected: app.route == .dynamics, ns: ns) { app.go(.dynamics) }
            RailIcon(icon: "books.vertical", label: L("历史记录"), selected: app.route == .history, ns: ns) { app.go(.history) }
            RailIcon(icon: "bell", label: L("消息"), selected: app.route == .messages, ns: ns) { app.go(.messages) }
                .overlay(alignment: .topTrailing) { UnreadBadge(count: messages.unread.total).scaleEffect(0.85).offset(x: 2, y: 4).allowsHitTesting(false) }
            Spacer()
            RailIcon(icon: settings.railAutoHide ? "pin" : "sidebar.left",
                     label: settings.railAutoHide ? L("固定侧栏") : L("自动隐藏侧栏"), selected: false, ns: ns) {
                withAnimation(.easeOut(duration: 0.2)) { settings.railAutoHide.toggle() }
            }
            RailIcon(icon: "gearshape", label: L("设置"), selected: false, ns: ns) { app.go(.settings) }
                .padding(.bottom, 10)
        }
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RailIcon: View {
    let icon: String
    let label: String
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: selected ? filledSymbol(icon) : icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(selected ? Theme.pink : (hover ? Theme.text : Theme.text2))
                .frame(width: 48, height: 48)
                .background {
                    if selected { RoundedRectangle(cornerRadius: 8).fill(Theme.raised).matchedGeometryEffect(id: "rail", in: ns) }
                }
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Now playing bar

struct NowPlayingBar: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var player: PlayerController
    @ObservedObject var actions: VideoActions
    @ObservedObject private var settings = AppSettings.shared
    @State private var showStats = false

    var body: some View {
        HStack(spacing: 16) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            center.frame(maxWidth: 720)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    private var left: some View {
        HStack(spacing: 14) {
            Button { app.expandNowPlaying() } label: {
                VideoLayer(player: player.player)
                    .frame(width: 128, height: 72)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                            .padding(5).background(.black.opacity(0.55), in: Circle()).padding(5)
                            .foregroundStyle(.white)
                    }
            }
            .buttonStyle(.pressable)
            .help(L("展开播放器"))
            VStack(alignment: .leading, spacing: 3) {
                Button { app.expandNowPlaying() } label: {
                    Text(app.nowCard?.title ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
                .buttonStyle(.pressable)
                Text(app.nowCard?.owner ?? "").font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Button { actions.toggleLike() } label: {
                Image(systemName: actions.relation.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: actions.relation.like)
                    .font(.system(size: 16))
                    .foregroundStyle(actions.relation.like ? Theme.pink : Theme.text2)
            }
            .buttonStyle(.pressable)
            .help(L("点赞"))
        }
    }

    private var center: some View {
        let autoNext = app.nowContext == .featured ? $settings.featuredAutoNext : $settings.detailAutoNext
        return VStack(spacing: 8) {
            HStack(spacing: 22) {
                Button { autoNext.wrappedValue.toggle() } label: {
                    Image(systemName: "repeat").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(autoNext.wrappedValue ? Theme.pink : Theme.text2)
                }
                .help(autoNext.wrappedValue ? L("自动连播：开") : L("自动连播：关"))
                Button { app.playPrevious() } label: { Image(systemName: "backward.end.fill").font(.system(size: 17)) }
                    .foregroundStyle(Theme.text2).help(L("上一个"))
                PlayPauseButton(clock: player.clock) { player.togglePlay() }
                Button { app.playNext() } label: { Image(systemName: "forward.end.fill").font(.system(size: 17)) }
                    .foregroundStyle(Theme.text2).help(L("下一个"))
                Button { settings.danmakuOn.toggle() } label: {
                    Image(systemName: settings.danmakuOn ? "text.bubble.fill" : "text.bubble").font(.system(size: 15))
                        .foregroundStyle(settings.danmakuOn ? Theme.text : Theme.text2)
                }
                .help(L("弹幕"))
                DanmakuSettingsButton(inPlayer: false)
            }
            .buttonStyle(.pressable)
            BarProgress(clock: player.clock) { player.seek(to: $0) }
        }
    }

    private var right: some View {
        HStack(spacing: 14) {
            if settings.infoOverlay != .off {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(player.badge).font(Theme.mono).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                }
            }
            Button { withAnimation(Motion.pop) { showStats.toggle() } } label: {
                Image(systemName: "chart.xyaxis.line").font(.system(size: 15)).foregroundStyle(showStats ? Theme.pink : Theme.text2)
            }
            .buttonStyle(.pressable)
            .help(L("统计信息"))
            .floatingPanel(id: "bar-stats", isPresented: $showStats, placement: .above(.trailing)) {
                StatsPanel(controller: player, closable: false)
                    .shadow(color: Theme.shadow, radius: 24, y: 12)
            }
            VolumeBar(player: player)
            Button { app.expandNowPlaying() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.pressable)
            .help(L("展开播放器"))
        }
    }
}

struct PlayPauseButton: View {
    @ObservedObject var clock: PlaybackClock
    var size: CGFloat = 36
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: size * 0.42))
                .foregroundStyle(Theme.panel)
                .frame(width: size, height: size)
                .background(Theme.text, in: Circle())
                .scaleEffect(hover ? 1.06 : 1)
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(clock.playing ? L("暂停") : L("播放"))
    }
}

struct BarProgress: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(clock.time)).frame(width: 52, alignment: .trailing)
            Scrubber(time: clock.time, duration: clock.duration, buffered: clock.buffered, style: .bar, onSeek: onSeek)
            Text(formatTime(clock.duration)).frame(width: 52, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.meta)
    }
}

struct VolumeBar: View {
    @ObservedObject var player: PlayerController
    var body: some View {
        HStack(spacing: 8) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.player.isMuted || player.player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14)).foregroundStyle(Theme.text2).frame(width: 20)
            }
            .buttonStyle(.pressable)
            ThinSlider(value: Binding(get: { player.player.isMuted ? 0 : Double(player.player.volume) },
                                      set: { player.setVolume(Float($0)) }))
                .frame(width: 90)
        }
    }
}

// MARK: - Login

struct LoginPromptView: View {
    @EnvironmentObject var app: AppModel
    let what: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "qrcode").font(.system(size: 44)).foregroundStyle(Theme.text2)
            Text(Lf("登录后查看%@", "\(what)")).font(.system(size: 22, weight: .black))
            Text(L("使用哔哩哔哩手机客户端扫码登录")).foregroundStyle(Theme.text2)
            PillButton(title: L("扫码登录"), filled: true) { app.showLogin = true }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct LoginView: View {
    let done: (Bool) -> Void
    @State private var qr: NSImage?
    @State private var message = L("正在获取二维码…")
    @State private var scanned = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            LogoMark(size: 40)
            Text(L("扫码登录哔哩哔哩")).font(.system(size: 20, weight: .black))
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable().padding(12).opacity(scanned ? 0.12 : 1)
                } else {
                    ProgressView().tint(.black)
                }
                if scanned { Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.pink) }
            }
            .frame(width: 220, height: 220)
            Text(message).font(.system(size: 14, weight: .semibold))
            Text(L("打开哔哩哔哩手机客户端，在「我的」右上角扫一扫")).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            HStack(spacing: 10) {
                PillButton(title: L("取消")) { task?.cancel(); done(false) }
                PillButton(title: L("刷新二维码"), filled: true, tint: Theme.primary) { start() }
            }
        }
        .padding(32)
        .frame(width: 380)
        .background(Theme.panel)
        .onAppear(perform: start)
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel()
        scanned = false
        task = Task { @MainActor in
            do {
                let (url, key) = try await BiliAPI.shared.qrGenerate()
                qr = Self.qrImage(url)
                message = L("等待扫码…")
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    switch try await BiliAPI.shared.qrPoll(key: key) {
                    case .waiting: break
                    case .scanned: scanned = true; message = L("已扫码，请在手机上确认")
                    case .expired: message = L("二维码已过期，请刷新"); return
                    case .done: message = L("登录成功"); done(true); return
                    case .other(let c, let m): message = Lf("登录失败 %@ %@", "\(c)", "\(m)"); return
                    }
                }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    static func qrImage(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

private struct PlayerNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Shared so the inline player can grow into the full-window one.
    var playerNamespace: Namespace.ID? {
        get { self[PlayerNamespaceKey.self] }
        set { self[PlayerNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func matchedPlayer(_ ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: "player", in: ns) } else { self }
    }
}
