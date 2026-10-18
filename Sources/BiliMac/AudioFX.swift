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
/// The audio file is served from memory by the local proxy, so this player never stalls; whenever
/// the video waits or jumps, the audio follows. Small drift is trimmed by nudging the rate (pitch
/// preserved); anything larger than 120 ms is fixed with an exact seek.
@MainActor
final class AudioFollower {
    let player = AVPlayer()
    private(set) var active = false
    private weak var main: AVPlayer?
    private var observers: [NSKeyValueObservation] = []
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private var seeking = false
    /// Learned start offset per playback rate: off 1×, the time-pitch unit adds a fixed delay
    /// (~200 ms at 1.5×), so a plain synced start keeps landing behind by the same amount.
    private var lead: [Float: Double] = [:]
    private var learnAfterSync = false
    private var wasPlaying = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// Loads the audio file and puts the tap on it. Throws if the track can't be read.
    func prepare(url: URL, fx: AudioFX, at time: Double) async throws {
        stop()
        let asset = AVURLAsset(url: url)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        main = nil
        active = false
    }

    private func sync(hard: Bool) {
        guard active, let main, !seeking else { return }
        let playing = main.timeControlStatus == .playing && main.rate != 0
        defer { wasPlaying = playing }
        let hard = hard || (playing && !wasPlaying)   // just resumed: start exactly in step
        let target = main.currentTime()
        guard target.isValid else { return }
        if !playing {
            if player.rate != 0 { player.pause() }
            if hard || abs(player.currentTime().seconds - target.seconds) > 0.05 { seek(to: target, thenRate: nil) }
            return
        }
        let drift = player.currentTime().seconds - target.seconds
        if learnAfterSync {
            learnAfterSync = false
            if abs(drift) < 0.6 { lead[main.rate, default: 0] -= drift }
        }
        if hard || abs(drift) > 0.08 {
            startInSync(with: main)
        } else {
            // Ahead → slow down a touch, behind → speed up, by at most 4 %.
            let nudge = abs(drift) > 0.015 ? Float(max(-0.04, min(0.04, -drift * 0.5))) : 0
            let want = main.rate * (1 + nudge)
            if abs(player.rate - want) > 0.001 { player.rate = want }
        }
    }

    /// Restarts the audio at a host time a moment ahead, at exactly the position the video's
    /// timebase will show then — a plain seek-then-play lands ~200 ms late.
    private func startInSync(with main: AVPlayer) {
        guard let timebase = main.currentItem?.timebase else { return }
        let hostClock = CMClockGetHostTimeClock()
        let start = CMTimeAdd(CMClockGetTime(hostClock), CMTime(seconds: 0.25, preferredTimescale: 1_000_000_000))
        var at = CMSyncConvertTime(start, from: hostClock, to: timebase)
        guard at.isValid else { return }
        at = CMTimeAdd(at, CMTime(seconds: lead[main.rate] ?? 0, preferredTimescale: 600))
        seeking = true
        learnAfterSync = true
        player.setRate(main.rate, time: at, atHostTime: start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.seeking = false }
    }

    private func seek(to t: CMTime, thenRate rate: Float?) {
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
