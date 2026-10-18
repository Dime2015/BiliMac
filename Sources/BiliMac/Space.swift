import AppKit
import SwiftUI

/// UP 主主页: banner, avatar, counts, follow, and their videos.
@MainActor
final class SpaceModel: ObservableObject {
    let mid: Int
    @Published var info: SpaceInfo?
    @Published var error: String?
    @Published var order = "pubdate"
    @Published var tint: Color = Theme.defaultTint

    init(mid: Int) { self.mid = mid }

    func load() async {
        guard info == nil else { return }
        do {
            let i = try await BiliAPI.shared.space(mid: mid)

            info = i
            if let t = await TintCache.shared.tint(for: i.face) { tint = t }
        } catch {
            self.error = error.localizedDescription
        }
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
                        Text(L("投稿视频")).font(.system(size: 22, weight: .black))
                        Spacer()
                        SlidingChips(options: [("pubdate", L("最新发布")), ("click", L("最多播放"))], selection: $model.order, style: .white)
                    }
                    ShelfGrid(list: app.list(for: "space:\(mid):\(model.order)"), emptyText: L("这位 UP 主还没有投稿"))
                        .id(model.order)
                        .padding(.horizontal, -10)
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
        }
        .task { await model.load() }
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
                CircleIconButton(icon: "safari", label: L("在浏览器中打开个人空间")) {
                    NSWorkspace.shared.open(URL(string: "https://space.bilibili.com/\(model.mid)")!)
                }
                .help(L("在浏览器中打开个人空间"))
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
