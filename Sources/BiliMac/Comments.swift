import SwiftUI

/// A video's comments: loading by 最热 / 最新, posting, replying and liking. Used by the video page and 精选.
@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published var mode = 3 { didSet { if oldValue != mode { Task { await reload() } } } }
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var end = false
    @Published private(set) var error: String?
    /// The comment whose reply box is open.
    @Published var replyingTo: Int?
    private(set) var aid: Int?
    private var upMid: Int?
    private var offset = ""

    /// Points the model at another video; call `reload()` to fetch.
    func reset(aid: Int, upMid: Int?, total: Int?) {
        guard aid != self.aid else { return }
        self.aid = aid
        self.upMid = upMid
        self.total = total ?? 0
        comments = []
        offset = ""
        end = false
        error = nil
        replyingTo = nil
    }

    func reload() async {
        comments = []
        offset = ""
        end = false
        await more()
    }

    func more() async {
        guard let aid, !loading, !end else { return }
        loading = true
        let mode = self.mode
        do {
            let r = try await BiliAPI.shared.replies(aid: aid, mode: mode, offset: offset, upMid: upMid)
            guard mode == self.mode, aid == self.aid else { loading = false; return }
            let seen = Set(comments.map(\.id))
            comments += r.items.filter { !seen.contains($0.id) }
            offset = r.next
            end = r.end || r.next.isEmpty
            // Signed out, bilibili reports only the handful it returns; keep the video's own count then.
            total = max(total, r.total)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Posts a comment (or a reply to `root`). Returns false on failure so the box keeps the text.
    func post(_ text: String, root: Int? = nil) async -> Bool {
        let app = AppModel.shared
        guard app.account.loggedIn else { app.showLogin = true; return false }
        guard let aid else { return false }
        do {
            let new = try await BiliAPI.shared.addComment(aid: aid, message: text, root: root, upMid: upMid)
            if let root, let i = comments.firstIndex(where: { $0.id == root }) {
                comments[i].rcount += 1
                comments[i].previews.insert((app.account.name ?? L("我"), text), at: 0)
                replyingTo = nil
                app.notify(L("回复成功"))
            } else {
                if let new { comments.insert(new, at: 0) }
                total += 1
                app.notify(L("评论成功"))
            }
            return true
        } catch {
            app.notify(Lf("发送失败：%@", error.localizedDescription))
            return false
        }
    }

    func toggleLike(_ c: Comment) {
        let app = AppModel.shared
        guard app.account.loggedIn else { app.showLogin = true; return }
        guard let aid, let i = comments.firstIndex(where: { $0.id == c.id }) else { return }
        let on = !comments[i].liked
        comments[i].liked = on
        comments[i].like += on ? 1 : -1
        Task {
            do { try await BiliAPI.shared.likeComment(aid: aid, rpid: c.id, on) }
            catch {
                if let j = comments.firstIndex(where: { $0.id == c.id }) { comments[j].liked = !on; comments[j].like += on ? -1 : 1 }
                app.notify(Lf("操作失败：%@", error.localizedDescription))
            }
        }
    }
}

struct CommentsSection: View {
    @ObservedObject var model: CommentsModel
    /// Side-panel use (精选): a close button after the sort chips.
    var onClose: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("评论")).font(.system(size: 20, weight: .bold))
                Text(formatCount(model.total))
                    .font(.system(size: 14)).foregroundStyle(Theme.text2)
                Spacer()
                SlidingChips(options: [(3, L("最热")), (2, L("最新"))], selection: $model.mode, style: .white)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.text2)
                            .frame(width: 28, height: 28).background(Theme.text.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .help(L("收起评论"))
                }
            }
            CommentComposer(placeholder: L("发一条友善的评论"), autofocus: false) { await model.post($0) }
                .padding(.bottom, 4)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.comments) { c in
                    CommentRow(c: c, model: model)
                        .onAppear { if c.id == model.comments.last?.id { Task { await model.more() } } }
                }
            }
            HStack {
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                else if model.error != nil {
                    PillButton(title: L("评论加载失败，重试")) { Task { await model.more() } }
                } else if model.end {
                    Text(model.comments.isEmpty ? L("还没有评论") : L("没有更多评论了")).font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .frame(maxWidth: 820, alignment: .leading)
        .padding(.top, 8)
    }
}

struct CommentRow: View {
    let c: Comment
    @ObservedObject var model: CommentsModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { if c.mid > 0 { AppModel.shared.go(.space(c.mid)) } } label: { Avatar(url: c.avatar, size: 36) }
                .buttonStyle(.pressable)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { if c.mid > 0 { AppModel.shared.go(.space(c.mid)) } } label: {
                        Text(c.uname).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(c.isVip ? Theme.pink : Theme.text2)
                    }
                    .buttonStyle(.pressable)

                    if c.level > 0 {
                        Text("LV\(c.level)").font(.system(size: 9.5, weight: .heavy))
                            .foregroundStyle(c.level >= 5 ? Color(hex: 0xF0A24A) : Theme.text3)
                    }
                    if c.isUp {
                        Text("UP").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(Theme.onPrimary)
                            .padding(.horizontal, 4).background(Theme.pink, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(c.message).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(formatRelativeDate(c.ctime))
                    Button { model.toggleLike(c) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: c.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            Text(c.like > 0 ? formatCount(c.like) : L("点赞"))
                        }
                        .foregroundStyle(c.liked ? Theme.pink : Theme.text3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.leading, 8)
                    Button { withAnimation(Motion.pop) { model.replyingTo = model.replyingTo == c.id ? nil : c.id } } label: {
                        Text(L("回复")).foregroundStyle(model.replyingTo == c.id ? Theme.pink : Theme.text3).contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .padding(.leading, 8)
                    if c.rcount > 0 { Text("·").padding(.leading, 4); Text(Lf("共 %@ 条回复", "\(c.rcount)")) }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                if model.replyingTo == c.id {
                    CommentComposer(placeholder: Lf("回复 @%@：", c.uname), autofocus: true, compact: true) {
                        await model.post($0, root: c.id)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !c.previews.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(c.previews.enumerated()), id: \.offset) { _, p in
                            (Text(p.0 + L("：")).foregroundColor(Theme.text2) + Text(p.1)).font(.system(size: 13)).lineLimit(2)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 12)
    }
}

/// Text box + 发布 for comments and replies. Return sends, Option-Return starts a new line.
struct CommentComposer: View {
    let placeholder: String
    var autofocus = false
    var compact = false
    let send: (String) async -> Bool
    @ObservedObject private var app = AppModel.shared
    @State private var text = ""
    @State private var sending = false
    @State private var editing = false
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if !app.account.loggedIn {
            Button { app.showLogin = true } label: {
                Text(L("登录后参与评论")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.pressable)
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                if !compact { Avatar(url: app.account.face, size: 36) }
                if editing || autofocus || !text.isEmpty {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit { submit() }
                        .onExitCommand { focused = false }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.text.opacity(focused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.pink.opacity(0.6) : .clear))
                        // After the view is in the window, or the focus request is lost.
                        .task { try? await Task.sleep(for: .milliseconds(80)); focused = true }
                        .onChange(of: focused) { _, f in if !f, text.isEmpty { editing = false } }
                } else {
                    // A plain button until clicked, so the page doesn't start with a text field holding the
                    // keyboard (space, F, ←/→ belong to the player).
                    Button { editing = true } label: {
                        Text(placeholder).font(.system(size: 13.5)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(Theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverCursor()
                }
                Button { submit() } label: {
                    Group {
                        if sending { ProgressView().controlSize(.small) } else { Text(L("发布")).font(.system(size: 13, weight: .bold)) }
                    }
                    .foregroundStyle(Theme.onPink)
                    .frame(width: 64, height: 36)
                    .background(Theme.pink.opacity(trimmed.isEmpty ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.pressable)
                .disabled(trimmed.isEmpty || sending)
            }
        }
    }

    private func submit() {
        let t = trimmed
        guard !t.isEmpty, !sending else { return }
        sending = true
        Task {
            if await send(t) { text = "" }
            sending = false
        }
    }
}
