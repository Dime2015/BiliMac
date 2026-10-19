import AppKit
import SwiftUI

// MARK: - Models

enum SearchKind: String, CaseIterable, Identifiable {
    case all, video, bangumi = "media_bangumi", film = "media_ft", live = "live_room", article, user = "bili_user"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return L("综合")
        case .video: return L("视频")
        case .bangumi: return L("番剧")
        case .film: return L("影视")
        case .live: return L("直播")
        case .article: return L("专栏")
        case .user: return L("用户")
        }
    }
}

/// 综合排序 / 最多播放 / 最新发布 / 最多弹幕 / 最多收藏 (bilibili's `order` values).
enum SearchOrder: String, CaseIterable, Identifiable {
    case rank = "totalrank", plays = "click", newest = "pubdate", danmaku = "dm", favorites = "stow", likes = "like"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rank: return L("综合排序")
        case .plays: return L("最多播放")
        case .newest: return L("最新发布")
        case .danmaku: return L("最多弹幕")
        case .favorites: return L("最多收藏")
        case .likes: return L("最多点赞")
        }
    }
}

/// Video length filter (bilibili's `duration` 0–4).
enum SearchDuration: Int, CaseIterable, Identifiable {
    case any, under10, to30, to60, over60
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .any: return L("全部时长")
        case .under10: return L("10 分钟以下")
        case .to30: return L("10–30 分钟")
        case .to60: return L("30–60 分钟")
        case .over60: return L("60 分钟以上")
        }
    }
}

/// Sorting for the other tabs: bilibili's `order` / `order_sort` for that kind.
struct RowSort: Hashable, Identifiable {
    let label: String
    let order: String
    var sort: Int? = nil
    var id: String { "\(order)-\(sort ?? -1)" }
}

extension SearchKind {
    var sorts: [RowSort] {
        switch self {
        case .user:
            return [RowSort(label: L("默认排序"), order: ""), RowSort(label: L("粉丝数由高到低"), order: "fans", sort: 0),
                    RowSort(label: L("粉丝数由低到高"), order: "fans", sort: 1), RowSort(label: L("等级由高到低"), order: "level", sort: 0)]
        case .live:
            return [RowSort(label: L("综合排序"), order: ""), RowSort(label: L("人气最高"), order: "online"),
                    RowSort(label: L("最新开播"), order: "live_time")]
        case .article:
            return [RowSort(label: L("综合排序"), order: "totalrank"), RowSort(label: L("最新发布"), order: "pubdate"),
                    RowSort(label: L("最多阅读"), order: "click"), RowSort(label: L("最多喜欢"), order: "attention"),
                    RowSort(label: L("最多评论"), order: "scores")]
        default: return []
        }
    }
}

struct SearchUser: Identifiable, Hashable {
    let mid: Int
    let name: String
    let face: URL?
    let sign: String
    let fans: Int
    let videos: Int
    let level: Int
    let official: String
    let liveRoom: Int?
    var recent: [VideoCard]
    var id: Int { mid }

    static func parse(_ j: JSON) -> SearchUser? {
        guard let mid = j.int("mid") else { return nil }
        let recent: [VideoCard] = j.arr("res").compactMap { v in
            guard let bvid = v.str("bvid"), !bvid.isEmpty else { return nil }
            return VideoCard(bvid: bvid, aid: v.int("aid"), title: plainTitle(v.str("title") ?? ""), cover: imageURL(v.str("pic")),
                             owner: j.str("uname") ?? "", ownerMid: mid, views: v.int("play") ?? Int(v.str("play") ?? ""),
                             danmaku: v.int("dm"), duration: parseDurationText(v.str("duration")),
                             pubdate: v.int("pubdate").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        return SearchUser(mid: mid, name: plainTitle(j.str("uname") ?? ""), face: imageURL(j.str("upic")), sign: j.str("usign") ?? "",
                          fans: j.int("fans") ?? 0, videos: j.int("videos") ?? 0, level: j.int("level") ?? 0,
                          official: j.obj("official_verify")?.str("desc") ?? "",
                          liveRoom: (j.int("is_live") ?? 0) == 1 ? j.int("room_id") : nil, recent: recent)
    }
}

struct LiveRoomCard: Identifiable, Hashable {
    let roomId: Int
    let title: String
    let cover: URL?
    let uname: String
    let uid: Int
    let face: URL?
    let online: Int
    let area: String
    let live: Bool
    var id: Int { roomId }

    static func parse(_ j: JSON) -> LiveRoomCard? {
        guard let room = j.int("roomid") ?? j.int("room_id") else { return nil }
        // Search, recommendation and area lists name the same fields a little differently.
        let cover = [j.str("user_cover"), j.str("cover"), j.str("system_cover"), j.str("pic")].compactMap { $0 }.first { !$0.isEmpty }
        return LiveRoomCard(roomId: room, title: plainTitle(j.str("title") ?? ""), cover: imageURL(cover),
                            uname: plainTitle(j.str("uname") ?? ""), uid: j.int("uid") ?? 0, face: imageURL(j.str("uface") ?? j.str("face")),
                            online: j.int("online") ?? 0, area: plainTitle(j.str("cate_name") ?? j.str("area_v2_name") ?? j.str("area_name") ?? ""),
                            live: (j.int("live_status") ?? 1) == 1)
    }
}

struct MediaCard: Identifiable, Hashable {
    let id: Int
    let title: String
    let cover: URL?
    let url: URL?
    let kind: String
    let score: Double?
    let meta: String

    static func parse(_ j: JSON) -> MediaCard? {
        guard let id = j.int("season_id") ?? j.int("media_id") else { return nil }
        let score = j.obj("media_score")?.double("score").flatMap { $0 > 0 ? $0 : nil }
        let year = j.int("pubtime").map { Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) }
        let meta = [year.map(String.init), j.str("styles"), j.str("index_show")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return MediaCard(id: id, title: plainTitle(j.str("title") ?? ""), cover: imageURL(j.str("cover")),
                         url: j.str("url").flatMap(URL.init(string:)), kind: j.str("season_type_name") ?? "", score: score, meta: meta)
    }
}

struct ArticleCard: Identifiable, Hashable {
    let id: Int
    let title: String
    let desc: String
    let image: URL?
    let author: String
    let mid: Int?
    let views: Int
    let likes: Int
    let date: Date?

    static func parse(_ j: JSON) -> ArticleCard? {
        guard let id = j.int("id") else { return nil }
        return ArticleCard(id: id, title: plainTitle(j.str("title") ?? ""), desc: plainTitle(j.str("desc") ?? ""),
                           image: (j["image_urls"] as? [String])?.first.flatMap(imageURL),
                           author: j.str("author") ?? "", mid: j.int("mid"), views: j.int("view") ?? 0, likes: j.int("like") ?? 0,
                           date: j.int("pub_time").map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

// MARK: - API

extension BiliAPI {
    /// 综合: result counts for each kind and the matching UP 主, if any.
    func searchOverview(_ keyword: String) async throws -> (counts: [SearchKind: Int], user: SearchUser?) {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/all/v2", ["keyword": keyword])
        let p = d.obj("pageinfo") ?? [:]
        func n(_ k: String) -> Int { p.obj(k)?.int("numResults") ?? 0 }
        let counts: [SearchKind: Int] = [.video: n("video"), .bangumi: n("media_bangumi"), .film: n("media_ft"),
                                         .live: max(n("live_room"), n("live")), .article: n("article"), .user: n("bili_user")]
        let user = d.arr("result").first { $0.str("result_type") == "bili_user" }?.arr("data").first.flatMap(SearchUser.parse)
        // Signed out, bilibili often answers this one with a captcha voucher and no data: count each kind on its
        // own instead (those searches still work), and take a user whose name is exactly the query.
        if counts.values.allSatisfy({ $0 == 0 }) && user == nil {
            async let v = searchCount(.video, keyword), l = searchCount(.live, keyword), a = searchCount(.article, keyword)
            async let u = try? searchRows(.user, keyword, page: 1)
            let users = (await u)?.rows ?? []
            let norm = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
            let exact = users.compactMap(SearchUser.parse).first { norm($0.name) == norm(keyword) }
            let userCount = users.isEmpty ? 0 : max(users.count, (try? await searchTotal(.user, keyword)) ?? users.count)
            return ([.video: await v, .live: await l, .article: await a, .user: userCount], exact)
        }
        return (counts, user)
    }

    private func searchCount(_ kind: SearchKind, _ keyword: String) async -> Int {
        (try? await searchTotal(kind, keyword)) ?? 0
    }

    private func searchTotal(_ kind: SearchKind, _ keyword: String) async throws -> Int {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/type", [
            "search_type": kind == .all ? "video" : kind.rawValue, "keyword": keyword, "page": "1",
        ])
        return d.int("numResults") ?? 0
    }

    func searchVideos(_ keyword: String, order: SearchOrder, duration: SearchDuration = .any, page: Int) async throws -> (items: [VideoCard], pages: Int) {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/type", [
            "search_type": "video", "keyword": keyword, "page": "\(page)", "order": order.rawValue, "duration": "\(duration.rawValue)",
        ])
        return (d.arr("result").compactMap(VideoCard.archive), d.int("numPages") ?? 1)
    }

    /// One page of another kind's results, still as JSON rows (each tab parses its own).
    func searchRows(_ kind: SearchKind, _ keyword: String, page: Int, sort: RowSort? = nil) async throws -> (rows: [JSON], pages: Int) {
        var p = ["search_type": kind.rawValue, "keyword": keyword, "page": "\(page)"]
        if let sort, !sort.order.isEmpty { p["order"] = sort.order }
        if let n = sort?.sort { p["order_sort"] = "\(n)" }
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/type", p)
        // Live search answers {live_room: [...], live_user: [...]}.
        let rows = (d["result"] as? [JSON]) ?? d.obj("result")?.arr(kind.rawValue) ?? []
        return (rows, d.int("numPages") ?? 1)
    }
}

// MARK: - State

@MainActor
final class SearchPageModel: ObservableObject {
    let query: String
    @Published var kind: SearchKind = .all
    @Published var order: SearchOrder = .rank
    @Published var duration: SearchDuration = .any
    @Published private(set) var rowSorts: [SearchKind: RowSort] = [:]

    func sort(for k: SearchKind) -> RowSort? { rowSorts[k] ?? k.sorts.first }

    func setSort(_ s: RowSort, for k: SearchKind) {
        guard s != sort(for: k) else { return }
        rowSorts[k] = s
        Task { await loadRows(k, reset: true) }
    }
    @Published private(set) var counts: [SearchKind: Int] = [:]
    @Published private(set) var user: SearchUser?
    @Published private(set) var userFollowing: Bool?

    @Published private(set) var users: [SearchUser] = []
    @Published private(set) var rooms: [LiveRoomCard] = []
    @Published private(set) var media: [MediaCard] = []
    @Published private(set) var articles: [ArticleCard] = []
    @Published private(set) var loading = false
    @Published private(set) var more = true
    private var page = 1

    init(query: String) { self.query = query }

    func loadOverview() async {
        guard counts.isEmpty else { return }
        let overview: (counts: [SearchKind: Int], user: SearchUser?)?
        do { overview = try await BiliAPI.shared.searchOverview(query) } catch { log("search overview: \(error)"); overview = nil }
        if let r = overview {
            counts = r.counts
            user = r.user
            if let u = r.user {
                // Fuller row of their latest videos, and whether I follow them.
                async let vids = try? BiliAPI.shared.spaceVideos(mid: u.mid, order: "pubdate", page: 1)
                async let info = try? BiliAPI.shared.space(mid: u.mid)
                if let v = await vids, !v.items.isEmpty { user?.recent = Array(v.items.prefix(8)) }
                if AppModel.shared.account.loggedIn, let i = await info { userFollowing = i.following }
            }
            if (r.counts[.live] ?? 0) > 0, rooms.isEmpty { await loadRows(.live, reset: true) }
        }
    }

    /// The video grid for the current order lives in the app's shared list cache.
    var videoKey: String { "searchv:\(order.rawValue):\(duration.rawValue):\(query)" }

    func select(_ k: SearchKind) {
        guard k != kind else { return }
        kind = k
        if [.user, .article, .bangumi, .film].contains(k) || (k == .live && rooms.isEmpty) {
            Task { await loadRows(k, reset: true) }
        }
    }

    /// Bumped on every reset, so a page still on its way for the old tab or sort is dropped.
    private var generation = 0

    func loadRows(_ k: SearchKind, reset: Bool = false) async {
        if reset { generation += 1; page = 1; more = true; loading = false }
        guard !loading, more else { return }
        loading = true
        let gen = generation
        defer { if gen == generation { loading = false } }
        let r: (rows: [JSON], pages: Int)
        do { r = try await BiliAPI.shared.searchRows(k, query, page: page, sort: sort(for: k)) } catch {
            guard gen == generation, (error as? URLError)?.code != .cancelled, !(error is CancellationError) else { return }
            log("search \(k.rawValue) p\(page): \(error)")
            more = false
            return
        }
        guard gen == generation else { return }
        switch k {
        case .user: users = (reset ? [] : users) + r.rows.compactMap(SearchUser.parse)
        case .live: rooms = (reset ? [] : rooms) + r.rows.compactMap(LiveRoomCard.parse)
        case .bangumi, .film: media = (reset ? [] : media) + r.rows.compactMap(MediaCard.parse)
        case .article: articles = (reset ? [] : articles) + r.rows.compactMap(ArticleCard.parse)
        default: break
        }
        more = page < r.pages && !r.rows.isEmpty
        page += 1
    }

    func toggleFollow() {
        guard let u = user, let on = userFollowing.map({ !$0 }) ?? (AppModel.shared.account.loggedIn ? true : nil) else {
            AppModel.shared.showLogin = true; return
        }
        Task {
            do {
                try await BiliAPI.shared.follow(mid: u.mid, on)
                userFollowing = on
                AppModel.shared.notify(on ? L("已关注") : L("已取消关注"))
            } catch { AppModel.shared.notify(Lf("操作失败：%@", "\(error.localizedDescription)")) }
        }
    }
}

// MARK: - Page

struct SearchPage: View {
    @StateObject private var model: SearchPageModel
    private var app: AppModel { AppModel.shared }

    init(query: String) { _model = StateObject(wrappedValue: SearchPageModel(query: query)) }

    var body: some View {
        MainPanel(tint: Theme.tint(hex: 0x2B3D4F, light: 0xDCE8F2)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SearchTabs(model: model)
                    switch model.kind {
                    case .all, .video:
                        HStack {
                            SlidingChips(options: SearchOrder.allCases.map { ($0, $0.label) }, selection: $model.order, style: .white)
                            Spacer(minLength: 12)
                            Dropdown(options: SearchDuration.allCases.map { ($0, $0.label) }, selection: $model.duration)
                        }
                        if model.kind == .all {
                            if let u = model.user { UserHero(user: u, following: model.userFollowing) { model.toggleFollow() } }
                            if !model.rooms.isEmpty {
                                SectionHeader(title: L("直播"), action: L("查看全部直播")) { model.select(.live) }
                                LiveGrid(rooms: Array(model.rooms.prefix(4)))
                            }
                        }
                        ShelfGrid(list: app.list(for: model.videoKey), emptyText: L("没有找到相关视频"))
                            .padding(.horizontal, -10)
                            .id(model.videoKey)
                    case .live:
                        sortChips(.live)
                        LiveGrid(rooms: model.rooms)
                        footer(.live, empty: model.rooms.isEmpty, text: L("没有正在直播的相关直播间"))
                    case .user:
                        sortChips(.user)
                        LazyVStack(spacing: 4) { ForEach(model.users) { UserRow(user: $0) } }
                        footer(.user, empty: model.users.isEmpty, text: L("没有找到相关用户"))
                    case .article:
                        sortChips(.article)
                        LazyVStack(spacing: 4) { ForEach(model.articles) { ArticleRow(article: $0) } }
                        footer(.article, empty: model.articles.isEmpty, text: L("没有找到相关专栏"))
                    case .bangumi, .film:
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 18) {
                            ForEach(model.media) { MediaTile(media: $0) }
                        }
                        footer(model.kind, empty: model.media.isEmpty, text: L("没有找到相关内容"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
        .task { await model.loadOverview() }
    }

    private func sortChips(_ k: SearchKind) -> some View {
        SlidingChips(options: k.sorts.map { ($0, $0.label) },
                     selection: Binding(get: { model.sort(for: k) ?? k.sorts[0] }, set: { model.setSort($0, for: k) }), style: .white)
    }

    @ViewBuilder private func footer(_ k: SearchKind, empty: Bool, text: String) -> some View {
        HStack {
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            // onAppear + Task: a .task would be cancelled (and its request with it) as soon as the spinner replaces this view.
            else if model.more { Color.clear.frame(height: 1).onAppear { Task { await model.loadRows(k) } } }
            else if empty { Text(text).font(.system(size: 13)).foregroundStyle(Theme.text3) }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

/// 综合 · 视频 99+ · 番剧 · 影视 · 直播 1 · 专栏 99+ · 用户 99+
private struct SearchTabs: View {
    @ObservedObject var model: SearchPageModel
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.query).font(.system(size: 30, weight: .black)).lineLimit(1)
            HStack(spacing: 22) {
                ForEach(SearchKind.allCases.filter(shown)) { k in
                    Button { withAnimation(Motion.slide) { model.select(k) } } label: {
                        VStack(spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(k.label).font(.system(size: 15, weight: model.kind == k ? .bold : .medium))
                                if let n = model.counts[k], k != .all {
                                    Text(n > 99 ? "99+" : "\(n)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                                        .foregroundStyle(Theme.text3)
                                }
                            }
                            .foregroundStyle(model.kind == k ? Theme.pink : Theme.text2)
                            ZStack {
                                Capsule().fill(.clear).frame(height: 3)
                                if model.kind == k { Capsule().fill(Theme.pink).frame(height: 3).matchedGeometryEffect(id: "tab", in: ns) }
                            }
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    /// 番剧 / 影视 only when there is something (they are region-locked outside mainland China).
    private func shown(_ k: SearchKind) -> Bool {
        k == .bangumi || k == .film ? (model.counts[k] ?? 0) > 0 : true
    }
}

private struct SectionHeader: View {
    let title: String
    let action: String
    let onAction: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .bold))
            Spacer()
            Button(action: onAction) {
                HStack(spacing: 3) {
                    Text(action)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.pressable)
        }
    }
}

/// The UP 主 the query names: card with follow, their latest videos, and a link to all of them.
private struct UserHero: View {
    let user: SearchUser
    let following: Bool?
    let onFollow: () -> Void
    private var app: AppModel { AppModel.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button { app.go(.space(user.mid)) } label: { Avatar(url: user.face, size: 64) }
                    .buttonStyle(.pressable)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Button { app.go(.space(user.mid)) } label: {
                            Text(user.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.text)
                        }
                        .buttonStyle(.pressable)
                        if user.level > 0 {
                            Text("LV\(user.level)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(hex: 0xF0A24A))
                        }
                        if let room = user.liveRoom {
                            Button { app.openLive(room) } label: {
                                Text(L("直播中")).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.pink, in: Capsule())
                            }
                            .buttonStyle(.pressable)
                            .help(L("进入直播间"))
                        }
                        Button(action: onFollow) {
                            Text(following == true ? L("已关注") : L("+ 关注"))
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(following == true ? Theme.text2 : Theme.onPrimary)
                                .padding(.horizontal, 14).frame(height: 28)
                                .background(following == true ? Theme.chip : Theme.primary, in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .padding(.leading, 6)
                    }
                    Text([Lf("%@粉丝", formatCount(user.fans)), Lf("%@个视频", "\(user.videos)"), user.official]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                    if !user.sign.isEmpty {
                        Text(user.sign).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if !user.recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(user.recent) { c in
                            Button { app.open(c) } label: { ShelfCard(card: c).frame(width: 220) }
                                .buttonStyle(.pressableCard)
                                .contextMenu { CardMenu(card: c) }
                        }
                    }
                    .padding(.horizontal, -10)
                }
                Button { app.go(.space(user.mid)) } label: {
                    HStack(spacing: 3) {
                        Text(L("查看TA的所有稿件"))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.blue)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .background(Theme.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct LiveGrid: View {
    let rooms: [LiveRoomCard]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], alignment: .leading, spacing: 18) {
            ForEach(rooms) { LiveTile(room: $0) }
        }
    }
}

private struct LiveTile: View {
    let room: LiveRoomCard
    @State private var hover = false
    var body: some View {
        Button { AppModel.shared.openLive(room.roomId) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(RemoteImage(url: thumbnail(room.cover, width: 480)))
                    .overlay(alignment: .topLeading) {
                        if room.live {
                            HStack(spacing: 4) {
                                Circle().fill(.white).frame(width: 5, height: 5)
                                Text(L("直播中")).font(.system(size: 10.5, weight: .bold))
                            }
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.pink, in: Capsule()).padding(8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if room.online > 0 {
                            Text(Lf("%@ 人看过", formatCount(room.online))).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.55), in: Capsule()).padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(room.title).font(.system(size: 13.5, weight: .bold)).lineLimit(1).foregroundStyle(Theme.text)
                HStack(spacing: 0) {
                    OwnerLink(name: room.uname, mid: room.uid)
                    if !room.area.isEmpty { Text(" · " + room.area).font(.system(size: 12.5)).foregroundStyle(Theme.meta).lineLimit(1) }
                }
            }
            .padding(8)
            .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .onHover { hover = $0 }
    }
}

private struct UserRow: View {
    let user: SearchUser
    @State private var hover = false
    var body: some View {
        Button { AppModel.shared.go(.space(user.mid)) } label: {
            HStack(spacing: 14) {
                Avatar(url: user.face, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(user.name).font(.system(size: 15, weight: .bold))
                        if user.level > 0 {
                            Text("LV\(user.level)").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Color(hex: 0xF0A24A))
                        }
                        if user.liveRoom != nil {
                            Text(L("直播中")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.pink, in: Capsule())
                        }
                    }
                    Text([Lf("%@粉丝", formatCount(user.fans)), Lf("%@个视频", "\(user.videos)"), user.official]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                    if !user.sign.isEmpty { Text(user.sign).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text)
            .padding(10)
            .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

private struct ArticleRow: View {
    let article: ArticleCard
    @State private var hover = false
    var body: some View {
        Button { NSWorkspace.shared.open(URL(string: "https://www.bilibili.com/read/cv\(article.id)")!) } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(article.title).font(.system(size: 15, weight: .bold)).lineLimit(2)
                    if !article.desc.isEmpty {
                        Text(article.desc).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(2)
                    }
                    HStack(spacing: 0) {
                        OwnerLink(name: article.author, mid: article.mid, font: .system(size: 12))
                        Text(" · " + [Lf("%@ 阅读", formatCount(article.views)), Lf("%@ 喜欢", formatCount(article.likes)),
                                      formatRelativeDate(article.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(Theme.meta).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let image = article.image {
                    RemoteImage(url: thumbnail(image, width: 300)).frame(width: 150, height: 94)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .foregroundStyle(Theme.text)
            .padding(10)
            .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(L("在浏览器中打开"))
    }
}

private struct MediaTile: View {
    let media: MediaCard
    var body: some View {
        Button { if let u = media.url { NSWorkspace.shared.open(u) } } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear.aspectRatio(3 / 4, contentMode: .fit)
                    .overlay(RemoteImage(url: thumbnail(media.cover, width: 320)))
                    .overlay(alignment: .topTrailing) {
                        if !media.kind.isEmpty {
                            Text(media.kind).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.pink, in: Capsule()).padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(media.title).font(.system(size: 13.5, weight: .bold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let s = media.score { Text(String(format: "%.1f", s)).font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0xF0A24A)) }
                    Text(media.meta).font(.system(size: 11.5)).foregroundStyle(Theme.meta).lineLimit(1)
                }
            }
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.pressableCard)
        .help(L("在浏览器中打开（版权内容，BiliMac 无法播放）"))
    }
}

