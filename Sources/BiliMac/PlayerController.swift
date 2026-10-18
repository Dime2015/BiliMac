import AppKit
import AVFoundation
import Combine
import Foundation

/// Fast-changing playback state, split out so only the controls re-render 4×/s.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var buffered: Double = 0
    @Published var playing = false
    @Published var waiting = false
}

struct StatsSnapshot {
    var rows: [(String, String)] = []
    var history: [Double] = []      // download bits/s, one sample per second
}

/// Plays one bilibili video (bvid + cid) through the local DASH→HLS proxy.
@MainActor
final class PlayerController: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    let player = AVPlayer()
    let clock = PlaybackClock()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var info: PlayInfo?
    @Published private(set) var video: DashTrack?
    @Published private(set) var audio: DashTrack?
    @Published private(set) var danmaku: [Danmaku] = []
    /// Danmaku-density curve for the progress bar (0…1 per bin); empty when there's too little danmaku.
    @Published private(set) var heat: [Double] = []
    /// People in the picture, for 防挡弹幕.
    let masker = PersonMasker()
    let audioFX = AudioFX()

    /// 画质增强: what the super-resolution layer is doing right now (stats panel), nil when idle.
    @Published var superResStatus: String?
    /// Size of the current video track, for deciding whether upscaling helps.
    var pictureSourceSize: CGSize { video.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    /// HDR / Dolby Vision tracks keep the system's own HDR pipeline.
    var isHDR: Bool { video.map { $0.id == 125 || $0.id == 126 } ?? false }

    /// 音效处理: plays the audio in `audioFollower` (with the tap) instead of inside the HLS item.
    let audioFollower = AudioFollower()

    /// When 响度均衡 or 人声增强 is on, downloads the audio into the proxy, drops it from the HLS
    /// playlist and gets the follower ready. Returns false (normal playback) if anything fails.
    private func prepareAudioFX(stream s: HLSStream, previous: HLSStream?, masterURL: URL, at time: Double) async -> Bool {
        guard settings.audioLoudness || settings.audioVoice, let track = s.audio else {
            audioFollower.stop()
            return false
        }
        // Keep memory sane: skip files over ~120 MB (very long videos).
        let duration = info?.duration ?? 0
        guard Double(track.dash.bandwidth) / 8 * max(duration, 60) < 120_000_000 else {
            log("audio fx: audio too large, playing normally")
            audioFollower.stop()
            return false
        }
        do {
            if let prev = previous, prev.audio?.dash == track.dash, let data = prev.audioData {
                s.audioData = data
            } else {
                s.audioData = try await withTimeout(seconds: 10) { try await HLSProxy.shared.fetchWhole(track, stats: s.stats) }
            }
            s.videoOnly = true
            audioFX.loudnessOn = settings.audioLoudness
            audioFX.voiceOn = settings.audioVoice
            audioFX.staticGainDB = info?.loudnessGainDB.map(Float.init)
            try await audioFollower.prepare(url: masterURL.deletingLastPathComponent().appendingPathComponent("audio.m4s"),
                                            fx: audioFX, at: time)
            return true
        } catch {
            log("audio fx unavailable, playing normally: \(error)")
            s.videoOnly = false
            s.audioData = nil
            audioFollower.stop()
            return false
        }
    }

    /// Settings changed: update the effect live, or re-attach when the path has to change.
    private func audioSettingsChanged(loudness: Bool, voice: Bool) {
        audioFX.loudnessOn = loudness
        audioFX.voiceOn = voice
        if (loudness || voice) != audioFollower.active, stream != nil { reloadStream() }
    }

    @Published var rate: Float = 1 {
        didSet {
            player.defaultRate = rate
            if player.rate != 0 { player.rate = rate }
            if oldValue != rate { flash(rate == 1 ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent", String(format: "%gx", rate)) }
        }
    }

    /// Centre-of-picture feedback (play/pause, seek, volume, speed), YouTube-style.
    struct Flash: Equatable { let id = UUID(); let icon: String; let text: String? }
    @Published private(set) var flash: Flash?
    func flash(_ icon: String, _ text: String? = nil) { flash = Flash(icon: icon, text: text) }

    // MARK: Scrub previews

    @Published private(set) var shots: Videoshot?
    private var shotsRequested = false
    private var shotFrames: [String: NSImage] = [:]

    func loadShotsIfNeeded() {
        guard !shotsRequested, !bvid.isEmpty, cid > 0 else { return }
        shotsRequested = true
        let (b, c) = (bvid, cid)
        Task {
            guard let s = try? await BiliAPI.shared.videoshot(bvid: b, cid: c), b == bvid else { return }
            shots = s
            for u in s.images { _ = await ImageCache.shared.load(u) }   // warm the sprite sheets
        }
    }

    /// Thumbnail for `t` seconds, or nil while the sprite sheet is still loading.
    func previewImage(at t: Double) -> NSImage? {
        guard let s = shots, let cell = s.cell(at: t) else { return nil }
        let key = "\(cell.url.absoluteString)#\(Int(cell.rect.minX)),\(Int(cell.rect.minY))"
        if let img = shotFrames[key] { return img }
        guard let sheet = ImageCache.shared.cached(cell.url),
              let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Sheets can be served at a different scale than img_x_size × columns suggests.
        let sx = CGFloat(cg.width) / CGFloat(s.width * s.columns), sy = CGFloat(cg.height) / CGFloat(s.height * s.rows)
        let r = CGRect(x: cell.rect.minX * sx, y: cell.rect.minY * sy, width: cell.rect.width * sx, height: cell.rect.height * sy)
        guard let crop = cg.cropping(to: r.integral) else { return nil }
        let img = NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        if shotFrames.count > 400 { shotFrames.removeAll() }
        shotFrames[key] = img
        return img
    }

    @Published private(set) var bvid = ""
    @Published private(set) var cid = 0
    private(set) var aid: Int?
    private(set) var stream: HLSStream?
    var onEnd: (() -> Void)?

    private var loadTask: Task<Void, Never>?
    private var itemObservers: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var tcsObserver: NSKeyValueObservation?
    private var ticker: Timer?
    private var history: [Double] = []
    private var realPlayed: Double = 0
    private var lastTick: Double?
    private var startTS = Int(Date().timeIntervalSince1970)
    private var sentFirstBeat = false
    private var lastBeat = Date.distantPast
    private var loadStarted = Date()
    private(set) var startupTime: Double?

    private let settings = AppSettings.shared

    private var bag = Set<AnyCancellable>()

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        settings.$audioLoudness.combineLatest(settings.$audioVoice).dropFirst().removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] l, v in self?.audioSettingsChanged(loudness: l, voice: v) }
            .store(in: &bag)
        // Dolby Vision played the official way or with its metadata: only matters for HDR tracks.
        settings.$dolbyVisionOfficial.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.isHDR == true { self?.reloadStream() } }
            .store(in: &bag)
        player.volume = settings.volume
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        tcsObserver = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let st = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.clock.playing = st == .playing
                let waiting = st == .waitingToPlayAtSpecifiedRate
                if waiting != self.clock.waiting { self.clock.waiting = waiting; self.waitingChanged(waiting) }
                if st == .paused { self.beat(force: true) }
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        ticker?.invalidate()
    }

    // MARK: Loading

    func load(bvid: String, cid: Int, aid: Int?, autoplay: Bool = true, resume: Bool = true) {
        teardownItem()
        self.bvid = bvid
        self.cid = cid
        self.aid = aid
        info = nil
        shots = nil
        shotsRequested = false
        shotFrames = [:]
        video = nil
        audio = nil
        danmaku = []
        heat = []
        history = []
        realPlayed = 0
        sentFirstBeat = false
        startupTime = nil
        manualQuality = false
        stallTimes = []
        startTS = Int(Date().timeIntervalSince1970)
        loadStarted = Date()
        clock.time = 0
        clock.duration = 0
        clock.buffered = 0
        phase = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            async let dm: [Danmaku] = (try? await Danmaku.load(cid: cid)) ?? []
            do {
                let info = try await BiliAPI.shared.playInfo(bvid: bvid, cid: cid)
                guard !Task.isCancelled else { return }
                self.info = info
                let v = info.pickVideo(order: self.settings.qualityOrder, codec: self.settings.codec)
                var start: Double = 0
                if resume, self.settings.resumePlayback, !Env.demo, let t = info.lastPlayTime,
                   info.lastPlayCid == nil || info.lastPlayCid == cid, t > 5, info.duration == 0 || t < info.duration - 10 {
                    start = t
                }
                var play = autoplay
                if let t = Env.startAt { start = t; play = false }
                try await self.attach(video: v, audio: info.bestAudio, at: start, play: play)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
                log("\(bvid) load error: \(error)")
            }
            let list = await dm
            if !Task.isCancelled {
                self.danmaku = list
                let duration = self.info?.duration ?? 0
                self.heat = Danmaku.heat(list, duration: duration > 0 ? duration : self.clock.duration)
            }
        }
    }

    private func attach(video v: DashTrack, audio a: DashTrack?, at time: Double, play: Bool) async throws {
        let sid = "\(bvid)-\(cid)-\(v.id)-\(Int(Date().timeIntervalSince1970 * 1000) % 10_000_000)"
        let s = try await HLSProxy.shared.prepare(id: sid, video: v, audio: a, node: settings.cdnNode)
        guard !Task.isCancelled else { return }
        let url = HLSProxy.shared.register(s)
        let old = stream
        stream = s
        video = v
        audio = a
        let fxReady = await prepareAudioFX(stream: s, previous: old, masterURL: url, at: time)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        masker.attach(item)
        itemObservers = [item.observe(\.status) { [weak self] it, _ in
            let st = it.status, err = it.error
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .readyToPlay:
                    if self.startupTime == nil { self.startupTime = Date().timeIntervalSince(self.loadStarted) }
                    self.phase = .ready
                case .failed:
                    self.phase = .failed(err?.localizedDescription ?? L("播放失败"))
                    log("\(self.bvid) item failed: \(String(describing: err))")
                default: break
                }
            }
        }]
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = [NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.beat(force: true)
                self?.onEnd?()
            }
        }]
        attachedAt = Date()
        player.replaceCurrentItem(with: item)
        if time > 0 { await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        if fxReady { audioFollower.follow(player) }
        if play { player.playImmediately(atRate: rate) }
        if let old { HLSProxy.shared.unregister(old.id) }
        log(String(format: "%@ p%ld %@ %@ %dx%d %@ cdn=%@", bvid, cid, shortQuality(v.id), v.codecs, v.width, v.height,
                   formatBitrate(Double(v.bandwidth)), s.video.urls.first?.host ?? "?"))
    }

    /// A quality picked by hand sticks for this video: no automatic stepping down.
    func setQuality(_ qn: Int) {
        manualQuality = true
        switchQuality(qn)
    }

    private func switchQuality(_ qn: Int) {
        guard let info, video?.id != qn, info.videos.contains(where: { $0.id == qn }) else { return }
        let t = player.currentTime().seconds
        let wasPlaying = player.rate != 0
        let v = info.pickVideo(qn: qn, codec: settings.codec)
        phase = .loading
        loadStarted = Date()
        Task {
            do { try await attach(video: v, audio: audio, at: t.isFinite ? t : 0, play: wasPlaying) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// Re-attach the same tracks (used when the CDN node changes).
    func reloadStream() {
        guard let v = video else { return }
        let t = player.currentTime().seconds
        let wasPlaying = player.rate != 0
        Task {
            do { try await attach(video: v, audio: audio, at: t.isFinite ? t : 0, play: wasPlaying) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    func retry() { load(bvid: bvid, cid: cid, aid: aid) }

    // MARK: Transport

    func play() { player.playImmediately(atRate: rate) }
    func pause() { player.pause() }
    func togglePlay() {
        if player.rate == 0 { play(); flash("play.fill") } else { pause(); flash("pause.fill") }
    }

    // MARK: Stepping down when the network can't keep up

    private(set) var manualQuality = false
    private var stallTimes: [Date] = []
    private var stallTask: Task<Void, Never>?
    private var lastDowngrade = Date.distantPast
    private var attachedAt = Date()
    private var lastSeek = Date.distantPast

    /// Two stalls within 45 s, or one that lasts over 4 s, step the quality down one entry in the order.
    /// Start-up and seeks into unbuffered video don't count.
    private func waitingChanged(_ waiting: Bool) {
        stallTask?.cancel()
        guard waiting, settings.autoDowngrade, !manualQuality, phase == .ready,
              Date().timeIntervalSince(attachedAt) > 3, Date().timeIntervalSince(lastSeek) > 6 else { return }
        let now = Date()
        stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 45 } + [now]
        if stallTimes.count >= 2 { stepDown(); return }
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.clock.waiting else { return }
            self.stepDown()
        }
    }

    private func stepDown() {
        guard let info, let cur = video?.id, Date().timeIntervalSince(lastDowngrade) > 15,
              let next = info.nextLower(after: cur, order: settings.qualityOrder) else { return }
        lastDowngrade = Date()
        stallTimes = []
        log("\(bvid) stalls at \(shortQuality(cur)) → \(shortQuality(next))")
        switchQuality(next)
        if AppModel.shared.nowPlaying === self {
            AppModel.shared.notify(Lf("网络跟不上 %@，已切到 %@", "\(shortQuality(cur))", "\(qualityNames[next] ?? shortQuality(next))"))
        }
    }

    func seek(to secs: Double) {
        lastSeek = Date()
        let d = clock.duration > 0 ? clock.duration : .greatestFiniteMagnitude
        let t = min(max(0, secs), d - 0.5)
        clock.time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(by delta: Double) {
        seek(to: player.currentTime().seconds + delta)
        let n = Int(abs(delta))
        flash(delta < 0 ? "gobackward" : "goforward", Lf(delta < 0 ? "-%@ 秒" : "+%@ 秒", "\(n)"))
    }

    func setVolume(_ v: Float, feedback: Bool = false) {
        player.volume = min(max(v, 0), 1)
        player.isMuted = false
        settings.volume = player.volume
        if feedback { flash(player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", "\(Int((player.volume * 100).rounded()))%") }
        objectWillChange.send()
    }

    func toggleMute() { player.isMuted.toggle(); objectWillChange.send() }

    /// Stops playback and releases the stream (reports final progress first).
    func stop() {
        beat(force: true)
        loadTask?.cancel()
        teardownItem()
        phase = .idle
    }

    private func teardownItem() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        audioFollower.stop()
        masker.attach(nil)
        itemObservers.removeAll()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        if let s = stream { HLSProxy.shared.unregister(s.id) }
        stream = nil
    }

    // MARK: Clock, heartbeat, stats

    private func tick(_ t: Double) {
        guard let item = player.currentItem else { return }
        if t.isFinite { clock.time = t }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { clock.duration = d } else if let info, info.duration > 0 { clock.duration = info.duration }
        let cur = item.currentTime().seconds
        clock.buffered = item.loadedTimeRanges.map(\.timeRangeValue).first {
            $0.start.seconds <= cur + 0.5 && $0.end.seconds >= cur
        }?.end.seconds ?? cur
        if clock.playing, let last = lastTick, t > last, t - last < 2 { realPlayed += t - last }
        lastTick = t
        beat(force: false)
    }

    private func beat(force: Bool) {
        guard settings.reportHistory, CookieJar.shared["SESSDATA"] != nil, !bvid.isEmpty, phase == .ready,
              ProcessInfo.processInfo.environment["BILIMAC_NOHEARTBEAT"] == nil, !Env.demo else { return }
        guard force || Date().timeIntervalSince(lastBeat) >= 15 else { return }
        guard force || clock.playing else { return }
        lastBeat = Date()
        let first = !sentFirstBeat
        sentFirstBeat = true
        let (aid, bvid, cid) = (aid, bvid, cid)
        let played = Int(clock.time), real = Int(realPlayed), start = startTS
        Task.detached { await BiliAPI.shared.heartbeat(aid: aid, bvid: bvid, cid: cid, played: played, realPlayed: real, start: start, first: first) }
    }

    private func sample() {
        guard let s = stream else { return }
        history.append(s.stats.rate(window: 1))
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    func stats() -> StatsSnapshot {
        var rows: [(String, String)] = []
        rows.append((L("视频"), "\(bvid) · cid \(cid)"))
        if let v = video {
            let fps = Double(v.frameRate).map { String(format: " @ %.0f fps", $0) } ?? ""
            rows.append((L("画面"), "\(v.width)×\(v.height)\(fps)"))
            rows.append((L("画质"), Lf("%@（qn %@）", "\(qualityNames[v.id] ?? "\(v.id)")", "\(v.id)")))
            rows.append((L("视频编码"), "\(v.codecName) · \(v.codecs)"))
            var rate = Lf("平均 %@", "\(formatBitrate(Double(v.bandwidth)))")
            if let p = stream?.videoPeak { rate += Lf(" · 峰值 %@", "\(formatBitrate(Double(p)))") }
            rows.append((L("视频码率"), rate))
        }
        if let a = audio { rows.append((L("音频"), "\(a.codecName) · \(a.codecs) · \(formatBitrate(Double(a.bandwidth)))")) }
        if audioFollower.active {
            let fx = [settings.audioLoudness ? L("响度均衡") : nil, settings.audioVoice ? L("人声增强") : nil].compactMap { $0 }
            let gain = info?.loudnessGainDB.map { String(format: " · %+.1f dB", $0) } ?? ""
            rows.append((L("音效"), fx.joined(separator: " + ") + gain))
        }
        if let sr = superResStatus { rows.append((L("超分"), sr)) }
        if let s = stream {
            let host = s.stats.lastHost ?? s.video.urls.first?.host ?? "-"
            rows.append((L("线路"), "\(settings.cdnNode.short) · \(host)"))
            rows.append((L("下载速度"), Lf("实时 %@", "\(formatBitrate(s.stats.rate(window: 1)))")))
            if let r = s.stats.segmentRate() { rows.append((L("线路吞吐"), formatBitrate(r))) }
            rows.append((L("已下载"), formatBytes(s.stats.total)))
        }
        let ahead = max(0, clock.buffered - clock.time)
        rows.append((L("缓冲"), String(format: L("%.1f 秒"), ahead)))
        if let ev = player.currentItem?.accessLog()?.events.last {
            rows.append((L("播放器带宽"), formatBitrate(ev.observedBitrate)))
            rows.append((L("卡顿 / 丢帧"), "\(ev.numberOfStalls) / \(ev.numberOfDroppedVideoFrames)"))
        }
        if let st = startupTime { rows.append((L("起播耗时"), String(format: L("%.2f 秒"), st))) }
        return StatsSnapshot(rows: rows, history: history)
    }

    /// Short line for the bottom bar badge.
    var badge: String {
        guard let v = video else { return "" }
        var parts = [shortQuality(v.id), v.codecName]
        if let s = stream {
            parts.append(cdnShortName(s.stats.lastHost ?? s.video.urls.first?.host ?? ""))
            parts.append(formatBitrate(s.stats.segmentRate() ?? s.stats.rate(window: 2)))
        }
        return parts.joined(separator: " · ")
    }

    /// Items for the info strip above the video.
    /// compact 0 = everything; 1 = short quality name, no frame rate; 2 = also no resolution or audio.
    func infoChips(compact: Int = 0) -> [InfoChip] {
        guard let v = video else { return [] }
        var c: [InfoChip] = [InfoChip(label: L("画质"), value: compact > 0 ? shortQuality(v.id) : (qualityNames[v.id] ?? shortQuality(v.id)), accent: true)]
        let fps = Double(v.frameRate).map { String(format: " · %.0f fps", $0) } ?? ""
        if compact < 2 { c.append(InfoChip(label: L("画面"), value: "\(v.width)×\(v.height)\(compact > 0 ? "" : fps)")) }
        c.append(InfoChip(label: v.codecName, value: formatBitrate(Double(v.bandwidth))))
        if compact < 2, let a = audio { c.append(InfoChip(label: a.codecName, value: formatBitrate(Double(a.bandwidth)))) }
        if let s = stream {
            let rates = s.stats.hostRates()
            if rates.isEmpty {
                c.append(InfoChip(label: cdnShortName(s.video.urls.first?.host ?? ""), value: "↓ —"))
            }
            for r in rates { c.append(InfoChip(label: cdnShortName(r.host), value: "↓ " + formatBitrate(r.bps), accent: r.bps > 0)) }
        }
        c.append(InfoChip(label: L("缓冲"), value: String(format: L("%.0f 秒"), max(0, clock.buffered - clock.time))))
        return c
    }

    /// Enhancements that are switched on, for the info strip: icon, short value, whether it's
    /// working right now, and a tooltip.
    func enhancementBadges() -> [EnhancementBadge] {
        var out: [EnhancementBadge] = []
        if settings.superResolution {
            // superResStatus: "ML 1.5× + MetalFX · 1280x720 → 1880x1058 · 6.1 ms"
            let engine = superResStatus?.components(separatedBy: " · ").first
            let short = engine.map { e in e.hasPrefix("ML") ? (e.components(separatedBy: " ").dropFirst().first ?? "ML") : "FX" }
            out.append(EnhancementBadge(icon: "sparkles", value: short, active: engine != nil,
                                        help: L("画质增强") + L("：") + (superResStatus ?? L("画面没有放大，或是 HDR 视频，暂不处理"))))
        }
        if settings.audioLoudness {
            let g = info?.loudnessGainDB.map { String(format: "%+.1f", $0) }
            out.append(EnhancementBadge(icon: "speaker.wave.2.fill", value: audioFollower.active ? (g ?? L("自动")) : nil, active: audioFollower.active,
                                        help: L("响度均衡") + L("：") + (audioFollower.active ? (g.map { $0 + " dB" } ?? L("自动")) : L("未生效"))))
        }
        if settings.audioVoice {
            out.append(EnhancementBadge(icon: "person.wave.2.fill", value: nil, active: audioFollower.active,
                                        help: L("人声增强") + (audioFollower.active ? "" : L("：") + L("未生效"))))
        }
        if settings.danmakuOn, settings.danmakuAvoidPeople {
            out.append(EnhancementBadge(icon: "person.fill.viewfinder", value: nil, active: true, help: L("防挡人物")))
        }
        return out
    }
}

struct EnhancementBadge: Hashable {
    let icon: String
    let value: String?
    let active: Bool
    let help: String
}

struct InfoChip: Hashable {
    let label: String
    let value: String
    var accent = false
}

/// "upos-sz-mirror08c.bilivideo.com" → "08c", "upos-hz-mirrorakam.akamaized.net" → "akam".
func cdnShortName(_ host: String) -> String {
    var h = host
    for p in ["upos-sz-mirror", "upos-hz-mirror", "upos-bstar1-mirror", "upos-"] where h.hasPrefix(p) { h = String(h.dropFirst(p.count)); break }
    return h.split(separator: ".").first.map(String.init) ?? host
}
