import AppKit
import SwiftUI

// MARK: - Models

/// One row of 聊天列表: a private chat, or an official account (社区中心, 服务通知 …).
struct ChatSession: Identifiable, Hashable {
    let talker: Int
    let type: Int
    var name: String
    var face: URL?
    var unread: Int
    var preview: String
    var time: Date?
    var sessionTS: Int
    var maxSeqno: Int
    /// Official accounts have their name in the session; people need a card lookup.
    var official: Bool
    var id: String { "\(type)-\(talker)" }
}

struct ChatMessage: Identifiable, Hashable {
    enum Content: Hashable {
        case text(String)
        case image(URL, CGSize?)
        /// Notification card (type 10): title, text and up to three links.
        case card(title: String, text: String, links: [Link])
        /// Shared video / article (types 7, 11, 12 …).
        case share(title: String, cover: URL?, link: String?)
        case tip(String)
        case withdrawn
        case unsupported
    }
    struct Link: Hashable { let text: String; let uri: String }

    let id: Int
    let seqno: Int
    let sender: Int
    let time: Date
    let content: Content

    static func parse(_ m: JSON) -> ChatMessage? {
        guard let seq = m.int("msg_seqno") else { return nil }
        let raw = m.str("content") ?? ""
        let c = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? JSON ?? [:]
        let content: Content
        switch m.int("msg_type") ?? 0 {
        case 1: content = .text(c.str("content") ?? raw)
        case 2:
            let size = c.double("width").flatMap { w in c.double("height").map { CGSize(width: w, height: $0) } }
            content = (c.str("url").flatMap(URL.init(string:))).map { .image($0, size) } ?? .unsupported
        case 5: content = .withdrawn
        case 6: content = (c.str("url").flatMap(URL.init(string:))).map { .image($0, CGSize(width: 120, height: 120)) } ?? .text(L("[表情]"))
        case 7, 11, 12, 13, 14:
            let link = c.str("jump_uri") ?? c.str("url") ?? c.str("bvid").map { "https://www.bilibili.com/video/\($0)" }
                ?? c.int("id").map { "https://www.bilibili.com/video/av\($0)" }
            content = .share(title: c.str("title") ?? c.str("headline") ?? L("[分享]"),
                             cover: (c.str("thumb") ?? c.str("cover") ?? c.arr("image_urls").first?.str("url")).flatMap(URL.init(string:)),
                             link: link)
        case 10:
            var links: [Link] = []
            for (t, u) in [("jump_text", "jump_uri"), ("jump_text_2", "jump_uri_2"), ("jump_text_3", "jump_uri_3")] {
                if let text = c.str(t), !text.isEmpty, let uri = c.str(u), !uri.isEmpty { links.append(Link(text: text, uri: uri)) }
            }
            content = .card(title: c.str("title") ?? "", text: Notice.plain(c.str("text") ?? ""), links: links)
        case 18: content = .tip(c.str("content") ?? raw)
        default: content = .unsupported
        }
        return ChatMessage(id: m.int("msg_key") ?? seq, seqno: seq, sender: m.int("sender_uid") ?? 0,
                           time: Date(timeIntervalSince1970: Double(m.int("timestamp") ?? 0)), content: content)
    }

    /// One line for the chat list.
    var preview: String {
        switch content {
        case .text(let s): return s
        case .image: return L("[图片]")
        case .card(let t, let text, _): return t.isEmpty ? text : t
        case .share(let t, _, _): return L("[分享]") + " " + t
        case .tip(let s): return s
        case .withdrawn: return L("撤回了一条消息")
        case .unsupported: return L("[暂不支持的消息]")
        }
    }
}

/// 回复我的 / @我的 / 收到的赞 entries, and 系统通知.
struct Notice: Identifiable, Hashable {
    struct Person: Hashable { let mid: Int; let name: String; let face: URL? }
    let id: Int
    var people: [Person] = []
    /// "回复了我的评论", "在评论中@了我", "等 3 人赞了我的视频" …
    var action: String
    var title: String = ""
    var body: String = ""
    /// What it answers / refers to (my comment, the video title).
    var quote: String = ""
    var image: URL?
    var link: String?
    var time: Date?
    var cursorTime: Int = 0

    /// System notices mark links as #{text}{"url"}; keep the text.
    static func plain(_ s: String) -> String {
        guard s.contains("#{") else { return s }
        let re = try! NSRegularExpression(pattern: #"#\{([^}]*)\}\{"[^"]*"\}"#)
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }

    /// The #{}{"url"} link, else the first bare URL in the text.
    static func firstLink(_ s: String) -> String? {
        if let r = s.range(of: #"\{"(https?://[^"]+)"\}"#, options: .regularExpression) { return String(s[r].dropFirst(2).dropLast(2)) }
        if let r = s.range(of: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#, options: .regularExpression) { return String(s[r]) }
        return nil
    }

    /// What was replied to / liked ("评论", "视频" …) in the UI language.
    static func business(_ b: String) -> String {
        let en = ["评论": "comment", "视频": "video", "动态": "post", "专栏": "article", "音频": "audio", "笔记": "note"]
        let ja = ["评论": "コメント", "视频": "動画", "动态": "投稿", "专栏": "記事", "音频": "音声", "笔记": "ノート"]
        if AppLanguage.current.hasPrefix("en") { return en[b] ?? b }
        if AppLanguage.current.hasPrefix("ja") { return ja[b] ?? b }
        return b
    }

    /// Site-wide notices wrap their text as {"web": "…"}.
    static func unwrap(_ s: String) -> String {
        guard s.hasPrefix("{"), let j = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? JSON else { return s }
        return j.str("web") ?? j.str("app") ?? j.values.compactMap { $0 as? String }.first ?? s
    }
}

// MARK: - API

extension BiliAPI {
    struct Unread { var chat = 0; var reply = 0; var at = 0; var like = 0; var system = 0
        var total: Int { chat + reply + at + like + system }
    }

    func messageUnread() async throws -> Unread {
        async let feed = get("https://api.bilibili.com/x/msgfeed/unread", ["build": "0", "mobi_app": "web"])
        async let chat = get("https://api.vc.bilibili.com/session_svr/v1/session_svr/single_unread",
                             ["unread_type": "0", "show_unfollow_list": "1", "show_dustbin": "1", "build": "0", "mobi_app": "web"])
        let f = try await feed, c = (try? await chat) ?? [:]
        return Unread(chat: (c.int("follow_unread") ?? 0) + (c.int("unfollow_unread") ?? 0),
                      reply: f.int("reply") ?? 0, at: f.int("at") ?? 0, like: f.int("like") ?? 0, system: f.int("sys_msg") ?? 0)
    }

    func chatSessions(before ts: Int? = nil) async throws -> (list: [ChatSession], more: Bool) {
        var p = ["session_type": "1", "group_fold": "1", "unfollow_fold": "0", "sort_rule": "2", "build": "0", "mobi_app": "web"]
        if let ts { p["end_ts"] = "\(ts)" }
        let d = try await get("https://api.vc.bilibili.com/session_svr/v1/session_svr/get_sessions", p)
        var list: [ChatSession] = d.arr("session_list").compactMap { s in
            guard let talker = s.int("talker_id") else { return nil }
            let last = s.obj("last_msg").flatMap(ChatMessage.parse)
            let acc = s.obj("account_info")
            return ChatSession(talker: talker, type: s.int("session_type") ?? 1, name: acc?.str("name") ?? "",
                               face: acc?.str("pic_url").flatMap(URL.init(string:)), unread: s.int("unread_count") ?? 0,
                               preview: last?.preview ?? "", time: last?.time, sessionTS: s.int("session_ts") ?? 0,
                               maxSeqno: s.int("max_seqno") ?? 0, official: acc != nil)
        }
        // People's names and faces come from their cards.
        let mids = list.filter { !$0.official }.map(\.talker)
        if !mids.isEmpty, let cards = try? await userCards(mids) {
            for i in list.indices where !list[i].official {
                if let c = cards[list[i].talker] { list[i].name = c.name; list[i].face = c.face }
            }
        }
        return (list, (d.int("has_more") ?? 0) == 1)
    }

    func userCards(_ mids: [Int]) async throws -> [Int: Notice.Person] {
        let url = URL(string: "https://api.vc.bilibili.com/account/v1/user/cards?uids=" + mids.map(String.init).joined(separator: ","))!
        let (obj, _) = try await rawJSON(url)
        var out: [Int: Notice.Person] = [:]
        for c in (obj["data"] as? [JSON]) ?? [] {
            guard let mid = c.int("mid") else { continue }
            out[mid] = Notice.Person(mid: mid, name: c.str("name") ?? "", face: c.str("face").flatMap(URL.init(string:)))
        }
        return out
    }

    /// Newest first from bilibili; returned oldest first. `before`: load messages older than this seqno.
    func chatMessages(talker: Int, type: Int, before: Int? = nil) async throws -> (list: [ChatMessage], more: Bool) {
        var p = ["talker_id": "\(talker)", "session_type": "\(type)", "size": "30", "sender_device_id": "1", "build": "0", "mobi_app": "web"]
        if let before { p["end_seqno"] = "\(before - 1)" }
        let d = try await get("https://api.vc.bilibili.com/svr_sync/v1/svr_sync/fetch_session_msgs", p)
        return (d.arr("messages").compactMap(ChatMessage.parse).sorted { $0.seqno < $1.seqno }, (d.int("has_more") ?? 0) == 1)
    }

    /// Marks a chat read up to `seqno`, like opening it in the official app.
    func ackChat(talker: Int, type: Int, seqno: Int) async throws {
        guard let csrf = CookieJar.shared["bili_jct"] else { return }
        try await post("https://api.vc.bilibili.com/session_svr/v1/session_svr/update_ack", [
            "talker_id": "\(talker)", "session_type": "\(type)", "ack_seqno": "\(seqno)", "csrf_token": csrf, "build": "0", "mobi_app": "web",
        ])
    }

    enum FeedKind: String { case reply, at, like }

    /// 回复我的 / @我的 / 收到的赞, newest first. `cursor`: (id, time) of the last item for the next page.
    func messageFeed(_ kind: FeedKind, cursor: (Int, Int)? = nil) async throws -> (list: [Notice], more: Bool) {
        var p = ["platform": "web", "build": "0", "mobi_app": "web"]
        let timeKey = kind == .reply ? "reply_time" : kind == .at ? "at_time" : "like_time"
        if let cursor { p["id"] = "\(cursor.0)"; p[timeKey] = "\(cursor.1)" }
        let d = try await get("https://api.bilibili.com/x/msgfeed/\(kind.rawValue)", p)
        func person(_ u: JSON) -> Notice.Person? {
            guard let mid = u.int("mid") else { return nil }
            return Notice.Person(mid: mid, name: u.str("nickname") ?? u.str("name") ?? "", face: u.str("avatar").flatMap(URL.init(string:)))
        }
        let rows: [JSON], cur: JSON?
        if kind == .like { rows = d.obj("total")?.arr("items") ?? []; cur = d.obj("total")?.obj("cursor") }
        else { rows = d.arr("items"); cur = d.obj("cursor") }
        let list: [Notice] = rows.compactMap { r in
            guard let id = r.int("id") else { return nil }
            let it = r.obj("item") ?? [:]
            let business = Notice.business(it.str("business") ?? "")
            let t = r.int(timeKey) ?? 0
            var n = Notice(id: id, action: "", image: it.str("image").flatMap(URL.init(string:)),
                           link: it.str("uri") ?? it.str("native_uri"), time: t > 0 ? Date(timeIntervalSince1970: Double(t)) : nil, cursorTime: t)
            switch kind {
            case .reply:
                n.people = r.obj("user").flatMap(person).map { [$0] } ?? []
                n.action = Lf("回复了我的%@", business.isEmpty ? Notice.business("评论") : business)
                n.body = it.str("source_content") ?? ""
                n.quote = it.str("target_reply_content").flatMap { $0.isEmpty ? nil : $0 } ?? it.str("title") ?? ""
            case .at:
                n.people = r.obj("user").flatMap(person).map { [$0] } ?? []
                n.action = Lf("在%@中@了我", business.isEmpty ? Notice.business("评论") : business)
                n.body = it.str("source_content") ?? ""
                n.quote = it.str("title") ?? ""
            case .like:
                n.people = r.arr("users").compactMap(person)
                let count = r.int("counts") ?? n.people.count
                n.action = count > 1 ? Lf("等 %@ 人赞了我的%@", "\(count)", business) : Lf("赞了我的%@", business)
                n.quote = it.str("title") ?? it.str("desc") ?? ""
            }
            return n
        }
        let end = (cur?.bool("is_end") ?? true) || list.isEmpty
        return (list, !end)
    }

    /// 系统通知: personal notices and site-wide ones, newest first.
    func systemNotices() async throws -> [Notice] {
        let csrf = CookieJar.shared["bili_jct"] ?? ""
        async let mine = get("https://message.bilibili.com/x/sys-msg/query_user_notify", ["csrf": csrf, "page_size": "20", "build": "0", "mobi_app": "web"])
        async let all = get("https://message.bilibili.com/x/sys-msg/query_unified_notify", ["csrf": csrf, "page_size": "20", "build": "0", "mobi_app": "web"])
        let rows = ((try? await mine)?.arr("system_notify_list") ?? []) + ((try? await all)?.arr("system_notify_list") ?? [])
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var seen = Set<Int>()
        return rows.compactMap { r -> Notice? in
            guard let id = r.int("id"), seen.insert(id).inserted else { return nil }
            let raw = Notice.unwrap(r.str("content") ?? "")
            let link = Notice.firstLink(raw) ?? r.str("card_link").flatMap { $0.isEmpty ? nil : $0 }
            return Notice(id: id, action: "", title: r.str("title") ?? "", body: Notice.plain(raw),
                          link: link, time: r.str("time_at").flatMap(f.date(from:)), cursorTime: r.int("cursor") ?? 0)
        }
        .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
    }

    /// Marks system notices read up to `cursor`.
    func ackSystemNotices(cursor: Int) async throws {
        let csrf = CookieJar.shared["bili_jct"] ?? ""
        try await post("https://message.bilibili.com/x/sys-msg/update_cursor?csrf=\(csrf)&cursor=\(cursor)&has_up=0&build=0&mobi_app=web", [:])
    }
}

// MARK: - State

@MainActor
final class MessageCenter: ObservableObject {
    static let shared = MessageCenter()

    enum Tab: Hashable { case chat, reply, at, like }
    enum Pane: Hashable { case system, chat(String) }

    @Published var tab = Tab.chat
    @Published var unread = BiliAPI.Unread()
    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var sessionsMore = false
    @Published private(set) var loadingSessions = false
    @Published var pane: Pane?
    @Published private(set) var error: String?

    @Published private(set) var feeds: [Tab: [Notice]] = [:]
    @Published private(set) var feedMore: [Tab: Bool] = [:]
    @Published private(set) var loadingFeed: Set<Tab> = []
    @Published private(set) var system: [Notice]?

    private var pollTask: Task<Void, Never>?

    /// Testing against a real account without marking anything read: BILIMAC_NO_MARK_READ=1.
    private let markRead = ProcessInfo.processInfo.environment["BILIMAC_NO_MARK_READ"] == nil

    /// Keeps the sidebar badge current while signed in.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUnread()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        unread = .init()
        sessions = []
        feeds = [:]
        system = nil
        pane = nil
    }

    func refreshUnread() async {
        guard AppModel.shared.account.loggedIn, !Env.demo else { return }
        if let u = try? await BiliAPI.shared.messageUnread() { unread = u }
    }

    func loadSessions(reset: Bool = false) async {
        guard !loadingSessions, reset || sessions.isEmpty || sessionsMore else { return }
        loadingSessions = true
        defer { loadingSessions = false }
        do {
            let r = try await BiliAPI.shared.chatSessions(before: reset ? nil : sessions.last?.sessionTS)
            if reset || sessions.isEmpty { sessions = r.list } else {
                let ids = Set(sessions.map(\.id))
                sessions += r.list.filter { !ids.contains($0.id) }
            }
            sessionsMore = r.more
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func session(_ id: String) -> ChatSession? { sessions.first { $0.id == id } }

    /// Opening a chat marks it read, like the official app.
    func opened(_ s: ChatSession, upTo seqno: Int) {
        guard s.unread > 0, markRead else { return }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i].unread = 0 }
        unread.chat = max(0, unread.chat - s.unread)
        Task { try? await BiliAPI.shared.ackChat(talker: s.talker, type: s.type, seqno: max(seqno, s.maxSeqno)) }
    }

    func loadSystem() async {
        do {
            let list = try await BiliAPI.shared.systemNotices()
            system = list
            if unread.system > 0, markRead, let top = list.map(\.cursorTime).max(), top > 0 {
                unread.system = 0
                try? await BiliAPI.shared.ackSystemNotices(cursor: top)
            }
        } catch { system = []; self.error = error.localizedDescription }
    }

    func loadFeed(_ tab: Tab, more: Bool = false) async {
        let kind: BiliAPI.FeedKind
        switch tab {
        case .reply: kind = .reply
        case .at: kind = .at
        case .like: kind = .like
        case .chat: return
        }
        guard !loadingFeed.contains(tab), more ? feedMore[tab] == true : feeds[tab] == nil else { return }
        loadingFeed.insert(tab)
        defer { loadingFeed.remove(tab) }
        let last = more ? feeds[tab]?.last.map { ($0.id, $0.cursorTime) } : nil
        do {
            let r = try await BiliAPI.shared.messageFeed(kind, cursor: last)
            feeds[tab] = (more ? feeds[tab] ?? [] : []) + r.list
            feedMore[tab] = r.more
            // The feed endpoints clear their own unread count when read.
            switch tab {
            case .reply: unread.reply = 0
            case .at: unread.at = 0
            case .like: unread.like = 0
            case .chat: break
            }
        } catch {
            if feeds[tab] == nil { feeds[tab] = [] }
            self.error = error.localizedDescription
        }
    }
}

/// Opens a bilibili link in the app when it can (videos, UP 主主页), otherwise in the browser.
@MainActor
func openBiliLink(_ s: String) {
    if let r = s.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) {
        AppModel.shared.open(VideoCard(bvid: String(s[r]), title: "", cover: nil, owner: ""))
        return
    }
    if let r = s.range(of: #"space\.bilibili\.com/\d+"#, options: .regularExpression),
       let mid = Int(s[r].split(separator: "/").last ?? "") {
        AppModel.shared.go(.space(mid))
        return
    }
    var url = s
    if url.hasPrefix("//") { url = "https:" + url }
    if let u = URL(string: url), u.scheme == "https" || u.scheme == "http" { NSWorkspace.shared.open(u) }
}

// MARK: - Page

struct MessagesPage: View {
    @ObservedObject private var center = MessageCenter.shared

    var body: some View {
        MainPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text(L("消息")).font(.system(size: 30, weight: .black))
                    SlidingChips(options: [
                        (MessageCenter.Tab.chat, label(L("聊天"), center.unread.chat + center.unread.system)),
                        (.reply, label(L("回复我的"), center.unread.reply)),
                        (.at, label(L("@我的"), center.unread.at)),
                        (.like, label(L("收到的赞"), center.unread.like)),
                    ], selection: $center.tab)
                    Spacer()
                }
                .padding(.horizontal, 24)
                switch center.tab {
                case .chat: ChatSplit()
                default: FeedList(tab: center.tab).id(center.tab)
                }
            }
            .padding(.top, 4)
        }
        .task { await center.refreshUnread() }
    }

    private func label(_ s: String, _ n: Int) -> String { n > 0 ? "\(s) \(n > 99 ? "99+" : "\(n)")" : s }
}

/// Unread count dot, as in the official app.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color(red: 0.93, green: 0.29, blue: 0.27), in: Capsule())
        }
    }
}

// MARK: Chats

private struct ChatSplit: View {
    @ObservedObject private var center = MessageCenter.shared

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    SessionRow(name: L("系统通知"), face: nil, icon: "speaker.wave.2.fill", iconTint: Theme.blue, preview: L("账号、活动和站务通知"),
                               time: nil, unread: center.unread.system, selected: center.pane == .system) { center.pane = .system }
                    ForEach(center.sessions) { s in
                        SessionRow(name: s.name, face: s.face, icon: nil, iconTint: .clear, preview: s.preview, time: s.time,
                                   unread: s.unread, selected: center.pane == .chat(s.id)) { center.pane = .chat(s.id) }
                    }
                    if center.sessionsMore {
                        ProgressView().controlSize(.small).padding(12)
                            .task { await center.loadSessions() }
                    } else if center.loadingSessions && center.sessions.isEmpty {
                        ProgressView().controlSize(.small).padding(30)
                    } else if let e = center.error, center.sessions.isEmpty {
                        Text(e).font(.system(size: 12)).foregroundStyle(Theme.text3).padding(20)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .frame(width: 340)
            Rectangle().fill(Theme.line.opacity(0.5)).frame(width: 1)
            Group {
                switch center.pane {
                case .system: SystemNoticeList()
                case .chat(let id):
                    if let s = center.session(id) { ConversationView(session: s).id(id) }
                case nil:
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34, weight: .light))
                        Text(L("选择一个会话")).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await center.loadSessions(reset: true) }
    }
}

private struct SessionRow: View {
    let name: String
    let face: URL?
    let icon: String?
    let iconTint: Color
    let preview: String
    let time: Date?
    let unread: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(iconTint, in: Circle())
                } else {
                    Avatar(url: face, size: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name.isEmpty ? " " : name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let time { Text(formatRelativeDate(time)).font(.system(size: 11)).foregroundStyle(Theme.text3) }
                    }
                    HStack(spacing: 6) {
                        Text(preview).font(.system(size: 12.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        Spacer(minLength: 4)
                        UnreadBadge(count: unread)
                    }
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.raised : hover ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }
}

private struct ConversationView: View {
    let session: ChatSession
    @ObservedObject private var center = MessageCenter.shared
    @State private var messages: [ChatMessage] = []
    @State private var more = false
    @State private var loading = true
    @State private var loadingOlder = false
    @State private var error: String?

    private var me: Int { AppModel.shared.account.mid ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(url: session.face, size: 32)
                Text(session.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                Spacer()
                if !session.official {
                    Button { AppModel.shared.go(.space(session.talker)) } label: {
                        Text(L("查看主页")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 10).frame(height: 26).background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Rectangle().fill(Theme.line.opacity(0.35)).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if more {
                        Button { Task { await loadOlder() } } label: {
                            Text(loadingOlder ? L("加载中…") : L("加载更早的消息"))
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                        }
                        .buttonStyle(.pressable)
                        .padding(.vertical, 6)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        if i == 0 || m.time.timeIntervalSince(messages[i - 1].time) > 300 {
                            Text(stamp(m.time)).font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.top, 6)
                        }
                        MessageBubble(message: m, mine: m.sender == me, face: m.sender == me ? AppModel.shared.account.face : session.face)
                    }
                    if loading { ProgressView().controlSize(.small).padding(30) }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.text3).padding(20) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)

            Text(L("BiliMac 目前只能查看私信，回复请使用官方客户端"))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.elevated.opacity(0.5))
        }
        .task {
            do {
                let r = try await BiliAPI.shared.chatMessages(talker: session.talker, type: session.type)
                messages = r.list
                more = r.more
                center.opened(session, upTo: r.list.last?.seqno ?? 0)
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func loadOlder() async {
        guard !loadingOlder, let first = messages.first else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        if let r = try? await BiliAPI.shared.chatMessages(talker: session.talker, type: session.type, before: first.seqno) {
            let ids = Set(messages.map(\.id))
            messages = r.list.filter { !ids.contains($0.id) } + messages
            more = r.more && !r.list.isEmpty
        }
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        f.dateFormat = cal.isDateInToday(d) ? "HH:mm" : cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M-d HH:mm" : "yyyy-M-d HH:mm"
        return f.string(from: d)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let mine: Bool
    let face: URL?

    var body: some View {
        switch message.content {
        case .tip(let s):
            Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .withdrawn:
            Text(mine ? L("你撤回了一条消息") : L("对方撤回了一条消息")).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity)
        default:
            HStack(alignment: .top, spacing: 10) {
                if mine { Spacer(minLength: 60) } else { Avatar(url: face, size: 32) }
                content
                if mine { Avatar(url: face, size: 32) } else { Spacer(minLength: 60) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.content {
        case .text(let s):
            Text(s)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .foregroundStyle(mine ? Theme.onPink : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Theme.pink : Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: 460, alignment: mine ? .trailing : .leading)
        case .image(let url, let size):
            let s = fitted(size)
            Button { NSWorkspace.shared.open(url) } label: {
                RemoteImage(url: url, contentMode: .fill)
                    .frame(width: s.width, height: s.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.pressable)
        case .card(let title, let text, let links):
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty { Text(title).font(.system(size: 14, weight: .bold)) }
                if !text.isEmpty {
                    Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !links.isEmpty {
                    Rectangle().fill(Theme.line.opacity(0.4)).frame(height: 1)
                    ForEach(links, id: \.self) { l in
                        Button { openBiliLink(l.uri) } label: {
                            HStack {
                                Text(l.text).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(Theme.blue)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .foregroundStyle(Theme.text)
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .share(let title, let cover, let link):
            Button { if let link { openBiliLink(link) } } label: {
                HStack(spacing: 10) {
                    if let cover {
                        RemoteImage(url: URL(string: cover.absoluteString + "@240w_150h_1c.webp"))
                            .frame(width: 96, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(3).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.text)
                .padding(10)
                .frame(width: 320, alignment: .leading)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.pressable)
            .disabled(link == nil)
        case .unsupported, .tip, .withdrawn:
            Text(L("[暂不支持的消息，请在官方客户端查看]")).font(.system(size: 12.5)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func fitted(_ size: CGSize?) -> CGSize {
        guard let s = size, s.width > 0, s.height > 0 else { return CGSize(width: 200, height: 200) }
        let k = min(240 / s.width, 240 / s.height, 1)
        return CGSize(width: max(60, s.width * k), height: max(60, s.height * k))
    }
}

private struct SystemNoticeList: View {
    @ObservedObject private var center = MessageCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("系统通知")).font(.system(size: 15, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            Rectangle().fill(Theme.line.opacity(0.35)).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let list = center.system {
                        if list.isEmpty { Text(L("没有系统通知")).font(.system(size: 13)).foregroundStyle(Theme.text3).padding(30) }
                        ForEach(list) { n in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(n.title).font(.system(size: 14, weight: .bold))
                                    Spacer()
                                    Text(formatRelativeDate(n.time)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                }
                                Text(n.body).font(.system(size: 12.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let link = n.link {
                                    Button { openBiliLink(link) } label: {
                                        Text(L("查看详情")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.blue)
                                    }
                                    .buttonStyle(.pressable)
                                }
                            }
                            .foregroundStyle(Theme.text)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(30)
                    }
                }
                .padding(20)
            }
        }
        .task { await center.loadSystem() }
    }
}

// MARK: 回复我的 / @我的 / 收到的赞

private struct FeedList: View {
    let tab: MessageCenter.Tab
    @ObservedObject private var center = MessageCenter.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                let items = center.feeds[tab] ?? []
                ForEach(items) { n in FeedRow(notice: n) }
                if center.feedMore[tab] == true {
                    ProgressView().controlSize(.small).padding(14)
                        .task { await center.loadFeed(tab, more: true) }
                } else if center.feeds[tab] == nil {
                    ProgressView().controlSize(.small).padding(30)
                } else if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: emptyIcon).font(.system(size: 32, weight: .light))
                        Text(emptyText).font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 80)
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .task { await center.loadFeed(tab) }
    }

    private var emptyIcon: String {
        switch tab {
        case .reply: return "arrowshape.turn.up.left"
        case .at: return "at"
        default: return "hand.thumbsup"
        }
    }

    private var emptyText: String {
        switch tab {
        case .reply: return L("还没有人回复你")
        case .at: return L("还没有人 @ 你")
        default: return L("还没有收到赞")
        }
    }
}

private struct FeedRow: View {
    let notice: Notice
    @State private var hover = false

    var body: some View {
        Button { if let l = notice.link { openBiliLink(l) } } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(notice.people.prefix(3).enumerated().reversed()), id: \.offset) { i, p in
                        Avatar(url: p.face, size: notice.people.count > 1 ? 34 : 42)
                            .offset(x: CGFloat(i) * 14, y: CGFloat(i) * 6)
                    }
                }
                .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(names).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                        Text(notice.action).font(.system(size: 12.5)).foregroundStyle(Theme.text3).lineLimit(1)
                    }
                    if !notice.body.isEmpty {
                        Text(notice.body).font(.system(size: 13.5)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    }
                    if !notice.quote.isEmpty {
                        Text(notice.quote).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
                    }
                    Text(formatRelativeDate(notice.time)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 8)
                if let image = notice.image {
                    RemoteImage(url: URL(string: image.absoluteString + "@200w_126h_1c.webp"))
                        .frame(width: 100, height: 63)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .foregroundStyle(Theme.text)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
    }

    private var names: String {
        let n = notice.people.prefix(2).map(\.name).joined(separator: "、")
        return n.isEmpty ? L("有人") : n
    }
}
