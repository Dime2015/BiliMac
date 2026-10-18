import SwiftUI
import VideoToolbox

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", route = "线路", play = "播放", info = "信息显示", danmaku = "弹幕", account = "账号", keys = "快捷键"
    var id: String { rawValue }
}

struct SettingsPage: View {
    @EnvironmentObject var app: AppModel
    @State private var selected: SettingsSection = .general

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Button { app.canBack ? app.goBack() : app.go(.home) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            Text(L("返回")).font(.system(size: 13))
                        }
                        .foregroundStyle(Theme.text2)
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, 12)
                    .padding(.top, 34)
                    .padding(.bottom, 18)
                    Text(L("设置")).font(.system(size: 24, weight: .black)).padding(.horizontal, 12).padding(.bottom, 12)
                    ForEach(SettingsSection.allCases) { s in
                        Button {
                            selected = s
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(s, anchor: .top) }
                        } label: {
                            Text(L(s.rawValue))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(selected == s ? Theme.text : Theme.text2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).frame(height: 40)
                                .background(selected == s ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        GeneralSection().id(SettingsSection.general)
                        RouteSection().id(SettingsSection.route)
                        PlaybackSection().id(SettingsSection.play)
                        InfoSection().id(SettingsSection.info)
                        DanmakuSection().id(SettingsSection.danmaku)
                        AccountSection().id(SettingsSection.account)
                        KeysSection().id(SettingsSection.keys)
                    }
                    .frame(maxWidth: 860, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - Building blocks

private struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 22, weight: .bold)).padding(.bottom, 10) }
}

private struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14.5))
                if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.meta) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
    }
}

private struct ToggleRow<Extra: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    @ViewBuilder var extra: () -> Extra
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14.5))
                if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.meta).fixedSize(horizontal: false, vertical: true) }
                extra()
            }
        }
        .toggleStyle(PinkToggleStyle())
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
    }
}

extension ToggleRow where Extra == EmptyView {
    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, subtitle: subtitle, isOn: isOn) { EmptyView() }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var body: some View {
        Row(title: title) {
            ThinSlider(value: Binding(get: { (value - range.lowerBound) / (range.upperBound - range.lowerBound) },
                                      set: { value = range.lowerBound + $0 * (range.upperBound - range.lowerBound) }))
                .frame(width: 200)
            Text(format(value)).font(Theme.mono).foregroundStyle(Theme.text2).frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Sections

private struct RouteSection: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var s = AppSettings.shared
    @StateObject private var test = SpeedTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("线路"))
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("视频线路")).font(.system(size: 14.5))
                    (Text(L("把海外节点改写到所选节点 · 当前 ")) + Text(currentHost).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.text2))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.meta)
                    if let e = test.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.pink) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    ForEach(CDNNode.allCases) { n in
                        Button {
                            s.cdnNode = n
                            app.nowPlaying?.reloadStream()
                        } label: {
                            VStack(spacing: 1) {
                                Text(n == .off ? L("默认") : n.rawValue).font(.system(size: 13, weight: .bold))
                                Group {
                                    if test.running == n { Text(L("测速中")) }
                                    else if let v = test.results[n] { Text(String(format: "%.1fM", v)) }
                                    else if test.failed.contains(n) { Text(L("失败")) }
                                    else { Text("—") }
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                                .opacity(0.8)
                            }
                            .foregroundStyle(s.cdnNode == n ? Theme.onPrimary : Theme.text2)
                            .frame(minWidth: 64)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(s.cdnNode == n ? Theme.pink : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .help(n.label)
                    }
                }
                .padding(3)
                .background(Color.dyn(0x000000, 0xF5E3EA), in: RoundedRectangle(cornerRadius: 8))
                Button(test.running == nil ? L("测速") : "…") { Task { await test.run() } }
                    .buttonStyle(.pressable)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.text2)
                    .disabled(test.running != nil)
                    .help(L("用同一个热门视频分段分别测试四条线路约 6 秒"))
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
        }
        .task { if autoTest, test.results.isEmpty { await test.run() } }
    }

    private var autoTest: Bool { ProcessInfo.processInfo.environment["BILIMAC_SPEEDTEST"] != nil }

    private var currentHost: String {
        if let h = app.nowPlaying?.stream?.stats.lastHost ?? app.nowPlaying?.stream?.video.urls.first?.host {
            return h.replacingOccurrences(of: ".bilivideo.com", with: "")
        }
        return (s.cdnNode.host ?? L("接口默认节点")).replacingOccurrences(of: ".bilivideo.com", with: "")
    }
}

private struct PlaybackSection: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("播放"))
            Row(title: L("画质策略"), subtitle: s.qualityPreset.detail) {
                SlidingChips(options: QualityPreset.allCases.map { ($0, $0.label) }, selection: $s.qualityPreset)
            }
            QualityChain(order: s.qualityOrder, vip: app.account.isVip || Env.demo, loggedIn: app.account.loggedIn || Env.demo)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
            if s.qualityPreset == .max {
                ToggleRow(title: L("HDR / 杜比视界优先"), subtitle: L("排在 4K 前面。需要支持 HDR 的屏幕，普通屏幕上画面会发灰"), isOn: $s.preferHDR)
            }
            ToggleRow(title: L("卡顿时自动降一档"),
                      subtitle: L("45 秒内卡顿两次，或一次缓冲超过 4 秒，就按上面的顺序降一档并提示；在播放器里手动选的画质不会被降"),
                      isOn: $s.autoDowngrade)
            Row(title: L("视频编码"),
                subtitle: Lf("硬件解码：HEVC %@ · AV1 %@", "\(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? L("支持") : L("不支持"))", "\(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? L("支持") : L("不支持"))")) {
                Dropdown(options: CodecPref.allCases.map { ($0, $0.label) }, selection: $s.codec)
            }
            ToggleRow(title: L("从上次观看的位置继续播放"), isOn: $s.resumePlayback)
            ToggleRow(title: L("同步观看历史到哔哩哔哩账号"), subtitle: L("和官方客户端共用历史记录与续播进度"), isOn: $s.reportHistory)
            ToggleRow(title: L("精选：播完自动下一个"), isOn: $s.featuredAutoNext)
            ToggleRow(title: L("视频页：播完自动播放相关推荐"), subtitle: L("分 P 视频总是按顺序连播"), isOn: $s.detailAutoNext)
        }
    }
}

private struct InfoSection: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("信息显示"))
            Row(title: L("播放控件位置"), subtitle: s.chromeLayout == .outside ? L("标题与信息在画面上方、控件在画面下方，不遮挡画面，始终显示") : L("叠加在画面上，观看时自动隐藏")) {
                SlidingChips(options: [(ChromeLayout.outside, L("画面外")), (ChromeLayout.overlay, L("叠加在画面上"))], selection: $s.chromeLayout)
            }
            Row(title: L("画面上方信息条"), subtitle: L("精选、视频页、全屏和底部播放条统一使用：清晰度、画面、编码与码率、当前连接的每个 CDN 节点的实时下载速度、缓冲")) {
                SlidingChips(options: InfoOverlayMode.allCases.map { ($0, $0.label) }, selection: $s.infoOverlay)
            }
            HStack(spacing: 6) {
                ForEach([(L("画质"), L("1080P 60帧"), true), (L("画面"), "1920×1080 · 60 fps", false), ("HEVC", "2.84 Mbps", false),
                         ("AAC", "192 kbps", false), ("08c", "↓ 31.6 Mbps", true), (L("缓冲"), L("28 秒"), false)], id: \.0) { l, v, a in
                    HStack(spacing: 5) {
                        Text(l).foregroundStyle(.white.opacity(0.55))
                        Text(v).foregroundStyle(a ? Theme.pink : .white)
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(.black, in: Capsule())
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
            Row(title: L("进度条热度"), subtitle: L("按弹幕密度画出视频里最热闹的片段（B 站官方的高能进度条接口已下线）")) {
                SlidingChips(options: HeatMode.allCases.map { ($0, $0.label) }, selection: $s.heatMode)
            }
            Row(title: L("双击画面"), subtitle: L("应用内全屏铺满 App 窗口（T）；屏幕全屏进入系统全屏（F）。Esc 逐级退出")) {
                SlidingChips(options: [(false, L("应用内全屏")), (true, L("屏幕全屏"))], selection: $s.doubleClickScreenFull)
            }
            Row(title: L("精选和视频页的侧栏"), subtitle: L("自动隐藏时，把鼠标移到窗口左边缘即可呼出")) {
                SlidingChips(options: [(false, L("固定")), (true, L("自动隐藏"))], selection: $s.railAutoHide)
            }
            ToggleRow(title: L("统计信息浮层（I）"),
                      subtitle: L("分辨率与帧率、画质、编码、平均/峰值码率、音频、节点、实时下载速度、线路吞吐、缓冲、卡顿与丢帧、起播耗时、近 60 秒速度曲线"),
                      isOn: $s.showStats)
            ToggleRow(title: L("精选：显示标题与 UP 主"), subtitle: L("关闭后精选只保留画面、弹幕和右侧操作"), isOn: $s.showFeaturedInfo)
        }
    }
}

private struct DanmakuSection: View {
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("弹幕"))
            ToggleRow(title: L("显示弹幕（D）"), isOn: $s.danmakuOn)
            SliderRow(title: L("不透明度"), value: $s.danmakuOpacity, range: 0.2...1) { "\(Int($0 * 100))%" }
            SliderRow(title: L("字号"), value: $s.danmakuScale, range: 0.6...1.6) { "\(Int($0 * 100))%" }
            SliderRow(title: L("速度"), value: $s.danmakuSpeed, range: 0.5...2) { String(format: "%.1fx", $0) }
            Row(title: L("显示区域")) {
                SlidingChips(options: [(0.25, "1/4"), (0.5, L("半屏")), (0.75, "3/4"), (1.0, L("全屏"))], selection: $s.danmakuArea)
            }
            ToggleRow(title: L("顶部 / 底部固定弹幕"), isOn: $s.danmakuTopBottom)
        }
    }
}

private struct AccountSection: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("账号"))
            HStack(spacing: 14) {
                if app.account.loggedIn {
                    Avatar(url: app.account.face, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.account.name ?? "").font(.system(size: 16, weight: .bold))
                        Text("UID \(app.account.mid ?? 0) · LV\(app.account.level)\(app.account.vipLabel.map { " · \($0)" } ?? "")")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    PillButton(title: L("退出登录")) { Task { await app.logout() } }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("未登录")).font(.system(size: 16, weight: .bold))
                        Text(L("只能看到通用推荐，最高 480P")).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    PillButton(title: L("扫码登录"), filled: true) { app.showLogin = true }
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.raised).frame(height: 1) }
            Text(L("登录信息保存在 ~/Library/Application Support/BiliMac/cookies.json（仅本人可读），退出登录会删除其中的 SESSDATA。"))
                .font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.top, 10)
        }
    }
}

private struct KeysSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("快捷键"))
            ForEach([(L("空格"), L("播放 / 暂停")), ("← / →", L("后退 / 前进 5 秒")), ("↑ / ↓", L("精选中切换上一个 / 下一个，其它页面调节音量")),
                     ("J / L", L("后退 / 前进 10 秒")), ("0 – 9", L("跳到 0% – 90% 的位置")), ("< >", L("减速 / 加速")), ("T", L("应用内全屏")), ("F", L("屏幕全屏")), ("Esc", L("逐级退出全屏")), ("D · I · M", L("弹幕 · 统计信息 · 静音")), ("⌘R", L("刷新列表")), ("⌘,", L("打开设置"))], id: \.0) { k, v in
                Row(title: v) {
                    Text(k).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

/// 「4K → 1080P 高码率 → …」: the fallback order, with what this account can't play dimmed.
private struct QualityChain: View {
    let order: [Int]
    let vip: Bool
    let loggedIn: Bool

    private func usable(_ qn: Int) -> Bool {
        if qn > 80 { return vip }          // 1080P+ / 1080P60 / 4K / HDR / 杜比视界 are 大会员
        if qn > 32 { return loggedIn }     // 720P and 1080P need login
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("每个视频按这个顺序取第一个可用的画质：")).font(.system(size: 12.5)).foregroundStyle(Theme.meta)
            FlowLayout(spacing: 6) {
                ForEach(Array(order.enumerated()), id: \.element) { i, qn in
                    HStack(spacing: 6) {
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3) }
                        Text(qualityNames[qn] ?? "\(qn)")
                            .font(.system(size: 12, weight: i == 0 ? .bold : .medium))
                            .foregroundStyle(i == 0 ? Theme.onPrimary : (usable(qn) ? Theme.text : Theme.text3))

                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(i == 0 ? Theme.pink : Theme.chip, in: Capsule())
                            .strikethrough(!usable(qn), color: Theme.text3)
                    }
                }
            }
            if order.contains(where: { $0 > 80 }) && !vip {
                Text(L("当前账号不是大会员，划线的档位会自动跳过")).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            }
        }
    }
}

private struct GeneralSection: View {
    @State private var language = AppLanguage.override
    @ObservedObject private var s = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("通用"))
            Row(title: L("外观"), subtitle: L("播放器始终保持深色")) {
                SlidingChips(options: AppAppearance.allCases.map { ($0, $0.label) }, selection: $s.appearance)
            }
            Row(title: L("语言"), subtitle: L("切换后重新启动 BiliMac 生效")) {
                Dropdown(options: AppLanguage.choices, selection: $language)
            }
            if language != AppLanguage.override || AppLanguage.pendingRestart {
                HStack {
                    Spacer()
                    PillButton(title: L("立即重新启动"), filled: true) { AppLanguage.relaunch() }
                }
                .padding(.vertical, 10)
            }
        }
        .onChange(of: language) { _, v in AppLanguage.set(v) }
    }
}
