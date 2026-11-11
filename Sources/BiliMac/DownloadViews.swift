import AppKit
import SwiftUI

// MARK: - The panel on the video page

/// Picks what to download: content, quality, codec, sound, format and folder, with the size it will take.
struct DownloadPanel: View {
    let bvid: String
    let cid: Int
    let title: String
    let owner: String
    let cover: URL?
    let duration: Int
    let close: () -> Void

    @EnvironmentObject var app: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var info: PlayInfo?
    @State private var error: String?
    @AppStorage("dl.content") private var content: DownloadContent = .both
    @AppStorage("dl.codec") private var codecPref = "HEVC"
    @AppStorage("dl.videoFormat") private var videoFormat: VideoFileFormat = .mp4
    @AppStorage("dl.audioFormat") private var audioFormat: AudioFileFormat = .m4a
    @State private var qn = 0
    @State private var audioKey = ""
    /// Exact size of the current choice, once the CDN has answered.
    @State private var exact: Int?
    private let mp3 = MP3Encoder.found

    private static let codecOrder = ["AVC", "HEVC", "AV1"]

    var body: some View {
        MenuSurface(width: 430) {
            MenuHeader(text: L("下载"))
            if let info {
                form(info)
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.pink).padding(12)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
            }
        }
        .task {
            do {
                let i = try await BiliAPI.shared.playInfo(bvid: bvid, cid: cid)
                qn = i.options.first(where: { o in o.available && i.videos.contains { $0.id == o.qn } })?.qn ?? i.videos.first?.id ?? 0
                let opts = audioOptions(i)
                audioKey = (opts.first { $0.key.hasPrefix("aac") } ?? opts.first)?.key ?? ""
                info = i
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Choices

    private struct AudioOption { let key: String; let track: DashTrack; let label: String }

    private func audioOptions(_ i: PlayInfo) -> [AudioOption] {
        // bilibili's tiers by id; the bandwidth it reports is measured and can be the same for all three.
        let tiers = [30280: "192K", 30232: "132K", 30216: "64K"]
        var out = i.audios.sorted { ($0.id, $0.bandwidth) > ($1.id, $1.bandwidth) }.map {
            AudioOption(key: "aac-\($0.id)", track: $0,
                        label: "AAC " + (tiers[$0.id] ?? "\(Int((Double($0.bandwidth) / 1000).rounded()))K"))
        }
        if let f = i.flac { out.insert(AudioOption(key: "flac", track: f, label: L("Hi-Res 无损")), at: 0) }
        if let d = i.dolby { out.insert(AudioOption(key: "dolby", track: d, label: L("杜比全景声")), at: 0) }
        return out
    }

    private func codecs(_ i: PlayInfo) -> [String] {
        let have = Set(i.videos.filter { $0.id == qn }.map(\.codecName))
        return Self.codecOrder.filter(have.contains)
    }

    private func videoTrack(_ i: PlayInfo) -> DashTrack? {
        let tracks = i.videos.filter { $0.id == qn }
        return tracks.first { $0.codecName == codecPref }
            ?? ["HEVC", "AVC", "AV1"].lazy.compactMap { c in tracks.first { $0.codecName == c } }.first
            ?? tracks.first
    }

    private func audioTrack(_ i: PlayInfo) -> DashTrack? {
        let opts = audioOptions(i)
        return (opts.first { $0.key == audioKey } ?? opts.last { $0.key.hasPrefix("aac") } ?? opts.first)?.track
    }

    private var wantsVideo: Bool { content != .audio }
    private var wantsAudio: Bool { content != .video }
    private var makesMP3: Bool { content == .audio && audioFormat == .mp3 }

    /// Rough size from the bitrates, before (or without) the exact one.
    private func estimate(_ i: PlayInfo) -> Int {
        let secs = Double(duration > 0 ? duration : Int(i.duration))
        var bits = 0.0
        if wantsVideo, let v = videoTrack(i) { bits += Double(v.bandwidth) }
        if wantsAudio {
            if makesMP3 { bits += Double(MP3Encoder.bitrate * 1000) } else if let a = audioTrack(i) { bits += Double(a.bandwidth) }
        }
        return Int(bits * secs / 8)
    }

    private func selectionKey(_ i: PlayInfo) -> String {
        "\(content.rawValue)|\(videoTrack(i)?.codecs ?? "")|\(videoTrack(i)?.id ?? 0)|\(audioTrack(i)?.id ?? 0)|\(audioFormat.rawValue)"
    }

    // MARK: Layout

    @ViewBuilder private func form(_ i: PlayInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            field(L("内容")) {
                MiniSegment(options: DownloadContent.allCases.map { ($0, $0.label) }, selection: $content)
            }
            if wantsVideo {
                field(L("画质")) { qualityList(i) }
                field(L("编码")) {
                    VStack(alignment: .leading, spacing: 5) {
                        MiniSegment(options: codecs(i).map { ($0, $0 == "AVC" ? "H.264" : $0) },
                                    selection: Binding(get: { videoTrack(i)?.codecName ?? codecPref }, set: { codecPref = $0 }))
                        Text(codecHint(videoTrack(i)?.codecName)).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            if wantsAudio {
                field(L("音质")) {
                    MiniSegment(options: audioOptions(i).map { ($0.key, $0.label) },
                                selection: Binding(get: { audioOptions(i).first { $0.track == audioTrack(i) }?.key ?? audioKey },
                                                   set: { audioKey = $0 }))
                }
            }
            field(L("格式")) {
                VStack(alignment: .leading, spacing: 5) {
                    if content == .audio {
                        MiniSegment(options: AudioFileFormat.allCases.map { ($0, $0.label) },
                                    selection: $audioFormat, disabled: mp3 == nil ? [.mp3] : [])
                        Text(audioFormatHint(i)).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        MiniSegment(options: VideoFileFormat.allCases.map { ($0, $0.label) }, selection: $videoFormat)
                    }
                }
            }
            field(L("保存到")) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(Theme.text2)
                    Text(settings.downloadFolderName).font(.system(size: 13)).lineLimit(1)
                        .help((settings.downloadFolder.path as NSString).abbreviatingWithTildeInPath)
                    Button(L("更改…")) { _ = AppSettings.chooseDownloadFolder() }
                        .buttonStyle(.pressable).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.pink)
                }
            }
            field(L("预计大小")) {
                HStack(spacing: 6) {
                    if let exact, !makesMP3 {
                        Text(formatBytes(exact)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    } else {
                        Text(Lf("约 %@", formatBytes(estimate(i)))).font(.system(size: 15, weight: .bold)).monospacedDigit()
                        if !makesMP3 { ProgressView().controlSize(.mini) }
                    }
                }
            }
            .task(id: selectionKey(i)) {
                exact = nil
                guard !makesMP3 else { return }
                var tracks: [DashTrack] = []
                if wantsVideo, let v = videoTrack(i) { tracks.append(v) }
                if wantsAudio, let a = audioTrack(i) { tracks.append(a) }
                var sum = 0
                for t in tracks {
                    guard let s = await TrackSizes.shared.size(of: t) else { return }
                    sum += s
                }
                if !Task.isCancelled { exact = sum }
            }
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: L("取消")) { close() }
                PillButton(title: L("下载"), icon: "arrow.down.to.line", filled: true) { start(i) }
                    .disabled(wantsVideo && videoTrack(i) == nil || wantsAudio && audioTrack(i) == nil)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.text2).frame(width: 58, alignment: .leading)
            c().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func qualityList(_ i: PlayInfo) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(i.options, id: \.qn) { o in
                let tracks = i.videos.filter { $0.id == o.qn }
                let usable = o.available && !tracks.isEmpty
                Button { qn = o.qn } label: {
                    HStack(spacing: 8) {
                        Image(systemName: qn == o.qn ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13)).foregroundStyle(qn == o.qn ? Theme.pink : Theme.text3)
                        Text(o.label).font(.system(size: 13))
                        if let t = tracks.first { Text("\(t.width)×\(t.height)").font(Theme.mono).foregroundStyle(Theme.text3) }
                        Spacer()
                        if usable, let t = tracks.min(by: { $0.bandwidth < $1.bandwidth }) {
                            let secs = Double(duration > 0 ? duration : Int(i.duration))
                            Text(Lf("约 %@", formatBytes(Int(Double(t.bandwidth) * secs / 8))))
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3).monospacedDigit()
                        } else if !usable {
                            Label(app.account.loggedIn ? L("需要大会员") : L("需要登录"), systemImage: "lock.fill")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        }
                    }
                    .padding(.horizontal, 6).frame(height: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(!usable)
                .opacity(usable ? 1 : 0.5)
            }
        }
    }

    private func codecHint(_ c: String?) -> String {
        switch c {
        case "HEVC": return L("体积小，苹果设备都能直接播放")
        case "AV1": return L("体积最小，较老的设备可能放不了")
        default: return L("兼容性最好，几乎所有设备和软件都能放")
        }
    }

    private func audioFormatHint(_ i: PlayInfo) -> String {
        if mp3 == nil { return L("MP3 需要先安装 LAME：在终端运行 brew install lame") }
        if audioFormat == .mp3 { return Lf("转成 %@ kbps MP3，兼容性最好，会损失一点音质", "\(MP3Encoder.bitrate)") }
        switch audioTrack(i).map({ $0 == i.flac ? "flac" : $0 == i.dolby ? "dolby" : "aac" }) {
        case "flac": return L("原始 FLAC 无损音轨，不重新编码")
        case "dolby": return L("原始杜比音轨，不重新编码")
        default: return L("原始 AAC 音轨，不重新编码，音质无损失")
        }
    }

    private func start(_ i: PlayInfo) {
        let v = wantsVideo ? videoTrack(i) : nil
        let a = wantsAudio ? audioTrack(i) : nil
        var parts: [String] = []
        if let v {
            parts.append(qualityNames[v.id] ?? "\(v.height)P")
            parts.append(v.codecName == "AVC" ? "H.264" : v.codecName)
        }
        if let a, content == .audio { parts.append(a == i.flac ? L("Hi-Res 无损") : a == i.dolby ? L("杜比全景声") : "AAC") }
        parts.append(content == .audio ? audioFormat.label : videoFormat.label)
        let job = DownloadJob(bvid: bvid, cid: cid, title: title, owner: owner, cover: cover, content: content,
                              video: v, audio: a, videoFormat: videoFormat, audioFormat: audioFormat,
                              folder: settings.downloadFolder, summary: parts.joined(separator: " · "))
        DownloadCenter.shared.add(job)
        close()
        app.notify(L("已加入下载")) { AppModel.shared.go(.downloads) }
    }
}

/// A small segmented control for the download panel.
private struct MiniSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var disabled: Set<Value> = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { v, t in
                let on = v == selection
                Button { selection = v } label: {
                    Text(t).font(.system(size: 12.5, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? Theme.onPrimary : Theme.text2)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(on ? Theme.pink : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(disabled.contains(v))
                .opacity(disabled.contains(v) ? 0.4 : 1)
            }
        }
        .padding(2)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

// MARK: - 下载 page

struct DownloadsPage: View {
    @ObservedObject private var center = DownloadCenter.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        MainPanel(tint: Theme.tint(hex: 0x23413A, light: 0xDCEEE8)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("我的")).font(.system(size: 13, weight: .bold))
                        Text(L("下载")).font(.system(size: 48, weight: .black))
                        HStack(spacing: 10) {
                            Text(Lf("保存到 %@", (settings.downloadFolder.path as NSString).abbreviatingWithTildeInPath))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            PillButton(title: L("打开文件夹"), icon: "folder") { NSWorkspace.shared.open(settings.downloadFolder) }
                            PillButton(title: L("更改…")) { _ = AppSettings.chooseDownloadFolder() }
                            if center.tasks.contains(where: { !$0.isActive }) {
                                PillButton(title: L("清除已结束")) { center.clearFinished() }
                            }
                        }
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.text2)
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 6)
                    if center.tasks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(Theme.text3)
                            Text(L("还没有下载。在视频页点「下载」按钮开始。")).foregroundStyle(Theme.text2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        ForEach(center.tasks) { t in DownloadRow(task: t) }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct DownloadRow: View {
    @ObservedObject var task: DownloadTask
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: task.job.cover)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(task.job.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                Text("\(task.job.owner) · \(task.job.summary)").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(10)
        .background(hover ? Theme.raised : Theme.chip.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            if case .done(let url) = task.state {
                Button(L("打开")) { NSWorkspace.shared.open(url) }
                Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button(L("打开视频页")) { AppModel.shared.open(VideoCard(bvid: task.job.bvid, title: task.job.title, cover: task.job.cover, owner: task.job.owner)) }
            Button(task.isActive ? L("取消并移除") : L("从列表移除")) { DownloadCenter.shared.remove(task) }
        }
    }

    @ViewBuilder private var status: some View {
        switch task.state {
        case .queued:
            Text(L("等待中")).font(.system(size: 12)).foregroundStyle(Theme.text2)
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: task.fraction)
                Text(task.total > 0
                     ? "\(formatBytes(task.received)) / \(formatBytes(task.total)) · \(formatBytes(Int(task.speed)))/s"
                     : L("正在连接…"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
            }
        case .processing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressBar(fraction: 1)
                Text(L("正在生成文件…")).font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        case .done(let url):
            Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.pink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text(L("已取消")).font(.system(size: 12)).foregroundStyle(Theme.text3)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch task.state {
            case .done(let url):
                IconButton(icon: "play.fill", help: L("打开")) { NSWorkspace.shared.open(url) }
                IconButton(icon: "magnifyingglass", help: L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failed, .cancelled:
                IconButton(icon: "arrow.clockwise", help: L("重试")) { DownloadCenter.shared.retry(task) }
                IconButton(icon: "xmark", help: L("从列表移除")) { DownloadCenter.shared.remove(task) }
            default:
                IconButton(icon: "xmark", help: L("取消")) { task.cancel() }
            }
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line.opacity(0.5))
                Capsule().fill(Theme.pink).frame(width: max(4, g.size.width * fraction))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 420)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .frame(width: 32, height: 32)
                .background(hover ? Theme.menuHover : Theme.chip, in: Circle())
        }
        .buttonStyle(.pressable)
        .onHover { hover = $0 }
        .help(help)
    }
}
