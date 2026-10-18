import AVFoundation
import SwiftUI

/// 互动弹幕: polls (#VOTE#) and star ratings (#GRADE#) creators pin to moments of a video.
struct InteractiveDm: Identifiable {
    struct Option: Hashable {
        let idx: Int
        let desc: String
        var count: Int
        /// "其他，请补充": needs typed text, which the web API doesn't take here.
        let writeIn: Bool
    }
    enum Kind {
        case vote(id: Int, question: String, options: [Option], total: Int, myVote: Int)
        case grade(id: Int, title: String, average: Double, count: Int, myScore: Int)
    }

    let id: Int
    /// When it appears and for how long (seconds).
    let time: Double
    let duration: Double
    /// Centre as a fraction of the picture (nil → bottom right).
    let x: Double?
    let y: Double?
    var kind: Kind

    var isVote: Bool { if case .vote = kind { return true } else { return false } }

    /// Parses `x/v2/dm/web/view` (DmWebViewReply, protobuf): field 9 = CommandDm {4 command, 6 progress ms, 9 extra JSON}.
    static func parse(_ data: Data) -> [InteractiveDm] {
        var out: [InteractiveDm] = []
        for (field, value) in Proto.fields([UInt8](data)) where field == 9 {
            guard case .bytes(let msg) = value else { continue }
            var command = "", progress = 0, extra = Data(), dmid = 0
            for (f, v) in Proto.fields(msg) {
                switch (f, v) {
                case (1, .varint(let n)): dmid = Int(truncatingIfNeeded: n)
                case (4, .bytes(let b)): command = String(decoding: b, as: UTF8.self)
                case (6, .varint(let n)): progress = Int(truncatingIfNeeded: n)
                case (9, .bytes(let b)): extra = Data(b)
                default: break
                }
            }
            guard command == "#VOTE#" || command == "#GRADE#",
                  let j = try? JSONSerialization.jsonObject(with: extra) as? JSON else { continue }
            let duration = Double(j.int("duration") ?? 5000) / 1000
            let x = j.double("posX_2").map { $0 / 100 }, y = j.double("posY_2").map { $0 / 100 }
            let kind: Kind
            if command == "#VOTE#" {
                guard let vid = j.int("vote_id") else { continue }
                let options = j.arr("options").compactMap { o -> Option? in
                    guard let idx = o.int("idx") else { return nil }
                    return Option(idx: idx, desc: o.str("desc") ?? "", count: o.int("cnt") ?? 0, writeIn: o.bool("has_self_def") ?? false)
                }
                kind = .vote(id: vid, question: j.str("question") ?? "", options: options, total: j.int("cnt") ?? 0, myVote: j.int("my_vote") ?? 0)
            } else {
                guard let gid = j.int("grade_id") else { continue }
                kind = .grade(id: gid, title: j.str("msg") ?? "", average: j.double("avg_score") ?? 0, count: j.int("count") ?? 0,
                              myScore: j.int("mid_score") ?? 0)
            }
            out.append(InteractiveDm(id: dmid == 0 ? out.count : dmid, time: Double(progress) / 1000, duration: max(duration, 5),
                                     x: x, y: y, kind: kind))
        }
        return out.sorted { $0.time < $1.time }
    }
}

/// Just enough protobuf to walk fields.
enum Proto {
    enum Value { case varint(UInt64), bytes([UInt8]) }

    static func fields(_ d: [UInt8]) -> [(Int, Value)] {
        var i = 0
        var out: [(Int, Value)] = []
        func varint() -> UInt64 {
            var r: UInt64 = 0, shift: UInt64 = 0
            while i < d.count {
                let b = d[i]; i += 1
                r |= UInt64(b & 0x7F) << shift
                if b < 0x80 { break }
                shift += 7
            }
            return r
        }
        while i < d.count {
            let key = varint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: out.append((field, .varint(varint())))
            case 2:
                let n = Int(varint())
                guard n >= 0, i + n <= d.count else { return out }
                out.append((field, .bytes(Array(d[i ..< i + n]))))
                i += n
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}

/// Shows the poll / rating cards at their moments, over the picture.
struct InteractiveOverlay: View {
    @ObservedObject var controller: PlayerController
    @ObservedObject private var settings = AppSettings.shared
    @State private var dismissed: Set<Int> = []
    /// Answered cards stay up a little longer so the result can be read.
    @State private var keepUntil: [Int: Double] = [:]

    var body: some View {
        if settings.danmakuOn, settings.showInteractive, !controller.interactions.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                GeometryReader { g in
                    let t = controller.player.currentTime().seconds
                    let rect = pictureRect(in: g.size)
                    let shown = controller.interactions.filter { visible($0, at: t) }
                    ZStack {
                        ForEach(shown) { item in
                            InteractiveCard(item: item, controller: controller,
                                            onAnswer: { keepUntil[item.id] = max(t, item.time + item.duration) + 5 },
                                            onClose: { dismissed.insert(item.id) })
                                .fixedSize()
                                .modifier(Place(rect: rect, x: item.x ?? 0.9, y: item.y ?? 0.8))
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                    .animation(Motion.pop, value: shown.map(\.id))
                }
            }
        }
    }

    private func visible(_ item: InteractiveDm, at t: Double) -> Bool {
        guard !dismissed.contains(item.id), t.isFinite else { return false }
        return t >= item.time && t < max(item.time + item.duration, keepUntil[item.id] ?? 0)
    }

    private func pictureRect(in size: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard let v = controller.video, v.width > 0, v.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: CGSize(width: v.width, height: v.height), insideRect: bounds)
    }

    /// Centres the card on (x, y) of the picture, kept inside it.
    private struct Place: ViewModifier {
        let rect: CGRect
        let x: Double
        let y: Double
        @State private var size: CGSize = CGSize(width: 260, height: 160)
        func body(content: Content) -> some View {
            let cx = min(max(rect.minX + rect.width * x, rect.minX + size.width / 2 + 12), rect.maxX - size.width / 2 - 12)
            let cy = min(max(rect.minY + rect.height * y, rect.minY + size.height / 2 + 12), rect.maxY - size.height / 2 - 76)
            content
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .position(x: cx, y: cy)
        }
    }
}

private struct InteractiveCard: View {
    let item: InteractiveDm
    @ObservedObject var controller: PlayerController
    let onAnswer: () -> Void
    let onClose: () -> Void
    @State private var local: InteractiveDm?

    private var current: InteractiveDm { local ?? controller.interactions.first { $0.id == item.id } ?? item }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch current.kind {
            case let .vote(_, question, options, total, myVote):
                header(icon: "chart.bar.fill", title: question)
                VStack(spacing: 6) {
                    ForEach(options, id: \.idx) { o in
                        voteRow(o, total: total, myVote: myVote)
                    }
                }
                Text(Lf("%@ 人参与", formatCount(total))).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            case let .grade(_, title, average, count, myScore):
                header(icon: "star.fill", title: title)
                Stars(score: myScore) { s in grade(s) }
                if myScore > 0 {
                    HStack(spacing: 6) {
                        Text(String(format: "%.1f", average)).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.pink)
                        Text(Lf("平均分 · %@ 人参与", formatCount(count))).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    }
                    .transition(.opacity)
                } else {
                    Text(Lf("%@ 人参与", formatCount(count))).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func header(icon: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.pink).padding(.top, 2)
            Text(title).font(.system(size: 14, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(L("关闭这张卡片"))
        }
    }

    @ViewBuilder private func voteRow(_ o: InteractiveDm.Option, total: Int, myVote: Int) -> some View {
        let answered = myVote != 0
        let share = total > 0 ? Double(o.count) / Double(total) : 0
        let mine = myVote == o.idx
        Button { vote(o) } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(answered ? 0.08 : 0.14))
                if answered {
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(mine ? Theme.pink.opacity(0.75) : .white.opacity(0.18))
                            .frame(width: max(6, g.size.width * share))
                    }
                    .transition(.opacity)
                }
                HStack {
                    Text(o.desc).font(.system(size: 13, weight: mine ? .bold : .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    if answered { Text("\(Int((share * 100).rounded()))%").font(.system(size: 12, weight: .semibold, design: .monospaced)) }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 30)
            .opacity(!answered && o.writeIn ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(answered || o.writeIn)
        .help(o.writeIn && !answered ? L("这个选项需要填写内容，请在官方客户端里投") : "")
    }

    private func vote(_ o: InteractiveDm.Option) {
        guard case let .vote(id, question, options, total, myVote) = current.kind, myVote == 0 else { return }
        guard AppModel.shared.account.loggedIn else { AppModel.shared.showLogin = true; return }
        let opts = options.map { $0.idx == o.idx ? InteractiveDm.Option(idx: $0.idx, desc: $0.desc, count: $0.count + 1, writeIn: $0.writeIn) : $0 }
        var updated = current
        updated.kind = .vote(id: id, question: question, options: opts, total: total + 1, myVote: o.idx)
        withAnimation(Motion.pop) { local = updated }
        onAnswer()
        controller.answer(updated)
        let progress = max(1, Int(controller.clock.time * 1000))
        let (aid, cid) = (controller.aid ?? 0, controller.cid)
        Task {
            do { try await BiliAPI.shared.voteInteractive(aid: aid, cid: cid, progressMs: progress, voteId: id, option: o.idx) }
            catch { AppModel.shared.notify(Lf("投票失败：%@", error.localizedDescription)) }
        }
    }

    private func grade(_ score: Int) {
        guard case let .grade(id, title, average, count, myScore) = current.kind, myScore == 0 else { return }
        guard AppModel.shared.account.loggedIn else { AppModel.shared.showLogin = true; return }
        var updated = current
        let newAvg = (average * Double(count) + Double(score)) / Double(count + 1)
        updated.kind = .grade(id: id, title: title, average: newAvg, count: count + 1, myScore: score)
        withAnimation(Motion.pop) { local = updated }
        onAnswer()
        controller.answer(updated)
        let progress = max(1, Int(controller.clock.time)) * 1000
        let (aid, cid) = (controller.aid ?? 0, controller.cid)
        Task {
            do { try await BiliAPI.shared.gradeInteractive(aid: aid, cid: cid, progressMs: progress, gradeId: id, score: score) }
            catch { AppModel.shared.notify(Lf("评分失败：%@", error.localizedDescription)) }
        }
    }
}

/// Five stars; scores are 2, 4, …, 10 like the official player.
private struct Stars: View {
    let score: Int
    let rate: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        let lit = hover ?? (score / 2)
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Button { rate(i * 2) } label: {
                    Image(systemName: i <= lit ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(i <= lit ? Theme.pink : .white.opacity(0.4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(score > 0)
                .onHover { inside in if score == 0 { hover = inside ? i : nil } }
            }
        }
    }
}
