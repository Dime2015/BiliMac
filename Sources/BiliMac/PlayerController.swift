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
    /// 互动弹幕: the creator's polls and ratings, by time.
    @Published private(set) var interactions: [InteractiveDm] = []
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

    /// How 音效处理 starts for a new stream.
    private enum FXStart { case off, ready, later(HLSStream.Track) }

    /// When 响度均衡 or 人声增强 is on, the audio plays in `audioFollower`, which needs the whole audio file.
    /// If the previous stream already had it (a quality change), the follower is set up now; otherwise the
    /// video starts with its own sound and the file is fetched in the background (`loadAudioFXLater`).
    /// Fetching it first held a 4K video back by 10 s or more (one throttled connection for the whole file).
    private func prepareAudioFX(stream s: HLSStream, previous: HLSStream?, at time: Double) async -> FXStart {
        guard settings.audioLoudness || settings.audioVoice, let track = s.audio else {
            audioFollower.stop()
            return .off
        }
        // Hi-Res 无损 / 杜比全景声 play untouched: too big to fetch whole quickly, and the point is the original sound.
        guard audioKind == .standard else {
            log("audio fx: skipped for \(track.dash.codecName) track")
            audioFollower.stop()
            return .off
        }
        // Keep memory sane: skip files over ~120 MB (very long videos).
        let duration = info?.duration ?? 0
        guard Double(track.dash.bandwidth) / 8 * max(duration, 60) < 120_000_000 else {
            log("audio fx: audio too large, playing normally")
            audioFollower.stop()
            return .off
        }
        guard let prev = previous, prev.audio?.dash == track.dash, let data = prev.audioData else {
            audioFollower.stop()
            return .later(track)
        }
        do {
            s.audioData = data
            s.videoOnly = true
            configureFX()
            try await audioFollower.prepare(data: data, fx: audioFX, at: time)
            return .ready
        } catch {
            log("audio fx unavailable, playing normally: \(error)")
            s.videoOnly = false
            s.audioData = nil
            audioFollower.stop()
            return .off
        }
    }

    private func configureFX() {
        audioFX.loudnessOn = settings.audioLoudness
        audioFX.voiceOn = settings.audioVoice
        audioFX.staticGainDB = info?.loudnessGainDB.map(Float.init)
    }

    private var fxTask: Task<Void, Never>?

    /// Fetches the audio once the video is playing, then hands the sound over to the follower: it starts in step
    /// with the video, and the stream's own audio is switched off.
    private func loadAudioFXLater(stream s: HLSStream, track: HLSStream.Track) {
        fxTask?.cancel()
        let (b, c) = (bvid, cid)
        let node = settings.cdnNode
        fxTask = Task { [weak self] in
            // Let the picture start first: the audio file would compete with the first video segments.
            while !Task.isCancelled {
                guard let self, self.stream === s else { return }
                if self.everReady { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let started = Date()
            do {
                let data = try await Self.fetchWholeTrack(track.dash, node: node, bvid: b, cid: c)
                guard let self, !Task.isCancelled, self.stream === s, let item = self.player.currentItem else { return }
                guard let group = try await item.asset.loadMediaSelectionGroup(for: .audible), group.allowsEmptySelection else {
                    throw APIError(description: "the stream's audio can't be switched off")
                }
                s.audioData = data
                self.configureFX()
                try await self.audioFollower.prepare(data: data, fx: self.audioFX, at: self.player.currentTime().seconds)
                guard !Task.isCancelled, self.stream === s, self.player.currentItem === item else { self.audioFollower.stop(); return }
                self.audioFollower.follow(self.player)
                // Switch the stream's sound off once the follower is actually playing (it starts a moment ahead,
                // in step), so the change-over has neither a gap nor a double.
                if self.player.rate != 0 {
                    for _ in 0..<15 where self.audioFollower.player.rate == 0 { try? await Task.sleep(for: .milliseconds(100)) }
                }
                guard !Task.isCancelled, self.stream === s, self.player.currentItem === item else { self.audioFollower.stop(); return }
                item.select(nil, in: group)
                s.videoOnly = true
                self.objectWillChange.send()   // the 音效 badges
                log(String(format: "%@ audio fx: on after %.1f s in the background (%@)", b, Date().timeIntervalSince(started),
                           formatBytes(data.count)))
            } catch {
                guard !Task.isCancelled else { return }
                log("audio fx unavailable, playing normally: \(error)")
                self?.audioFollower.stop()
            }
        }
    }

    /// The whole file of a track, in parallel ranges (one connection is throttled by the CDN).
    nonisolated static func fetchWholeTrack(_ t: DashTrack, node: CDNNode, bvid: String, cid: Int) async throws -> Data {
        var track = t
        var size = await TrackSizes.shared.size(of: track)
        if size == nil {
            track = try DownloadTask.same(t, in: try await BiliAPI.shared.playInfo(bvid: bvid, cid: cid))
            size = await TrackSizes.shared.size(of: track)
        }
        guard let size else { throw APIError(description: "no size for the audio track") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bilimac-fx-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let fetcher = TrackFetcher(track: track, node: node) {
            try DownloadTask.same(track, in: try await BiliAPI.shared.playInfo(bvid: bvid, cid: cid))
        }
        try await fetcher.fetch(total: size, to: file) { _ in }
        return try Data(contentsOf: file)
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
        settings.$audioPref.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] pref in self?.audioPrefChanged(pref) }
            .store(in: &bag)
        // Dolby Vision played the official way or with its metadata: only matters for HDR tracks.
        settings.$dolbyVisionOfficial.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in if self?.isHDR == true { self?.reloadStream() } }
            .store(in: &bag)
        player.volume = settings.volume
        if Env.mute { player.isMuted = true }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        tcsObserver = player.observe(\.timeControlStatus) { [weak self] p, _ in
            let st = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.clock.playing = st == .playing
                if st == .playing, !self.startLogged { self.startLogged = true; self.mark("playing") }
                let waiting = st == .waitingToPlayAtSpecifiedRate
                if waiting != self.clock.waiting { self.clock.waiting = waiting; self.waitingChanged(waiting) }
                if st == .paused { self.beat(force: true) }
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
                self?.considerStepUp()
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        ticker?.invalidate()
    }

    /// Sends a danmaku at the current time and shows it right away.
    func sendDanmaku(_ text: String, mode: Int, color: UInt32) async throws {
        guard let aid else { throw APIError(description: L("视频信息还没加载完")) }
        let t = max(0, player.currentTime().seconds)
        try await BiliAPI.shared.sendDanmaku(aid: aid, cid: cid, text: text, progressMs: Int(t * 1000), mode: mode, color: color)
        // Slightly ahead so it enters from the edge instead of popping up mid-screen.
        let d = Danmaku(time: t + 0.1, mode: mode, size: 25, color: color, text: text, mine: true)
        let i = danmaku.firstIndex { $0.time > d.time } ?? danmaku.count
        danmaku.insert(d, at: i)
    }

    /// Keeps an answered poll / rating so it shows the result if it comes round again.
    func answer(_ item: InteractiveDm) {
        if let i = interactions.firstIndex(where: { $0.id == item.id }) { interactions[i] = item }
    }

    // MARK: Loading

    /// startAt: open at this position (seconds) instead of the start / the account's resume point.
    func load(bvid: String, cid: Int, aid: Int?, autoplay: Bool = true, resume: Bool = true, startAt: Double? = nil) {
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
        interactions = []
        history = []
        realPlayed = 0
        sentFirstBeat = false
        startupTime = nil
        manualQuality = false
        everReady = false
        startLogged = false
        lastRecovery = .distantPast
        stallTimes = []
        lastStall = .distantPast
        lastUpgrade = .distantPast
        upgradeBackoff = 30
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
            async let cmds: [InteractiveDm] = (try? await BiliAPI.shared.interactiveDanmaku(aid: aid, cid: cid)) ?? []
            do {
                let info = try await BiliAPI.shared.playInfo(bvid: bvid, cid: cid)
                guard !Task.isCancelled else { return }
                self.mark("play url")
                self.info = info
                let v = info.pickVideo(order: self.settings.qualityOrder, codec: self.settings.codec)
                var start: Double = startAt ?? 0
                if startAt == nil, resume, self.settings.resumePlayback, !Env.demo, let t = info.lastPlayTime,
                   info.lastPlayCid == nil || info.lastPlayCid == cid, t > 5, info.duration == 0 || t < info.duration - 10 {
                    start = t
                }
                var play = autoplay
                if let t = Env.startAt { start = t; play = false }
                try await self.attach(video: v, audio: info.pickAudio(self.settings.audioPref), at: start, play: play)
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
            let interactive = await cmds
            if !Task.isCancelled {
                self.interactions = interactive
                if !interactive.isEmpty { log("\(bvid) interactive danmaku: \(interactive.map { "\($0.isVote ? "vote" : "grade")@\(Int($0.time))s" }.joined(separator: " "))") }
            }
        }
    }

    private func attach(video v: DashTrack, audio a: DashTrack?, at time: Double, play: Bool) async throws {
        let sid = "\(bvid)-\(cid)-\(v.id)-\(Int(Date().timeIntervalSince1970 * 1000) % 10_000_000)"
        let s = try await HLSProxy.shared.prepare(id: sid, video: v, audio: a, node: settings.cdnNode)
        guard !Task.isCancelled else { return }
        mark("segment index")
        let (b, c) = (bvid, cid)
        s.refresher = { [weak self] in
            let info = try await BiliAPI.shared.playInfo(bvid: b, cid: c)
            let fresh = try Self.sameTracks(in: info, video: v, audio: a)
            await self?.urlsRefreshed(info, fresh, stream: sid)
            return fresh
        }
        if let how = Env.testExpired { s.spoilURLsForTesting(how); log("test: \(how) spoiled, expires \(s.expiry.map { "\($0)" } ?? "?")") }
        let url = HLSProxy.shared.register(s)
        let old = stream
        stream = s
        video = v
        audio = a
        fxTask?.cancel()
        let fx = await prepareAudioFX(stream: s, previous: old, at: time)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        masker.attach(item)
        itemObservers = [item.observe(\.status) { [weak self] it, _ in
            let st = it.status, err = it.error
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .readyToPlay:
                    self.mark("ready to play")
                    self.everReady = true
                    if self.startupTime == nil { self.startupTime = Date().timeIntervalSince(self.loadStarted) }
                    self.phase = .ready
                    if self.audioKind != .standard, !self.audioFollower.active {
                        // Confirms the lossless / Dolby track is really being decoded, not silently dropped.
                        let audible = it.tracks.contains { $0.assetTrack?.mediaType == .audio && $0.isEnabled }
                        log("\(self.bvid) \(self.audio?.codecName ?? "") audio track \(audible ? "playing" : "missing")")
                    }
                case .failed:
                    log("\(self.bvid) item failed: \(String(describing: err))")
                    // Mid-video (often after a sleep, with the network still coming back): load it again where it was.
                    if self.everReady, self.player.currentItem === it, Date().timeIntervalSince(self.lastRecovery) > 30 {
                        self.recover()
                    } else {
                        self.phase = .failed(err?.localizedDescription ?? L("播放失败"))
                    }
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
        switch fx {
        case .ready: audioFollower.follow(player)
        case .later(let track): loadAudioFXLater(stream: s, track: track)
        case .off: break
        }
        if play { player.playImmediately(atRate: rate) }
        if let old { HLSProxy.shared.unregister(old.id) }
        log(String(format: "%@ p%ld %@ %@ %dx%d %@ cdn=%@", bvid, cid, shortQuality(v.id), v.codecs, v.width, v.height,
                   formatBitrate(Double(v.bandwidth)), s.video.urls.first?.host ?? "?"))
    }

    /// The tracks matching `v` / `a` in a newly fetched PlayInfo: same quality, codec and file layout, so
    /// the segment table built from the old URLs fits the new ones.
    nonisolated static func sameTracks(in info: PlayInfo, video v: DashTrack, audio a: DashTrack?) throws -> (video: DashTrack, audio: DashTrack?) {
        func same(_ x: DashTrack, _ y: DashTrack) -> Bool {
            x.id == y.id && x.codecs == y.codecs && x.initRange == y.initRange && x.indexRange == y.indexRange
        }
        guard let nv = info.videos.first(where: { same($0, v) }) else { throw APIError(description: "video track no longer offered") }
        guard let a else { return (nv, nil) }
        let audios = info.audios + [info.flac, info.dolby].compactMap { $0 }
        guard let na = audios.first(where: { same($0, a) }) else { throw APIError(description: "audio track no longer offered") }
        return (nv, na)
    }

    /// The proxy signed new URLs for the playing stream: keep the quality list's URLs fresh as well, so
    /// switching quality or audio later doesn't start from expired ones.
    private func urlsRefreshed(_ fresh: PlayInfo, _ tracks: (video: DashTrack, audio: DashTrack?), stream sid: String) {
        guard stream?.id == sid else { return }
        info = fresh
        video = tracks.video
        audio = tracks.audio
    }

    /// Before building a new stream from the URLs in `info`: if the playing stream's have expired, so have
    /// those; refreshing it updates `info`, `video` and `audio` too.
    private func refreshIfStale() async {
        if let s = stream, s.isStale { _ = await s.refreshURLs() }
    }

    private var everReady = false
    private var startLogged = false

    /// Start-up timeline in the log: how long from opening the video to each step.
    private func mark(_ step: String) {
        guard !startLogged || step == "playing" else { return }
        log(String(format: "%@ startup: %@ at %.2f s", bvid, step, Date().timeIntervalSince(loadStarted)))
    }
    private var lastRecovery = Date.distantPast

    /// Reloads the current video at the current position with a newly fetched play URL.
    private func recover() {
        lastRecovery = Date()
        let (b, c, t) = (bvid, cid, player.currentTime().seconds)
        let qn = video?.id, oldAudio = audio
        phase = .loading
        loadStarted = Date()
        log("\(b) recovering at \(Int(t.isFinite ? t : 0))s")
        Task {
            // Give the network a moment after a wake.
            try? await Task.sleep(for: .seconds(2))
            do {
                let fresh = try await BiliAPI.shared.playInfo(bvid: b, cid: c)
                guard b == bvid, c == cid else { return }
                info = fresh
                let v = qn.map { fresh.pickVideo(qn: $0, codec: settings.codec) } ?? fresh.pickVideo(order: settings.qualityOrder, codec: settings.codec)
                let a = oldAudio.flatMap { old in
                    (fresh.audios + [fresh.flac, fresh.dolby].compactMap { $0 }).first { $0.id == old.id && $0.codecs == old.codecs }
                } ?? fresh.pickAudio(settings.audioPref)
                try await attach(video: v, audio: a, at: t.isFinite ? t : 0, play: true)
            } catch {
                guard b == bvid, c == cid else { return }
                phase = .failed(error.localizedDescription)
                log("\(b) recovery failed: \(error)")
            }
        }
    }

    /// The video's aid, once its details are in (a load started from a card without one).
    func adoptAid(_ aid: Int) { if self.aid == nil { self.aid = aid } }

    /// A quality picked by hand sticks for this video: no automatic stepping down.
    func setQuality(_ qn: Int) {
        manualQuality = true
        switchQuality(qn)
    }

    private func switchQuality(_ qn: Int) {
        guard let info, video?.id != qn, info.videos.contains(where: { $0.id == qn }) else { return }
        let t = player.currentTime().seconds
        let wasPlaying = player.rate != 0
        phase = .loading
        loadStarted = Date()
        Task {
            await refreshIfStale()
            guard let info = self.info else { return }
            let v = info.pickVideo(qn: qn, codec: settings.codec)
            do { try await attach(video: v, audio: audio, at: t.isFinite ? t : 0, play: wasPlaying) }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// Hi-Res 无损 / 杜比全景声 / standard: what the current audio track is.
    enum AudioKind { case hiRes, dolby, standard }
    var audioKind: AudioKind {
        guard let a = audio, let info else { return .standard }
        if a == info.flac { return .hiRes }
        if a == info.dolby { return .dolby }
        return .standard
    }

    private func audioPrefChanged(_ pref: AudioPref) {
        guard let info, video != nil, let a0 = info.pickAudio(pref), a0 != audio else { return }
        let t = player.currentTime().seconds
        let wasPlaying = player.rate != 0
        Task {
            await refreshIfStale()
            guard let v = video, let a = self.info?.pickAudio(pref) else { return }
            do { try await attach(video: v, audio: a, at: t.isFinite ? t : 0, play: wasPlaying) }
            catch { phase = .failed(error.localizedDescription) }
            switch audioKind {
            case .hiRes: flash("waveform", L("Hi-Res 无损"))
            case .dolby: flash("hifispeaker.2.fill", L("杜比全景声"))
            case .standard: flash("speaker.wave.2.fill", L("标准音质"))
            }
        }
    }

    /// Re-attach the same tracks (used when the CDN node changes).
    func reloadStream() {
        guard video != nil else { return }
        let t = player.currentTime().seconds
        let wasPlaying = player.rate != 0
        Task {
            await refreshIfStale()
            guard let v = video else { return }
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

    /// Two real stalls (buffer run dry, over 1 s) within 60 s, or one that lasts over 4 s, step the quality
    /// down one entry in the order. Start-up, seeks into unbuffered video and AVPlayer's momentary
    /// "evaluating buffering rate" waits (every play / pause / speed change) don't count.
    private func waitingChanged(_ waiting: Bool) {
        // Logged so stalls can be diagnosed from a run (why, how much buffer was left, link speed).
        if waiting {
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
            log(String(format: "%@ waiting (%@) at %.1fs, buffer %.1fs, link %@", bvid, reason, clock.time,
                       max(0, clock.buffered - clock.time), stream?.stats.segmentRate().map(formatBitrate) ?? "-"))
        } else if stallStarted != .distantPast {
            log(String(format: "%@ resumed after %.1fs", bvid, Date().timeIntervalSince(stallStarted)))
        }
        stallStarted = waiting ? Date() : .distantPast
        stallTask?.cancel()
        guard waiting, settings.autoDowngrade, !manualQuality, phase == .ready,
              Date().timeIntervalSince(attachedAt) > 3, Date().timeIntervalSince(lastSeek) > 6 else { return }
        // Not a stall: AVPlayer re-evaluating after play / pause / speed changes (it reports "waiting" for a
        // moment with plenty buffered), or a wait while more than a few seconds are still buffered.
        if player.reasonForWaitingToPlay == .evaluatingBufferingRate { return }
        if clock.buffered - clock.time > 3 { return }
        stallTask = Task { [weak self] in
            // A real stall lasts: count it after 1 s, step down if it reaches 4 s.
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.clock.waiting else { return }
            let now = Date()
            self.lastStall = now
            self.stallTimes = self.stallTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
            if self.stallTimes.count >= 2 { self.stepDown(); return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.clock.waiting else { return }
            self.stepDown()
        }
    }

    private func stepDown() {
        guard let info, let cur = video?.id, Date().timeIntervalSince(lastDowngrade) > 15,
              let next = info.nextLower(after: cur, order: settings.qualityOrder) else { return }
        // Stepping straight back down after an automatic step up: wait longer before the next try.
        if Date().timeIntervalSince(lastUpgrade) < 60 { upgradeBackoff = min(upgradeBackoff * 2, 300) }
        lastDowngrade = Date()
        stallTimes = []
        log("\(bvid) stalls at \(shortQuality(cur)) → \(shortQuality(next))")
        switchQuality(next)
        if AppModel.shared.nowPlaying === self {
            AppModel.shared.notify(Lf("网络跟不上 %@，已切到 %@", "\(shortQuality(cur))", "\(qualityNames[next] ?? shortQuality(next))"))
        }
    }

    // MARK: Stepping back up when the network recovers

    private var lastStall = Date.distantPast
    private var stallStarted = Date.distantPast
    private var lastUpgrade = Date.distantPast
    /// Seconds to wait after the last quality change before trying one step up (doubles after a failed try).
    private var upgradeBackoff: Double = 30

    /// Once a second: after an automatic step down, go one step back up the strategy's order when the
    /// buffer is comfortable, nothing has stalled for a while, and the measured link speed has room for
    /// the higher stream.
    private func considerStepUp() {
        guard settings.autoDowngrade, !manualQuality, phase == .ready, clock.playing, !clock.waiting,
              let info, let cur = video?.id, let s = stream else { return }
        let order = settings.qualityOrder
        guard let up = info.nextHigher(than: cur, order: order) else { return }
        let now = Date()
        let sinceChange = now.timeIntervalSince(max(lastDowngrade, lastUpgrade, attachedAt))
        guard sinceChange >= upgradeBackoff, now.timeIntervalSince(lastStall) > 30,
              now.timeIntervalSince(lastSeek) > 10, clock.buffered - clock.time >= 20,
              let link = s.stats.segmentRate() else { return }
        let need = Double(info.pickVideo(qn: up, codec: settings.codec).bandwidth) * 1.5
        guard link >= need else { return }
        lastUpgrade = now
        log("\(bvid) network ok (\(formatBitrate(link)) ≥ \(formatBitrate(need))): \(shortQuality(cur)) → \(shortQuality(up))")
        switchQuality(up)
        if AppModel.shared.nowPlaying === self {
            AppModel.shared.notify(Lf("网络恢复，已切回 %@", "\(qualityNames[up] ?? shortQuality(up))"))
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
        fxTask?.cancel()
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
        // 自动: trying another line can cost a slow segment; only while the buffer can take one.
        if let s = stream, s.node == .auto { s.exploreOK = clock.buffered - clock.time > 15 }
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
    var badge: String { badge(rate: stream.map { formatBitrate($0.stats.segmentRate() ?? $0.stats.rate(window: 2)) }) }

    /// `badge` with room for the widest usual bitrate: the space it takes, so the live value never resizes the bar.
    var badgeTemplate: String { badge(rate: stream == nil ? nil : "00.00 Mbps") }

    private func badge(rate: String?) -> String {
        guard let v = video else { return "" }
        var parts = [shortQuality(v.id), v.codecName]
        if let s = stream {
            parts.append(cdnShortName(s.stats.lastHost ?? s.video.urls.first?.host ?? ""))
            if let rate { parts.append(rate) }
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
        let fxOff = audioKind == .standard ? L("未生效") : L("播放无损 / 杜比音轨时保持原声，不做处理")
        if settings.audioLoudness {
            let g = info?.loudnessGainDB.map { String(format: "%+.1f", $0) }
            out.append(EnhancementBadge(icon: "speaker.wave.2.fill", value: audioFollower.active ? (g ?? L("自动")) : nil, active: audioFollower.active,
                                        help: L("响度均衡") + L("：") + (audioFollower.active ? (g.map { $0 + " dB" } ?? L("自动")) : fxOff)))
        }
        if settings.audioVoice {
            out.append(EnhancementBadge(icon: "person.wave.2.fill", value: nil, active: audioFollower.active,
                                        help: L("人声增强") + (audioFollower.active ? "" : L("：") + fxOff)))
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
