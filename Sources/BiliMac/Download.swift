import AppKit
import AVFoundation
import Foundation

// MARK: - What to download

/// Whole video, its sound only, or its picture only.
enum DownloadContent: String, CaseIterable, Identifiable {
    case both, audio, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return L("视频 + 音频")
        case .audio: return L("仅音频")
        case .video: return L("仅视频（无声）")
        }
    }
}

enum VideoFileFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum AudioFileFormat: String, CaseIterable, Identifiable {
    case m4a, mp3
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

/// One download, fully decided: the tracks, what to make of them and where.
struct DownloadJob {
    let bvid: String
    let cid: Int
    /// Shown in the list and used for the file name (includes the part's name for multi-part videos).
    let title: String
    let owner: String
    let cover: URL?
    let content: DownloadContent
    let video: DashTrack?
    let audio: DashTrack?
    let videoFormat: VideoFileFormat
    let audioFormat: AudioFileFormat
    let folder: URL
    /// e.g. "1080P 高清 · HEVC · MP4".
    let summary: String

    var fileExtension: String {
        content == .audio ? audioFormat.rawValue : videoFormat.rawValue
    }
}

/// Where MP3s come from: macOS has no MP3 encoder, so it uses LAME (or ffmpeg) when installed.
enum MP3Encoder {
    case lame(String), ffmpeg(String)

    static var found: MP3Encoder? {
        let fm = FileManager.default
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            if fm.isExecutableFile(atPath: dir + "/lame") { return .lame(dir + "/lame") }
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            if fm.isExecutableFile(atPath: dir + "/ffmpeg") { return .ffmpeg(dir + "/ffmpeg") }
        }
        return nil
    }

    static let bitrate = 320   // kbps
}

// MARK: - Sizes

/// Exact track sizes (one ranged request each), remembered for the session.
actor TrackSizes {
    static let shared = TrackSizes()
    private var known: [String: Int] = [:]

    /// The file's size from the CDN, trying each URL; nil if none answers.
    func size(of t: DashTrack) async -> Int? {
        let key = "\(t.id)-\(t.codecs)-\(t.indexRange)-\(t.urls.first?.path ?? "")"
        if let s = known[key] { return s }
        let node = AppSettings.shared.cdnNode
        for u in (t.urls.map(node.rewrite) + t.urls).uniqued() {
            if let s = try? await Self.probe(u) { known[key] = s; return s }
        }
        return nil
    }

    /// Total size from a one-byte range request (Content-Range: bytes 0-0/TOTAL).
    static func probe(_ u: URL) async throws -> Int {
        var r = URLRequest(url: u)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue(biliReferer, forHTTPHeaderField: "Referer")
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        r.timeoutInterval = 8
        let (_, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError(description: "no response") }
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let total = cr.split(separator: "/").last.flatMap({ Int($0) }) { return total }
        if http.statusCode == 200, http.expectedContentLength > 0 { return Int(http.expectedContentLength) }
        throw APIError(description: "HTTP \(http.statusCode)")
    }
}

// MARK: - Fetching one track

/// Downloads one DASH track to a file: fixed-size ranges, several at once (the CDN limits each connection),
/// each retried on another host and, when every host refuses (the signed URLs expired), with new URLs.
final class TrackFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    private var refreshing: Task<Void, Error>?
    private var lastRefresh = Date.distantPast
    private let refresh: @Sendable () async throws -> DashTrack
    private let node: CDNNode

    static let chunk = 4 << 20
    static let parallel = 6

    init(track: DashTrack, node: CDNNode, refresh: @escaping @Sendable () async throws -> DashTrack) {
        self.node = node
        self.refresh = refresh
        urls = (track.urls.map(node.rewrite) + track.urls).uniqued()
        if node == .auto, let host = LinePicker.shared.recentBest, let first = urls.first {
            urls = [CDNNode.rewrite(first, host: host)] + urls.filter { $0.host != host }
        }
    }

    private var currentURLs: [URL] { lock.lock(); defer { lock.unlock() }; return urls }

    private func refreshURLs() async throws {
        let t: Task<Void, Error>? = {
            lock.lock(); defer { lock.unlock() }
            if let r = refreshing { return r }
            if Date().timeIntervalSince(lastRefresh) < 20 { return nil }
            let r = Task { [self] in
                defer { finishRefresh(nil) }
                let fresh = try await refresh()
                finishRefresh((fresh.urls.map(node.rewrite) + fresh.urls).uniqued())
            }
            refreshing = r
            return r
        }()
        try await t?.value
    }

    private func finishRefresh(_ new: [URL]?) {
        lock.lock(); defer { lock.unlock() }
        if let new { urls = new; lastRefresh = Date() }
        refreshing = nil
    }

    /// Writes the whole file (`total` bytes) to `file`, reporting each finished range's size.
    func fetch(total: Int, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let writeLock = NSLock()
        let ranges = stride(from: 0, to: total, by: Self.chunk).map { $0 ... min($0 + Self.chunk, total) - 1 }
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = 0
            func add() {
                guard next < ranges.count else { return }
                let r = ranges[next]
                next += 1
                g.addTask {
                    let data = try await self.fetchRange(r)
                    try Task.checkCancellation()
                    try writeLock.withLock {
                        try handle.seek(toOffset: UInt64(r.lowerBound))
                        try handle.write(contentsOf: data)
                    }
                    progress(data.count)
                }
            }
            for _ in 0..<Self.parallel { add() }
            while try await g.next() != nil { add() }
        }
    }

    private func fetchRange(_ r: ClosedRange<Int>) async throws -> Data {
        var lastError: Error = APIError(description: "no url")
        var refreshed = false
        for attempt in 0..<4 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt))) }
            var refused = true
            for u in currentURLs {
                try Task.checkCancellation()
                do {
                    var req = URLRequest(url: u)
                    req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
                    req.setValue(biliReferer, forHTTPHeaderField: "Referer")
                    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    req.setValue("bytes=\(r.lowerBound)-\(r.upperBound)", forHTTPHeaderField: "Range")
                    req.timeoutInterval = 30
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 206, data.count == r.count { return data }
                    if code == 200, r.lowerBound == 0, data.count >= r.count { return data.prefix(r.count) }
                    lastError = APIError(description: "HTTP \(code) from \(u.host ?? "?")")
                    if code != 403 && code != 404 && code != 410 { refused = false }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let e as URLError where e.code == .cancelled {
                    throw CancellationError()
                } catch {
                    lastError = error
                    refused = false
                }
            }
            // Every host refused: the signed URLs have expired (or are about to). Get new ones once.
            if refused, !refreshed {
                refreshed = true
                log("download: all hosts refused a range, refreshing URLs")
                try await refreshURLs()
            }
        }
        throw lastError
    }
}

// MARK: - Making the file

enum MediaWriter {
    /// Puts the tracks into one file without re-encoding.
    static func mux(video: URL?, audio: URL?, to out: URL, type: AVFileType, metadata: [AVMetadataItem]) async throws {
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: type)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var readers: [AVAssetReader] = []
        var pumps: [Pump] = []
        for (url, media) in [(video, AVMediaType.video), (audio, .audio)] {
            guard let url else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: media).first else {
                throw APIError(description: L("下载的文件里没有可用的轨道"))
            }
            let hint = try await track.load(.formatDescriptions).first
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: media, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw APIError(description: Lf("%@ 文件放不下这种编码，请换一种格式", type == .mov ? "MOV" : type == .m4a ? "M4A" : "MP4"))
            }
            writer.add(input)
            readers.append(reader)
            pumps.append(Pump(input: input, output: output))
        }
        for r in readers where !r.startReading() { throw r.error ?? APIError(description: "read failed") }
        guard writer.startWriting() else { throw writer.error ?? APIError(description: "write failed") }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { g in
            for (n, p) in pumps.enumerated() {
                g.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        p.input.requestMediaDataWhenReady(on: DispatchQueue(label: "mux.\(n)")) {
                            while p.input.isReadyForMoreMediaData {
                                if let s = p.output.copyNextSampleBuffer() {
                                    if !p.input.append(s) { p.input.markAsFinished(); c.resume(); return }
                                } else {
                                    p.input.markAsFinished(); c.resume(); return
                                }
                            }
                        }
                    }
                }
            }
        }
        if writer.status == .failed { throw writer.error ?? APIError(description: "write failed") }
        if let r = readers.first(where: { $0.status == .failed }) { throw r.error ?? APIError(description: "read failed") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? APIError(description: "write failed") }
        try retagSampleEntries(out)
    }

    /// bilibili tags HEVC `hev1` (and Dolby Vision `dvhe`, some H.264 `avc3`): the variants that may carry parameter
    /// sets inside the frames. Apple's players (QuickTime, Photos, iPhone) only open the `hvc1` / `dvh1` / `avc1` kind,
    /// and these streams also carry the sets in the header, so the file only needs its sample entry renamed: four bytes
    /// in the `moov` box, nothing re-encoded.
    static func retagSampleEntries(_ url: URL) throws {
        let renames: [(String, String)] = [("hev1", "hvc1"), ("dvhe", "dvh1"), ("avc3", "avc1")]
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= end {
            try h.seek(toOffset: offset)
            guard let head = try h.read(upToCount: 16), head.count >= 8 else { return }
            var size = UInt64(head[0]) << 24 | UInt64(head[1]) << 16 | UInt64(head[2]) << 8 | UInt64(head[3])
            let type = String(decoding: head[4..<8], as: UTF8.self)
            if size == 1, head.count == 16 { size = head[8..<16].reduce(0) { $0 << 8 | UInt64($1) } }
            if size == 0 { size = end - offset }
            guard size >= 8 else { return }
            if type == "moov" {
                try h.seek(toOffset: offset)
                guard var moov = try h.read(upToCount: Int(size)) else { return }
                var changed = false
                for (from, to) in renames {
                    var search = moov.startIndex
                    while let r = moov.range(of: Data(from.utf8), in: search..<moov.endIndex) {
                        search = r.upperBound
                        // A sample entry: its size comes just before the type and stays inside the box.
                        guard r.lowerBound >= moov.startIndex + 4 else { continue }
                        let s = moov[(r.lowerBound - 4)..<r.lowerBound].reduce(0) { $0 << 8 | Int($1) }
                        guard s > 8, r.lowerBound - 4 + s <= moov.endIndex else { continue }
                        moov.replaceSubrange(r, with: Data(to.utf8))
                        changed = true
                    }
                }
                if changed {
                    try h.seek(toOffset: offset)
                    try h.write(contentsOf: moov)
                }
                return
            }
            offset += size
        }
    }

    private final class Pump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderTrackOutput
        init(input: AVAssetWriterInput, output: AVAssetReaderTrackOutput) { self.input = input; self.output = output }
    }

    /// Decodes the audio to 16-bit stereo PCM and streams it into LAME (or ffmpeg).
    static func mp3(from audio: URL, to out: URL, encoder: MP3Encoder, title: String, artist: String, cover: URL?) async throws {
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: audio)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw APIError(description: L("下载的文件里没有可用的轨道"))
        }
        let fd = try await track.load(.formatDescriptions).first
        let rate = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }.map(Int.init) ?? 48000
        let sampleRate = [32000, 44100, 48000].contains(rate) ? rate : 48000
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2, AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? APIError(description: "read failed") }

        let p = Process()
        switch encoder {
        case .lame(let path):
            p.executableURL = URL(fileURLWithPath: path)
            var args = ["--quiet", "-r", "-s", String(format: "%g", Double(sampleRate) / 1000), "--bitwidth", "16", "--signed",
                        "--little-endian", "-m", "j", "-b", "\(MP3Encoder.bitrate)", "-q", "2",
                        "--id3v2-only", "--id3v2-utf16", "--tt", title, "--ta", artist]
            if let cover { args += ["--ti", cover.path] }
            p.arguments = args + ["-", out.path]
        case .ffmpeg(let path):
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-v", "error", "-y", "-f", "s16le", "-ar", "\(sampleRate)", "-ac", "2", "-i", "-",
                           "-codec:a", "libmp3lame", "-b:a", "\(MP3Encoder.bitrate)k",
                           "-metadata", "title=\(title)", "-metadata", "artist=\(artist)", out.path]
        }
        // LAME reads --tt / --ta in the locale's encoding: an app launched from Finder has none, and a Chinese title
        // was cut at its first non-ASCII character.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        p.environment = env
        let pipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        try p.run()
        let writer = pipe.fileHandleForWriting
        let fed: Result<Void, Error> = await Task.detached {
            do {
                while let s = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let block = CMSampleBufferGetDataBuffer(s) else { continue }
                    var length = 0
                    var ptr: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                      dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { continue }
                    try writer.write(contentsOf: Data(bytesNoCopy: ptr, count: length, deallocator: .none))
                }
                return .success(())
            } catch { return .failure(error) }
        }.value
        try? writer.close()
        if case .failure = fed { p.terminate() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !p.isRunning { c.resume(); return }
            p.terminationHandler = { _ in c.resume() }
            if !p.isRunning { p.terminationHandler = nil; c.resume() }
        }
        if case .failure(let e) = fed { throw e }
        if reader.status == .failed { throw reader.error ?? APIError(description: "read failed") }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw APIError(description: Lf("MP3 编码失败：%@", msg.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// Title, author and cover for MP4 / M4A (iTunes keys) or MOV (QuickTime keys).
    static func metadata(title: String, artist: String, cover: Data?, mov: Bool) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, type: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            m.extendedLanguageTag = "und"
            if let type { m.dataType = type }
            return m
        }
        var items = [item(mov ? .quickTimeMetadataTitle : .iTunesMetadataSongName, title as NSString),
                     item(mov ? .quickTimeMetadataArtist : .iTunesMetadataArtist, artist as NSString)]
        if let cover {
            items.append(item(mov ? .quickTimeMetadataArtwork : .iTunesMetadataCoverArt, cover as NSData,
                              type: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }
}

// MARK: - A download in the list

@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, downloading, processing, done(URL), failed(String), cancelled
    }

    let id = UUID()
    let job: DownloadJob
    @Published private(set) var state: State = .queued
    @Published private(set) var received = 0
    @Published private(set) var total = 0
    /// Bytes per second over the last few seconds.
    @Published private(set) var speed: Double = 0
    private var work: Task<Void, Never>?
    private var samples: [(Date, Int)] = []

    init(job: DownloadJob) { self.job = job }

    var isActive: Bool { state == .queued || state == .downloading || state == .processing }
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    func start(onFinish: @escaping @MainActor () -> Void) {
        state = .downloading
        received = 0
        total = 0
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.run()
                self.state = .done(url)
                AppModel.shared.notify(Lf("下载完成：%@", self.job.title)) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch is CancellationError {
                self.state = .cancelled
            } catch {
                if Task.isCancelled { self.state = .cancelled } else {
                    self.state = .failed(Self.describe(error))
                    log("download \(self.job.bvid) failed: \(error)")
                }
            }
            onFinish()
        }
    }

    func cancel() {
        work?.cancel()
        if state == .queued { state = .cancelled }
    }

    private func added(_ n: Int) {
        received += n
        let now = Date()
        samples.append((now, received))
        // Ranges finish in bursts (several run at once): average over ~8 s, keeping one older sample as the base.
        while samples.count > 2, now.timeIntervalSince(samples[1].0) > 8 { samples.removeFirst() }
        if let first = samples.first, now.timeIntervalSince(first.0) > 0.5 {
            speed = Double(received - first.1) / now.timeIntervalSince(first.0)
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) ||
            (ns.underlyingErrors.first as NSError?)?.code == Int(EPERM) {
            return L("没有权限写入保存位置：请在「系统设置 › 隐私与安全性 › 文件与文件夹」里允许 BiliMac，或换一个保存位置")
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return L("磁盘空间不足") }
        return error.localizedDescription
    }

    private func run() async throws -> URL {
        let job = self.job
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let temp = caches.appendingPathComponent("io.github.dime2015.BiliMac/downloads/\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        // Sizes first: the progress bar and the disk-space check need them.
        var tracks: [(DashTrack, String)] = []
        if let v = job.video, job.content != .audio { tracks.append((v, "video.mp4")) }
        if let a = job.audio, job.content != .video { tracks.append((a, "audio.mp4")) }
        // The URLs were signed when the panel opened; a retry hours later (or a panel left open) finds them expired.
        var sizes: [Int] = []
        var fresh: PlayInfo?
        for (n, (t, name)) in tracks.enumerated() {
            if let s = await TrackSizes.shared.size(of: t) { sizes.append(s); continue }
            if fresh == nil { fresh = try await BiliAPI.shared.playInfo(bvid: job.bvid, cid: job.cid) }
            let renewed = try Self.same(t, in: fresh!)
            guard let s = await TrackSizes.shared.size(of: renewed) else {
                throw APIError(description: L("拿不到文件大小，可能是网络问题，稍后重试"))
            }
            tracks[n] = (renewed, name)
            sizes.append(s)
        }
        total = sizes.reduce(0, +)
        samples = [(Date(), 0)]
        try Self.checkSpace(need: total * 2, at: temp)
        try Self.checkSpace(need: total, at: job.folder)

        let node = AppSettings.shared.cdnNode
        for ((track, name), size) in zip(tracks, sizes) {
            let (b, c) = (job.bvid, job.cid)
            let fetcher = TrackFetcher(track: track, node: node) {
                try Self.same(track, in: try await BiliAPI.shared.playInfo(bvid: b, cid: c))
            }
            try await fetcher.fetch(total: size, to: temp.appendingPathComponent(name)) { n in
                Task { @MainActor in self.added(n) }
            }
        }
        try Task.checkCancellation()

        state = .processing
        let coverFile = temp.appendingPathComponent("cover.jpg")
        var coverData: Data?
        if let c = job.cover, let jpg = Self.coverURL(c), let (d, _) = try? await URLSession.shared.data(from: jpg) {
            coverData = d
            try? d.write(to: coverFile)
        }
        let out = temp.appendingPathComponent("out.\(job.fileExtension)")
        let videoFile = job.content == .audio ? nil : temp.appendingPathComponent("video.mp4")
        let audioFile = job.content == .video || job.audio == nil ? nil : temp.appendingPathComponent("audio.mp4")
        if job.content == .audio, job.audioFormat == .mp3 {
            guard let enc = MP3Encoder.found, let audioFile else { throw APIError(description: L("没有找到 MP3 编码器")) }
            try await MediaWriter.mp3(from: audioFile, to: out, encoder: enc, title: job.title, artist: job.owner,
                                      cover: coverData == nil ? nil : coverFile)
        } else {
            let type: AVFileType = job.content == .audio ? .m4a : job.videoFormat.fileType
            try await MediaWriter.mux(video: videoFile, audio: audioFile, to: out, type: type,
                                      metadata: MediaWriter.metadata(title: job.title, artist: job.owner, cover: coverData, mov: type == .mov))
        }
        try Task.checkCancellation()

        try fm.createDirectory(at: job.folder, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(in: job.folder, name: Self.fileName(job.title), ext: job.fileExtension)
        try fm.moveItem(at: out, to: dest)
        return dest
    }

    /// The same file in a newly fetched PlayInfo (new signed URLs).
    nonisolated static func same(_ t: DashTrack, in info: PlayInfo) throws -> DashTrack {
        let all = info.videos + info.audios + [info.flac, info.dolby].compactMap { $0 }
        guard let m = all.first(where: { $0.id == t.id && $0.codecs == t.codecs && $0.indexRange == t.indexRange }) else {
            throw APIError(description: L("这个画质 / 音质已经不提供了"))
        }
        return m
    }

    /// bilibili covers can be WebP / PNG; ask the image service for a JPEG of at most 1280 px.
    private static func coverURL(_ u: URL) -> URL? {
        guard u.host?.hasSuffix("hdslb.com") == true else { return u }
        return URL(string: u.absoluteString.replacingOccurrences(of: "http://", with: "https://") + "@1280w.jpg")
    }

    private static func checkSpace(need: Int, at dir: URL) throws {
        var probe = dir
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        if Int64(need) > free {
            throw APIError(description: Lf("磁盘空间不足：需要 %@，只剩 %@", formatBytes(need), formatBytes(Int(free))))
        }
    }

    /// A file name from the title: no path separators, not too long.
    static func fileName(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.isEmpty { s = "BiliMac" }
        return String(s.prefix(120))
    }

    private static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - The list

@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()
    @Published private(set) var tasks: [DownloadTask] = []
    /// Downloads running at the same time; the rest wait.
    private let maxRunning = 2

    var activeCount: Int { tasks.filter(\.isActive).count }

    func add(_ job: DownloadJob) {
        tasks.insert(DownloadTask(job: job), at: 0)
        pump()
    }

    func retry(_ t: DownloadTask) {
        guard let i = tasks.firstIndex(where: { $0 === t }) else { return }
        tasks[i] = DownloadTask(job: t.job)
        pump()
    }

    func remove(_ t: DownloadTask) {
        t.cancel()
        tasks.removeAll { $0 === t }
    }

    func clearFinished() { tasks.removeAll { !$0.isActive } }

    /// BILIMAC_TEST_DOWNLOAD (see `Env.testDownload`).
    static func testDownload(_ spec: String) async {
        let f = spec.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6 else { return log("test download: bad spec") }
        do {
            let d = try await BiliAPI.shared.detail(bvid: f[0])
            let i = try await BiliAPI.shared.playInfo(bvid: d.bvid, cid: d.cid)
            let content = DownloadContent(rawValue: f[1]) ?? .both
            let qn = Int(f[2]).flatMap { $0 > 0 ? $0 : nil } ?? i.videos.map(\.id).max() ?? 0
            let v = i.videos.first { $0.id == qn && $0.codecName == f[3] } ?? i.videos.first { $0.id == qn }
            let special = f.count > 6 ? f[5] : ""
            let a = special == "flac" ? i.flac : special == "dolby" ? i.dolby : i.audios.max { $0.bandwidth < $1.bandwidth }
            let fmt = f[4]
            // With BILIMAC_TEST_EXPIRED=sig too: start from URLs every host refuses, to check the refresh.
            func spoiled(_ t: DashTrack?) -> DashTrack? {
                guard let t, Env.testExpired == "sig" else { return t }
                let urls = t.urls.map { u -> URL in
                    guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
                    c.queryItems = c.queryItems?.map { $0.name == "upsig" ? URLQueryItem(name: "upsig", value: "0") : $0 }
                    return c.url ?? u
                }
                return DashTrack(id: t.id, codecs: t.codecs, bandwidth: t.bandwidth, width: t.width, height: t.height,
                                 frameRate: t.frameRate, urls: urls, initRange: t.initRange, indexRange: t.indexRange)
            }
            let job = DownloadJob(bvid: d.bvid, cid: d.cid, title: d.title, owner: d.ownerName, cover: d.cover, content: content,
                                  video: spoiled(v), audio: spoiled(a), videoFormat: VideoFileFormat(rawValue: fmt) ?? .mp4,
                                  audioFormat: AudioFileFormat(rawValue: fmt) ?? .m4a,
                                  folder: URL(fileURLWithPath: f[f.count - 1], isDirectory: true), summary: "test")
            log("test download: \(v.map { "\($0.id) \($0.codecs)" } ?? "-") + \(a?.codecs ?? "-") → \(fmt)")
            shared.add(job)
            let t = shared.tasks[0]
            while t.isActive { try await Task.sleep(for: .milliseconds(500)) }
            switch t.state {
            case .done(let url): log("test download: done \(url.path) (\(t.total) bytes fetched)")
            case .failed(let m): log("test download: failed \(m)")
            default: log("test download: \(t.state)")
            }
        } catch {
            log("test download: \(error)")
        }
    }

    private func pump() {
        var running = tasks.filter { $0.state == .downloading || $0.state == .processing }.count
        for t in tasks.reversed() where t.state == .queued {
            guard running < maxRunning else { break }
            running += 1
            t.start { [weak self] in self?.pump() }
        }
        objectWillChange.send()   // the sidebar's count of running downloads
    }
}
