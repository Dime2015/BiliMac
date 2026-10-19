import SwiftUI

struct HomePage: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let list = app.list(for: app.homeTab.key)
        MainPanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SlidingChips(options: HomeTab.allCases.map { ($0, L($0.rawValue)) }, selection: $app.homeTab)
                    Text(app.greeting).font(.system(size: 30, weight: .black))
                    if app.account.loggedIn {
                        ContinueGrid(list: app.list(for: "history"))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(sectionTitle).font(.system(size: 22, weight: .bold))
                            Spacer()
                            Button(app.homeTab == .recommend ? L("换一换") : L("刷新")) { Task { await list.reload() } }
                                .buttonStyle(.pressable)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(Theme.text2)
                        }
                        .padding(.horizontal, 10)
                        ShelfGrid(list: list, ranked: app.homeTab == .ranking)
                    }
                    .padding(.horizontal, -10)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .id(app.homeTab)
        }
    }

    private var sectionTitle: String {
        switch app.homeTab {
        case .recommend: return L("为你推荐")
        case .popular: return L("当下热门")
        case .ranking: return L("全站排行")
        }
    }
}

private struct ContinueGrid: View {
    /// Not observed: grids should redraw only when their own list changes, not on every app-state change.
    private var app: AppModel { AppModel.shared }
    @ObservedObject var list: PagedList
    var body: some View {
        let items = Array(list.items.filter { ($0.progress ?? 0) > 0 }.prefix(6))
        Group {
            if !items.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(items) { c in
                        Button { app.open(c) } label: { QuickTile(card: c) }
                            .buttonStyle(.pressableCard)
                            .contextMenu { CardMenu(card: c) }
                    }
                }
            }
        }
        .task { if list.isEmptyAndIdle { await list.loadMore() } }
    }
}

struct ShelfGrid: View {
    /// Not observed: grids should redraw only when their own list changes, not on every app-state change.
    private var app: AppModel { AppModel.shared }
    @ObservedObject var list: PagedList
    var ranked = false
    var emptyText = L("这里还没有内容")
    var removeAction: ((VideoCard) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 214, maximum: 330), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(Array(list.items.enumerated()), id: \.element.id) { i, card in
                    Button { app.open(card) } label: {
                        ShelfCard(card: card, rank: ranked ? i + 1 : nil)
                    }
                    .buttonStyle(.pressableCard)
                    .entrance(i, id: card.id, list: list)
                    .contextMenu { CardMenu(card: card, removeAction: removeAction) }
                    .onAppear { if i >= list.items.count - 8 { Task { await list.loadMore() } } }
                }
            }
            HStack {
                Spacer()
                if list.loading {
                    ProgressView().controlSize(.small)
                } else if let e = list.error {
                    VStack(spacing: 10) {
                        Text(e).foregroundStyle(Theme.text2)
                        PillButton(title: L("重试")) { Task { await list.loadMore() } }
                    }
                } else if list.exhausted {
                    Text(list.items.isEmpty ? emptyText : L("没有更多了")).font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.vertical, 20)
        }
        .task { if list.isEmptyAndIdle { await list.loadMore() } }
    }
}

/// Playlist-style page: kicker, huge title, grid.
struct ListPage: View {
    /// Not observed: grids should redraw only when their own list changes, not on every app-state change.
    private var app: AppModel { AppModel.shared }
    let kicker: String
    let title: String
    let subtitle: String?
    let key: String
    var emptyText = L("这里还没有内容")
    var removeAction: ((VideoCard) -> Void)? = nil
    var tint: Color = Theme.tint(hex: 0x2B3D4F, light: 0xDCE8F2)

    var body: some View {
        let list = app.list(for: key)
        MainPanel(tint: tint) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(kicker: kicker, title: title, subtitle: subtitle, list: list)
                    ShelfGrid(list: list, emptyText: emptyText, removeAction: removeAction)
                        .padding(.horizontal, -10)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .id(key)
        }
    }
}

struct PageHeader: View {
    let kicker: String
    let title: String
    let subtitle: String?
    @ObservedObject var list: PagedList
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kicker).font(.system(size: 13, weight: .bold))
            Text(title).font(.system(size: 48, weight: .black)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let subtitle { Text(subtitle) }
                if !list.items.isEmpty {
                    if subtitle != nil { Text("·") }
                    Text(Lf("%@%@ 个视频", "\(list.items.count)", "\(list.exhausted ? "" : "+")"))
                }
                Spacer()
                Button { Task { await list.reload() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold)) }
                    .buttonStyle(.pressable)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(L("刷新 ⌘R"))
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.text2)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

struct FavoritesPage: View {
    @EnvironmentObject var app: AppModel
    let folderID: Int?

    var body: some View {
        if let id = folderID, let folder = app.favFolders.first(where: { $0.id == id }) ?? app.favFolders.first {
            let list = app.list(for: "fav:\(folder.id)")
            MainPanel(tint: Theme.tint(hex: 0x3D2A5C, light: 0xE6DDF3)) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(kicker: L("收藏夹"), title: folder.title, subtitle: Lf("共 %@ 个视频", "\(folder.count)"), list: list)
                        if app.favFolders.count > 1 {
                            SlidingChips(options: app.favFolders.map { ($0.id, $0.title) },
                                         selection: Binding(get: { folder.id }, set: { app.go(.favorites($0)) }), style: .white)
                        }
                        ShelfGrid(list: list, emptyText: L("收藏夹是空的")).padding(.horizontal, -10)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
                .id(folder.id)
            }
        } else {
            MainPanel { LoginPromptView(what: L("收藏夹")) }
        }
    }
}
