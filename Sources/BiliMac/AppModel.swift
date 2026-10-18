import AppKit
import QuartzCore
import Combine
import SwiftUI

enum Route: Hashable {
    case home, featured, dynamics, history, watchLater, favorites(Int?), search(String), video(VideoCard), space(Int),
         collection(SpaceCollection), settings

    /// Pages that use the collapsed icon rail instead of the full sidebar.
    var usesRail: Bool {
        switch self {
        case .featured, .video: return true
        default: return false
        }
    }

    var needsLogin: Bool {
        switch self {
        case .dynamics, .history, .watchLater, .favorites: return true
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
            let r = try await fetch(state)
            guard gen == generation else { return }
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
        await loadMore()
    }

    func remove(_ bvid: String) { items.removeAll { $0.bvid == bvid } }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Navigation
    @Published private(set) var route: Route = .home
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
        await BiliAPI.shared.ensureBuvid()
        await refreshAccount()
        if ProcessInfo.processInfo.environment["BILIMAC_NAVBENCH"] != nil { Task { await navBench() } }
        if ProcessInfo.processInfo.environment["BILIMAC_HOMETAB"] == "popular" { homeTab = .popular }
        if let r = Env.route {
            if r == "featured" { go(.featured) }
            else if r == "settings" { go(.settings) }
            else if r == "dynamics" { go(.dynamics) }
            else if r.hasPrefix("search:") { submitSearch(String(r.dropFirst(7))) }
            else if r.hasPrefix("video:") { open(VideoCard(bvid: String(r.dropFirst(6)), title: "", cover: nil, owner: "")) }
            else if r.hasPrefix("space:"), let mid = Int(r.dropFirst(6)) { go(.space(mid)) }
        }
    }

    /// Debug: cycles through pages and logs how long each switch keeps the main thread busy.
    var navStarted: CFTimeInterval = 0
    private func navBench() async {
        try? await Task.sleep(for: .seconds(4))
        let routes: [Route] = [.dynamics, .home, .history, .watchLater, .favorites(nil), .home, .settings, .home, .dynamics, .home]
        for r in routes {
            navStarted = CACurrentMediaTime()
            go(r)
            let t0 = navStarted
            // Measure until the main queue is free again (after SwiftUI's update pass).
            DispatchQueue.main.async {
                DispatchQueue.main.async { log(String(format: "nav→%@ main busy %.0f ms", "\(r)", (CACurrentMediaTime() - t0) * 1000)) }
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }

    // MARK: Navigation

    /// Direction of the last navigation (drives which side pages enter from).
    @Published private(set) var navForward = true

    func go(_ r: Route) {
        guard r != route else { return }
        backStack.append(route)
        forwardStack.removeAll()
        move(to: r, forward: true)
    }

    func goBack() {
        guard let r = backStack.popLast() else { return }
        forwardStack.append(route)
        move(to: r, forward: false)
    }

    func goForward() {
        guard let r = forwardStack.popLast() else { return }
        backStack.append(route)
        move(to: r, forward: true)
    }

    private func move(to r: Route, forward: Bool) {
        navForward = forward
        withAnimation(Motion.page) { route = r }
        updateNav()
    }

    private func updateNav() {
        canBack = !backStack.isEmpty
        canForward = !forwardStack.isEmpty
        if playerMode != .normal, !route.usesRail { setPlayerMode(.normal) }
    }

    func open(_ card: VideoCard) { go(.video(card)) }

    let search = SearchModel()

    func submitSearch(_ query: String? = nil) {
        let q = (query ?? searchText).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchText = q
        search.record(q)
        if let l = lists["search:\(q)"] { Task { await l.reload() } }
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
        switch route {
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
        } else {
            favFolders = []
        }
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

    func notify(_ s: String) {
        withAnimation(Motion.pop) { toast = s }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { withAnimation { toast = nil } }
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
            l = PagedList { s in
                let p = Int(s["p"] ?? "1")!
                return (try await api.homeRecommend(page: p), ["p": "\(p + 1)"], true)
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
            if key.hasPrefix("search:") {
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
        index = target
        activate()
        if index >= items.count - 3 { Task { await fetchMore(); preloadNeighbours() } }
    }

    private func controller(for i: Int, autoplay: Bool) -> PlayerController? {
        guard items.indices.contains(i), let cid = items[i].cid else { return nil }
        let it = items[i]
        if let p = players[it.bvid] { return p }
        let p = PlayerController()
        p.load(bvid: it.bvid, cid: cid, aid: it.aid, autoplay: autoplay, resume: false)
        players[it.bvid] = p
        return p
    }

    private func activate() {
        guard let c = controller(for: index, autoplay: true), let item = currentItem else { return }
        for p in players.values where p !== c { p.pause() }
        if c.phase == .ready { c.seek(to: 0) }
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
        case 123: if let p { p.seek(by: -5); return nil }           // ←
        case 124: if let p { p.seek(by: 5); return nil }            // →
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
        let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
        if let p, let c = e.characters, c == "<" || c == ">" {
            let i = speeds.firstIndex(of: p.rate) ?? 2
            p.rate = speeds[max(0, min(speeds.count - 1, i + (c == ">" ? 1 : -1)))]
            return nil
        }
        return e
    }

    private func scroll(_ e: NSEvent) -> NSEvent? {
        guard featuredActive, let win = e.window, win.attachedSheet == nil else { return e }
        // Let scroll views (up-next column, menus) keep their own scrolling.
        var v = win.contentView?.hitTest(e.locationInWindow)
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

    private func fire(_ forward: Bool) {
        lastFire = Date()
        forward ? model.featured.next() : model.featured.previous()
    }
}
