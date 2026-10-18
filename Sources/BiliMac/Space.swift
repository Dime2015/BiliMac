import AppKit
import SwiftUI

/// UP 主主页: banner, avatar, counts, follow, their videos and their 合集 / 系列.
@MainActor
final class SpaceModel: ObservableObject {
    enum Tab: Hashable { case videos, collections }
    let mid: Int
    @Published var info: SpaceInfo?
    @Published var error: String?
    @Published var order = "pubdate"
    @Published var tab = Tab.videos
    @Published var collections: [SpaceCollection] = []
    @Published var tint: Color = Theme.defaultTint

    init(mid: Int) {
        self.mid = mid
        if Env.spaceTab == "collections" { tab = .collections }
    }

    func load() async {
        guard info == nil else { return }
        async let cs = try? BiliAPI.shared.spaceCollections(mid: mid)
        do {
            let i = try await BiliAPI.shared.space(mid: mid)
            info = i
            if let t = await TintCache.shared.tint(for: i.face) { tint = t }
        } catch {
            self.error = error.localizedDescription
        }
        collections = await cs ?? []
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
    /// Not observed: the grid should redraw only when its own list changes.
    private var app: AppModel { AppModel.shared }
    let mid: Int
    @StateObject private var model: SpaceModel

    init(mid: Int) {
        self.mid = mid
        _model = StateObject(wrappedValue: SpaceModel(mid: mid))
    }

    var body: some View {
        MainPanel(tint: model.tint) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SpaceHeader(model: model)
                    HStack {
                        if model.collections.isEmpty {
                            Text(L("投稿视频")).font(.system(size: 22, weight: .black))
                        } else {
                            SlidingChips(options: [(SpaceModel.Tab.videos, L("投稿视频")),
                                                   (.collections, Lf("合集与系列 %@", "\(model.collections.count)"))],
                                         selection: $model.tab)
                        }
                        Spacer()
                        if model.tab == .videos {
                            SlidingChips(options: [("pubdate", L("最新发布")), ("click", L("最多播放"))], selection: $model.order, style: .white)
                        }
                    }
                    switch model.tab {
                    case .videos:
                        ShelfGrid(list: app.list(for: "space:\(mid):\(model.order)"), emptyText: L("这位 UP 主还没有投稿"))
                            .id(model.order)
                            .padding(.horizontal, -10)
                    case .collections:
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 214, maximum: 330), spacing: 8, alignment: .top)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(model.collections) { c in
                                Button { app.open(c) } label: { CollectionCard(collection: c) }
                                    .buttonStyle(.pressableCard)
                            }
                        }
                        .padding(.horizontal, -10)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .task { await model.load() }
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
                    Text(i?.name ?? " ")
                        .font(.system(size: 40, weight: .black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
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
