import SwiftUI

// Ways into live rooms besides search: followed streamers who are live (动态 + sidebar), and 直播中 badges
// next to an uploader's name when they are streaming.

struct LiveNow: Identifiable, Hashable {
    let roomId: Int
    let uid: Int
    let uname: String
    let title: String
    let face: URL?
    var id: Int { uid }

    init?(_ j: JSON) {
        guard let room = j.int("room_id") ?? j.int("roomid"), room > 0 else { return nil }
        roomId = room
        uid = j.int("uid") ?? j.int("mid") ?? 0
        uname = j.str("uname") ?? ""
        title = j.str("title") ?? ""
        face = imageURL(j.str("face"))
    }
}

extension BiliAPI {
    /// Followed streamers who are live now (signed in only), and how many there are in all.
    func followedLive() async throws -> (rooms: [LiveNow], count: Int) {
        do {
            let d = try await get("https://api.live.bilibili.com/xlive/web-ucenter/v1/xfetter/GetWebList",
                                  ["page": "1", "page_size": "30"])
            // `rooms` and `list` can carry the same streamers: keep each one once.
            var seen = Set<Int>()
            let rooms = (d.arr("rooms") + d.arr("list")).compactMap(LiveNow.init).filter { seen.insert($0.uid > 0 ? $0.uid : -$0.roomId).inserted }
            return (rooms, max(min(d.int("count") ?? 0, rooms.count), rooms.count))
        } catch {
            // The 动态 page's own source: the live_users row of the portal.
            log("GetWebList: \(error.localizedDescription), trying the 动态 portal")
            let u = try await get("https://api.bilibili.com/x/polymer/web-dynamic/v1/portal").obj("live_users") ?? [:]
            var seen = Set<Int>()
            let rooms = u.arr("items").compactMap(LiveNow.init).filter { seen.insert($0.uid > 0 ? $0.uid : -$0.roomId).inserted }
            return (rooms, max(u.int("count") ?? 0, rooms.count))
        }
    }

    /// Which of these users are live now (uid → room). Public: works signed out, no WBI signature.
    func liveStatus(uids: [Int]) async throws -> [Int: LiveNow] {
        var c = URLComponents(string: "https://api.live.bilibili.com/room/v1/Room/get_status_info_by_uids")!
        c.queryItems = uids.map { URLQueryItem(name: "uids[]", value: "\($0)") }
        let d = try await call(c.url!)
        var out: [Int: LiveNow] = [:]
        for case let r as JSON in d.values where r.int("live_status") == 1 {
            if let l = LiveNow(r), l.uid > 0 { out[l.uid] = l }
        }
        return out
    }
}

@MainActor
final class LiveNowCenter: ObservableObject {
    static let shared = LiveNowCenter()

    /// Followed streamers live now, for the 动态 strip and the sidebar count.
    @Published private(set) var followed: [LiveNow] = []
    @Published private(set) var followedCount = 0

    /// Test switch: BILIMAC_LIVE_UIDS=uid,uid… fills the followed list from these users (works signed out).
    static let testUIDs: [Int]? = ProcessInfo.processInfo.environment["BILIMAC_LIVE_UIDS"]
        .map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    private var pollTask: Task<Void, Never>?
    private var cache: [Int: (room: LiveNow?, at: Date)] = [:]
    private var pending: [Int: Task<[Int: LiveNow]?, Never>] = [:]

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFollowed()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        followed = []
        followedCount = 0
    }

    func refreshFollowed() async {
        if let uids = Self.testUIDs {
            guard let m = try? await BiliAPI.shared.liveStatus(uids: uids) else { return }
            followed = uids.compactMap { m[$0] }
            followedCount = followed.count
            return
        }
        guard AppModel.shared.account.loggedIn, !Env.demo else { return }
        guard let r = try? await BiliAPI.shared.followedLive() else { return }
        followed = r.rooms
        followedCount = r.count
        let now = Date()
        for l in r.rooms { cache[l.uid] = (l, now) }
    }

    /// The user's live room if they are streaming now; checked at most every 3 minutes per user.
    func room(for uid: Int) async -> LiveNow? {
        if let c = cache[uid], Date().timeIntervalSince(c.at) < 180 { return c.room }
        let task = pending[uid] ?? Task { try? await BiliAPI.shared.liveStatus(uids: [uid]) }
        pending[uid] = task
        let result = await task.value
        pending[uid] = nil
        // A failed check isn't remembered, so the next look tries again.
        guard let result else { return cache[uid]?.room }
        cache[uid] = (result[uid], Date())
        return result[uid]
    }
}

// MARK: - Views

/// "● 直播中" next to an uploader's name while they stream; opens the room.
struct LiveBadge: View {
    let uid: Int?
    var large = false
    @State private var room: LiveNow?

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let room {
                Button { AppModel.shared.openLive(room.roomId) } label: {
                    HStack(spacing: large ? 5 : 4) {
                        Circle().fill(.white).frame(width: large ? 7 : 5, height: large ? 7 : 5)
                        Text(L("直播中")).font(.system(size: large ? 13 : 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, large ? 10 : 7)
                    .frame(height: large ? 26 : 19)
                    .background(Theme.pink, in: Capsule())
                    .fixedSize()
                }
                .buttonStyle(.pressable)
                .hoverCursor()
                .help(room.title.isEmpty ? L("进入直播间") : Lf("进入直播间：%@", room.title))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .task(id: uid) {
            room = nil
            guard let uid, uid > 0 else { return }
            let r = await LiveNowCenter.shared.room(for: uid)
            if !Task.isCancelled { withAnimation(Motion.pop) { room = r } }
        }
    }
}

/// Pink count of followed streamers who are live, for the sidebar's 动态 row.
struct LiveCountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle().fill(.white).frame(width: 5, height: 5)
                Text(count > 99 ? "99+" : "\(count)").font(.system(size: 10.5, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(Theme.pink, in: Capsule())
            .help(Lf("%@ 位关注的主播正在直播", "\(count)"))
        }
    }
}

/// 正在直播: followed streamers who are live, at the top of 动态.
struct LiveNowStrip: View {
    @ObservedObject private var center = LiveNowCenter.shared

    var body: some View {
        if !center.followed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L("正在直播")).font(.system(size: 17, weight: .bold))
                    Text("\(center.followedCount)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3).monospacedDigit()
                    Spacer()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(center.followed) { LiveNowCell(room: $0) }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .transition(.opacity)
        }
    }
}

private struct LiveNowCell: View {
    let room: LiveNow
    @State private var hover = false

    var body: some View {
        Button { AppModel.shared.openLive(room.roomId) } label: {
            VStack(spacing: 6) {
                Avatar(url: room.face, size: 56)
                    .padding(3)
                    .overlay(Circle().strokeBorder(Theme.pink, lineWidth: 2))
                    .overlay(alignment: .bottom) {
                        Text(L("直播")).font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 15)
                            .background(Theme.pink, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.panel, lineWidth: 1.5))
                            .offset(y: 5)
                    }
                    .scaleEffect(hover ? 1.05 : 1)
                    .animation(Motion.pop, value: hover)
                Text(room.uname).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover ? Theme.text : Theme.text2)
                    .lineLimit(1)
                    .frame(width: 74)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(room.title.isEmpty ? room.uname : "\(room.uname)：\(room.title)")
    }
}
