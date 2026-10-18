import SwiftUI

/// The danmaku button's companion: display settings plus 屏蔽设定, opened from the player's control bar
/// and the bottom now-playing bar.
struct DanmakuSettingsButton: View {
    /// The player is always dark; the bottom bar follows the app's appearance.
    var inPlayer = true
    @State private var open = false
    init(inPlayer: Bool = true) {
        self.inPlayer = inPlayer
        _open = State(initialValue: inPlayer && Env.openDanmakuPanel)
    }
    @State private var hover = false

    var body: some View {
        Button { withAnimation(Motion.pop) { open.toggle() } } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(open ? Theme.pink : (inPlayer ? .white : Theme.text2))
                .frame(width: inPlayer ? 32 : 24, height: inPlayer ? 32 : 24)
                .background(Theme.text.opacity(inPlayer && hover ? 0.16 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(L("弹幕设置与屏蔽"))
        .floatingPanel(id: "danmaku-settings", isPresented: $open, placement: .above(.center)) {
            // Panels draw at the window root, outside the player's forced-dark environment.
            if inPlayer { DanmakuPanel().environment(\.colorScheme, .dark) } else { DanmakuPanel() }
        }
    }
}

struct DanmakuPanel: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        MenuSurface(width: 360) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("弹幕")).font(.system(size: 15, weight: .bold))
                    Spacer()
                    Toggle("", isOn: $s.danmakuOn).toggleStyle(PinkToggleStyle()).labelsHidden().fixedSize()
                }
                VStack(spacing: 10) {
                    slider(L("不透明度"), $s.danmakuOpacity, 0.2...1) { "\(Int($0 * 100))%" }
                    slider(L("字号"), $s.danmakuScale, 0.6...1.6) { "\(Int($0 * 100))%" }
                    slider(L("速度"), $s.danmakuSpeed, 0.5...2) { String(format: "%.1fx", $0) }
                    HStack {
                        Text(L("显示区域")).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Spacer()
                        SlidingChips(options: [(0.25, "1/4"), (0.5, L("半屏")), (0.75, "3/4"), (1.0, L("全屏"))],
                                     selection: $s.danmakuArea, style: .white)
                            .scaleEffect(0.9, anchor: .trailing)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("防挡人物")).font(.system(size: 12.5, weight: .semibold))
                        Text(L("弹幕从画面里的人身后穿过")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Toggle("", isOn: $s.danmakuAvoidPeople).toggleStyle(PinkToggleStyle()).labelsHidden().fixedSize()
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("互动弹幕")).font(.system(size: 12.5, weight: .semibold))
                        Text(L("UP 主发起的投票和评分")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Toggle("", isOn: $s.showInteractive).toggleStyle(PinkToggleStyle()).labelsHidden().fixedSize()
                }
                MenuDivider().padding(.horizontal, -6)
                DanmakuFilterEditor(compact: true)
            }
            .padding(12)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        _ format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                .lineLimit(1).minimumScaleFactor(0.85).frame(width: 88, alignment: .leading)
            ThinSlider(value: Binding(get: { (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound) },
                                      set: { value.wrappedValue = range.lowerBound + $0 * (range.upperBound - range.lowerBound) }))
                .frame(height: 16)
            Text(format(value.wrappedValue)).font(Theme.mono).foregroundStyle(Theme.text2).frame(width: 40, alignment: .trailing)
        }
    }
}

/// 屏蔽设定: types, level, and the rule list. Used in the panel and on the settings page.
struct DanmakuFilterEditor: View {
    var compact = false
    @ObservedObject private var s = AppSettings.shared
    @State private var draft = ""
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("屏蔽类型")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                typeChip(L("滚动"), "arrow.left", $s.danmakuBlockScroll)
                typeChip(L("顶部"), "arrow.up.to.line", $s.danmakuBlockTop)
                typeChip(L("底部"), "arrow.down.to.line", $s.danmakuBlockBottom)
                typeChip(L("彩色"), "paintpalette", $s.danmakuBlockColor)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("屏蔽等级")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    if !compact {
                        Text(L("按 B 站给每条弹幕的评分隐藏低质量弹幕，等级越高屏蔽越多"))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }
                .frame(width: compact ? 88 : nil, alignment: .leading)
                if !compact { Spacer() }
                ThinSlider(value: Binding(get: { Double(s.danmakuLevel) / 10 },
                                          set: { s.danmakuLevel = Int(($0 * 10).rounded()) }))
                    .frame(width: compact ? nil : 200, height: 16)
                Text(s.danmakuLevel == 0 ? L("关闭") : "Lv\(s.danmakuLevel)")
                    .font(Theme.mono).foregroundStyle(s.danmakuLevel == 0 ? Theme.text3 : Theme.pink)
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text(Lf("屏蔽列表 %@", "\(s.danmakuBlocklist.count)")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2)
                Spacer()
                Button(importing ? L("导入中…") : L("从 B 站账号导入")) { importCloud() }
                    .buttonStyle(.pressable)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.pink)
                    .disabled(importing)
                    .help(L("导入你在哔哩哔哩网页或客户端里设置的屏蔽词和屏蔽用户"))
            }
            HStack(spacing: 8) {
                TextField(L("关键词，或 /正则表达式/"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(add)
                Button(L("添加"), action: add)
                    .buttonStyle(.pressable)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.text3 : Theme.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Theme.text.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if !s.danmakuBlocklist.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(s.danmakuBlocklist.enumerated()), id: \.element) { _, rule in
                            RuleRow(rule: rule) { s.danmakuBlocklist.removeAll { $0 == rule } }
                        }
                    }
                }
                .frame(maxHeight: compact ? 150 : 240)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func typeChip(_ title: String, _ icon: String, _ blocked: Binding<Bool>) -> some View {
        Button { withAnimation(Motion.press) { blocked.wrappedValue.toggle() } } label: {
            VStack(spacing: 4) {
                Image(systemName: blocked.wrappedValue ? "eye.slash" : icon).font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(blocked.wrappedValue ? Theme.pink : Theme.text)
            .frame(maxWidth: compact ? .infinity : 72)
            .frame(height: 50)
            .background(blocked.wrappedValue ? Theme.pink.opacity(0.16) : Theme.text.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(blocked.wrappedValue ? Lf("已屏蔽%@弹幕", title) : Lf("屏蔽%@弹幕", title))
    }

    private func add() {
        let r = draft.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return }
        if let p = DanmakuFilter.regex(r), (try? NSRegularExpression(pattern: p)) == nil {
            AppModel.shared.notify(L("正则表达式写法有误"))
            return
        }
        if !s.danmakuBlocklist.contains(r) { s.danmakuBlocklist.insert(r, at: 0) }
        draft = ""
    }

    private func importCloud() {
        guard AppModel.shared.account.loggedIn else { AppModel.shared.showLogin = true; return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let rules = try await BiliAPI.shared.danmakuCloudRules()
                let new = rules.filter { !s.danmakuBlocklist.contains($0) }
                s.danmakuBlocklist += new
                AppModel.shared.notify(Lf("已导入 %@ 条屏蔽规则", "\(new.count)"))
            } catch {
                AppModel.shared.notify(Lf("导入失败：%@", error.localizedDescription))
            }
        }
    }
}

private struct RuleRow: View {
    let rule: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).frame(width: 16)
            Text(label).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .opacity(hover ? 1 : 0.35)
            .help(L("删除"))
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(hover ? Theme.text.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
    }

    private var icon: String {
        if DanmakuFilter.sender(rule) != nil { return "person.crop.circle.badge.xmark" }
        if DanmakuFilter.regex(rule) != nil { return "chevron.left.forwardslash.chevron.right" }
        return "text.quote"   // "textformat" renders as localized letters (格式)
    }

    private var label: String {
        if let h = DanmakuFilter.sender(rule) { return Lf("用户 %@", String(h.prefix(8))) }
        return rule
    }
}

/// 发弹幕: opens a small composer above the control bar (also with Return while a video plays).
struct DanmakuSendButton: View {
    @ObservedObject var controller: PlayerController
    @State private var open = false
    @State private var hover = false
    /// Return key from the input router.
    static let requests = NotificationCenter.default.publisher(for: .init("BiliMacComposeDanmaku"))

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(open ? Theme.pink : .white)
                .frame(width: 32, height: 32)
                .background(Theme.text.opacity(hover ? 0.16 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(L("发弹幕 ⏎"))
        .onReceive(Self.requests) { _ in open = true }
        .floatingPanel(id: "danmaku-send-\(ObjectIdentifier(controller).hashValue)", isPresented: $open, placement: .above(.center)) {
            DanmakuComposer(controller: controller) { open = false }.environment(\.colorScheme, .dark)
        }
    }
}

private struct DanmakuComposer: View {
    @ObservedObject var controller: PlayerController
    let done: () -> Void
    @ObservedObject private var app = AppModel.shared
    @State private var text = ""
    @State private var sending = false
    @AppStorage("danmakuSendMode") private var mode = 1
    @AppStorage("danmakuSendColor") private var color = 0xFFFFFF
    @FocusState private var focused: Bool

    private static let colors: [Int] = [0xFFFFFF, 0xFE0302, 0xFF7204, 0xFFD302, 0xA0EE00, 0x00CD00, 0x89D5FF, 0x4266BE, 0xCC0273]
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        MenuSurface(width: 380) {
            VStack(alignment: .leading, spacing: 12) {
                if !app.account.loggedIn {
                    Text(L("登录后才能发弹幕")).font(.system(size: 13, weight: .semibold))
                    PillButton(title: L("登录")) { done(); app.showLogin = true }
                } else {
                    HStack(spacing: 8) {
                        TextField(L("发个友善的弹幕见证当下"), text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .focused($focused)
                            .onSubmit { send() }
                            .onExitCommand { done() }
                            .onChange(of: text) { _, t in if t.count > 100 { text = String(t.prefix(100)) } }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        Button { send() } label: {
                            Group {
                                if sending { ProgressView().controlSize(.small) } else { Text(L("发送")).font(.system(size: 12.5, weight: .bold)) }
                            }
                            .foregroundStyle(.black)
                            .frame(width: 54, height: 32)
                            .background(Theme.pink.opacity(trimmed.isEmpty ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.pressable)
                        .disabled(trimmed.isEmpty || sending)
                    }
                    HStack(spacing: 12) {
                        SlidingChips(options: [(1, L("滚动")), (5, L("顶部")), (4, L("底部"))], selection: $mode, style: .white)
                            .scaleEffect(0.9, anchor: .leading)
                        Spacer(minLength: 0)
                        Text("\(text.count)/100").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3)
                    }
                    HStack(spacing: 7) {
                        ForEach(Self.colors, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(Color(hex: UInt32(c)))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(.white.opacity(color == c ? 0.95 : 0.2), lineWidth: color == c ? 2 : 1))
                                    .padding(2)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    Text(L("在当前播放位置发送；彩色、顶部和底部弹幕可能需要更高的账号等级或大会员"))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func send() {
        let t = trimmed
        guard !t.isEmpty, !sending else { return }
        sending = true
        Task {
            do {
                try await controller.sendDanmaku(t, mode: mode, color: UInt32(color))
                if !AppSettings.shared.danmakuOn { AppSettings.shared.danmakuOn = true }
                text = ""
                done()
                controller.flash("checkmark.bubble.fill", L("弹幕已发送"))
            } catch {
                AppModel.shared.notify(Lf("弹幕发送失败：%@", error.localizedDescription))
            }
            sending = false
        }
    }
}
