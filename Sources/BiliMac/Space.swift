import AppKit
import SwiftUI

/// UP 主主页, laid out like the website's space: header, then 主页 · 动态 · 投稿 · 合集和系列 tabs and a search
/// box that searches only this uploader's videos and 动态.
@MainActor
final class SpaceModel: ObservableObject {
    enum Tab: Hashable { case home, dynamics, videos, collections }
    enum SearchKind: Hashable { case videos, dynamics }
    let mid: Int
    @Published var info: SpaceInfo?
    @Published var error: String?
    @Published var order = "pubdate"
    @Published private(set) var tab = Tab.home
    @Published var collections: [SpaceCollection] = []
    @Published var collectionsLoaded = false
    @Published var topVideo: VideoCard?
    @Published var tint: Color = Theme.defaultTint
    /// Bumped when a 查看全部 button switches tabs, so the page scrolls back up to the tabs.
    @Published private(set) var jump = 0

    // Search inside this space
    @Published var query = ""
    @Published private(set) var searchTerm: String?
    @Published var searchKind = SearchKind.videos
    @Published private(set) var searchVideos: PagedList?
    @Published private(set) var searchDynamics: DynamicFeed?
    @Published private(set) var searchVideoTotal: Int?
    @Published private(set) var searchID = 0

    lazy var dynamics: DynamicFeed = { [mid] in
        DynamicFeed { cursor in
            let r = try await BiliAPI.shared.spaceDynamics(mid: mid, offset: cursor)
            return (r.items, r.offset, r.more && !(r.offset ?? "").isEmpty)
        }
    }()

    /// Newest-first uploads, shared by 主页 and 投稿.
    var latest: PagedList { AppModel.shared.list(for: "space:\(mid):pubdate") }

    init(mid: Int) {
        self.mid = mid
        switch Env.spaceTab {
        case "dynamics": tab = .dynamics
        case "videos": tab = .videos
        case "collections": tab = .collections
        case let s? where s.hasPrefix("search:"):
            query = String(s.dropFirst(7))
            search()
        default: break
        }
    }

    func load() async {
        guard info == nil else { return }
        async let cs = try? BiliAPI.shared.spaceCollections(mid: mid)
        async let top = BiliAPI.shared.spaceTopVideo(mid: mid)
        do {
            let i = try await BiliAPI.shared.space(mid: mid)
            info = i
            if let t = await TintCache.shared.tint(for: i.face) { tint = t }
        } catch {
            self.error = error.localizedDescription
        }
        collections = await cs ?? []
        collectionsLoaded = true
        topVideo = await top
    }

    func select(_ t: Tab, scrollUp: Bool = false) {
        withAnimation(Motion.slide) {
            if searchTerm != nil { clearSearch() }
            tab = t
        }
        if scrollUp { jump += 1 }
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        let mid = mid
        searchTerm = q
        searchVideoTotal = nil
        searchID += 1
        searchVideos = PagedList { [weak self] s in
            let p = Int(s["p"] ?? "1")!
            let r = try await BiliAPI.shared.spaceSearch(mid: mid, keyword: q, page: p)
            if p == 1 { await MainActor.run { self?.searchVideoTotal = r.total } }
            return (r.items, ["p": "\(p + 1)"], r.more)
        }
        searchDynamics = DynamicFeed { cursor in
            let p = Int(cursor ?? "1") ?? 1
            let r = try await BiliAPI.shared.spaceDynamicSearch(mid: mid, keyword: q, page: p)
            return (r.items, "\(p + 1)", r.more)
        }
    }

    func clearSearch() {
        query = ""
        searchTerm = nil
        searchVideos = nil
        searchDynamics = nil
        searchVideoTotal = nil
    }

    func toggleFollow() {
        guard let i = info else { return }
        guard AppModel.shared.account.loggedIn else { AppModel.shared.showLogin = true; return }
        let on = !i.following
        Task {
            do {
                try await BiliAPI.shared.follow(mid: mid, on)
                info?.following = on
                AppModel.shared.notify(on ? L("已关注") : L("已取消关注"))
            } catch { AppModel.shared.notify(Lf("操作失败：%@", "\(error.localizedDescription)")) }
        }
    }
}

struct SpacePage: View {
    /// Not observed: the grids should redraw only when their own lists change.
    private var app: AppModel { AppModel.shared }
    let mid: Int
    @StateObject private var model: SpaceModel

    init(mid: Int) {
        self.mid = mid
        _model = StateObject(wrappedValue: SpaceModel(mid: mid))
    }

    var body: some View {
        MainPanel(tint: model.tint) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SpaceHeader(model: model)
                        SpaceTabBar(model: model).id("tabs")
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .onChange(of: model.jump) { withAnimation(Motion.page) { proxy.scrollTo("tabs", anchor: .top) } }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        if model.searchTerm != nil {
            SpaceSearchResults(model: model)
        } else {
            switch model.tab {
            case .home:
                SpaceOverview(model: model, latest: model.latest)
            case .dynamics:
                DynamicList(feed: model.dynamics, emptyText: L("这位 UP 主还没有发过动态"))
            case .videos:
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        if let n = model.info?.archives, n > 0 {
                            Text(Lf("共 %@ 个视频", "\(n)")).font(.system(size: 13.5)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        SlidingChips(options: [("pubdate", L("最新发布")), ("click", L("最多播放"))], selection: $model.order, style: .white)
                    }
                    ShelfGrid(list: app.list(for: "space:\(mid):\(model.order)"), emptyText: L("这位 UP 主还没有投稿"))
                        .id(model.order)
                        .padding(.horizontal, -10)
                }
            case .collections:
                if model.collectionsLoaded && model.collections.isEmpty {
                    EmptyNote(text: L("这位 UP 主还没有合集和系列"))
                } else if !model.collectionsLoaded {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
                } else {
                    CollectionGrid(collections: model.collections)
                }
            }
        }
    }
}

/// "999+"-style tab count.
private func tabCount(_ n: Int) -> String { n > 999 ? "999+" : "\(n)" }

// MARK: - Tabs + search box

private struct SpaceTabBar: View {
    @ObservedObject var model: SpaceModel
    @Namespace private var ns
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 30) {
                tab(.home, icon: "house.fill", L("主页"), color: Color(hex: 0x4CB45C))
                tab(.dynamics, icon: "fanblades.fill", L("动态"), color: Theme.pink)
                tab(.videos, icon: "play.tv.fill", L("投稿"), count: model.info.map { tabCount($0.archives) }, color: Theme.blue)
                tab(.collections, icon: "square.stack.3d.up.fill", L("合集和系列"),
                    count: model.collections.isEmpty ? nil : tabCount(model.collections.count), color: Theme.blue)
                Spacer(minLength: 16)
                searchBox.padding(.bottom, 13)
            }
            Rectangle().fill(Theme.line.opacity(0.55)).frame(height: 1)
        }
    }

    private func tab(_ t: SpaceModel.Tab, icon: String, _ title: String, count: String? = nil, color: Color) -> some View {
        let on = model.searchTerm == nil && model.tab == t
        return Button { model.select(t) } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 16, weight: on ? .bold : .medium))
                if let count {
                    Text(count).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(on ? Theme.pink : Theme.text3)
                }
            }
            .foregroundStyle(on ? Theme.pink : Theme.text)
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) {
                if on {
                    Capsule().fill(Theme.pink).frame(height: 3)
                        .matchedGeometryEffect(id: "underline", in: ns)
                }
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private var searchBox: some View {
        HStack(spacing: 6) {
            TextField(L("搜索视频、动态"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onSubmit { model.search() }
            if !model.query.isEmpty || model.searchTerm != nil {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.pressable)
                .help(L("清除搜索"))
            }
            Button { model.search() } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .buttonStyle(.pressable)
            .help(L("搜索"))
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 36)
        .background(Theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(searchFocused ? Theme.pink.opacity(0.7) : Theme.line.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - 主页 (overview)

private struct SpaceOverview: View {
    private var app: AppModel { AppModel.shared }
    @ObservedObject var model: SpaceModel
    @ObservedObject var latest: PagedList
    @State private var columns = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let top = model.topVideo {
                section(L("置顶视频")) { TopVideoCard(card: top) }
            }
            section(L("最新视频"), more: .videos) {
                let items = Array(latest.items.prefix(columns * 2))
                if items.isEmpty {
                    if let e = latest.error {
                        EmptyNote(text: e)
                    } else if latest.exhausted {
                        EmptyNote(text: L("这位 UP 主还没有投稿"))
                    } else {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
                    }
                } else {
                    LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
                        ForEach(items) { card in
                            Button { app.open(card) } label: { ShelfCard(card: card) }
                                .buttonStyle(.pressableCard)
                                .contextMenu { CardMenu(card: card) }
                        }
                    }
                    .padding(.horizontal, -10)
                }
            }
            if !model.collections.isEmpty {
                section(L("合集和系列"), count: model.collections.count, more: .collections) {
                    CollectionGrid(collections: Array(model.collections.prefix(columns)), columns: columns)
                }
            }
        }
        // Whole rows only: as many cards as the adaptive grid on 投稿 fits in a row (min 214pt + 8pt gaps).
        .onGeometryChange(for: Int.self) { max(1, Int(($0.size.width + 20 + 8) / 222)) } action: { columns = $0 }
        .task { if latest.isEmptyAndIdle { await latest.loadMore() } }
    }

    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns) }

    private func section<C: View>(_ title: String, count: Int? = nil, more: SpaceModel.Tab? = nil,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold))
                if let count { Text("\(count)").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text3) }
                Spacer()
                if let more {
                    Button { model.select(more, scrollUp: true) } label: {
                        HStack(spacing: 3) {
                            Text(L("查看全部"))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .buttonStyle(.pressable)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Theme.text2)
                }
            }
            content()
        }
    }
}

/// The video pinned to the top of the space: wide cover beside the title.
private struct TopVideoCard: View {
    let card: VideoCard
    @State private var hover = false

    var body: some View {
        Button { AppModel.shared.open(card) } label: {
            HStack(alignment: .top, spacing: 18) {
                Cover(url: card.cover, width: 720, radius: 8)
                    .overlay(alignment: .bottomTrailing) { DurationBadge(seconds: card.duration) }
                    .frame(width: 360)
                    .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: hover ? 16 : 0, y: hover ? 10 : 0)
                VStack(alignment: .leading, spacing: 10) {
                    Label(L("置顶"), systemImage: "pin.fill")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(Theme.onPink)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.pink, in: RoundedRectangle(cornerRadius: 4))
                    Text(card.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Theme.text)
                    Text(meta).font(.system(size: 13)).foregroundStyle(Theme.meta)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .contextMenu { CardMenu(card: card) }
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
        .padding(.horizontal, -10)
    }

    private var meta: String {
        var parts: [String] = []
        if let v = card.views { parts.append(Lf("%@ 播放", "\(formatCount(v))")) }
        if let d = card.danmaku { parts.append(Lf("%@ 弹幕", "\(formatCount(d))")) }
        if let p = card.pubdate { parts.append(formatRelativeDate(p)) }
        return parts.joined(separator: " · ")
    }
}

private struct EmptyNote: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text3)
            Spacer()
        }
        .padding(.vertical, 20)
    }
}

// MARK: - 合集和系列

private struct CollectionGrid: View {
    private var app: AppModel { AppModel.shared }
    let collections: [SpaceCollection]
    /// Fixed column count (主页 shows exactly one row); nil fits as many as the width allows.
    var columns: Int? = nil

    var body: some View {
        let grid = columns.map { Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: $0) }
            ?? [GridItem(.adaptive(minimum: 214, maximum: 330), spacing: 8, alignment: .top)]
        LazyVGrid(columns: grid, alignment: .leading, spacing: 8) {
            ForEach(collections) { c in
                Button { app.open(c) } label: { CollectionCard(collection: c) }
                    .buttonStyle(.pressableCard)
            }
        }
        .padding(.horizontal, -10)
    }
}

/// 合集 / 系列 tile: cover with a stacked-cards edge, name, count.
private struct CollectionCard: View {
    let collection: SpaceCollection
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                // Two cards peeking out above the cover say "a set of videos".
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.text.opacity(0.08))
                    .padding(.horizontal, 16).offset(y: -8)
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.text.opacity(0.14))
                    .padding(.horizontal, 8).offset(y: -4)
                Cover(url: collection.cover, width: 560)
                    .overlay(alignment: .bottomTrailing) {
                        Label("\(collection.total)", systemImage: "list.bullet")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
            }
            .padding(.top, 8)
            .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: hover ? 16 : 0, y: hover ? 10 : 0)
            .offset(y: hover ? -3 : 0)
            Text(collection.name)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Text(Lf("%@ · %@ 个视频", collection.kind == .season ? L("合集") : L("系列"), "\(collection.total)"))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.meta)
        }
        .padding(10)
        .background(hover ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.pop) { hover = h } }
    }
}

// MARK: - Search results

private struct SpaceSearchResults: View {
    @ObservedObject var model: SpaceModel

    var body: some View {
        if let term = model.searchTerm, let videos = model.searchVideos, let dyn = model.searchDynamics {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Lf("“%@”的搜索结果", term)).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Spacer()
                    Button { model.clearSearch() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            Text(L("清除搜索"))
                        }
                    }
                    .buttonStyle(.pressable)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(Theme.text2)
                }
                SlidingChips(options: [(SpaceModel.SearchKind.videos, model.searchVideoTotal.map { Lf("视频 %@", "\($0)") } ?? L("视频")),
                                       (.dynamics, L("动态"))],
                             selection: $model.searchKind, style: .white)
                switch model.searchKind {
                case .videos:
                    ShelfGrid(list: videos, emptyText: L("没有找到相关视频"))
                        .padding(.horizontal, -10)
                case .dynamics:
                    DynamicList(feed: dyn, emptyText: L("没有找到相关动态"))
                }
            }
            .id(model.searchID)
        }
    }
}

// MARK: - 动态

/// One 动态 from an uploader's space feed (or its 动态 search), reduced to what the app can show.
struct SpaceDynamic: Identifiable {
    struct Run { let text: String; let link: Bool }
    struct Pic { let url: URL; let size: CGSize? }
    let id: String
    var author = ""
    var authorMid: Int?
    var authorFace: URL?
    var date: Date?
    /// How the feed words the time ("3天前"); falls back to the date.
    var time = ""
    var pinned = false
    var title: String?
    var text: [Run] = []
    var pics: [Pic] = []
    var video: VideoCard?
    /// A kind the app can't show (live, 番剧, music…): a note and a web link instead.
    var unsupported = false
    /// The reposted 动态 (zero or one).
    var origin: [SpaceDynamic] = []
    var url: URL { URL(string: "https://t.bilibili.com/\(id)")! }

    /// x/polymer/web-dynamic item.
    static func parse(_ it: JSON) -> SpaceDynamic? {
        guard let m = it.obj("modules") else { return nil }
        var d = SpaceDynamic(id: it.str("id_str") ?? UUID().uuidString)
        let au = m.obj("module_author") ?? [:]
        d.author = au.str("name") ?? ""
        d.authorMid = au.int("mid")
        d.authorFace = imageURL(au.str("face"))
        d.date = au.int("pub_ts").flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        d.time = au.str("pub_time").flatMap { $0.isEmpty ? nil : $0 } ?? formatRelativeDate(d.date)
        d.pinned = m.obj("module_tag")?.str("text") == "置顶"
        let dy = m.obj("module_dynamic") ?? [:]
        d.text = runs(dy.obj("desc")?.arr("rich_text_nodes") ?? [], fallback: dy.obj("desc")?.str("text"))
        let major = dy.obj("major") ?? [:]
        switch major.str("type") {
        case "MAJOR_TYPE_ARCHIVE", "MAJOR_TYPE_UGC_SEASON":
            let a = major.obj("archive") ?? major.obj("ugc_season") ?? [:]
            if let bvid = a.str("bvid") ?? bv(in: a.str("jump_url")) {
                d.video = VideoCard(bvid: bvid, aid: a.int("aid"), title: a.str("title") ?? "", cover: imageURL(a.str("cover")),
                                    owner: d.author, ownerMid: d.authorMid, ownerFace: d.authorFace,
                                    views: parseCountText(a.obj("stat")?.str("play")),
                                    danmaku: parseCountText(a.obj("stat")?.str("danmaku")),
                                    duration: parseDurationText(a.str("duration_text")), pubdate: d.date)
            } else {
                d.unsupported = true
            }
        case "MAJOR_TYPE_OPUS":
            let o = major.obj("opus") ?? [:]
            d.title = o.str("title").flatMap { $0.isEmpty ? nil : $0 }
            if d.text.isEmpty { d.text = runs(o.obj("summary")?.arr("rich_text_nodes") ?? [], fallback: o.obj("summary")?.str("text")) }
            d.pics = o.arr("pics").compactMap { p in
                imageURL(p.str("url")).map { Pic(url: $0, size: size(p.double("width"), p.double("height"))) }
            }
        case "MAJOR_TYPE_DRAW":
            d.pics = (major.obj("draw")?.arr("items") ?? []).compactMap { p in
                imageURL(p.str("src")).map { Pic(url: $0, size: size(p.double("width"), p.double("height"))) }
            }
        case "MAJOR_TYPE_ARTICLE":
            let a = major.obj("article") ?? [:]
            d.title = a.str("title")
            if d.text.isEmpty, let t = a.str("desc") { d.text = [Run(text: t, link: false)] }
            d.pics = ((a["covers"] as? [String]) ?? []).prefix(1).compactMap { imageURL($0).map { Pic(url: $0, size: nil) } }
        case "MAJOR_TYPE_NONE":
            // A deleted original: the feed says so in its tips.
            d.text = [Run(text: major.obj("none")?.str("tips") ?? L("原动态已失效"), link: false)]
        case nil:
            break
        case let t?:
            let key = t.replacingOccurrences(of: "MAJOR_TYPE_", with: "").lowercased()
            d.title = major.obj(key)?.str("title")
            d.unsupported = true
        }
        if let o = it.obj("orig"), let od = parse(o) { d.origin = [od] }
        return d
    }

    /// x/space/dynamic/search card: `desc` plus `card`, a JSON string in the legacy shape.
    static func parseLegacy(_ c: JSON) -> SpaceDynamic? {
        guard let desc = c.obj("desc"), let card = json(c.str("card")) else { return nil }
        let info = desc.obj("user_profile")?.obj("info") ?? [:]
        return legacy(type: desc.int("type"), card, id: desc.str("dynamic_id_str") ?? desc.str("dynamic_id") ?? UUID().uuidString,
                      author: info.str("uname") ?? "", mid: info.int("uid"), face: imageURL(info.str("face")),
                      date: desc.int("timestamp"), bvid: desc.str("bvid"))
    }

    private static func legacy(type: Int?, _ card: JSON, id: String, author: String, mid: Int?, face: URL?,
                               date: Int?, bvid: String?) -> SpaceDynamic {
        var d = SpaceDynamic(id: id)
        d.author = author
        d.authorMid = mid
        d.authorFace = face
        d.date = date.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        d.time = formatRelativeDate(d.date)
        let item = card.obj("item") ?? [:]
        func plain(_ s: String?) -> [Run] {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return [] }
            return [Run(text: s, link: false)]
        }
        switch type {
        case 1: // repost
            d.text = plain(item.str("content"))
            if let o = json(card.str("origin")) {
                let u = card.obj("origin_user")?.obj("info") ?? [:]
                d.origin = [legacy(type: item.int("orig_type"), o, id: item.str("orig_dy_id") ?? UUID().uuidString,
                                   author: u.str("uname") ?? "", mid: u.int("uid"), face: imageURL(u.str("face")),
                                   date: nil, bvid: nil)]
            }
        case 2: // pictures
            d.text = plain(item.str("description"))
            d.pics = item.arr("pictures").compactMap { p in
                imageURL(p.str("img_src")).map { Pic(url: $0, size: size(p.double("img_width"), p.double("img_height"))) }
            }
        case 4: // text
            d.text = plain(item.str("content"))
        case 8: // video
            d.text = plain(card.str("dynamic"))
            let owner = card.obj("owner") ?? [:]
            if let b = bvid.flatMap({ $0.isEmpty ? nil : $0 }) ?? bv(in: card.str("short_link_v2")) ?? bv(in: card.str("jump_url"))
                ?? card.int("aid").map(bv(aid:)) {
                d.video = VideoCard(bvid: b, aid: card.int("aid"), title: card.str("title") ?? "", cover: imageURL(card.str("pic")),
                                    owner: owner.str("name") ?? author, ownerMid: owner.int("mid") ?? mid,
                                    ownerFace: imageURL(owner.str("face")) ?? face,
                                    views: card.obj("stat")?.int("view"), danmaku: card.obj("stat")?.int("danmaku"),
                                    duration: card.int("duration"),
                                    pubdate: card.int("pubdate").map { Date(timeIntervalSince1970: TimeInterval($0)) })
            } else {
                d.unsupported = true
            }
        case 64: // 专栏
            d.title = card.str("title")
            d.text = plain(card.str("summary"))
            d.pics = ((card["image_urls"] as? [String]) ?? []).prefix(1).compactMap { imageURL($0).map { Pic(url: $0, size: nil) } }
        default:
            d.title = card.str("title")
            d.unsupported = true
        }
        return d
    }

    private static func runs(_ nodes: [JSON], fallback: String?) -> [Run] {
        var r: [Run] = nodes.compactMap { n in
            guard let t = n.str("text"), !t.isEmpty else { return nil }
            let type = n.str("type") ?? ""
            return Run(text: t, link: type != "RICH_TEXT_NODE_TYPE_TEXT" && type != "RICH_TEXT_NODE_TYPE_EMOJI")
        }
        if r.isEmpty, let f = fallback, !f.isEmpty { r = [Run(text: f, link: false)] }
        // Posts often end in blank lines.
        while let last = r.last {
            let t = last.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if t.isEmpty { r.removeLast(); continue }
            r[r.count - 1] = Run(text: t, link: last.link)
            break
        }
        return r
    }

    private static func json(_ s: String?) -> JSON? {
        guard let data = s?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? JSON
    }

    private static func bv(in s: String?) -> String? {
        guard let s, let r = s.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) else { return nil }
        return String(s[r])
    }

    /// av → BV (reposted videos in the legacy shape carry only the aid).
    private static func bv(aid: Int) -> String {
        let alphabet = Array("FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf")
        var out = [Character](repeating: "1", count: 9)
        var t = ((1 << 51) | aid) ^ 23_442_827_791_579
        for i in [8, 7, 0, 5, 1, 3, 2, 4, 6] {
            out[i] = alphabet[t % 58]
            t /= 58
        }
        return "BV1" + String(out)
    }

    private static func size(_ w: Double?, _ h: Double?) -> CGSize? {
        guard let w, let h, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// A paged list of 动态 with an opaque cursor.
@MainActor
final class DynamicFeed: ObservableObject {
    @Published private(set) var items: [SpaceDynamic] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var exhausted = false
    private var cursor: String?
    private let fetch: (String?) async throws -> (items: [SpaceDynamic], next: String?, more: Bool)

    init(fetch: @escaping (String?) async throws -> (items: [SpaceDynamic], next: String?, more: Bool)) {
        self.fetch = fetch
    }

    var isEmptyAndIdle: Bool { items.isEmpty && !loading && error == nil && !exhausted }

    func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        do {
            let r = try await fetch(cursor)
            let seen = Set(items.map(\.id))
            items += r.items.filter { !seen.contains($0.id) }
            cursor = r.next
            exhausted = !r.more
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

private struct DynamicList: View {
    @ObservedObject var feed: DynamicFeed
    let emptyText: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(feed.items.enumerated()), id: \.element.id) { i, d in
                DynamicCard(item: d)
                    .onAppear { if i >= feed.items.count - 4 { Task { await feed.loadMore() } } }
            }
            HStack {
                Spacer()
                if feed.loading {
                    ProgressView().controlSize(.small)
                } else if let e = feed.error {
                    VStack(spacing: 10) {
                        Text(e).foregroundStyle(Theme.text2)
                        PillButton(title: L("重试")) { Task { await feed.loadMore() } }
                    }
                } else if feed.exhausted {
                    Text(feed.items.isEmpty ? emptyText : L("没有更多了")).font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task { if feed.isEmptyAndIdle { await feed.loadMore() } }
    }
}

private struct DynamicCard: View {
    let item: SpaceDynamic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Avatar(url: item.authorFace, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.author).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(item.time).font(.system(size: 12)).foregroundStyle(Theme.meta)
                }
                if item.pinned {
                    Text(L("置顶"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.pink)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.pink, lineWidth: 1))
                }
                Spacer()
                Button { NSWorkspace.shared.open(item.url) } label: {
                    Image(systemName: "safari").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.pressable)
                .help(L("在浏览器中打开"))
            }
            DynamicBody(item: item)
            if let o = item.origin.first {
                VStack(alignment: .leading, spacing: 10) {
                    if !o.author.isEmpty {
                        AuthorName(name: "@" + o.author, mid: o.authorMid)
                    }
                    DynamicBody(item: o)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// "@name" in a repost; opens that uploader's space.
private struct AuthorName: View {
    let name: String
    let mid: Int?
    @State private var hover = false

    var body: some View {
        Text(name)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.blue)
            .underline(hover && mid != nil)
            .onHover { hover = $0 }
            .onTapGesture { if let mid, mid > 0 { AppModel.shared.go(.space(mid)) } }
    }
}

private struct DynamicBody: View {
    let item: SpaceDynamic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = item.title, !t.isEmpty {
                Text(t).font(.system(size: 15.5, weight: .bold))
            }
            if !item.text.isEmpty {
                Text(attributed)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let v = item.video { DynamicVideo(card: v) }
            if !item.pics.isEmpty { DynamicPics(pics: item.pics) }
            if item.unsupported {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.dashed")
                    Text(L("暂不支持显示这类动态"))
                    Button(L("在浏览器中查看")) { NSWorkspace.shared.open(item.url) }
                        .buttonStyle(.pressable)
                        .foregroundStyle(Theme.blue)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text3)
            }
        }
    }

    private var attributed: AttributedString {
        item.text.reduce(into: AttributedString()) { s, r in
            var a = AttributedString(r.text)
            if r.link { a.foregroundColor = Theme.blue }
            s += a
        }
    }
}

/// A video inside a 动态: cover beside title and counts; opens in the app.
private struct DynamicVideo: View {
    let card: VideoCard
    @State private var hover = false

    var body: some View {
        Button { AppModel.shared.open(card) } label: {
            HStack(alignment: .top, spacing: 14) {
                Cover(url: card.cover, width: 480)
                    .overlay(alignment: .bottomTrailing) { DurationBadge(seconds: card.duration) }
                    .frame(width: 236)
                VStack(alignment: .leading, spacing: 8) {
                    Text(card.title)
                        .font(.system(size: 14.5, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Theme.text)
                    HStack(spacing: 12) {
                        if let v = card.views { Label(formatCount(v), systemImage: "play.rectangle") }
                        if let d = card.danmaku { Label(formatCount(d), systemImage: "text.bubble") }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.meta)
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Theme.text.opacity(hover ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableCard)
        .contextMenu { CardMenu(card: card) }
        .onHover { hover = $0 }
    }
}

/// One picture large; several as a grid of squares. Click opens the full image.
private struct DynamicPics: View {
    let pics: [SpaceDynamic.Pic]

    var body: some View {
        if pics.count == 1, let p = pics.first {
            let ratio = p.size.map { min(max($0.width / $0.height, 0.6), 2) } ?? 4 / 3
            tile(p, width: 720)
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: ratio >= 1 ? 420 : 300, alignment: .leading)
        } else {
            let cols = pics.count == 2 || pics.count == 4 ? 2 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(132), spacing: 6), count: cols), alignment: .leading, spacing: 6) {
                ForEach(Array(pics.prefix(9).enumerated()), id: \.offset) { _, p in
                    tile(p, width: 264).frame(width: 132, height: 132)
                }
            }
        }
    }

    private func tile(_ p: SpaceDynamic.Pic, width: Int) -> some View {
        Color.clear
            .overlay(RemoteImage(url: thumb(p.url, width)))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(p.url) }
            .hoverCursor()
    }

    private func thumb(_ u: URL, _ w: Int) -> URL {
        guard u.host?.hasSuffix("hdslb.com") == true, !u.path.contains("@") else { return u }
        return URL(string: u.absoluteString + "@\(w)w.webp") ?? u
    }
}

private struct SpaceHeader: View {
    @ObservedObject var model: SpaceModel

    var body: some View {
        let i = model.info
        VStack(alignment: .leading, spacing: 16) {
            // Banner: the uploader's own space header image.
            Color.clear
                .frame(height: 168)
                .overlay(RemoteImage(url: i?.banner))
                .background(model.tint)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(alignment: .top, spacing: 20) {
                // Only the avatar rises into the banner; name and buttons sit below it.
                Avatar(url: i?.face, size: 108)
                    .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 4))
                    .shadow(color: Theme.shadow, radius: 14, y: 6)
                    .padding(.top, -66)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let o = i?.official {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.blue)
                            Text(o).lineLimit(1)
                        } else {
                            Text(L("UP 主"))
                        }
                        if let lv = i?.level, lv > 0 {
                            Text("LV\(lv)").font(.system(size: 10, weight: .heavy))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(hex: 0xF0A24A), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.black)
                        }
                    }
                    .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 12) {
                        Text(i?.name ?? " ")
                            .font(.system(size: 40, weight: .black))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        LiveBadge(uid: model.mid, large: true)
                    }
                }
                Spacer(minLength: 12)
                if let i {
                    PillButton(title: i.following ? L("已关注") : L("+ 关注"), filled: !i.following, tint: Theme.primary) {
                        model.toggleFollow()
                    }
                    .padding(.top, 8)
                }
                SpaceMoreButton(mid: model.mid)
                .padding(.top, 11)
            }
            .padding(.leading, 20)

            if let i {
                HStack(spacing: 28) {
                    stat(i.fans, L("粉丝"))
                    stat(i.followingCount, L("关注"))
                    stat(i.likes, L("获赞"))
                    stat(i.archives, L("投稿"))
                }
                .padding(.leading, 4)
                if !i.sign.isEmpty {
                    Text(i.sign)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 4)
                }
            } else if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.text2)
            }
        }
        .padding(.top, 8)
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatCount(n)).font(.system(size: 18, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
        }
    }
}

/// "…": copy the space link, or open it on the web.
private struct SpaceMoreButton: View {
    let mid: Int
    @State private var open = false
    private var url: URL { URL(string: "https://space.bilibili.com/\(mid)")! }

    var body: some View {
        CircleIconButton(icon: "ellipsis", label: L("更多")) { withAnimation(Motion.pop) { open.toggle() } }
            .help(L("更多"))
            .floatingPanel(id: "space-more", isPresented: $open, placement: .below(.trailing)) {
                MenuSurface(width: 220) {
                    MenuRow(title: L("复制主页链接"), icon: "link") {
                        open = false
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        AppModel.shared.notify(L("已复制链接"))
                    }
                    MenuRow(title: L("在浏览器中打开"), icon: "safari") {
                        open = false
                        NSWorkspace.shared.open(url)
                    }
                }
            }
    }
}
