import AppKit
import QuartzCore
import Combine
import SwiftUI

enum Route: Hashable {
    case home, featured, dynamics, history, watchLater, favorites(Int?), search(String), video(VideoCard), space(Int),
         collection(SpaceCollection), messages, live(Int), liveHome, settings, downloads
    /// 分区: a tid_v2 (UGC) or a PGC season_type, see `Region`.
    case region(Int)

    /// Pages that use the collapsed icon rail instead of the full sidebar.
    var usesRail: Bool {
        switch self {
        case .featured, .video, .live: return true
        default: return false
        }
    }

    var needsLogin: Bool {
        switch self {
        case .dynamics, .history, .watchLater, .favorites, .messages: return true
        default: return false
        }
    }
}

enum HomeTab: String, CaseIterable, Identifiable {
    case recommend = "推荐", popular = "热门", ranking = "排行榜"
    var id: String { rawValue }
    var key: String {
        switch self {
        case .recommend: return "home"
        case .popular: return "popular"
        case .ranking: return "ranking"
        }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case history = "历史", watchLater = "稍后再看", favorites = "收藏夹"
    var id: String { rawValue }
}

enum PlayContext { case featured, video }

enum PlayerMode { case normal, appFull, screenFull }

/// A paged list of video cards with its own cursor state.
@MainActor
final class PagedList: ObservableObject {
    @Published private(set) var items: [VideoCard] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var exhausted = false
    /// Cards that already played their entrance animation.
    var revealed: Set<String> = []
    private var state: [String: String] = [:]
    /// When the first page of the current contents arrived (首页 refreshes itself when this gets old).
    private(set) var loadedAt: Date?
    private let fetch: ([String: String]) async throws -> (items: [VideoCard], state: [String: String], more: Bool)
    private var generation = 0

    init(fetch: @escaping ([String: String]) async throws -> (items: [VideoCard], state: [String: String], more: Bool)) {
        self.fetch = fetch
    }

    var isEmptyAndIdle: Bool { items.isEmpty && !loading && error == nil && !exhausted }

    func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        let gen = generation
        do {
            let first = state.isEmpty
            let r = try await fetch(state)
            guard gen == generation else { return }
            if first { loadedAt = Date() }
            let seen = Set(items.map(\.bvid))
            items += r.items.filter { !seen.contains($0.bvid) }
            state = r.state
            exhausted = !r.more
            error = nil
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
        if gen == generation { loading = false }
    }

    func reload() async {
        generation += 1
        items = []
        state = [:]
        exhausted = false
        error = nil
        loading = false
        loadedAt = nil
        await loadMore()
    }

    func remove(_ bvid: String) { items.removeAll { $0.bvid == bvid } }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Navigation
    @Published private(set) var route: Route = .home
    /// The route the window chrome (sidebar or icon rail, now-playing bar) follows. It changes without
    /// animation just before `route` does: animating the page area's size made every page, scroll view
    /// and size reader in it lay out again on every frame of the spring.
    @Published private(set) var layoutRoute: Route = .home
    @Published private(set) var canBack = false
    @Published private(set) var canForward = false
    private var backStack: [Route] = []
    private var forwardStack: [Route] = []
    @Published var homeTab: HomeTab = .recommend
    @Published var libraryFilter: LibraryFilter = .history
    @Published var searchText = ""

    // Account
    @Published var account = Account()
    @Published var favFolders: [FavFolder] = []
    @Published var showLogin = false
    @Published var toast: String?
    /// Runs when the toast is clicked (it then shows longer, with a 「查看」 hint).
    private(set) var toastAction: (() -> Void)?
    /// A settings section to scroll to when 设置 opens (its title, e.g. "账号").
    var settingsFocus: String?
    /// The phone-feed fallback is announced once per launch.
    private var announcedFeedFallback = false

    // Now playing (one player at a time, like a music app)
    @Published private(set) var nowPlaying: PlayerController?
    @Published private(set) var nowCard: VideoCard?
    @Published private(set) var nowContext: PlayContext = .featured
    /// Detail + like/coin/fav state of whatever is playing.
    let nowActions = VideoActions()
    var nowDetail: VideoDetail? { nowActions.detail }
    /// How the current player is shown: in its page, filling the app window, or macOS full screen.
    @Published private(set) var playerMode: PlayerMode = .normal
    private var modeBeforeScreen: PlayerMode = .normal
    var immersive: Bool { playerMode != .normal }

    let featured = FeaturedModel()
    private(set) var lists: [String: PagedList] = [:]
    private var toastTask: Task<Void, Never>?

    func start() async {
        SuperResShaders.warmUp()
        await BiliAPI.shared.ensureBuvid()
        await refreshAccount()
        if ProcessInfo.processInfo.environment["BILIMAC_NAVBENCH"] != nil { Task { await navBench() } }
        if ProcessInfo.processInfo.environment["BILIMAC_PERFBENCH"] != nil { Task { await perfBench() } }
        if ProcessInfo.processInfo.environment["BILIMAC_HOMETAB"] == "popular" { homeTab = .popular }
        if let spec = Env.testDownload { Task { await DownloadCenter.testDownload(spec) } }
        if let r = Env.route {
            if r == "featured" { go(.featured) }
            else if r == "settings" { go(.settings) }
            else if r == "dynamics" { go(.dynamics) }
            else if r == "messages" { go(.messages) }
            else if r.hasPrefix("search:") { submitSearch(String(r.dropFirst(7))) }
            else if r.hasPrefix("video:") {
                let p = r.dropFirst(6).split(separator: ":")
                open(VideoCard(bvid: String(p[0]), cid: p.count > 1 ? Int(p[1]) : nil, title: "", cover: nil, owner: ""))
            }
            else if r.hasPrefix("region:"), let id = Int(r.dropFirst(7)) { go(.region(id)) }
            else if r.hasPrefix("space:"), let mid = Int(r.dropFirst(6)) { go(.space(mid)) }
            else if r.hasPrefix("live:"), let room = Int(r.dropFirst(5)) { go(.live(room)) }
            else if r == "live" { go(.liveHome) }
            else if r == "downloads" { go(.downloads) }
        }
    }

    /// Debug: cycles through pages and logs how long each switch keeps the main thread busy.
    var navStarted: CFTimeInterval = 0
    private func navBench() async {
        try? await Task.sleep(for: .seconds(4))
        // BILIMAC_NAVBENCH=featured: back and forth between 精选 and 首页.
        let routes: [Route] = ProcessInfo.processInfo.environment["BILIMAC_NAVBENCH"] == "featured"
            ? [.featured, .home, .featured, .home, .featured, .home, .featured, .home]
            : [.dynamics, .home, .history, .watchLater, .favorites(nil), .home, .settings, .home, .dynamics, .home]
        // BILIMAC_NAVBENCH=swipe: watch 12 videos in 精选, then go to 首页.
        if ProcessInfo.processInfo.environment["BILIMAC_NAVBENCH"] == "swipe" {
            go(.featured)
            for i in 0..<12 {
                try? await Task.sleep(for: .seconds(3))
                let t0 = CACurrentMediaTime()
                featured.next()
                DispatchQueue.main.async { log(String(format: "swipe %d main busy %.0f ms", i + 1, (CACurrentMediaTime() - t0) * 1000)) }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        for r in routes {
            navStarted = CACurrentMediaTime()
            go(r)
            let t0 = navStarted
            // Measure until the main queue is free again (after SwiftUI's update pass).
            DispatchQueue.main.async {
                DispatchQueue.main.async { log(String(format: "nav→%@ main busy %.0f ms", "\(r)", (CACurrentMediaTime() - t0) * 1000)) }
            }
            // Then watch the main thread for 3 s: the longest gap between 10 ms ticks is the hitch you feel.
            Task { @MainActor in
                var last = CACurrentMediaTime(), worst = 0.0, worstAt = 0.0
                while CACurrentMediaTime() - t0 < 3 {
                    try? await Task.sleep(for: .milliseconds(10))
                    let now = CACurrentMediaTime()
                    if now - last > worst { worst = now - last; worstAt = last - t0 }
                    last = now
                }
                log(String(format: "nav→%@ worst main stall %.0f ms at +%.0f ms", "\(r)", worst * 1000, worstAt * 1000))
            }
            try? await Task.sleep(for: .seconds(r == .featured ? 4 : 2.5))
        }
    }

    // MARK: 首页 freshness

    /// Related videos of what was watched lately (newest first), led into the web feed's next first page.
    private var recentRelated: [VideoCard] = []

    /// Called when a video page has its details.
    func noteWatched(_ d: VideoDetail) {
        let fresh = d.related.prefix(4).filter { $0.bvid != d.bvid }
        recentRelated.removeAll { r in fresh.contains { $0.bvid == r.bvid } }
        recentRelated.insert(contentsOf: fresh, at: 0)
        recentRelated = Array(recentRelated.prefix(8))
    }

    fileprivate func relatedFirst(_ cards: [VideoCard]) -> [VideoCard] {
        let lead = Array(recentRelated.prefix(4))
        guard !lead.isEmpty else { return cards }
        recentRelated.removeFirst(lead.count)
        let ids = Set(lead.map(\.bvid))
        return lead.map { c in var c = c; c.reason = L("看过的相关"); return c } + cards.filter { !ids.contains($0.bvid) }
    }

    /// Back on 首页 after a while: show a new batch, as the phone app does when you come back to it.
    private func refreshHomeIfStale() {
        guard homeTab == .recommend, let l = lists["home"], let t = l.loadedAt, Date().timeIntervalSince(t) > 10 * 60 else { return }
        Task { await l.reload() }
    }

    // MARK: Navigation


    func go(_ r: Route) {
        guard r != route else { return }
        backStack.append(route)
        forwardStack.removeAll()
        move(to: r)
    }

    func goBack() {
        guard let r = backStack.popLast() else { return }
        forwardStack.append(route)
        move(to: r)
    }

    func goForward() {
        guard let r = forwardStack.popLast() else { return }
        backStack.append(route)
        move(to: r)
    }

    /// The page before this one is a video too (this one was opened from its 推荐).
    var backIsVideo: Bool {
        if case .video? = backStack.last { return true }
        return false
    }

    /// ✕ / minimise on a video page: past every video opened one from another, back to the page the first was
    /// opened from. 前进 walks through them again.
    func leaveVideos() {
        forwardStack.append(route)
        while case .video? = backStack.last { forwardStack.append(backStack.removeLast()) }
        move(to: backStack.popLast() ?? .home)
    }

    private func move(to r: Route) {
        // Leaving a page ends any text editing on it; otherwise the hidden search field
        // keeps the keyboard and swallows the player's arrow keys.
        FloatingCenter.shared.dismissAll()
        if let w = NSApp.keyWindow, let t = w.firstResponder as? NSText, t.isEditable { w.makeFirstResponder(nil) }
        layoutRoute = r
        withAnimation(Motion.page) { route = r }
        if r == .home { refreshHomeIfStale() }
        // Keep a plain change after the animated one: it makes SwiftUI apply the animated update now.
        // Without it, a switch started from code (not a click) can wait until something else changes.
        canBack = !backStack.isEmpty
        canForward = !forwardStack.isEmpty
        if playerMode != .normal, !r.usesRail { setPlayerMode(.normal) }
        HangRecorder.context.withLock { $0 = "page " + String(String(describing: r).prefix(60)) }
    }

    func open(_ card: VideoCard) { go(.video(card)) }

    func openLive(_ roomId: Int) { go(.live(roomId)) }

    /// 直播 and the rooms opened from it light up the 直播 entry.
    var onLivePages: Bool {
        switch route {
        case .liveHome, .live: return true
        default: return false
        }
    }

    let search = SearchModel()

    func submitSearch(_ query: String? = nil) {
        let q = (query ?? searchText).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchText = q
        search.record(q)
        for (k, l) in lists where k == "search:\(q)" || (k.hasPrefix("searchv:") && k.hasSuffix(":\(q)")) { Task { await l.reload() } }
        go(.search(q))
    }

    /// The page that shows the current player.
    func expandNowPlaying() {
        guard let card = nowCard else { return }
        if nowContext == .featured { go(.featured) } else { go(.video(card)) }
    }

    /// Whether the bottom bar should show (hidden while the player itself is on screen).
    var showsNowPlayingBar: Bool {
        guard nowPlaying != nil, let card = nowCard else { return false }
        switch layoutRoute {
        case .featured: return nowContext != .featured
        case .video(let c): return c.bvid != card.bvid
        default: return true
        }
    }

    func setPlayerMode(_ m: PlayerMode) {
        guard m != playerMode else { return }
        if m != .normal, nowPlaying != nil, !route.usesRail { expandNowPlaying() }
        if m == .screenFull { modeBeforeScreen = playerMode == .screenFull ? .normal : playerMode }
        withAnimation(Motion.page) { playerMode = m }
        let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.canBecomeMain }
        if let w, w.styleMask.contains(.fullScreen) != (m == .screenFull) { w.toggleFullScreen(nil) }
    }

    /// 应用内全屏 (T): player fills the window, window stays a window.
    func toggleAppFull() { setPlayerMode(playerMode == .appFull ? .normal : .appFull) }

    /// 屏幕全屏 (F).
    func toggleScreenFull() { setPlayerMode(playerMode == .screenFull ? modeBeforeScreen : .screenFull) }

    /// Double-click on the video.
    func playerDoubleClick() {
        AppSettings.shared.doubleClickScreenFull ? toggleScreenFull() : toggleAppFull()
    }

    /// Esc steps out one level.
    func exitPlayerMode() {
        switch playerMode {
        case .screenFull: setPlayerMode(modeBeforeScreen)
        case .appFull: setPlayerMode(.normal)
        case .normal: break
        }
    }

    /// Called when the window leaves full screen by other means (green button, ⌃⌘F).
    func windowExitedFullScreen() {
        if playerMode == .screenFull { withAnimation(Motion.page) { playerMode = modeBeforeScreen } }
    }

    // MARK: Now playing

    func setNowPlaying(_ p: PlayerController, card: VideoCard, context: PlayContext) {
        if let old = nowPlaying, old !== p {
            if featured.owns(old) { old.pause() } else { old.stop() }
        }
        let changed = nowCard?.bvid != card.bvid
        nowPlaying = p
        nowCard = card
        nowContext = context
        InputRouter.shared.player = p
        p.onEnd = { [weak self] in self?.playbackEnded() }
        if changed { Task { await nowActions.load(bvid: card.bvid) } }
    }

    /// ✕: stop what's playing and drop the bottom bar. 精选 keeps its player (paused) and takes it back when opened.
    func closeNowPlaying() {
        guard let p = nowPlaying else { return }
        if featured.owns(p) { p.pause() } else { p.stop() }
        nowPlaying = nil
        nowCard = nil
        InputRouter.shared.player = nil
    }

    private func playbackEnded() {
        switch nowContext {
        case .featured: if AppSettings.shared.featuredAutoNext { featured.next() }
        case .video:
            if let p = nowPlaying, let d = nowDetail, let i = d.pages.firstIndex(where: { $0.cid == p.cid }), i + 1 < d.pages.count {
                playNext()
            } else if AppSettings.shared.detailAutoNext {
                playNext()
            }
        }
    }

    func playNext() {
        switch nowContext {
        case .featured: featured.next()
        case .video:
            guard let p = nowPlaying, let d = nowDetail else { return }
            if let i = d.pages.firstIndex(where: { $0.cid == p.cid }), i + 1 < d.pages.count {
                p.load(bvid: d.bvid, cid: d.pages[i + 1].cid, aid: d.aid, resume: false)
            } else if let r = d.related.first {
                if case .video = route { open(r) } else { playInBackground(r) }
            }
        }
    }

    func playPrevious() {
        switch nowContext {
        case .featured: featured.previous()
        case .video:
            guard let p = nowPlaying else { return }
            if p.clock.time < 5, let d = nowDetail, let i = d.pages.firstIndex(where: { $0.cid == p.cid }), i > 0 {
                p.load(bvid: d.bvid, cid: d.pages[i - 1].cid, aid: d.aid, resume: false)
            } else {
                p.seek(to: 0)
            }
        }
    }

    /// Starts a video in the bottom bar without leaving the current page.
    func playInBackground(_ card: VideoCard) {
        Task {
            do {
                let d = try await BiliAPI.shared.detail(bvid: card.bvid)
                let p = PlayerController()
                p.load(bvid: d.bvid, cid: card.cid ?? d.cid, aid: d.aid)
                nowActions.detail = d
                setNowPlaying(p, card: card, context: .video)
            } catch { notify(Lf("播放失败：%@", "\(error.localizedDescription)")) }
        }
    }

    // MARK: Account

    func refreshAccount() async {
        do { account = try await BiliAPI.shared.nav() } catch { log("nav: \(error)") }
        if account.loggedIn, let mid = account.mid {
            favFolders = (try? await BiliAPI.shared.favFolders(mid: mid)) ?? []
            MessageCenter.shared.startPolling()
        } else {
            favFolders = []
            MessageCenter.shared.stop()
        }
        if account.loggedIn || LiveNowCenter.testUIDs != nil { LiveNowCenter.shared.startPolling() } else { LiveNowCenter.shared.stop() }
    }

    func didLogin() async {
        await refreshAccount()
        lists.removeAll()
        await featured.reset()
        notify(Lf("已登录：%@", "\(account.name ?? "")"))
    }

    func logout() async {
        CookieJar.shared.clearLogin()
        account = Account()
        await refreshAccount()
        lists.removeAll()
        await featured.reset()
        notify(L("已退出登录"))
    }

    func notify(_ s: String, action: (() -> Void)? = nil) {
        toastAction = action
        withAnimation(Motion.pop) { toast = s }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(action == nil ? 2.2 : 6))
            if !Task.isCancelled { withAnimation { toast = nil } }
        }
    }

    func runToastAction() {
        let a = toastAction
        toastTask?.cancel()
        withAnimation { toast = nil }
        a?()
    }

    /// 首页 fell back from the phone feed to the web one (risk control, an expired authorization, a network
    /// error): say so once, with a way to the account settings where the reason is shown.
    fileprivate func announceFeedFallback() {
        guard !announcedFeedFallback else { return }
        announcedFeedFallback = true
        notify(L("手机端推荐暂时不可用，已改用网页推荐")) { [weak self] in
            self?.settingsFocus = "账号"
            self?.go(.settings)
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let g = h < 5 ? L("夜深了") : h < 11 ? L("早上好") : h < 13 ? L("中午好") : h < 18 ? L("下午好") : L("晚上好")
        if let n = account.name, account.loggedIn { return Lf("%@，%@", "\(g)", "\(n)") }
        return g
    }

    // MARK: Lists

    /// Lazily created list (kept while navigating).
    /// Collections opened so far, so `list(for:)` can build their loaders from the key.
    private var collections: [String: SpaceCollection] = [:]

    func open(_ c: SpaceCollection) {
        collections[c.listKey] = c
        go(.collection(c))
    }

    func list(for key: String) -> PagedList {
        if let l = lists[key] { return l }
        let api = BiliAPI.shared
        let l: PagedList
        switch key {
        case "home":
            l = PagedList { [weak self] s in
                // The phone feed while authorized; if it fails, this page (and the rest) come from the web feed.
                let auth = AppFeedAuth.shared
                if AppSettings.shared.appFeed, s["src"] != "web", auth.authorized {
                    do {
                        let token = try await auth.validToken()
                        let r = try await AppAPI.feed(token: token, idx: Int(s["idx"] ?? "0") ?? 0)
                        auth.lastError = nil
                        return (r.cards, ["src": "app", "idx": "\(r.next)"], true)
                    } catch {
                        log("app feed: \(error)")
                        auth.lastError = error.localizedDescription
                        self?.announceFeedFallback()
                    }
                }
                let p = Int(s["p"] ?? "1")!
                var cards = try await api.homeRecommend(page: p)
                // The web feed hardly reacts to what was just watched, so lead with a few related videos of it.
                if p == 1, let self { cards = self.relatedFirst(cards) }
                return (cards, ["src": "web", "p": "\(p + 1)"], true)
            }
        case "popular":
            l = PagedList { s in
                let p = Int(s["p"] ?? "1")!
                let r = try await api.popular(page: p)
                return (r.items, ["p": "\(p + 1)"], r.more)
            }
        case "ranking":
            l = PagedList { _ in (try await api.ranking(), [:], false) }
        case "dynamics":
            l = PagedList { s in
                let r = try await api.dynamics(offset: s["o"])
                return (r.items, ["o": r.offset ?? ""], r.more && r.offset != nil)
            }
        case "history":
            l = PagedList { s in
                let r = try await api.history(max: s["max"].flatMap(Int.init), viewAt: s["at"].flatMap(Int.init))
                var st: [String: String] = [:]
                if let m = r.max { st["max"] = "\(m)" }
                if let a = r.viewAt { st["at"] = "\(a)" }
                return (r.items, st, !r.items.isEmpty && r.max != nil && r.max != 0)
            }
        case "watchLater":
            l = PagedList { _ in (try await api.watchLater(), [:], false) }
        default:
            if key.hasPrefix("searchv:") {
                // searchv:<order>:<duration>:<query>
                let parts = key.dropFirst(8).split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                let order = SearchOrder(rawValue: String(parts.first ?? "")) ?? .rank
                let duration = SearchDuration(rawValue: Int(parts.count > 1 ? parts[1] : "") ?? 0) ?? .any
                let q = parts.count > 2 ? String(parts[2]) : ""
                l = PagedList { s in
                    let p = Int(s["p"] ?? "1")!
                    let r = try await api.searchVideos(q, order: order, duration: duration, page: p)
                    return (r.items, ["p": "\(p + 1)"], p < r.pages)
                }
            } else if key.hasPrefix("search:") {
                let q = String(key.dropFirst(7))
                l = PagedList { s in
                    let p = Int(s["p"] ?? "1")!
                    let r = try await api.search(q, page: p)
                    return (r.items, ["p": "\(p + 1)"], p < r.pages)
                }
            } else if let c = collections[key] {
                l = PagedList { s in
                    let p = Int(s["p"] ?? "1")!
                    let r = try await api.collectionVideos(c, page: p)
                    return (r.items, ["p": "\(p + 1)"], r.more)
                }
            } else if key.hasPrefix("space:") {
                // space:<mid>:<order>
                let parts = key.split(separator: ":")
                let mid = Int(parts[1]) ?? 0, order = String(parts[2])
                l = PagedList { s in
                    let p = Int(s["p"] ?? "1")!
                    let r = try await api.spaceVideos(mid: mid, order: order, page: p)
                    return (r.items, ["p": "\(p + 1)"], r.more)
                }
            } else if key.hasPrefix("region:") {
                l = Self.regionList(key)
            } else if key.hasPrefix("fav:"), let id = Int(key.dropFirst(4)) {
                l = PagedList { s in
                    let p = Int(s["p"] ?? "1")!
                    let r = try await api.favList(mediaId: id, page: p)
                    return (r.items, ["p": "\(p + 1)"], r.more)
                }
            } else {
                l = PagedList { _ in ([], [:], false) }
            }
        }
        lists[key] = l
        return l
    }

    // MARK: Quick actions from cards

    func addToWatchLater(_ card: VideoCard) {
        guard account.loggedIn else { showLogin = true; return }
        Task {
            do {
                var aid = card.aid
                if aid == nil { aid = try await BiliAPI.shared.detail(bvid: card.bvid).aid }
                try await BiliAPI.shared.addWatchLater(aid: aid!)
                notify(L("已添加到稍后再看"))
                await lists["watchLater"]?.reload()
            } catch { notify(Lf("添加失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func removeFromWatchLater(_ card: VideoCard) {
        guard let aid = card.aid else { return }
        Task {
            do {
                try await BiliAPI.shared.removeWatchLater(aid: aid)
                lists["watchLater"]?.remove(card.bvid)
                notify(L("已从稍后再看移除"))
            } catch { notify(Lf("移除失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func copyLink(_ card: VideoCard) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.url.absoluteString, forType: .string)
        notify(L("已复制链接"))
    }
}

// MARK: - Like / coin / favourite / follow for one video

@MainActor
final class VideoActions: ObservableObject {
    @Published var detail: VideoDetail?
    @Published var relation = Relation()

    func load(bvid: String) async {
        if detail?.bvid != bvid {
            detail = nil
            detail = try? await BiliAPI.shared.detail(bvid: bvid)
        }
        relation = Relation()
        if AppModel.shared.account.loggedIn, let r = try? await BiliAPI.shared.relation(bvid: bvid) { relation = r }
    }

    private func requireLogin() -> Bool {
        if AppModel.shared.account.loggedIn { return true }
        AppModel.shared.showLogin = true
        return false
    }

    func toggleLike() {
        guard requireLogin(), let d = detail else { return }
        let on = !relation.like
        Task {
            do {
                try await BiliAPI.shared.like(bvid: d.bvid, on)
                relation.like = on
                detail?.stat.like += on ? 1 : -1
            } catch { AppModel.shared.notify(Lf("点赞失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func coin(_ n: Int) {
        guard requireLogin(), let d = detail else { return }
        Task {
            do {
                try await BiliAPI.shared.coin(bvid: d.bvid, count: n, alsoLike: !relation.like)
                relation.coin += n
                detail?.stat.coin += n
                if !relation.like { relation.like = true; detail?.stat.like += 1 }
                AppModel.shared.notify(Lf("投币成功 ×%@", "\(n)"))
            } catch { AppModel.shared.notify(Lf("投币失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func toggleFollow() {
        guard requireLogin(), let d = detail else { return }
        let on = !d.following
        Task {
            do {
                try await BiliAPI.shared.follow(mid: d.ownerMid, on)
                detail?.following = on
                detail?.follower += on ? 1 : -1
                AppModel.shared.notify(on ? L("已关注") : L("已取消关注"))
            } catch { AppModel.shared.notify(Lf("操作失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func watchLater() {
        guard requireLogin(), let d = detail else { return }
        Task {
            do { try await BiliAPI.shared.addWatchLater(aid: d.aid); AppModel.shared.notify(L("已添加到稍后再看")) }
            catch { AppModel.shared.notify(Lf("添加失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func folders() async -> [FavFolder] {
        guard let mid = AppModel.shared.account.mid, let d = detail else { return [] }
        return (try? await BiliAPI.shared.favFolders(mid: mid, rid: d.aid)) ?? []
    }

    func applyFavorites(original: [FavFolder], edited: [FavFolder]) {
        guard let d = detail else { return }
        let was = Set(original.filter(\.contains).map(\.id))
        let now = Set(edited.filter(\.contains).map(\.id))
        let add = Array(now.subtracting(was)), del = Array(was.subtracting(now))
        guard !add.isEmpty || !del.isEmpty else { return }
        Task {
            do {
                try await BiliAPI.shared.favorite(aid: d.aid, add: add, remove: del)
                let favNow = !now.isEmpty
                if favNow != relation.favorite { detail?.stat.favorite += favNow ? 1 : -1 }
                relation.favorite = favNow
                AppModel.shared.notify(favNow ? L("已收藏") : L("已取消收藏"))
            } catch { AppModel.shared.notify(Lf("收藏失败：%@", "\(error.localizedDescription)")) }
        }
    }
}

// MARK: - 精选 feed

@MainActor
final class FeaturedModel: ObservableObject {
    @Published private(set) var items: [VideoCard] = []
    @Published private(set) var index = 0
    @Published private(set) var direction = 1
    @Published private(set) var error: String?
    @Published private(set) var current: PlayerController?
    private var players: [String: PlayerController] = [:]
    /// Where you left each video in this feed, so switching back carries on from there.
    private var positions: [String: Double] = [:]
    private var page = 0
    private var fetching = false

    var currentItem: VideoCard? { items.indices.contains(index) ? items[index] : nil }
    var upNext: [VideoCard] { Array(items.dropFirst(index + 1).prefix(3)) }

    func owns(_ p: PlayerController) -> Bool { players.values.contains { $0 === p } }

    /// Called when the 精选 page appears: it becomes the thing that's playing.
    func take() async {
        if items.isEmpty {
            await fetchMore()
            if !items.isEmpty { activate() }
        } else if let c = current, let item = currentItem {
            AppModel.shared.setNowPlaying(c, card: item, context: .featured)
            c.play()
        }
    }

    func reset() async {
        for p in players.values { p.stop() }
        players.removeAll()
        positions.removeAll()
        current = nil
        items = []
        index = 0
        page = 0
        if AppModel.shared.route == .featured { await take() }
    }

    func fetchMore() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }
        page += 1
        do {
            var new = try await BiliAPI.shared.featured(page: page)
            // Screenshots: start the feed on a chosen video.
            if page == 1, let seed = ProcessInfo.processInfo.environment["BILIMAC_FEATURED_SEED"],
               let d = try? await BiliAPI.shared.detail(bvid: seed) {
                new.insert(VideoCard(bvid: d.bvid, cid: d.cid, aid: d.aid, title: d.title, cover: d.cover, owner: d.ownerName,
                                     views: d.stat.view, danmaku: d.stat.danmaku, duration: d.duration, pubdate: d.pubdate), at: 0)
            }
            let seen = Set(items.map(\.bvid))
            items += new.filter { !seen.contains($0.bvid) && $0.cid != nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func next() { move(1) }
    func previous() { move(-1) }
    func jump(to card: VideoCard) {
        guard let i = items.firstIndex(of: card) else { return }
        move(i - index)
    }

    private func move(_ d: Int) {
        guard d != 0 else { return }
        let target = index + d
        guard target >= 0 else { return }
        guard target < items.count else {
            if d > 0 { Task { await fetchMore(); if index + 1 < items.count { move(1) } } }
            return
        }
        direction = d > 0 ? 1 : -1
        rememberPosition()
        index = target
        activate()
        if index >= items.count - 3 { Task { await fetchMore(); preloadNeighbours() } }
    }

    private func controller(for i: Int, autoplay: Bool) -> PlayerController? {
        guard items.indices.contains(i), let cid = items[i].cid else { return nil }
        let it = items[i]
        if let p = players[it.bvid] { return p }
        let p = PlayerController()
        p.load(bvid: it.bvid, cid: cid, aid: it.aid, autoplay: autoplay, resume: false, startAt: positions[it.bvid])
        players[it.bvid] = p
        return p
    }

    /// Notes where the current video was left (skips the first seconds and the very end).
    private func rememberPosition() {
        guard let c = current, let item = currentItem else { return }
        let t = c.clock.time, d = c.clock.duration
        if t > 3, d == 0 || t < d - 5 { positions[item.bvid] = t } else { positions[item.bvid] = nil }
        if positions.count > 200 { positions.removeAll() }
    }

    private func activate() {
        let saved = currentItem.flatMap { positions[$0.bvid] }
        guard let c = controller(for: index, autoplay: true), let item = currentItem else { return }
        for p in players.values where p !== c { p.pause() }
        if c.phase == .ready {
            if let saved {
                if abs(c.clock.time - saved) > 1 { c.seek(to: saved) }
            } else if c.clock.duration > 0, c.clock.time > c.clock.duration - 5 {
                c.seek(to: 0)   // watched to the end before: start over
            }
        }
        if let saved { c.flash("arrow.uturn.backward", Lf("从 %@ 继续", formatTime(saved))) }
        c.play()
        current = c
        AppModel.shared.setNowPlaying(c, card: item, context: .featured)
        preloadNeighbours()
    }

    private func preloadNeighbours() {
        let keep = Set([index - 1, index, index + 1].filter(items.indices.contains).map { items[$0].bvid })
        for (k, p) in players where !keep.contains(k) && p !== AppModel.shared.nowPlaying { p.stop(); players[k] = nil }
        _ = controller(for: index + 1, autoplay: false)
    }

    func reloadStreams() { for p in players.values { p.reloadStream() } }
}

// MARK: - Keyboard / scroll routing

@MainActor
final class InputRouter {
    static let shared = InputRouter()
    /// The player keyboard shortcuts drive (the one that's playing).
    weak var player: PlayerController?
    private var accum: CGFloat = 0
    private var firedThisGesture = false
    private var lastFire = Date.distantPast
    private var lastArrowSeek = Date.distantPast
    /// Seconds ← / → jump.
    static let seekStep: Double = 15

    private var model: AppModel { AppModel.shared }
    private var featuredActive: Bool { model.route == .featured }

    func install() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return e }
                return e.type == .keyDown ? self.key(e) : self.scroll(e)
            }
        }
    }

    private func key(_ e: NSEvent) -> NSEvent? {
        guard let win = e.window, !win.isSheet, win.attachedSheet == nil else { return e }
        if let r = win.firstResponder as? NSText, r.isEditable { return e }   // search field etc.
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
        let settings = AppSettings.shared
        let p = player
        switch e.keyCode {
        case 125: // ↓
            if featuredActive { model.featured.next(); return nil }
            if let p { p.setVolume(p.player.volume - 0.1, feedback: true); return nil }
        case 126: // ↑
            if featuredActive { model.featured.previous(); return nil }
            if let p { p.setVolume(p.player.volume + 0.1, feedback: true); return nil }
        case 49: if let p { p.togglePlay(); return nil }            // space
        case 36, 76:                                                 // return: 发弹幕
            if p != nil, !FloatingCenter.shared.isOpen {
                NotificationCenter.default.post(name: .init("BiliMacComposeDanmaku"), object: nil)
                return nil
            }
        case 123, 124:                                               // ← →
            guard let p else { break }
            // Holding the key repeats ~30×/s; step at most every 0.15 s so it scans instead of flying.
            if e.isARepeat, Date().timeIntervalSince(lastArrowSeek) < 0.15 { return nil }
            lastArrowSeek = Date()
            p.seek(by: e.keyCode == 123 ? -Self.seekStep : Self.seekStep)
            return nil
        case 53:                                                     // esc
            if FloatingCenter.shared.isOpen { FloatingCenter.shared.dismissAll(); return nil }
            if model.playerMode != .normal { model.exitPlayerMode(); return nil }
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f": if p != nil { model.toggleScreenFull(); return nil }
        case "t": if p != nil { model.toggleAppFull(); return nil }
        case "d": settings.danmakuOn.toggle(); return nil
        case "i": settings.showStats.toggle(); return nil
        case "m": if let p { p.toggleMute(); return nil }
        // YouTube keys: J / L ±10 s, K play/pause, 0–9 jump to 0–90 %, < > speed.
        case "j": if let p { p.seek(by: -10); return nil }
        case "l": if let p { p.seek(by: 10); return nil }
        case "k": if let p { p.togglePlay(); return nil }
        default: break
        }
        if let p, let c = e.characters, let digit = Int(c), c.count == 1, p.clock.duration > 0 {
            p.seek(to: p.clock.duration * Double(digit) / 10)
            p.flash("arrow.forward.to.line", "\(digit * 10)%")
            return nil
        }
        let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]   // no 3×: see the speed menu
        if let p, let c = e.characters, c == "<" || c == ">" {
            let i = speeds.firstIndex(of: p.rate) ?? 2
            p.rate = speeds[max(0, min(speeds.count - 1, i + (c == ">" ? 1 : -1)))]
            return nil
        }
        return e
    }

    private func scroll(_ e: NSEvent) -> NSEvent? {
        ScrollActivity.last = Date()
        guard let win = e.window, let root = win.contentView, win.attachedSheet == nil else { return e }
        var hit = root.hitTest(e.locationInWindow)   // hitTest takes the superview's (here the window's) coordinates
        // Kept-alive pages sit under the shown one, transparent, and AppKit can still pick a hidden page's scroll
        // view as the one under the pointer: every scroll then went to a page nobody could see, and nothing in the
        // window scrolled. Hand such a scroll to the scroll view that's actually showing there.
        if let h = hit, Self.isInvisible(h) {
            hit = Self.visibleView(in: root, at: e.locationInWindow)
            var v = hit
            while let cur = v {
                if let target = cur as? NSScrollView { target.scrollWheel(with: e); return nil }
                v = cur.superview
            }
        }
        guard featuredActive else { return e }
        // Let scroll views (up-next column, menus) keep their own scrolling.
        var v = hit
        while let cur = v { if cur is NSScrollView { return e }; v = cur.superview }
        if !e.momentumPhase.isEmpty { return nil }
        if e.phase.isEmpty {
            guard abs(e.scrollingDeltaY) > 0.5, Date().timeIntervalSince(lastFire) > 0.45 else { return nil }
            fire(e.scrollingDeltaY < 0)
            return nil
        }
        if e.phase.contains(.began) { accum = 0; firedThisGesture = false }
        accum += e.scrollingDeltaY
        if !firedThisGesture, abs(accum) > 40 {
            firedThisGesture = true
            fire(accum < 0)
        }
        return nil
    }

    /// True when `v` or a view it sits in is hidden or fully transparent (a kept-alive page that isn't shown).
    private static func isInvisible(_ v: NSView) -> Bool {
        var cur: NSView? = v
        while let c = cur {
            if c.isHidden || c.alphaValue == 0 || (c.layer?.opacity ?? 1) == 0 { return true }
            cur = c.superview
        }
        return false
    }

    /// AppKit's hit test, skipping hidden and fully transparent views. `point` is in window coordinates.
    private static func visibleView(in root: NSView, at point: NSPoint) -> NSView? {
        func search(_ v: NSView) -> NSView? {
            if v.isHidden || v.alphaValue == 0 || (v.layer?.opacity ?? 1) == 0 { return nil }
            let p = v.convert(point, from: nil)
            guard v.bounds.contains(p) || !v.clipsToBounds && !v.subviews.isEmpty else { return nil }
            for sub in v.subviews.reversed() { if let hit = search(sub) { return hit } }
            return v.bounds.contains(p) ? v : nil
        }
        return search(root)
    }

    private func fire(_ forward: Bool) {
        lastFire = Date()
        forward ? model.featured.next() : model.featured.previous()
    }
}
