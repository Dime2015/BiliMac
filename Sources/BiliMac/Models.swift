import Foundation

struct VideoCard: Identifiable, Hashable {
    var bvid: String
    var cid: Int? = nil
    var aid: Int? = nil
    var title: String
    var cover: URL?
    var owner: String
    var ownerMid: Int? = nil
    var ownerFace: URL? = nil
    var views: Int? = nil
    var danmaku: Int? = nil
    var duration: Int? = nil
    var pubdate: Date? = nil
    var progress: Int? = nil       // seconds watched (history / watch later); -1 = finished
    var reason: String? = nil      // 推荐理由 / 已关注 etc.
    var viewedAt: Date? = nil
    var id: String { bvid }

    var url: URL { URL(string: "https://www.bilibili.com/video/\(bvid)")! }

    /// Parses the common archive shape used by popular / ranking / rcmd / related / watch-later.
    static func archive(_ j: JSON) -> VideoCard? {
        guard let bvid = j.str("bvid"), !bvid.isEmpty else { return nil }
        let owner = j.obj("owner")
        let stat = j.obj("stat")
        return VideoCard(
            bvid: bvid, cid: j.int("cid").flatMap { $0 > 0 ? $0 : nil }, aid: j.int("aid") ?? j.int("id"),
            title: plainTitle(j.str("title") ?? ""), cover: imageURL(j.str("pic") ?? j.str("cover")),
            owner: owner?.str("name") ?? j.str("author") ?? "", ownerMid: owner?.int("mid") ?? j.int("mid"),
            ownerFace: imageURL(owner?.str("face")),
            views: stat?.int("view") ?? stat?.int("play") ?? j.int("play"),
            danmaku: stat?.int("danmaku") ?? j.int("video_review"),
            duration: j.int("duration") ?? parseDurationText(j.str("duration")),
            pubdate: j.int("pubdate").map { Date(timeIntervalSince1970: TimeInterval($0)) },
            progress: j.int("progress"),
            reason: j.obj("rcmd_reason")?.str("content").flatMap { $0.isEmpty ? nil : $0 })
    }
}

struct VideoPage: Identifiable, Hashable {
    let cid: Int
    let page: Int
    let part: String
    let duration: Int
    var id: Int { cid }
}

struct VideoStat {
    var view = 0, danmaku = 0, reply = 0, favorite = 0, coin = 0, share = 0, like = 0
}

struct VideoDetail {
    let aid: Int
    let bvid: String
    let cid: Int
    let title: String
    let desc: String
    let cover: URL?
    let pubdate: Date?
    let duration: Int
    let ownerMid: Int
    let ownerName: String
    let ownerFace: URL?
    var follower: Int
    var following: Bool
    let archiveCount: Int
    var stat: VideoStat
    let pages: [VideoPage]
    let related: [VideoCard]
    let tags: [String]
    let partition: String

    static func parse(_ d: JSON) -> VideoDetail? {
        guard let v = d.obj("View"), let aid = v.int("aid"), let bvid = v.str("bvid") else { return nil }
        let owner = v.obj("owner") ?? [:]
        let st = v.obj("stat") ?? [:]
        let card = d.obj("Card") ?? [:]
        let pages = v.arr("pages").compactMap { p -> VideoPage? in
            guard let cid = p.int("cid") else { return nil }
            return VideoPage(cid: cid, page: p.int("page") ?? 1, part: p.str("part") ?? "", duration: p.int("duration") ?? 0)
        }
        return VideoDetail(
            aid: aid, bvid: bvid, cid: v.int("cid") ?? pages.first?.cid ?? 0,
            title: v.str("title") ?? "", desc: v.str("desc") ?? "", cover: imageURL(v.str("pic")),
            pubdate: v.int("pubdate").map { Date(timeIntervalSince1970: TimeInterval($0)) },
            duration: v.int("duration") ?? 0,
            ownerMid: owner.int("mid") ?? 0, ownerName: owner.str("name") ?? "", ownerFace: imageURL(owner.str("face")),
            follower: card.int("follower") ?? card.obj("card")?.int("fans") ?? 0,
            following: card.bool("following") ?? false,
            archiveCount: card.int("archive_count") ?? 0,
            stat: VideoStat(view: st.int("view") ?? 0, danmaku: st.int("danmaku") ?? 0, reply: st.int("reply") ?? 0,
                            favorite: st.int("favorite") ?? 0, coin: st.int("coin") ?? 0, share: st.int("share") ?? 0,
                            like: st.int("like") ?? 0),
            pages: pages,
            related: d.arr("Related").compactMap(VideoCard.archive),
            tags: d.arr("Tags").compactMap { $0.str("tag_name") },
            partition: v.str("tname_v2") ?? v.str("tname") ?? "")
    }
}

struct Relation {
    var like = false
    var coin = 0
    var favorite = false
    var attention = false
}

/// An uploader's space (UP 主主页) header.
struct SpaceInfo {
    let mid: Int
    let name: String
    let face: URL?
    let sign: String
    let banner: URL?
    let fans: Int
    let followingCount: Int
    let likes: Int
    let archives: Int
    let level: Int
    let official: String?
    var following: Bool
}

struct Comment: Identifiable {
    let id: Int
    let mid: Int
    let uname: String
    let avatar: URL?
    let level: Int
    let isVip: Bool
    let message: String
    let like: Int
    let ctime: Date
    let rcount: Int
    let previews: [(String, String)]
    let isUp: Bool

    static func parse(_ r: JSON, upMid: Int?) -> Comment? {
        guard let id = r.int("rpid") else { return nil }
        let m = r.obj("member") ?? [:]
        let previews = r.arr("replies").prefix(3).map { s in
            (s.obj("member")?.str("uname") ?? "", s.obj("content")?.str("message") ?? "")
        }
        return Comment(
            id: id, mid: r.int("mid") ?? 0, uname: m.str("uname") ?? "", avatar: imageURL(m.str("avatar")),

            level: m.obj("level_info")?.int("current_level") ?? 0,
            isVip: (m.obj("vip")?.int("vipStatus") ?? 0) == 1,
            message: r.obj("content")?.str("message") ?? "", like: r.int("like") ?? 0,
            ctime: Date(timeIntervalSince1970: TimeInterval(r.int("ctime") ?? 0)),
            rcount: r.int("rcount") ?? 0, previews: Array(previews),
            isUp: upMid != nil && r.int("mid") == upMid)
    }
}

struct FavFolder: Identifiable, Hashable {
    let id: Int
    let title: String
    let count: Int
    var contains: Bool
}

struct Account {
    var loggedIn = false
    var mid: Int?
    var name: String?
    var face: URL?
    var level: Int = 0
    var isVip = false
    var vipLabel: String?
    var coins: Double = 0
}
