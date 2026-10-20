import AVFoundation
import MediaToolbox

/// 响度均衡 + 人声增强, applied with an MTAudioProcessingTap on the player item's audio.
///
/// - Loudness: brings every video to about −16 LUFS. When bilibili's playurl reports the video's
///   measured loudness we use that as a fixed gain; otherwise a slow automatic gain follows the
///   short-term level (ignoring silence). A peak limiter keeps boosts from clipping.
/// - Voice: splits stereo into mid (where dialogue sits) and side, lifts presence and trims
///   low-mid mud on the mid, and lowers the side a little.
///
/// Parameters are plain Float fields read on the render thread; the render path never allocates.
final class AudioFX: @unchecked Sendable {
    // Settings, written from the main thread.
    var loudnessOn = false
    var voiceOn = false
    /// Fixed gain in dB from bilibili's measured loudness; nil = automatic gain.
    var staticGainDB: Float? = nil

    fileprivate var sampleRate: Float = 48_000
    fileprivate var channels = 2
    fileprivate var nonInterleaved = true
    fileprivate var isFloat = true

    // Voice EQ (on mid): low-shelf cut at 200 Hz, presence peak at 2.8 kHz, small peak at 5 kHz.
    fileprivate var lowShelf = Biquad()
    fileprivate var presence = Biquad()
    fileprivate var air = Biquad()
    // Automatic gain.
    fileprivate var meanSquare: Float = 0
    fileprivate var autoGain: Float = 1
    // Limiter.
    fileprivate var limiterGain: Float = 1
    /// Smoothed gain actually applied (avoids zipper noise when settings change).
    fileprivate var appliedGain: Float = 1

    static let targetLUFS: Float = -16

    /// Audio mix carrying the tap for `track`, or nil if the tap can't be created.
    func audioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioFX>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let fx = Unmanaged<AudioFX>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                fx.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let fx = Unmanaged<AudioFX>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                fx.process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    fileprivate func prepare(_ f: AudioStreamBasicDescription) {
        sampleRate = Float(f.mSampleRate)
        channels = Int(f.mChannelsPerFrame)
        nonInterleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        lowShelf = .lowShelf(freq: 200, gainDB: -3, fs: sampleRate)
        presence = .peaking(freq: 2800, gainDB: 5, q: 0.9, fs: sampleRate)
        air = .peaking(freq: 5000, gainDB: 2, q: 1.2, fs: sampleRate)
        meanSquare = 0; autoGain = 1; limiterGain = 1; appliedGain = 1
        log(String(format: "audio tap: %.0f Hz, %d ch, %@, %@", f.mSampleRate, channels,
                   nonInterleaved ? "planar" : "interleaved", isFloat ? "float32" : "other"))
    }

    fileprivate func process(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let loud = loudnessOn, voice = voiceOn
        guard isFloat, frames > 0, loud || voice || appliedGain != 1 else { return }
        // Planar stereo is what AVFoundation hands taps; fall back to doing nothing otherwise.
        guard nonInterleaved, abl.count >= 1,
              let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let r = abl.count >= 2 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil

        let fs = sampleRate
        // Level detector ~400 ms; gain follows over ~3 s (down faster than up).
        let msCoeff = 1 - exp(-1 / (0.4 * fs))
        let upCoeff = 1 - exp(-1 / (3.0 * fs))
        let downCoeff = 1 - exp(-1 / (0.8 * fs))
        let relCoeff = 1 - exp(-1 / (0.15 * fs))
        let smooth = 1 - exp(-1 / (0.05 * fs))
        let ceiling: Float = 0.89            // −1 dBFS
        // −16 LUFS is roughly −19 dBFS RMS for typical programme material.
        let targetRMS: Float = pow(10, (AudioFX.targetLUFS - 3) / 20)
        let fixed: Float? = staticGainDB.map { pow(10, min(max($0, -15), 12) / 20) }

        for i in 0..<frames {
            var a = l[i], b = r?[i] ?? a
            if voice {
                var mid = (a + b) * 0.5
                let side = (a - b) * 0.5 * 0.8
                mid = air.run(presence.run(lowShelf.run(mid)))
                a = mid + side; b = mid - side
            }
            var target: Float = 1
            if loud {
                if let fixed {
                    target = fixed
                } else {
                    let m = (a * a + b * b) * 0.5
                    meanSquare += (m - meanSquare) * msCoeff
                    if meanSquare > 1e-5 {            // above about −50 dBFS: not silence
                        let want = min(max(targetRMS / sqrt(meanSquare), 0.18), 4)
                        autoGain += (want - autoGain) * (want < autoGain ? downCoeff : upCoeff)
                    }
                    target = autoGain
                }
            }
            appliedGain += (target - appliedGain) * smooth
            a *= appliedGain; b *= appliedGain
            // Peak limiter.
            let peak = max(abs(a), abs(b))
            if peak * limiterGain > ceiling {
                limiterGain = ceiling / peak
            } else {
                limiterGain += (1 - limiterGain) * relCoeff
            }
            l[i] = a * limiterGain
            r?[i] = b * limiterGain
        }
    }
}

/// RBJ biquad, transposed direct form II.
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func peaking(freq: Float, gainDB: Float, q: Float, fs: Float) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Float.pi * freq / fs, alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha / A
        return Biquad(b0: (1 + alpha * A) / a0, b1: -2 * c / a0, b2: (1 - alpha * A) / a0, a1: -2 * c / a0, a2: (1 - alpha / A) / a0)
    }

    static func lowShelf(freq: Float, gainDB: Float, fs: Float) -> Biquad {
        let A = pow(10, gainDB / 40), w = 2 * Float.pi * freq / fs, c = cos(w), s = sin(w)
        let alpha = s / 2 * sqrt(2), sq = 2 * sqrt(A) * alpha
        let a0 = (A + 1) + (A - 1) * c + sq
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + sq) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * c) / a0,
                      b2: A * ((A + 1) - (A - 1) * c - sq) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0,
                      a2: ((A + 1) + (A - 1) * c - sq) / a0)
    }
}

/// Plays the audio in its own AVPlayer so the 音效处理 tap can run (taps are ignored on HLS items),
/// slaved to the video player: same time, rate, pause state, volume and mute.
///
/// The audio is played from a temporary file, so this player never stalls; whenever
/// the video waits or jumps, the audio follows. Small drift is trimmed by nudging the rate (pitch
/// preserved); at 1× anything larger than 120 ms (250 ms just after a start or a speed change) is
/// fixed by restarting the audio in step.
@MainActor
final class AudioFollower {
    let player = AVPlayer()
    private(set) var active = false
    private weak var main: AVPlayer?
    private var observers: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var seeking = false
    /// Bumped by every restart, so a slower one still finishing can't start the audio again.
    private var restartGen = 0
    /// Current drift correction, as a fraction of the video's rate.
    private var trim: Float = 0
    private var lastRate: Float = 1
    /// Until then a speed change or a start is still settling: allow more drift before restarting.
    private var settleUntil: CFTimeInterval = 0
    private var file: URL?
    private var wasPlaying = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Loads the audio and puts the tap on it. Throws if the track can't be read.
    /// Played from a temporary file, so its seeks don't go through the local proxy that is busy with the
    /// video's segments.
    func prepare(data: Data, fx: AudioFX, at time: Double) async throws {
        stop()
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("bilimac-audio-\(UUID().uuidString).mp4")
        try data.write(to: f)
        file = f
        let asset = AVURLAsset(url: f)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw APIError(description: "no audio track")
        }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = fx.audioMix(for: track)
        player.replaceCurrentItem(with: item)
        await player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        active = true
    }

    /// Starts following `main` (call after its item is in place).
    func follow(_ main: AVPlayer) {
        guard active else { return }
        self.main = main
        observers = [
            main.observe(\.timeControlStatus) { [weak self] _, _ in Task { @MainActor in self?.sync(hard: false) } },
            main.observe(\.rate) { [weak self] _, _ in Task { @MainActor in self?.sync(hard: false) } },
            main.observe(\.volume, options: [.initial]) { [weak self] p, _ in
                let v = p.volume
                Task { @MainActor in self?.player.volume = v }
            },
            main.observe(\.isMuted, options: [.initial]) { [weak self] p, _ in
                let m = p.isMuted
                Task { @MainActor in self?.player.isMuted = m }
            },
        ]
        tokens = [NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: main.currentItem,
                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(hard: true) }
        }]
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync(hard: false) }
        }
        sync(hard: true)
    }

    func stop() {
        observers.removeAll()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        timer?.invalidate()
        timer = nil
        restartGen += 1
        seeking = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        main = nil
        active = false
    }

    private func sync(hard: Bool) {
        guard active, let main, !seeking else { return }
        // A speed change makes the audio's time-pitch unit stall for a moment (~0.1 s at 2×): let the trim
        // below catch that up instead of restarting the audio, which left a gap on every change.
        if main.rate != 0, main.rate != lastRate { lastRate = main.rate; settleUntil = CACurrentMediaTime() + 1.5 }
        // The video also reports "waiting" for a moment on a speed change while it keeps going: follow it.
        if main.rate != 0, player.rate != 0, main.timeControlStatus == .waitingToPlayAtSpecifiedRate,
           main.reasonForWaitingToPlay == .evaluatingBufferingRate {
            if abs(player.rate - main.rate * (1 + trim)) > 0.001 { player.rate = main.rate * (1 + trim) }
            return
        }
        let playing = main.timeControlStatus == .playing && main.rate != 0
        defer { wasPlaying = playing }
        let resumed = playing && !wasPlaying
        let target = main.currentTime()
        guard target.isValid else { return }
        if !playing {
            if player.rate != 0 { player.pause() }
            if hard || abs(player.currentTime().seconds - target.seconds) > 0.05 { seek(to: target, thenRate: nil) }
            return
        }
        let drift = player.currentTime().seconds - target.seconds
        if resumed, !hard, player.rate == 0, abs(drift) < 0.06 {
            // Paused where the video is (the pause seeks it there): just go along with it. No jump and no
            // gap; the trim takes up the few tens of ms either side. (A timed restart off 1× started up to
            // half a second late, by a different amount each time.)
            trim = 0
            player.rate = main.rate
            settleUntil = CACurrentMediaTime() + 1.5
            return
        }
        // Off 1× the audio starts 0.1–0.35 s late by a different amount each time, so a restart can't
        // fix an offset there (it kept restarting for seconds): only a jump that big restarts it.
        let limit = main.rate != 1 ? 0.8 : CACurrentMediaTime() < settleUntil ? 0.25 : 0.12
        if hard || resumed || abs(drift) > limit {
            trim = 0
            startInSync(with: main)
        } else {
            // Ahead → run slower, behind → faster (pitch preserved), more for a bigger gap. Each rate change
            // shifts the time-pitch unit by a few tens of ms, so the correction moves in steps: it starts
            // past 40 ms and holds until back under 10 ms.
            let a = abs(drift)
            let step: Float = a > 0.15 ? 0.06 : a > 0.04 ? 0.03 : a < 0.01 ? 0 : abs(trim)
            trim = (drift > 0 ? -1 : 1) * step
            let want = main.rate * (1 + trim)
            if abs(player.rate - want) > 0.001 { player.rate = want }
        }
    }

    /// Restarts the audio in step with the video: jump a moment ahead of it, decode up to there
    /// (preroll), then start at the exact host time the video's timebase reaches that point.
    /// Lands within ~20 ms at 1×; off 1× it can still start late (see `sync`).
    private func startInSync(with main: AVPlayer, ahead: Double = 0.2) {
        guard let item = main.currentItem else { return }
        let rate = main.rate
        restartGen += 1
        let gen = restartGen
        seeking = true
        player.pause()
        let target = CMTimeAdd(main.currentTime(), CMTime(seconds: ahead * Double(rate), preferredTimescale: 600))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            Task { @MainActor in
                guard let self, gen == self.restartGen else { return }
                guard done else { self.seeking = false; return }
                self.player.preroll(atRate: rate) { _ in
                    Task { @MainActor in
                        guard gen == self.restartGen else { return }
                        let host = CMClockGetHostTimeClock()
                        guard let tb = item.timebase, main.rate == rate, main.currentItem === item else { self.seeking = false; return }
                        let at = CMSyncConvertTime(target, from: tb, to: host)
                        let margin = CMTimeSubtract(at, CMClockGetTime(host)).seconds
                        guard margin > 0.01 else {
                            // The video got there first: try again further ahead.
                            self.startInSync(with: main, ahead: min(ahead * 2, 1.2))
                            return
                        }
                        self.player.setRate(rate, time: .invalid, atHostTime: at)
                        DispatchQueue.main.asyncAfter(deadline: .now() + margin + 0.3) { [weak self] in
                            guard let self, gen == self.restartGen else { return }
                            self.seeking = false
                        }
                    }
                }
            }
        }
    }

    private func seek(to t: CMTime, thenRate rate: Float?) {
        restartGen += 1
        seeking = true
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let rate { self.player.rate = rate }
            }
        }
    }
}
