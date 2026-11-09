import CryptoKit
import Foundation

/// 首页「推荐」from the phone app's feed.
///
/// The web feed BiliMac otherwise uses leans on long-term interests and barely reacts to what was just watched;
/// the phone feed does (watch a few iPhone videos and the next refresh is full of them). It needs an app login
/// token, which a TV-style QR login gives, and its requests are signed with that client's app key — the same
/// public key other third-party bilibili clients use. If the token stops working, 首页 falls back to the web feed.
@MainActor
final class AppFeedAuth: ObservableObject {
    static let shared = AppFeedAuth()

    struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var mid: Int?
        var expiresAt: Date?
    }

    @Published private(set) var token: Token?
    /// Set when the phone feed refused the token or failed, so settings can say why 首页 fell back.
    @Published var lastError: String?

    var authorized: Bool { token != nil }
    /// When the token was last confirmed to still belong to the account (checked at most every 30 minutes).
    private var confirmedAt: Date?

    /// The feed answers an expired or revoked token with the signed-out feed instead of an error, so check the
    /// token still identifies the account before using it; throws when it doesn't.
    func validToken() async throws -> String {
        guard let t = token else { throw APIError(description: L("未授权")) }
        if let c = confirmedAt, Date().timeIntervalSince(c) < 30 * 60 { return t.accessToken }
        let mid = try await AppAPI.accountMid(token: t.accessToken)
        guard mid > 0, t.mid == nil || t.mid == mid else {
            throw APIError(description: L("授权已失效，请重新扫码授权"))
        }
        confirmedAt = Date()
        return t.accessToken
    }

    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiliMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("app-token.json")
        if let data = try? Data(contentsOf: url) { token = try? JSONDecoder().decode(Token.self, from: data) }
    }

    func save(_ t: Token) {
        token = t
        lastError = nil
        confirmedAt = nil
        guard let data = try? JSONEncoder().encode(t) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func clear() {
        token = nil
        lastError = nil
        confirmedAt = nil
        try? FileManager.default.removeItem(at: url)
    }
}

/// Signed requests to the app API (passport TV login and app.bilibili.com).
enum AppAPI {
    private static let appKey = "4409e2ce8ffd12b8"
    private static let appSecret = "59b43e04ad6965f34319062b478f83dd"
    private static let userAgent = "Mozilla/5.0 BiliDroid/8.20.0 os/android model/Pixel mobi_app/android build/8200300 channel/master innerVer/8200300 osVer/14 network/2"
    /// No cookies: the web login has nothing to do with these endpoints.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    private static func signed(_ params: [String: String]) -> String {
        var p = params
        p["appkey"] = appKey
        p["ts"] = "\(Int(Date().timeIntervalSince1970))"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let q = p.keys.sorted().map { "\($0)=\(p[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        let sign = Insecure.MD5.hash(data: Data((q + appSecret).utf8)).map { String(format: "%02x", $0) }.joined()
        return q + "&sign=" + sign
    }

    private static func send(_ url: String, _ params: [String: String], post: Bool) async throws -> JSON {
        let q = signed(params)
        var r = URLRequest(url: URL(string: post ? url : url + "?" + q)!)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if post {
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(q.utf8)
        }
        let (data, _) = try await session.data(for: r)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw APIError(description: L("接口返回异常")) }
        return obj
    }

    // MARK: TV QR login

    static func qrGenerate() async throws -> (url: String, code: String) {
        let d = try await send("https://passport.bilibili.com/x/passport-tv-login/qrcode/auth_code", ["local_id": "0"], post: true)
        guard d.int("code") == 0, let data = d.obj("data"), let u = data.str("url"), let c = data.str("auth_code") else {
            throw APIError(description: d.str("message") ?? L("二维码生成失败"))
        }
        return (u, c)
    }

    enum QRState { case waiting, scanned, expired, done(AppFeedAuth.Token), other(Int, String) }

    static func qrPoll(code: String) async throws -> QRState {
        let d = try await send("https://passport.bilibili.com/x/passport-tv-login/qrcode/poll", ["auth_code": code, "local_id": "0"], post: true)
        switch d.int("code") ?? -1 {
        case 86039: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            guard let data = d.obj("data"), let access = data.str("access_token") else { return .other(0, L("接口返回异常")) }
            let expires = data.int("expires_in").map { Date().addingTimeInterval(TimeInterval($0)) }
            return .done(.init(accessToken: access, refreshToken: data.str("refresh_token"), mid: data.int("mid"), expiresAt: expires))
        case let c: return .other(c, d.str("message") ?? "")
        }
    }

    // MARK: Feed

    /// The account a token belongs to; 0 when bilibili no longer accepts it.
    static func accountMid(token: String) async throws -> Int {
        let d = try await send("https://app.bilibili.com/x/v2/account/mine", [
            "access_key": token, "build": "8200300", "mobi_app": "android", "platform": "android",
        ], post: false)
        return d.obj("data")?.int("mid") ?? 0
    }

    /// One page of the phone feed. `idx` 0 is a fresh pull; afterwards pass the `next` this returned.
    static func feed(token: String, idx: Int) async throws -> (cards: [VideoCard], next: Int) {
        let d = try await send("https://app.bilibili.com/x/v2/feed/index", [
            "access_key": token, "build": "8200300", "mobi_app": "android", "platform": "android", "device": "phone",
            "c_locale": "zh_CN", "s_locale": "zh_CN", "idx": "\(idx)", "pull": idx == 0 ? "true" : "false", "flush": "0",
            "column": "2", "fnval": "4048", "fnver": "0", "force_host": "0", "fourk": "1", "network": "wifi", "qn": "32",
            "recsys_mode": "0", "voice_balance": "0", "login_event": "0",
        ], post: false)
        guard d.int("code") == 0, let data = d.obj("data") else {
            throw APIError(description: Lf("手机端推荐不可用（%@ %@）", "\(d.int("code") ?? -1)", d.str("message") ?? ""))
        }
        let items = data.arr("items")
        let cards = items.compactMap(card)
        return (cards, items.last?.int("idx") ?? idx)
    }

    private static func card(_ j: JSON) -> VideoCard? {
        guard j.str("card_goto") == "av" || j.str("goto") == "av" else { return nil }
        let args = j.obj("args"), player = j.obj("player_args")
        guard let aid = args?.int("aid") ?? player?.int("aid") ?? j.int("param"), aid > 0 else { return nil }
        // cover_left_icon: 1 = plays, 3 = danmaku (the second slot is sometimes something else).
        let danmaku = j.int("cover_left_icon_2") == 3 ? parseCountText(j.str("cover_left_text_2")) : nil
        let reason = j.obj("rcmd_reason_style")?.str("text")
        return VideoCard(
            bvid: av2bv(aid), cid: player?.int("cid").flatMap { $0 > 0 ? $0 : nil }, aid: aid,
            title: plainTitle(j.str("title") ?? ""), cover: imageURL(j.str("cover")),
            owner: args?.str("up_name") ?? "", ownerMid: args?.int("up_id"),
            views: j.int("cover_left_icon_1") == 1 ? parseCountText(j.str("cover_left_text_1")) : nil,
            danmaku: danmaku,
            duration: player?.int("duration") ?? parseDurationText(j.str("cover_right_text")),
            reason: reason.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// av number → BV id (bilibili's public scheme, checked against their API for old and new av numbers).
func av2bv(_ aid: Int) -> String {
    let table = Array("FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf")
    var b = Array("BV1000000000")
    var t = (Int64(1) << 51 | Int64(aid)) ^ 23_442_827_791_579
    var i = b.count - 1
    while t > 0 {
        b[i] = table[Int(t % 58)]
        t /= 58
        i -= 1
    }
    b.swapAt(3, 9)
    b.swapAt(4, 7)
    return String(b)
}
