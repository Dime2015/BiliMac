import CryptoKit
import Foundation

// MARK: - Playback models

struct DashTrack: Hashable {
    let id: Int
    let codecs: String
    let bandwidth: Int
    let width: Int
    let height: Int
    let frameRate: String
    let urls: [URL]          // primary first, then backups
    let initRange: ClosedRange<Int>
    let indexRange: ClosedRange<Int>

    var codecName: String {
        if codecs.hasPrefix("hvc1") || codecs.hasPrefix("hev1") { return "HEVC" }
        if codecs.hasPrefix("avc1") { return "AVC" }
        if codecs.hasPrefix("av01") { return "AV1" }
        if codecs.hasPrefix("mp4a") { return "AAC" }
        if codecs.hasPrefix("ec-3") { return "E-AC-3" }
        if codecs.hasPrefix("fLaC") || codecs.hasPrefix("flac") { return "FLAC" }
        return codecs
    }
}

struct QualityOption: Hashable, Identifiable {
    let qn: Int
    let label: String
    let available: Bool    // a DASH track exists for it (false = needs VIP / login)
    var id: Int { qn }
}

struct PlayInfo {
    let videos: [DashTrack]
    let audios: [DashTrack]
    let options: [QualityOption]
    let lastPlayTime: Double?
    let lastPlayCid: Int?
    let duration: Double

    /// First quality in `order` this video actually has; otherwise the best non-HDR one it has.
    func pickVideo(order: [Int], codec: CodecPref) -> DashTrack {
        let ids = Set(videos.map(\.id))
        if let qn = order.first(where: ids.contains) { return pickVideo(qn: qn, codec: codec) }
        return pickVideo(qn: 120, codec: codec)
    }

    /// The next entry after `current` in `order` that this video has (for stepping down on stalls).
    func nextLower(after current: Int, order: [Int]) -> Int? {
        let ids = Set(videos.map(\.id))
        guard let i = order.firstIndex(of: current) else { return order.first { ids.contains($0) && $0 < current } }
        return order.dropFirst(i + 1).first(where: ids.contains)
    }

    /// Best quality ≤ `qn` (HDR/Dolby Vision only when asked for explicitly), codec by preference.
    func pickVideo(qn: Int, codec: CodecPref) -> DashTrack {
        let ids = Set(videos.map(\.id))
        let normal = ids.filter { $0 <= 120 || $0 == qn }
        let target = normal.filter { $0 <= qn }.max() ?? normal.min() ?? ids.min()!
        let order = codec.order
        return videos.filter { $0.id == target }.min { a, b in
            (order.firstIndex { a.codecs.hasPrefix($0) } ?? 99) < (order.firstIndex { b.codecs.hasPrefix($0) } ?? 99)
        }!
    }

    var bestAudio: DashTrack? { audios.max { $0.bandwidth < $1.bandwidth } }
}

let qualityNames: [Int: String] = [
    127: L("8K 超高清"), 126: L("杜比视界"), 125: L("HDR 真彩"), 120: L("4K 超清"), 116: L("1080P 60帧"), 112: L("1080P 高码率"),
    80: L("1080P 高清"), 74: L("720P 60帧"), 64: L("720P 准高清"), 32: L("480P 标清"), 16: L("360P 流畅"), 6: L("240P 极速"),
]

func shortQuality(_ qn: Int) -> String {
    switch qn {
    case 127: return "8K"
    case 126: return L("杜比视界")
    case 125: return "HDR"
    case 120: return "4K"
    case 116: return "1080P60"
    case 112: return "1080P+"
    case 80: return "1080P"
    case 74: return "720P60"
    case 64: return "720P"
    case 32: return "480P"
    case 16: return "360P"
    default: return "\(qn)"
    }
}

// MARK: - Cookie jar (file-backed, mode 0600)

final class CookieJar {
    static let shared = CookieJar()
    private(set) var cookies: [String: String] = [:]
    private let lock = NSLock()
    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BiliMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("cookies.json")
        // Migrate the login from the earlier prototype.
        let old = base.appendingPathComponent("BiliFeedPrototype/cookies.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: url)
        }
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode([String: String].self, from: d) {
            cookies = c
        }
    }

    var header: String { header(signedIn: true) }

    func header(signedIn: Bool) -> String {
        lock.lock(); defer { lock.unlock() }
        let login: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
        return cookies.filter { signedIn || !login.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    subscript(name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cookies[name]
    }

    func set(_ new: [String: String]) {
        lock.lock()
        cookies.merge(new) { _, b in b }
        let snapshot = cookies
        lock.unlock()
        save(snapshot)
    }

    func clearLogin() {
        lock.lock()
        for k in ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"] { cookies[k] = nil }
        let snapshot = cookies
        lock.unlock()
        save(snapshot)
    }

    private func save(_ c: [String: String]) {
        guard let d = try? JSONEncoder().encode(c) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - API client

actor BiliAPI {
    static let shared = BiliAPI()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private var mixinKey: String?
    private var mixinKeyDate = Date.distantPast

    private static let mixinTable = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue(biliReferer, forHTTPHeaderField: "Referer")
        r.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        let cookie = CookieJar.shared.header(signedIn: !Env.demo || url.path.contains("playurl"))
        if !cookie.isEmpty { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return r
    }

    private func getJSON(_ url: URL) async throws -> (json: JSON, response: HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request(url))
        guard let http = resp as? HTTPURLResponse else { throw APIError(description: L("无响应")) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw APIError(description: Lf("接口返回异常（HTTP %@）", "\(http.statusCode)"))
        }
        return (obj, http)
    }

    private func check(_ obj: JSON, _ path: String) throws -> JSON {
        let code = obj.int("code") ?? -1
        guard code == 0 else {
            let msg = obj.str("message") ?? ""
            throw APIError(description: code == -101 ? L("需要登录") : Lf("%@（%@）", "\(msg.isEmpty ? L("请求失败") : msg)", "\(code)"))
        }
        return obj.obj("data") ?? obj.obj("result") ?? [:]
    }

    func call(_ url: URL) async throws -> JSON {
        let (obj, _) = try await getJSON(url)
        return try check(obj, url.path)
    }

    func get(_ base: String, _ params: [String: String] = [:]) async throws -> JSON {
        var c = URLComponents(string: base)!
        if !params.isEmpty { c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await call(c.url!)
    }

    func signedGet(_ base: String, _ params: [String: String]) async throws -> JSON {
        try await call(signedURL(base, params))
    }

    /// Form POST with the CSRF token (`bili_jct`) that every write endpoint requires.
    @discardableResult
    func post(_ urlString: String, _ form: [String: String]) async throws -> JSON {
        guard let csrf = CookieJar.shared["bili_jct"] else { throw APIError(description: L("需要登录")) }
        var r = request(URL(string: urlString)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var f = form
        f["csrf"] = csrf
        r.httpBody = Data(Self.formEncode(f).utf8)
        let (data, _) = try await session.data(for: r)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw APIError(description: L("接口返回异常")) }
        return try check(obj, urlString)
    }

    private static let allowed: CharacterSet = {
        var c = CharacterSet.alphanumerics
        c.insert(charactersIn: "-_.~")
        return c
    }()

    private static func formEncode(_ p: [String: String]) -> String {
        p.keys.sorted().map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(p[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&")
    }

    // MARK: buvid / WBI / account

    /// Anonymous device cookies; search and some feeds return -412 without them.
    func ensureBuvid() async {
        guard CookieJar.shared["buvid3"] == nil else { return }
        do {
            let d = try await call(URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!)
            var c: [String: String] = [:]
            if let b3 = d.str("b_3") { c["buvid3"] = b3 }
            if let b4 = d.str("b_4") { c["buvid4"] = b4 }
            CookieJar.shared.set(c)
        } catch { log("buvid: \(error)") }
    }

    func nav() async throws -> Account {
        // nav returns -101 when anonymous but still includes wbi_img.
        let (obj, _) = try await getJSON(URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        guard let d = obj.obj("data"), let img = d.obj("wbi_img"),
              let imgURL = img.str("img_url"), let subURL = img.str("sub_url") else {
            throw APIError(description: L("nav: 缺少 wbi_img"))
        }
        func stem(_ s: String) -> String {
            let last = s.split(separator: "/").last.map(String.init) ?? s
            return last.split(separator: ".").first.map(String.init) ?? last
        }
        let raw = Array(stem(imgURL) + stem(subURL))
        mixinKey = String(Self.mixinTable.compactMap { $0 < raw.count ? raw[$0] : nil }.prefix(32))
        mixinKeyDate = Date()
        let vip = d.obj("vip_label")?.str("text")
        return Account(loggedIn: d.bool("isLogin") ?? false, mid: d.int("mid"), name: d.str("uname"),
                       face: imageURL(d.str("face")), level: d.obj("level_info")?.int("current_level") ?? 0,
                       isVip: (d.int("vipStatus") ?? 0) == 1, vipLabel: (vip?.isEmpty ?? true) ? nil : vip,
                       coins: d.double("money") ?? 0)
    }

    private func wbiKey() async throws -> String {
        if let k = mixinKey, Date().timeIntervalSince(mixinKeyDate) < 3600 { return k }
        _ = try await nav()
        return mixinKey!
    }

    func signedURL(_ base: String, _ params: [String: String]) async throws -> URL {
        let key = try await wbiKey()
        var p = params
        p["wts"] = String(Int(Date().timeIntervalSince1970))
        let banned = Set("!'()*")
        for (k, v) in p { p[k] = String(v.filter { !banned.contains($0) }) }
        let query = Self.formEncode(p)
        let digest = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "\(base)?\(query)&w_rid=\(digest)")!
    }

    // MARK: Feeds

    /// The Mac app's 「精选」 feed.
    func featured(page: Int) async throws -> [VideoCard] {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd", [
            "fresh_idx": "\(page)", "fresh_idx_1h": "\(page)", "ps": "10", "plat": "1",
            "feed_version": "CLIENT_SELECTED", "fresh_type": "0", "web_location": "bilibili-electron",
        ])
        return d.arr("item").filter { $0.str("goto") == "av" }.compactMap(VideoCard.archive)
    }

    /// Home 「推荐」 grid.
    func homeRecommend(page: Int) async throws -> [VideoCard] {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/index/top/feed/rcmd", [
            "fresh_type": "4", "ps": "20", "fresh_idx": "\(page)", "fresh_idx_1h": "\(page)", "brush": "\(page)",
            "feed_version": "V8", "homepage_ver": "1", "y_num": "4", "last_y_num": "5", "web_location": "1430650",
        ])
        return d.arr("item").filter { $0.str("goto") == "av" }.compactMap(VideoCard.archive)
    }

    func popular(page: Int) async throws -> (items: [VideoCard], more: Bool) {
        let d = try await get("https://api.bilibili.com/x/web-interface/popular", ["ps": "20", "pn": "\(page)"])
        return (d.arr("list").compactMap(VideoCard.archive), !(d.bool("no_more") ?? false))
    }

    func ranking() async throws -> [VideoCard] {
        let d = try await get("https://api.bilibili.com/x/web-interface/ranking/v2", ["rid": "0", "type": "all"])
        return d.arr("list").compactMap(VideoCard.archive)
    }

    func dynamics(offset: String?) async throws -> (items: [VideoCard], offset: String?, more: Bool) {
        var p = ["type": "video", "features": "itemOpusStyle", "timezone_offset": "-480"]
        if let offset, !offset.isEmpty { p["offset"] = offset }
        let d = try await get("https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all", p)
        let items: [VideoCard] = d.arr("items").compactMap { it in
            let m = it.obj("modules") ?? [:]
            guard let a = m.obj("module_dynamic")?.obj("major")?.obj("archive"), let bvid = a.str("bvid") else { return nil }
            let au = m.obj("module_author") ?? [:]
            return VideoCard(bvid: bvid, aid: a.int("aid"), title: a.str("title") ?? "", cover: imageURL(a.str("cover")),
                             owner: au.str("name") ?? "", ownerMid: au.int("mid"), ownerFace: imageURL(au.str("face")),
                             views: parseCountText(a.obj("stat")?.str("play")),
                             danmaku: parseCountText(a.obj("stat")?.str("danmaku")),
                             duration: parseDurationText(a.str("duration_text")),
                             pubdate: au.int("pub_ts").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        return (items, d.str("offset"), d.bool("has_more") ?? false)
    }

    func search(_ keyword: String, page: Int) async throws -> (items: [VideoCard], pages: Int) {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/type", [
            "search_type": "video", "keyword": keyword, "page": "\(page)",
        ])
        return (d.arr("result").compactMap(VideoCard.archive), d.int("numPages") ?? 1)
    }

    struct HotWord: Hashable { let keyword: String; let icon: URL? }

    /// bilibili 热搜.
    func hotSearch() async throws -> [HotWord] {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/square", ["limit": "10", "platform": "web"])
        return (d.obj("trending")?.arr("list") ?? []).compactMap { w in
            guard let k = w.str("keyword"), !k.isEmpty else { return nil }
            return HotWord(keyword: k, icon: imageURL(w.str("icon")))
        }
    }

    /// Search-box completions for a partial query.
    func searchSuggest(_ term: String) async throws -> [String] {
        var c = URLComponents(string: "https://s.search.bilibili.com/main/suggest")!
        c.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "main_ver", value: "v1"),
                        URLQueryItem(name: "func", value: "suggest"), URLQueryItem(name: "suggest_type", value: "accurate"),
                        URLQueryItem(name: "sub_type", value: "tag"), URLQueryItem(name: "tag_num", value: "10")]
        let (obj, _) = try await getJSON(c.url!)
        return (obj.obj("result")?.arr("tag") ?? []).compactMap { $0.str("value") }
    }

    /// The rotating placeholder keyword the website shows in its search box.
    func defaultSearchWord() async -> String? {
        try? await signedGet("https://api.bilibili.com/x/web-interface/wbi/search/default", [:]).str("show_name")
    }

    func history(max: Int?, viewAt: Int?) async throws -> (items: [VideoCard], max: Int?, viewAt: Int?) {
        var p = ["ps": "24", "type": "archive"]
        if let max, let viewAt { p["max"] = "\(max)"; p["view_at"] = "\(viewAt)"; p["business"] = "archive" }
        let d = try await get("https://api.bilibili.com/x/web-interface/history/cursor", p)
        let items: [VideoCard] = d.arr("list").compactMap { it in
            guard let h = it.obj("history"), h.str("business") == "archive", let bvid = h.str("bvid"), !bvid.isEmpty else { return nil }
            return VideoCard(bvid: bvid, cid: h.int("cid"), aid: h.int("oid"), title: it.str("title") ?? "",
                             cover: imageURL(it.str("cover")), owner: it.str("author_name") ?? "",
                             ownerMid: it.int("author_mid"), ownerFace: imageURL(it.str("author_face")),
                             duration: it.int("duration"), progress: it.int("progress"),
                             viewedAt: it.int("view_at").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        let c = d.obj("cursor")
        return (items, c?.int("max"), c?.int("view_at"))
    }

    func watchLater() async throws -> [VideoCard] {
        let d = try await get("https://api.bilibili.com/x/v2/history/toview")
        return d.arr("list").compactMap(VideoCard.archive)
    }

    func favFolders(mid: Int, rid: Int? = nil) async throws -> [FavFolder] {
        var p = ["up_mid": "\(mid)", "type": "2"]
        if let rid { p["rid"] = "\(rid)" }
        let d = try await get("https://api.bilibili.com/x/v3/fav/folder/created/list-all", p)
        return d.arr("list").compactMap { f in
            guard let id = f.int("id") else { return nil }
            return FavFolder(id: id, title: f.str("title") ?? "", count: f.int("media_count") ?? 0,
                             contains: (f.int("fav_state") ?? 0) == 1)
        }
    }

    func favList(mediaId: Int, page: Int) async throws -> (items: [VideoCard], more: Bool) {
        let d = try await get("https://api.bilibili.com/x/v3/fav/resource/list", [
            "media_id": "\(mediaId)", "pn": "\(page)", "ps": "20", "platform": "web",
        ])
        let items: [VideoCard] = d.arr("medias").compactMap { m in
            guard m.int("type") == 2, let bvid = m.str("bvid") ?? m.str("bv_id"), m.str("title") != "已失效视频" else { return nil }
            let up = m.obj("upper") ?? [:]
            return VideoCard(bvid: bvid, cid: m.obj("ugc")?.int("first_cid"), aid: m.int("id"),
                             title: m.str("title") ?? "", cover: imageURL(m.str("cover")),
                             owner: up.str("name") ?? "", ownerMid: up.int("mid"), ownerFace: imageURL(up.str("face")),
                             views: m.obj("cnt_info")?.int("play"), danmaku: m.obj("cnt_info")?.int("danmaku"),
                             duration: m.int("duration"),
                             pubdate: m.int("pubtime").map { Date(timeIntervalSince1970: TimeInterval($0)) })
        }
        return (items, d.bool("has_more") ?? false)
    }

    // MARK: Video page

    func detail(bvid: String) async throws -> VideoDetail {
        let d = try await signedGet("https://api.bilibili.com/x/web-interface/wbi/view/detail", ["bvid": bvid])
        guard let v = VideoDetail.parse(d) else { throw APIError(description: L("视频信息解析失败")) }
        return v
    }

    func relation(bvid: String) async throws -> Relation {
        let d = try await get("https://api.bilibili.com/x/web-interface/archive/relation", ["bvid": bvid])
        return Relation(like: d.bool("like") ?? false, coin: d.int("coin") ?? 0,
                        favorite: d.bool("favorite") ?? false, attention: d.bool("attention") ?? false)
    }

    /// mode 3 = 热门, 2 = 最新.
    func replies(aid: Int, mode: Int, offset: String, upMid: Int?) async throws -> (items: [Comment], next: String, end: Bool, total: Int) {
        let pagination = "{\"offset\":\"\(offset.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        let d = try await signedGet("https://api.bilibili.com/x/v2/reply/wbi/main", [
            "oid": "\(aid)", "type": "1", "mode": "\(mode)", "pagination_str": pagination, "plat": "1",
            "web_location": "1315875",
        ])
        var list = d.arr("replies")
        if offset.isEmpty { list = d.arr("top_replies") + list }
        let c = d.obj("cursor") ?? [:]
        return (list.compactMap { Comment.parse($0, upMid: upMid) },
                c.obj("pagination_reply")?.str("next_offset") ?? "",
                c.bool("is_end") ?? true, c.int("all_count") ?? 0)
    }

    /// Scrub-preview sprite sheets (YouTube-style hover thumbnails).
    func videoshot(bvid: String, cid: Int) async throws -> Videoshot {
        let d = try await get("https://api.bilibili.com/x/player/videoshot", ["bvid": bvid, "cid": "\(cid)", "index": "1"])
        let images = (d["image"] as? [String] ?? []).compactMap(imageURL)
        let index = (d["index"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        guard !images.isEmpty, index.count > 1 else { throw APIError(description: "no videoshot") }
        return Videoshot(images: images, columns: d.int("img_x_len") ?? 10, rows: d.int("img_y_len") ?? 10,
                         width: d.int("img_x_size") ?? 160, height: d.int("img_y_size") ?? 90, index: index)
    }

    func danmaku(cid: Int) async throws -> Data {
        let (data, _) = try await session.data(for: request(URL(string: "https://api.bilibili.com/x/v1/dm/list.so?oid=\(cid)")!))
        return data
    }

    func playInfo(bvid: String, cid: Int) async throws -> PlayInfo {
        let d = try await signedGet("https://api.bilibili.com/x/player/wbi/playurl", [
            "bvid": bvid, "cid": "\(cid)", "qn": "127", "fnval": "4048", "fnver": "0", "fourk": "1",
            "web_location": "1315873",
        ])
        guard let dash = d.obj("dash") else { throw APIError(description: L("该视频没有 DASH 流（可能是付费/番剧内容）")) }
        let videos = dash.arr("video").compactMap(Self.track)
        let audios = dash.arr("audio").compactMap(Self.track)
        guard !videos.isEmpty else { throw APIError(description: L("没有可用的视频轨")) }
        let ids = Set(videos.map(\.id))
        let accept = (d["accept_quality"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        let descs = d["accept_description"] as? [String] ?? []
        var options: [QualityOption] = accept.enumerated().map { i, qn in
            QualityOption(qn: qn, label: qualityNames[qn] ?? (i < descs.count ? descs[i] : "\(qn)"), available: ids.contains(qn))
        }
        for qn in ids where !accept.contains(qn) {
            options.append(QualityOption(qn: qn, label: qualityNames[qn] ?? "\(qn)", available: true))
        }
        options.sort { $0.qn > $1.qn }
        let last = d.int("last_play_time").map { Double($0) / 1000 }
        return PlayInfo(videos: videos, audios: audios, options: options,
                        lastPlayTime: (last ?? 0) > 0 ? last : nil, lastPlayCid: d.int("last_play_cid"),
                        duration: Double(dash.int("duration") ?? 0))
    }

    private static func track(_ v: JSON) -> DashTrack? {
        func range(_ s: String?) -> ClosedRange<Int>? {
            guard let parts = s?.split(separator: "-"), parts.count == 2,
                  let a = Int(parts[0]), let b = Int(parts[1]), a <= b else { return nil }
            return a...b
        }
        let base = v.str("baseUrl") ?? v.str("base_url")
        let backups = (v["backupUrl"] ?? v["backup_url"]) as? [String] ?? []
        let seg = v.obj("segment_base") ?? v.obj("SegmentBase")
        guard let id = v.int("id"), let base,
              let ini = range(seg?.str("initialization") ?? seg?.str("Initialization")),
              let idx = range(seg?.str("index_range") ?? seg?.str("indexRange")) else { return nil }
        return DashTrack(id: id, codecs: v.str("codecs") ?? "", bandwidth: v.int("bandwidth") ?? 0,
                         width: v.int("width") ?? 0, height: v.int("height") ?? 0,
                         frameRate: v.str("frameRate") ?? v.str("frame_rate") ?? "",
                         urls: ([base] + backups).compactMap(URL.init(string:)), initRange: ini, indexRange: idx)
    }

    // MARK: Actions (all need login + csrf)

    func like(bvid: String, _ on: Bool) async throws {
        try await post("https://api.bilibili.com/x/web-interface/archive/like", ["bvid": bvid, "like": on ? "1" : "2"])
    }

    func coin(bvid: String, count: Int, alsoLike: Bool) async throws {
        try await post("https://api.bilibili.com/x/web-interface/coin/add",
                       ["bvid": bvid, "multiply": "\(count)", "select_like": alsoLike ? "1" : "0"])
    }

    func favorite(aid: Int, add: [Int], remove: [Int]) async throws {
        try await post("https://api.bilibili.com/x/v3/fav/resource/deal", [
            "rid": "\(aid)", "type": "2",
            "add_media_ids": add.map(String.init).joined(separator: ","),
            "del_media_ids": remove.map(String.init).joined(separator: ","),
        ])
    }

    func follow(mid: Int, _ on: Bool) async throws {
        try await post("https://api.bilibili.com/x/relation/modify", ["fid": "\(mid)", "act": on ? "1" : "2", "re_src": "11"])
    }

    func addWatchLater(aid: Int) async throws {
        try await post("https://api.bilibili.com/x/v2/history/toview/add", ["aid": "\(aid)"])
    }

    func removeWatchLater(aid: Int) async throws {
        try await post("https://api.bilibili.com/x/v2/history/toview/del", ["aid": "\(aid)"])
    }

    /// Reports playback progress so 历史记录 / 续播 stay in sync with the official apps.
    func heartbeat(aid: Int?, bvid: String, cid: Int, played: Int, realPlayed: Int, start: Int, first: Bool) async {
        var f = ["bvid": bvid, "cid": "\(cid)", "played_time": "\(played)", "real_played_time": "\(realPlayed)",
                 "realtime": "\(realPlayed)", "start_ts": "\(start)", "type": "3", "dt": "2",
                 "play_type": first ? "1" : "0", "spmid": "333.788.0.0"]
        if let aid { f["aid"] = "\(aid)" }
        if let mid = CookieJar.shared["DedeUserID"] { f["mid"] = mid }
        do { try await post("https://api.bilibili.com/x/click-interface/web/heartbeat", f) } catch { log("heartbeat: \(error)") }
    }

    // MARK: QR login

    func qrGenerate() async throws -> (url: String, key: String) {
        let d = try await call(URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!)
        guard let u = d.str("url"), let k = d.str("qrcode_key") else { throw APIError(description: L("二维码生成失败")) }
        return (u, k)
    }

    enum QRState { case waiting, scanned, expired, done, other(Int, String) }

    func qrPoll(key: String) async throws -> QRState {
        var comps = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        comps.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        let (obj, http) = try await getJSON(comps.url!)
        let d = obj.obj("data") ?? [:]
        let code = d.int("code") ?? (obj.int("code") ?? -1)
        switch code {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            var c: [String: String] = [:]
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { r, kv in
                if let k = kv.key as? String, let v = kv.value as? String { r[k] = v }
            }
            for ck in HTTPCookie.cookies(withResponseHeaderFields: headers, for: comps.url!) { c[ck.name] = ck.value }
            if c["SESSDATA"] == nil, let s = d.str("url"), let q = URLComponents(string: s)?.queryItems {
                for item in q where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(item.name) {
                    c[item.name] = item.value
                }
            }
            guard c["SESSDATA"] != nil else { return .other(0, L("登录成功但没有拿到 SESSDATA")) }
            CookieJar.shared.set(c)
            mixinKey = nil
            return .done
        default:
            return .other(code, d.str("message") ?? "")
        }
    }
}

/// "12.3万" / "1.2亿" / "980" → Int
func parseCountText(_ s: String?) -> Int? {
    guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if s.hasSuffix("万"), let v = Double(s.dropLast()) { return Int(v * 1e4) }
    if s.hasSuffix("亿"), let v = Double(s.dropLast()) { return Int(v * 1e8) }
    return Int(s)
}

struct Videoshot {
    let images: [URL]
    let columns: Int
    let rows: Int
    let width: Int
    let height: Int
    /// Seconds for each frame (index[0] is a leading 0).
    let index: [Int]

    /// Sprite sheet and cell for the frame shown at `t` seconds.
    func cell(at t: Double) -> (url: URL, rect: CGRect)? {
        let secs = Int(t)
        var i = index.lastIndex { $0 <= secs } ?? 0
        i = max(0, i - 1)
        let perSheet = columns * rows
        let sheet = i / perSheet, n = i % perSheet
        guard images.indices.contains(sheet) else { return nil }
        return (images[sheet], CGRect(x: (n % columns) * width, y: (n / columns) * height, width: width, height: height))
    }
}
