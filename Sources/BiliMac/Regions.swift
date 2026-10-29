import SwiftUI

// MARK: - Model

/// A channel from the website's home-page grid. UGC channels use the 2025 partition numbers (tid_v2, 1001–1031);
/// the six PGC channels (番剧, 影视 …) are licensed series that only bilibili's own players can show, so their
/// pages list posters that open in the browser.
struct Region: Identifiable, Hashable {
    enum Kind: Hashable {
        /// `ranked`: whether ranking/v2 accepts the tid (资讯 answers -400).
        case ugc(tid: Int, ranked: Bool)
        case pgc(seasonType: Int)
    }

    /// Route id: the tid for UGC channels, the season_type (1–7) for PGC ones; the two ranges never overlap.
    let id: Int
    let name: String
    let kind: Kind
    /// Path on www.bilibili.com.
    let path: String

    var webURL: URL { URL(string: "https://www.bilibili.com/\(path)/")! }
    var isPGC: Bool { if case .pgc = kind { return true } else { return false } }

    /// Header wash, a different hue per channel.
    var tint: Color {
        let hue = CGFloat((id * 37) % 360) / 360
        return Theme.tint(hue: hue, saturation: 0.45)
    }

    private static func ugc(_ tid: Int, _ name: String, _ route: String, ranked: Bool = true) -> Region {
        Region(id: tid, name: name, kind: .ugc(tid: tid, ranked: ranked), path: "c/\(route)")
    }

    private static func pgc(_ type: Int, _ name: String, _ path: String) -> Region {
        Region(id: type, name: name, kind: .pgc(seasonType: type), path: path)
    }

    /// The two rows on the website's home page, in its order (row by row).
    static let main: [Region] = [
        pgc(1, L("番剧"), "anime"), pgc(4, L("国创"), "guochuang"), pgc(7, L("综艺"), "variety"),
        ugc(1005, L("动画"), "douga"), ugc(1007, L("鬼畜"), "kichiku"), ugc(1004, L("舞蹈"), "dance"),
        ugc(1002, L("娱乐"), "ent"), ugc(1012, L("科技数码"), "tech"), ugc(1020, L("美食"), "food"),
        pgc(2, L("电影"), "movie"), pgc(5, L("电视剧"), "tv"), pgc(3, L("纪录片"), "documentary"),
        ugc(1008, L("游戏"), "game"), ugc(1003, L("音乐"), "music"), ugc(1001, L("影视"), "cinephile"),
        ugc(1010, L("知识"), "knowledge"), ugc(1009, L("资讯"), "information", ranked: false),
    ]

    /// Behind 「更多」.
    static let more: [Region] = [
        ugc(1021, L("小剧场"), "shortplay"), ugc(1013, L("汽车"), "car"), ugc(1014, L("时尚美妆"), "fashion"),
        ugc(1018, L("体育运动"), "sports"), ugc(1024, L("动物"), "animal"), ugc(1029, "vlog", "vlog"),
        ugc(1006, L("绘画"), "painting"), ugc(1011, L("人工智能"), "ai"), ugc(1015, L("家装房产"), "home"),
        ugc(1016, L("户外"), "outdoors"), ugc(1017, L("健身"), "gym"), ugc(1019, L("手工"), "handmake"),
        ugc(1022, L("旅游出行"), "travel"), ugc(1023, L("三农"), "rural"), ugc(1025, L("亲子"), "parenting"),
        ugc(1026, L("健康"), "health"), ugc(1027, L("情感"), "emotion"), ugc(1030, L("生活兴趣"), "life_joy"),
        ugc(1031, L("生活经验"), "life_experience"),
    ]

    static func find(_ id: Int) -> Region? { (main + more).first { $0.id == id } }
}

enum RegionMode: String, CaseIterable {
    case recommend, ranking
    var title: String { self == .recommend ? L("推荐") : L("排行榜") }
}

/// A licensed series (番剧, 电影 …) from the PGC ranking or index.
struct Season: Identifiable, Hashable {
    let id: Int
    let title: String
    let cover: URL?
    let badge: String?
    let rating: String?
    /// 更新至第 12 话 / 全 12 话 …
    let progress: String?
    /// Plays or the index's sort value (2025年10月更新, 123万追番 …).
    let meta: String?
    let url: URL

    static func rank(_ j: JSON) -> Season? {
        guard let id = j.int("season_id"), let title = j.str("title") else { return nil }
        let stat = j.obj("stat")
        let rating = j.str("rating").map { $0.replacingOccurrences(of: "分", with: "") }
        return Season(id: id, title: title, cover: imageURL(j.str("cover")),
                      badge: nonEmpty(j.obj("badge_info")?.str("text") ?? j.str("badge")),
                      rating: nonEmpty(rating), progress: nonEmpty(j.obj("new_ep")?.str("index_show") ?? j.str("desc")),
                      meta: stat?.int("view").map { Lf("%@ 播放", "\(formatCount($0))") },
                      url: link(j.str("url"), id))
    }

    static func index(_ j: JSON) -> Season? {
        guard let id = j.int("season_id"), let title = j.str("title") else { return nil }
        return Season(id: id, title: title, cover: imageURL(j.str("cover")),
                      badge: nonEmpty(j.obj("badge_info")?.str("text") ?? j.str("badge")),
                      rating: nonEmpty(j.str("score")), progress: nonEmpty(j.str("index_show")),
                      // Sorted by score, `order` repeats the rating ("9.8分").
                      meta: nonEmpty(j.str("order")).flatMap { $0.hasSuffix("分") ? nil : $0 }, url: link(j.str("link"), id))
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static func link(_ s: String?, _ id: Int) -> URL {
        imageURL(s) ?? URL(string: "https://www.bilibili.com/bangumi/play/ss\(id)")!
    }
}

/// PGC lists: the ranking, then the index sorted three ways.
enum SeasonOrder: String, CaseIterable {
    case ranking, updated, plays, score

    var title: String {
        switch self {
        case .ranking: return L("排行榜")
        case .updated: return L("最近更新")
        case .plays: return L("最多播放")
        case .score: return L("最高评分")
        }
    }

    /// pgc/season/index/result `order`.
    var indexOrder: Int? {
        switch self {
        case .ranking: return nil
        case .updated: return 0
        case .plays: return 2
        case .score: return 4
        }
    }
}

// MARK: - API

extension BiliAPI {
    /// 分区推荐: the feed on www.bilibili.com/c/<channel>/. Endless; `page` starts at 1.
    func regionFeed(tid: Int, page: Int) async throws -> [VideoCard] {
        let d = try await get("https://api.bilibili.com/x/web-interface/region/feed/rcmd", [
            "display_id": "\(page)", "request_cnt": "15", "from_region": "\(tid)", "device": "web", "plat": "30",
        ])
        return d.arr("archives").compactMap { a -> VideoCard? in
            guard (a.str("goto") ?? "av") == "av", var c = VideoCard.archive(a) else { return nil }
            // This feed names the channel under `author`, not `owner`.
            if let au = a.obj("author") { c.owner = au.str("name") ?? c.owner; c.ownerMid = au.int("mid") ?? c.ownerMid }
            return c
        }
    }

    /// 分区排行 (top 100 of the last few days). Signed out, it answers -352 unless it comes from the ranking page.
    func regionRanking(tid: Int) async throws -> [VideoCard] {
        let d = try await get("https://api.bilibili.com/x/web-interface/ranking/v2", ["rid": "\(tid)", "type": "all"],
                              referer: "https://www.bilibili.com/v/popular/rank/all")
        return d.arr("list").compactMap(VideoCard.archive)
    }

    /// PGC ranking (3 days). Regions without the licence get an empty list.
    func seasonRanking(type: Int) async throws -> [Season] {
        let d = try await get("https://api.bilibili.com/pgc/season/rank/web/list", ["season_type": "\(type)", "day": "3"])
        return d.arr("list").compactMap(Season.rank)
    }

    func seasonIndex(type: Int, order: Int, page: Int) async throws -> (items: [Season], more: Bool) {
        let d = try await get("https://api.bilibili.com/pgc/season/index/result", [
            "season_type": "\(type)", "st": "\(type)", "type": "1", "order": "\(order)", "sort": "0",
            "page": "\(page)", "pagesize": "30",
        ])
        return (d.arr("list").compactMap(Season.index), (d.int("has_next") ?? 0) == 1)
    }
}

extension AppModel {
    /// Loader for `region:<tid>:<mode>` keys (see `list(for:)`).
    static func regionList(_ key: String) -> PagedList {
        let parts = key.split(separator: ":")
        let tid = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let mode = parts.count > 2 ? RegionMode(rawValue: String(parts[2])) ?? .recommend : .recommend
        let api = BiliAPI.shared
        switch mode {
        case .recommend:
            return PagedList { s in
                let p = Int(s["p"] ?? "1")!
                let items = try await api.regionFeed(tid: tid, page: p)
                // The website stops after a few hundred cards; so do we.
                return (items, ["p": "\(p + 1)"], !items.isEmpty && p < 20)
            }
        case .ranking:
            return PagedList { _ in (try await api.regionRanking(tid: tid), [:], false) }
        }
    }
}

@MainActor
final class SeasonList: ObservableObject {
    @Published private(set) var items: [Season] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var exhausted = false
    private var page = 1
    private var generation = 0
    private let fetch: (Int) async throws -> (items: [Season], more: Bool)

    init(fetch: @escaping (Int) async throws -> (items: [Season], more: Bool)) { self.fetch = fetch }

    var isEmptyAndIdle: Bool { items.isEmpty && !loading && error == nil && !exhausted }

    func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        let gen = generation
        do {
            let r = try await fetch(page)
            guard gen == generation else { return }
            let seen = Set(items.map(\.id))
            items += r.items.filter { !seen.contains($0.id) }
            page += 1
            exhausted = !r.more || r.items.isEmpty
            error = nil
        } catch {
            if gen == generation { self.error = error.localizedDescription }
        }
        if gen == generation { loading = false }
    }

    func reload() async {
        generation += 1
        items = []; page = 1; exhausted = false; error = nil; loading = false
        await loadMore()
    }

    private static var cache: [String: SeasonList] = [:]

    static func shared(type: Int, order: SeasonOrder) -> SeasonList {
        let key = "\(type):\(order.rawValue)"
        if let l = cache[key] { return l }
        let api = BiliAPI.shared
        let l: SeasonList
        if let o = order.indexOrder {
            l = SeasonList { p in try await api.seasonIndex(type: type, order: o, page: p) }
        } else {
            l = SeasonList { _ in (try await api.seasonRanking(type: type), false) }
        }
        cache[key] = l
        return l
    }
}

// MARK: - Home-page tags

/// The website's channel grid: two rows of nine, the last one 「更多」 with the rest in a popover.
struct RegionTags: View {
    @State private var showMore = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 9), spacing: 8) {
            ForEach(Region.main) { r in
                RegionPill(title: r.name) { AppModel.shared.go(.region(r.id)) }
            }
            RegionPill(title: L("更多"), chevron: true, active: showMore) { showMore.toggle() }
                .popover(isPresented: $showMore, arrowEdge: .bottom) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 8), count: 4), spacing: 8) {
                        ForEach(Region.more) { r in
                            RegionPill(title: r.name) {
                                showMore = false
                                AppModel.shared.go(.region(r.id))
                            }
                        }
                    }
                    .padding(14)
                }
        }
    }
}

struct RegionPill: View {
    let title: String
    var chevron = false
    var active = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                if chevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(active ? 180 : 0))
                }
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(hover || active ? Theme.pink : Theme.text)
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 6)
            .background(Theme.text.opacity(hover || active ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.text.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .animation(Motion.pop, value: active)
    }
}

// MARK: - Region page

struct RegionPage: View {
    let id: Int

    var body: some View {
        if let r = Region.find(id) {
            if r.isPGC { SeasonPage(region: r) } else { VideoRegionPage(region: r) }
        } else {
            MainPanel { Text(L("这里还没有内容")).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

/// Header shared by both kinds: kicker, huge name, a link to the same channel on the website.
private struct RegionHeader<Accessory: View>: View {
    let region: Region
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("分区")).font(.system(size: 13, weight: .bold))
            Text(region.name).font(.system(size: 48, weight: .black)).lineLimit(1)
            HStack(spacing: 10) {
                accessory()
                Spacer()
                Button { NSWorkspace.shared.open(region.webURL) } label: {
                    Label(L("在浏览器中打开"), systemImage: "arrow.up.right.square").font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.text2)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

private struct VideoRegionPage: View {
    private var app: AppModel { AppModel.shared }
    let region: Region
    @State private var mode: RegionMode = .recommend

    private var modes: [RegionMode] {
        if case .ugc(_, let ranked) = region.kind, !ranked { return [.recommend] }
        return RegionMode.allCases
    }

    var body: some View {
        let list = app.list(for: "region:\(region.id):\(mode.rawValue)")
        MainPanel(tint: region.tint) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RegionHeader(region: region) {
                        SlidingChips(options: modes.map { ($0, $0.title) }, selection: $mode, style: .white)
                        Button { Task { await list.reload() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold))
                        }
                        .buttonStyle(.pressable)
                        .foregroundStyle(Theme.text2)
                        .keyboardShortcut("r", modifiers: .command)
                        .help(L("刷新 ⌘R"))
                    }
                    ShelfGrid(list: list, ranked: mode == .ranking).padding(.horizontal, -10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .id(mode)
        }
    }
}

// MARK: - PGC (licensed series)

private struct SeasonPage: View {
    let region: Region
    @State private var order: SeasonOrder = .ranking

    private var type: Int { if case .pgc(let t) = region.kind { return t } else { return 1 } }

    var body: some View {
        let list = SeasonList.shared(type: type, order: order)
        MainPanel(tint: region.tint) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RegionHeader(region: region) {
                        SlidingChips(options: SeasonOrder.allCases.map { ($0, $0.title) }, selection: $order, style: .white)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(L("番剧、电影和电视剧等是 B 站的版权内容，只能在官方播放器里观看，BiliMac 无法播放。点击会在浏览器中打开。"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text2)
                    SeasonGrid(list: list, ranked: order == .ranking, region: region)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .id(order)
        }
    }
}

private struct SeasonGrid: View {
    @ObservedObject var list: SeasonList
    let ranked: Bool
    let region: Region

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16, alignment: .top)], alignment: .leading, spacing: 20) {
                ForEach(Array(list.items.enumerated()), id: \.element.id) { i, s in
                    Button { NSWorkspace.shared.open(s.url) } label: { PosterCard(season: s, rank: ranked ? i + 1 : nil) }
                        .buttonStyle(.pressableCard)
                        .help(L("在浏览器中打开"))
                        .contextMenu {
                            Button(L("在浏览器中打开")) { NSWorkspace.shared.open(s.url) }
                            Button(L("复制链接")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.url.absoluteString, forType: .string)
                            }
                        }
                        .onAppear { if i >= list.items.count - 8 { Task { await list.loadMore() } } }
                }
            }
            HStack {
                Spacer()
                if list.loading {
                    ProgressView().controlSize(.small)
                } else if let e = list.error {
                    VStack(spacing: 10) {
                        Text(e).foregroundStyle(Theme.text2)
                        PillButton(title: L("重试")) { Task { await list.loadMore() } }
                    }
                } else if list.exhausted {
                    if list.items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "globe.asia.australia").font(.system(size: 30)).foregroundStyle(Theme.text3)
                            Text(L("没有拿到内容")).font(.system(size: 15, weight: .bold))
                            Text(L("番剧和影视按地区授权，在中国大陆以外常常看不到。"))
                                .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            HStack(spacing: 10) {
                                PillButton(title: L("重试")) { Task { await list.reload() } }
                                PillButton(title: L("在浏览器中打开"), filled: true) { NSWorkspace.shared.open(region.webURL) }
                            }
                        }
                        .padding(.top, 30)
                    } else {
                        Text(L("没有更多了")).font(.system(size: 13)).foregroundStyle(Theme.text3)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .task { if list.isEmptyAndIdle { await list.loadMore() } }
    }
}

private struct PosterCard: View {
    let season: Season
    let rank: Int?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(RemoteImage(url: poster))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let b = season.badge {
                        Text(b).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.pink, in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rank {
                        Text("\(rank)").font(.system(size: 15, weight: .black)).foregroundStyle(.white)
                            .frame(minWidth: 28, minHeight: 28)
                            .background(rank <= 3 ? Theme.pink : .black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let p = season.progress {
                        Text(p).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8, style: .continuous))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.pink, in: Circle())
                        .padding(8).padding(.bottom, 22)
                        .scaleEffect(hover ? 1 : 0.55)
                        .opacity(hover ? 1 : 0)
                }
                .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: hover ? 14 : 0, y: hover ? 8 : 0)
                .offset(y: hover ? -3 : 0)
            Text(season.title)
                .font(.system(size: 13.5, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Theme.text)
            HStack(spacing: 6) {
                if let r = season.rating {
                    Text(Lf("%@ 分", r)).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.1)).fontWeight(.semibold)
                }
                if let m = season.meta { Text(m).lineLimit(1) }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.meta)
        }
        .contentShape(Rectangle())
        .cardHover($hover)
    }

    private var poster: URL? {
        guard let u = season.cover, u.host?.hasSuffix("hdslb.com") == true, !u.path.contains("@") else { return season.cover }
        return URL(string: u.absoluteString + "@330w_440h_1c.webp")
    }
}
