import SwiftUI

/// 直播 in the sidebar: recommended rooms, or one area's rooms by popularity or newest.
struct LiveArea: Identifiable, Hashable {
    let id: Int
    let name: String
}

extension BiliAPI {
    func liveRecommend(page: Int) async throws -> [LiveRoomCard] {
        let d = try await signedGet("https://api.live.bilibili.com/xlive/web-interface/v1/second/getUserRecommend",
                                    ["page": "\(page)", "page_size": "30", "platform": "web", "web_location": "444.8"])
        return d.arr("list").compactMap(LiveRoomCard.parse)
    }

    func liveAreas() async throws -> [LiveArea] {
        let url = URL(string: "https://api.live.bilibili.com/room/v1/Area/getList")!
        let (obj, _) = try await rawJSON(url)
        return ((obj["data"] as? [JSON]) ?? []).compactMap { a in a.int("id").map { LiveArea(id: $0, name: a.str("name") ?? "") } }
    }

    /// The newer area endpoint answers -352; this older one still works signed in or not.
    func liveAreaRooms(parent: Int, sort: String, page: Int) async throws -> [LiveRoomCard] {
        let url = URL(string: "https://api.live.bilibili.com/room/v3/area/getRoomList?parent_area_id=\(parent)&area_id=0&page=\(page)&page_size=30&sort_type=\(sort)&platform=web")!
        let (obj, _) = try await rawJSON(url)
        let d = obj["data"] as? JSON
        return ((d?["list"] as? [JSON]) ?? []).compactMap(LiveRoomCard.parse)
    }
}

@MainActor
final class LiveHomeModel: ObservableObject {
    static let shared = LiveHomeModel()
    /// 0 = 推荐.
    @Published var area = 0 { didSet { if area != oldValue { Task { await reload() } } } }
    @Published var sort = "online" { didSet { if sort != oldValue { Task { await reload() } } } }
    @Published private(set) var areas: [LiveArea] = []
    @Published private(set) var rooms: [LiveRoomCard] = []
    @Published private(set) var loading = false
    @Published private(set) var more = true
    @Published private(set) var error: String?
    private var page = 1
    private var generation = 0

    func start() async {
        if areas.isEmpty { areas = (try? await BiliAPI.shared.liveAreas()) ?? [] }
        if rooms.isEmpty { await reload() }
    }

    func reload() async {
        generation += 1
        page = 1
        more = true
        rooms = []
        loading = false
        await loadMore()
    }

    func loadMore() async {
        guard !loading, more else { return }
        loading = true
        let gen = generation
        defer { if gen == generation { loading = false } }
        do {
            let list = area == 0 ? try await BiliAPI.shared.liveRecommend(page: page)
                                 : try await BiliAPI.shared.liveAreaRooms(parent: area, sort: sort, page: page)
            guard gen == generation else { return }
            let seen = Set(rooms.map(\.id))
            rooms += list.filter { !seen.contains($0.id) }
            more = !list.isEmpty && page < 10
            page += 1
            error = nil
        } catch {
            guard gen == generation, (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
            more = false
        }
    }
}

struct LiveHomePage: View {
    @ObservedObject private var model = LiveHomeModel.shared

    var body: some View {
        MainPanel(tint: Theme.tint(hex: 0x4A2A3D, light: 0xF6DCE6)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L("直播")).font(.system(size: 30, weight: .black))
                    // Followed streamers who are live (signed in); hides itself otherwise.
                    LiveNowStrip()
                    ScrollView(.horizontal, showsIndicators: false) {
                        SlidingChips(options: [(0, L("推荐"))] + model.areas.map { ($0.id, $0.name) }, selection: $model.area)
                    }
                    if model.area != 0 {
                        SlidingChips(options: [("online", L("人气最高")), ("live_time", L("最新开播"))], selection: $model.sort, style: .white)
                    }
                    LiveGrid(rooms: model.rooms)
                    HStack {
                        Spacer()
                        if model.loading { ProgressView().controlSize(.small) }
                        else if let e = model.error {
                            PillButton(title: L("重试")) { Task { await model.reload() } }
                            Text(e).font(.system(size: 12)).foregroundStyle(Theme.text3)
                        } else if model.more {
                            // onAppear + Task: survives this view being swapped for the spinner.
                            Color.clear.frame(height: 1).onAppear { Task { await model.loadMore() } }
                        } else if model.rooms.isEmpty {
                            Text(L("没有正在直播的直播间")).font(.system(size: 13)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .task { await model.start() }
    }
}
