import AppKit
import AVFoundation
import Compression
import SwiftUI
import VideoToolbox

// MARK: - Models

struct LiveRoomInfo {
    let roomId: Int
    let title: String
    let cover: URL?
    let live: Bool
    let uid: Int
    let uname: String
    let face: URL?
    let area: String
    let watched: String
    let online: Int
    var fans = 0
    var tags: [String] = []
    /// 主播公告 and the room's own description.
    var notice = ""
    var about = ""
    var official = ""
    var started: Date?
    var parentAreaId = 0
    var areaId = 0
    var areaName = ""
}

struct LiveStream {
    struct Quality: Hashable, Identifiable { let qn: Int; let name: String; var id: Int { qn } }
    let urls: [URL]
    let codec: String
    let qn: Int
    let qualities: [Quality]
}

struct LiveChatItem: Identifiable, Hashable {
    enum Kind: Hashable { case text, gift, superChat(price: Int), notice }
    /// 粉丝牌: the streamer's fan club badge the sender wears.
    struct Medal: Hashable { let name: String; let level: Int; let start: UInt32; let end: UInt32; let lit: Bool }
    struct Sticker: Hashable { let url: URL; let width: CGFloat; let height: CGFloat }
    let id = UUID()
    let kind: Kind
    let uname: String
    let text: String
    let color: UInt32
    var face: URL? = nil
    var medal: Medal? = nil
    /// 舰长 3 / 提督 2 / 总督 1, 0 = none.
    var guardLevel = 0
    var nameColor: UInt32? = nil
    var sticker: Sticker? = nil
    var giftIcon: URL? = nil
    /// SuperChat: header and body colors.
    var scTop: UInt32? = nil
    var scBody: UInt32? = nil

    static func hex(_ s: String?) -> UInt32? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        return UInt32(t, radix: 16)
    }

    static func medal(_ m: JSON?) -> Medal? {
        guard let m, let name = m.str("name") ?? m.str("medal_name"), !name.isEmpty,
              let level = m.int("level") ?? m.int("medal_level"), level > 0 else { return nil }
        let start = (m.int("color_start") ?? m.int("medal_color_start") ?? m.int("color") ?? m.int("medal_color") ?? 0x5762A799).asColor
        let end = (m.int("color_end") ?? m.int("medal_color_end") ?? 0).asColor
        return Medal(name: name, level: level, start: start, end: end == 0 ? start : end, lit: (m.int("is_light") ?? 1) == 1)
    }
}

private extension Int { var asColor: UInt32 { UInt32(truncatingIfNeeded: self) & 0xFFFFFF } }

// MARK: - API

extension BiliAPI {
    func liveRoom(_ roomId: Int) async throws -> LiveRoomInfo {
        // Signed like the website: unsigned, it answers -352 to visitors who aren't signed in.
        let d = try await signedGet("https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom",
                                    ["room_id": "\(roomId)", "web_location": "444.8"])
        let r = d.obj("room_info") ?? [:]
        let a = d.obj("anchor_info")?.obj("base_info") ?? [:]
        let about = plainTitle((r.str("description") ?? "").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveRoomInfo(roomId: r.int("room_id") ?? roomId, title: r.str("title") ?? "", cover: imageURL(r.str("cover") ?? r.str("keyframe")),
                            live: r.int("live_status") == 1, uid: r.int("uid") ?? 0, uname: a.str("uname") ?? "", face: imageURL(a.str("face")),
                            area: [r.str("parent_area_name"), r.str("area_name")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                            watched: d.obj("watched_show")?.str("text_large") ?? "", online: r.int("online") ?? 0,
                            fans: d.obj("anchor_info")?.obj("relation_info")?.int("attention") ?? 0,
                            tags: (r.str("tags") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                            notice: d.obj("news_info")?.str("content")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            about: about, official: a.obj("official_info")?.str("title") ?? "",
                            started: r.int("live_start_time").flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                            parentAreaId: r.int("parent_area_id") ?? 0, areaId: r.int("area_id") ?? 0, areaName: r.str("area_name") ?? "")
    }

    /// The fMP4 HLS stream (the TS one is slow or unreachable on some CDN nodes), HEVC when it decodes in hardware.
    func liveStream(_ roomId: Int, qn: Int) async throws -> LiveStream {
        let d = try await get("https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo", [
            "room_id": "\(roomId)", "protocol": "0,1", "format": "0,1,2", "codec": "0,1", "qn": "\(qn)", "platform": "web", "ptype": "8",
        ])
        guard let play = d.obj("playurl_info")?.obj("playurl") else { throw APIError(description: L("主播还没开播")) }
        let names = Dictionary(play.arr("g_qn_desc").compactMap { q in q.int("qn").map { ($0, q.str("desc") ?? "\($0)") } }, uniquingKeysWith: { a, _ in a })
        let hevcOK = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        var candidates: [(codec: String, json: JSON)] = []
        for s in play.arr("stream") where s.str("protocol_name") == "http_hls" {
            for f in s.arr("format") where f.str("format_name") == "fmp4" {
                for c in f.arr("codec") { candidates.append((c.str("codec_name") ?? "", c)) }
            }
        }
        guard let pick = candidates.first(where: { $0.codec == (hevcOK ? "hevc" : "avc") }) ?? candidates.first else {
            throw APIError(description: L("没有可播放的直播流"))
        }
        let c = pick.json
        let base = c.str("base_url") ?? ""
        let urls = c.arr("url_info").compactMap { u in URL(string: (u.str("host") ?? "") + base + (u.str("extra") ?? "")) }
        let accept = (c["accept_qn"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
        return LiveStream(urls: urls, codec: pick.codec, qn: c.int("current_qn") ?? qn,
                          qualities: accept.map { LiveStream.Quality(qn: $0, name: names[$0] ?? "\($0)") })
    }

    func liveDanmuInfo(_ roomId: Int) async throws -> (token: String, hosts: [String]) {
        let d = try await signedGet("https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
                                    ["id": "\(roomId)", "type": "0", "web_location": "444.8"])
        let hosts = d.arr("host_list").compactMap { h -> String? in
            guard let host = h.str("host") else { return nil }
            return "wss://\(host):\(h.int("wss_port") ?? 443)/sub"
        }
        return (d.str("token") ?? "", hosts.isEmpty ? ["wss://broadcastlv.chat.bilibili.com:443/sub"] : hosts)
    }

    func sendLiveDanmaku(roomId: Int, text: String) async throws {
        guard let csrf = CookieJar.shared["bili_jct"] else { throw APIError(description: L("需要登录")) }
        try await post("https://api.live.bilibili.com/msg/send", [
            "bubble": "0", "msg": text, "color": "16777215", "mode": "1", "room_type": "0", "jumpfrom": "0", "fontsize": "25",
            "rnd": "\(Int(Date().timeIntervalSince1970))", "roomid": "\(roomId)", "csrf_token": csrf,
        ])
    }
}

// MARK: - Live chat (bilibili's danmaku WebSocket)

/// Packets: 16-byte header (length, header length, protocol version, operation, sequence) + body. Op 7 authenticates,
/// op 2 is the 30 s heartbeat, op 5 carries messages (version 2 = zlib-compressed batch of packets).
final class LiveChat: @unchecked Sendable {
    var onItem: (@MainActor (LiveChatItem) -> Void)?
    var onWatched: (@MainActor (String) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var stopped = false

    func connect(roomId: Int, uid: Int?) async {
        stopped = false
        guard let info = try? await BiliAPI.shared.liveDanmuInfo(roomId), let url = URL(string: info.hosts.first ?? "") else {
            log("live chat: no danmu info for \(roomId)")
            return
        }
        var req = URLRequest(url: url)
        req.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        let t = URLSession.shared.webSocketTask(with: req)
        task = t
        t.resume()
        let auth: [String: Any] = ["uid": uid ?? 0, "roomid": roomId, "protover": 2, "buvid": CookieJar.shared["buvid3"] ?? "",
                                   "platform": "web", "type": 2, "key": info.token]
        send(op: 7, body: (try? JSONSerialization.data(withJSONObject: auth)) ?? Data())
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                self?.send(op: 2, body: Data("[object Object]".utf8))
                try? await Task.sleep(for: .seconds(30))
            }
        }
        receive()
    }

    func stop() {
        stopped = true
        heartbeat?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func send(op: UInt32, body: Data) {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        put32(UInt32(16 + body.count)); put16(16); put16(1); put32(op); put32(1)
        d.append(body)
        task?.send(.data(d)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(.data(let d)): self.parse(d)
            case .success: break
            case .failure(let e):
                log("live chat closed: \(e.localizedDescription)")
                return
            }
            self.receive()
        }
    }

    private func parse(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func u16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
        while i + 16 <= b.count {
            let len = u32(i), hlen = u16(i + 4), ver = u16(i + 6), op = u32(i + 8)
            guard len >= hlen, i + len <= b.count else { break }
            let body = Data(b[(i + hlen)..<(i + len)])
            if op == 5 {
                if ver == 2, let inflated = Self.zlib(body) { parse(inflated) }
                else if ver == 0 { handle(body) }
            }
            i += len
        }
    }

    private func handle(_ body: Data) {
        guard let j = (try? JSONSerialization.jsonObject(with: body)) as? JSON, let cmd = j.str("cmd") else { return }
        let d = j.obj("data") ?? [:]
        var item: LiveChatItem?
        switch cmd.split(separator: ":").first.map(String.init) ?? cmd {
        case "DANMU_MSG":
            guard let info = j["info"] as? [Any], info.count > 2, let text = info[1] as? String else { break }
            let meta = info[0] as? [Any] ?? []
            let user = info[2] as? [Any] ?? []
            let color = (meta.count > 3 ? meta[3] as? NSNumber : nil)?.uint32Value ?? 0xFFFFFF
            var it = LiveChatItem(kind: .text, uname: user.count > 1 ? (user[1] as? String ?? "") : "", text: text, color: color)
            // The newer user block (info[0][15].user) carries face, badge, guard and name colour.
            let u = (meta.count > 15 ? meta[15] as? JSON : nil)?.obj("user")
            if let base = u?.obj("base") {
                it.face = imageURL(base.str("face"))
                it.nameColor = LiveChatItem.hex(base.str("name_color_str"))
            }
            it.medal = LiveChatItem.medal(u?.obj("medal"))
                ?? (info.count > 3 ? info[3] as? [Any] : nil).flatMap { a -> LiveChatItem.Medal? in
                    guard a.count > 4, let lv = (a[0] as? NSNumber)?.intValue, let name = a[1] as? String, !name.isEmpty else { return nil }
                    let c = ((a[4] as? NSNumber)?.intValue ?? 0).asColor
                    return LiveChatItem.Medal(name: name, level: lv, start: c, end: c, lit: true)
                }
            it.guardLevel = (info.count > 7 ? (info[7] as? NSNumber)?.intValue : nil) ?? u?.obj("medal")?.int("guard_level") ?? 0
            // Room stickers (表情) come as an image; the text is only their name.
            if meta.count > 13, let e = meta[13] as? JSON, let url = imageURL(e.str("url")) {
                it.sticker = .init(url: url, width: CGFloat(e.double("width") ?? 60), height: CGFloat(e.double("height") ?? 60))
            }
            item = it
        case "SUPER_CHAT_MESSAGE":
            let ui = d.obj("user_info")
            var it = LiveChatItem(kind: .superChat(price: d.int("price") ?? 0), uname: ui?.str("uname") ?? "",
                                  text: d.str("message") ?? "", color: 0xFFFFFF)
            it.face = imageURL(ui?.str("face"))
            it.medal = LiveChatItem.medal(d.obj("medal_info"))
            it.scTop = LiveChatItem.hex(d.str("background_bottom_color"))
            it.scBody = LiveChatItem.hex(d.str("background_color"))
            item = it
        case "SEND_GIFT":
            var it = LiveChatItem(kind: .gift, uname: d.str("uname") ?? "",
                                  text: Lf("%@ %@ × %@", d.str("action") ?? L("投喂"), d.str("giftName") ?? "", "\(d.int("num") ?? 1)"),
                                  color: 0xFFFFFF)
            it.face = imageURL(d.str("face"))
            it.medal = LiveChatItem.medal(d.obj("medal_info"))
            it.giftIcon = imageURL(d.obj("gift_info")?.str("webp") ?? d.obj("gift_info")?.str("img_basic"))
            item = it
        case "WATCHED_CHANGE":
            if let t = d.str("text_large") { Task { @MainActor in self.onWatched?(t) } }
        default: break
        }
        if let item { Task { @MainActor in self.onItem?(item) } }
    }

    /// zlib stream (2-byte header) → raw deflate decode.
    static func zlib(_ d: Data) -> Data? {
        guard d.count > 2 else { return nil }
        let src = [UInt8](d.dropFirst(2))
        var cap = max(src.count * 8, 64 << 10)
        for _ in 0..<4 {
            var out = [UInt8](repeating: 0, count: cap)
            let n = compression_decode_buffer(&out, cap, src, src.count, nil, COMPRESSION_ZLIB)
            if n > 0 && n < cap { return Data(out.prefix(n)) }
            cap *= 4
        }
        return nil
    }
}

@MainActor
final class LiveChatStore: ObservableObject {
    @Published private(set) var items: [LiveChatItem] = []
    func append(_ new: [LiveChatItem]) {
        items.append(contentsOf: new)
        if items.count > 200 { items.removeFirst(items.count - 200) }
    }
}

// MARK: - Controller

@MainActor
final class LiveController: ObservableObject {
    let roomId: Int
    let player = AVPlayer()
    @Published private(set) var info: LiveRoomInfo?
    @Published private(set) var stream: LiveStream?
    @Published private(set) var error: String?
    @Published private(set) var playing = false
    /// The chat list has its own store, so new lines redraw only the list, never the player side.
    let chatStore = LiveChatStore()
    @Published private(set) var watched = ""
    @Published private(set) var following: Bool?
    @Published private(set) var moreRooms: [LiveRoomCard] = []
    /// Scrolling danmaku over the picture (not published: only its canvas redraws).
    let danmakuLayer = LiveDanmakuLayer()
    /// Chat lines arrive in bursts; they reach the list a few times a second, not one page update each.
    private var pending: [LiveChatItem] = []
    private var flushTask: Task<Void, Never>?
    let opened = Date()
    private let liveChat = LiveChat()
    private var hostIndex = 0
    private var statusObs: NSKeyValueObservation?
    private var statsTask: Task<Void, Never>?

    private var bufferAhead: Double {
        guard let item = player.currentItem, let r = item.loadedTimeRanges.last?.timeRangeValue else { return 0 }
        return (r.start + r.duration - item.currentTime()).seconds
    }
    private var rateObs: NSKeyValueObservation?

    init(roomId: Int) {
        self.roomId = roomId
        player.volume = AppSettings.shared.volume
        rateObs = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let on = p.timeControlStatus == .playing
            Task { @MainActor in self?.playing = on }
        }
    }

    func start() async {
        do {
            let i = try await BiliAPI.shared.liveRoom(roomId)
            info = i
            watched = i.watched
            guard i.live else { error = L("主播还没开播"); return }
            try await play(qn: 10000)
            liveChat.onItem = { [weak self] item in self?.received(item) }
            liveChat.onWatched = { [weak self] t in self?.watched = t }
            let uid = AppModel.shared.account.mid
            Task { await liveChat.connect(roomId: i.roomId, uid: uid) }
            Task {
                // Same area, most popular first, without this room.
                let list = (try? await BiliAPI.shared.liveAreaRooms(parent: i.parentAreaId, area: i.areaId, sort: "online", page: 1)) ?? []
                moreRooms = Array(list.filter { $0.roomId != i.roomId }.prefix(8))
            }
            if AppModel.shared.account.loggedIn {
                Task { following = (try? await BiliAPI.shared.space(mid: i.uid))?.following }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func play(qn: Int) async throws {
        let s = try await BiliAPI.shared.liveStream(info?.roomId ?? roomId, qn: qn)
        stream = s
        hostIndex = 0
        attach()
    }

    func setQuality(_ qn: Int) {
        guard qn != stream?.qn else { return }
        Task { do { try await play(qn: qn) } catch { self.error = error.localizedDescription } }
    }

    /// Next CDN host when one fails.
    private func attach() {
        guard let s = stream, hostIndex < s.urls.count else { error = L("直播流加载失败"); return }
        let item = AVPlayerItem(url: s.urls[hostIndex])
        // Segments are 1 s long: sitting right at the live edge stalls on the smallest hiccup. A few seconds
        // behind it plays smoothly.
        item.configuredTimeOffsetFromLive = CMTime(seconds: 6, preferredTimescale: 600)
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.preferredForwardBufferDuration = 6
        statusObs = item.observe(\.status) { [weak self] it, _ in
            guard it.status == .failed else { return }
            Task { @MainActor in
                guard let self else { return }
                log("live \(self.roomId) host \(self.hostIndex) failed: \(String(describing: it.error))")
                self.hostIndex += 1
                self.attach()
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        error = nil
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            // Every 10 s: what the stream and the decoder are doing (for "the picture stutters" reports).
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let e = self.player.currentItem?.accessLog()?.events.last else { continue }
                log(String(format: "live %d: %@ %.1f Mbps (link %.1f) dropped %d stalls %d buffer %.1fs status %d",
                           self.roomId, self.stream?.codec ?? "", e.indicatedBitrate / 1e6, e.observedBitrate / 1e6,
                           e.numberOfDroppedVideoFrames, e.numberOfStalls, self.bufferAhead, self.player.timeControlStatus.rawValue))
            }
        }
    }

    private func received(_ item: LiveChatItem) {
        if case .text = item.kind, AppSettings.shared.danmakuOn {
            danmakuLayer.add(item.text, color: item.color, at: Date().timeIntervalSinceReferenceDate)
        }
        pending.append(item)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.chatStore.append(self.pending)
            self.pending = []
            self.flushTask = nil
        }
    }

    func togglePlay() {
        if player.timeControlStatus == .paused {
            // Back to the live edge, not where it stopped.
            if let end = player.currentItem?.seekableTimeRanges.last?.timeRangeValue.end { player.seek(to: end) }
            player.play()
        } else {
            player.pause()
        }
    }

    func toggleFollow() {
        guard let i = info else { return }
        guard AppModel.shared.account.loggedIn else { AppModel.shared.showLogin = true; return }
        let on = !(following ?? false)
        Task {
            do {
                try await BiliAPI.shared.follow(mid: i.uid, on)
                following = on
                AppModel.shared.notify(on ? L("已关注") : L("已取消关注"))
            } catch { AppModel.shared.notify(Lf("操作失败：%@", "\(error.localizedDescription)")) }
        }
    }

    func setVolume(_ v: Float) {
        player.volume = v
        AppSettings.shared.volume = v
    }

    func stop() {
        statsTask?.cancel()
        liveChat.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func send(_ text: String) async -> Bool {
        do {
            try await BiliAPI.shared.sendLiveDanmaku(roomId: info?.roomId ?? roomId, text: text)
            return true
        } catch {
            AppModel.shared.notify(Lf("弹幕发送失败：%@", error.localizedDescription))
            return false
        }
    }
}

// MARK: - Page

struct LivePage: View {
    @StateObject private var live: LiveController
    @ObservedObject private var settings = AppSettings.shared
    @State private var hover = false
    @State private var lastMove = Date()
    @State private var draft = ""
    private var app: AppModel { AppModel.shared }

    init(roomId: Int) { _live = StateObject(wrappedValue: LiveController(roomId: roomId)) }

    var body: some View {
        HStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    player
                    if let i = live.info {
                        header(i)
                        details(i)
                    }
                    if !live.moreRooms.isEmpty {
                        Text(Lf("更多「%@」直播", live.info?.areaName ?? "")).font(.system(size: 17, weight: .bold)).padding(.top, 6)
                        LiveGrid(rooms: live.moreRooms)
                    }
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            chatPanel
                .frame(width: 320)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .task {
            app.nowPlaying?.pause()
            await live.start()
        }
        .onDisappear { live.stop() }
    }

    private var player: some View {
        ZStack {
            Color.black
            VideoLayer(player: live.player)
            if settings.danmakuOn { LiveDanmakuCanvas(layer: live.danmakuLayer) }
            if let e = live.error {
                VStack(spacing: 10) {
                    if let c = live.info?.cover {
                        RemoteImage(url: thumbnail(c, width: 640), contentMode: .fill).frame(width: 320, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).opacity(0.6)
                    }
                    Text(e).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
            } else if live.stream == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            controls.opacity(hover ? 1 : 0).animation(.easeOut(duration: 0.2), value: hover)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onContinuousHover { phase in
            switch phase {
            case .active: hover = true; lastMove = Date()
            case .ended: hover = false
            }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(.white).frame(width: 6, height: 6)
                    Text(L("直播中")).font(.system(size: 11.5, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.pink, in: Capsule())
                if !live.watched.isEmpty { Text(live.watched).font(.system(size: 12, weight: .semibold)) }
                Spacer()
            }
            .padding(12)
            Spacer()
            HStack(spacing: 10) {
                Button { live.togglePlay() } label: {
                    Image(systemName: live.playing ? "pause.fill" : "play.fill").font(.system(size: 16)).frame(width: 30, height: 30)
                }
                .buttonStyle(.pressable)
                .help(live.playing ? L("暂停") : L("回到直播"))
                Spacer()
                if let s = live.stream, s.qualities.count > 1 {
                    Menu {
                        ForEach(s.qualities) { q in
                            Button { live.setQuality(q.qn) } label: {
                                if q.qn == s.qn { Label(q.name, systemImage: "checkmark") } else { Text(q.name) }
                            }
                        }
                    } label: {
                        Text(s.qualities.first { $0.qn == s.qn }?.name ?? L("画质")).font(.system(size: 12.5, weight: .bold))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                Button { settings.danmakuOn.toggle() } label: {
                    Image(systemName: settings.danmakuOn ? "text.bubble.fill" : "text.bubble").font(.system(size: 15))
                        .foregroundStyle(settings.danmakuOn ? Theme.pink : .white)
                }
                .buttonStyle(.pressable)
                .help(L("弹幕 D"))
                Image(systemName: live.player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13))
                ThinSlider(value: Binding(get: { Double(live.player.volume) }, set: { live.setVolume(Float($0)) })).frame(width: 80)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                }
                .buttonStyle(.pressable)
                .help(L("屏幕全屏 F"))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
    }

    private func header(_ i: LiveRoomInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { app.go(.space(i.uid)) } label: { Avatar(url: i.face, size: 52) }
                .buttonStyle(.pressable)
                .help(L("查看 UP 主主页"))
            VStack(alignment: .leading, spacing: 5) {
                Text(i.title).font(.system(size: 19, weight: .bold)).lineLimit(2)
                HStack(spacing: 0) {
                    OwnerLink(name: i.uname, mid: i.uid, font: .system(size: 13.5, weight: .semibold), color: Theme.text2)
                    Text([i.area, live.watched, i.started.map { Lf("开播 %@", liveSince($0)) } ?? ""]
                        .filter { !$0.isEmpty }.map { " · " + $0 }.joined())
                        .font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            Spacer()
            Button { live.toggleFollow() } label: {
                VStack(spacing: 1) {
                    Text(live.following == true ? L("已关注") : L("+ 关注")).font(.system(size: 13, weight: .bold))
                    if i.fans > 0 { Text(Lf("%@粉丝", formatCount(i.fans))).font(.system(size: 10.5)).opacity(0.8) }
                }
                .foregroundStyle(live.following == true ? Theme.text2 : Theme.onPrimary)
                .padding(.horizontal, 16).frame(height: 40)
                .background(live.following == true ? Theme.chip : Theme.primary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.pressable)
            Button { NSWorkspace.shared.open(URL(string: "https://live.bilibili.com/\(i.roomId)")!) } label: {
                Image(systemName: "safari").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32).background(Theme.chip, in: Circle())
            }
            .buttonStyle(.pressable)
            .help(L("在浏览器中打开"))
        }
    }

    /// Tags, the streamer's notice, the room description and verification, as cards.
    @ViewBuilder private func details(_ i: LiveRoomInfo) -> some View {
        if !i.tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(i.tags, id: \.self) { t in
                    Text(t).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10).frame(height: 26).background(Theme.chip, in: Capsule())
                }
            }
        }
        let cards = [(L("主播公告"), i.notice), (L("房间简介"), i.about), (L("认证"), i.official)].filter { !$0.1.isEmpty }
        if !cards.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(cards, id: \.0) { title, text in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.text3)
                        Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.text).textSelection(.enabled)
                            .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(Theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    /// "2 小时 5 分" since the stream started.
    private func liveSince(_ d: Date) -> String {
        let m = max(0, Int(Date().timeIntervalSince(d) / 60))
        return m >= 60 ? Lf("%@ 小时 %@ 分", "\(m / 60)", "\(m % 60)") : Lf("%@ 分钟", "\(m)")
    }

    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("弹幕")).font(.system(size: 15, weight: .bold)).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ChatLines(store: live.chatStore)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                }
                .defaultScrollAnchor(.bottom)
                .onReceive(live.chatStore.$items) { _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider().opacity(0.4)
            if app.account.loggedIn {
                HStack(spacing: 8) {
                    TextField(L("发个弹幕"), text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(Theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { send() }
                    Button(L("发送")) { send() }
                        .buttonStyle(.pressable)
                        .font(.system(size: 12.5, weight: .bold))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(10)
            } else {
                Button { app.showLogin = true } label: {
                    Text(L("登录后才能发弹幕")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        Task { if await live.send(t) { draft = "" } }
    }
}

private struct ChatLines: View {
    @ObservedObject var store: LiveChatStore
    var body: some View { ForEach(store.items) { ChatLine(item: $0).id($0.id) } }
}

private struct ChatLine: View {
    let item: LiveChatItem
    @State private var hover = false

    var body: some View {
        Group {
            switch item.kind {
            case .superChat(let price): superChat(price)
            case .gift: gift
            default: danmaku
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// [粉丝牌] name：message, the way the official chat reads; stickers as images.
    private var danmaku: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if item.guardLevel > 0 { GuardMark(level: item.guardLevel) }
            if let m = item.medal { MedalBadge(medal: m) }
            if item.sticker == nil {
                (Text(item.uname + "：").foregroundColor(nameColor) + Text(item.text).foregroundColor(Theme.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(item.uname + "：").font(.system(size: 13.5)).foregroundStyle(nameColor)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(hover ? Theme.text.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
        .modifier(StickerBelow(sticker: item.sticker))
    }

    private var nameColor: Color {
        if let c = item.nameColor, c != 0 { return Color(hex: c) }
        return item.guardLevel > 0 ? Color(hex: 0xE15D8A) : Theme.text3
    }

    private var gift: some View {
        HStack(spacing: 8) {
            if let icon = item.giftIcon {
                RemoteImage(url: icon, contentMode: .fit).frame(width: 26, height: 26)
            } else {
                Image(systemName: "gift.fill").font(.system(size: 13)).foregroundStyle(Color(hex: 0xF0A24A)).frame(width: 26, height: 26)
            }
            (Text(item.uname + " ").foregroundColor(Theme.text2) + Text(item.text).foregroundColor(Color(hex: 0xF0A24A)))
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF0A24A).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Two-tone card like the official SuperChat: who and how much on top, the message below.
    private func superChat(_ price: Int) -> some View {
        let top = Color(hex: item.scTop ?? 0x2A60B2), body = Color(hex: item.scBody ?? 0xEDF5FF)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Avatar(url: item.face, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.uname).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                    if let m = item.medal { MedalBadge(medal: m) }
                }
                Spacer(minLength: 4)
                Text("¥\(price)").font(.system(size: 14, weight: .heavy)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(top)
            Text(item.text).font(.system(size: 13.5)).foregroundStyle(.black.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(body)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 3)
    }
}

/// 粉丝牌: the club name on the colour gradient, the level in a white box, dimmed when unlit.
private struct MedalBadge: View {
    let medal: LiveChatItem.Medal
    var body: some View {
        HStack(spacing: 0) {
            Text(medal.name).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 4)
            Text("\(medal.level)").font(.system(size: 10, weight: .heavy)).monospacedDigit()
                .foregroundStyle(Color(hex: medal.start))
                .padding(.horizontal, 3)
                .frame(minWidth: 16)
                .background(.white)
        }
        .frame(height: 16)
        .background(LinearGradient(colors: [Color(hex: medal.start), Color(hex: medal.end)], startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(hex: medal.start), lineWidth: 1))
        .opacity(medal.lit ? 1 : 0.45)
        .fixedSize()
        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3.5 }
    }
}

/// 舰长 / 提督 / 总督.
private struct GuardMark: View {
    let level: Int
    var body: some View {
        Image(systemName: "sailboat.fill")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(level == 1 ? Color(hex: 0xE5484D) : level == 2 ? Color(hex: 0xA855F7) : Color(hex: 0x3B82F6))
            .help(level == 1 ? L("总督") : level == 2 ? L("提督") : L("舰长"))
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
    }
}

/// A sticker message: the image under the name, at a modest size.
private struct StickerBelow: ViewModifier {
    let sticker: LiveChatItem.Sticker?
    func body(content: Content) -> some View {
        if let s = sticker {
            VStack(alignment: .leading, spacing: 2) {
                content
                let h = min(48, s.height)
                RemoteImage(url: s.url, contentMode: .fit)
                    .frame(width: h * max(0.3, s.width / max(s.height, 1)), height: h)
                    .padding(.leading, 6)
            }
        } else {
            content
        }
    }
}
