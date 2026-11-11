import AVFoundation
import Foundation
import Network

/// CDN node to force for video/audio segment requests (same signed path, different host).
enum CDNNode: String, CaseIterable, Identifiable {
    case auto, c08 = "08c", hwb, hw, off
    var id: String { rawValue }
    /// The host every request is sent to; nil for 自动 (the play URL's own host first, see `LinePicker`) and 默认.
    var host: String? {
        switch self {
        case .auto: return nil
        case .c08: return "upos-sz-mirror08c.bilivideo.com"
        case .hwb: return "upos-sz-mirrorhwb.bilivideo.com"
        case .hw: return "upos-sz-mirrorhw.bilivideo.com"
        case .off: return nil
        }
    }
    var label: String {
        switch self {
        case .auto: return L("自动（用接口默认节点快速开播，再换到下载最快的线路）")
        case .c08: return L("08c（国内 · 推荐）")
        case .hwb: return L("hwb（华为云）")
        case .hw: return L("hw（华为云）")
        case .off: return L("不改写（使用接口默认海外节点）")
        }
    }
    var short: String {
        switch self {
        case .off: return L("默认")
        case .auto: return L("自动")
        default: return rawValue
        }
    }

    /// The same signed URL on another host.
    static func rewrite(_ url: URL, host: String) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.host = host
        c.port = nil
        return c.url ?? url
    }

    /// Rewrites upos-* hosts only; PCDN/MCDN URLs (different signing) are left alone.
    func rewrite(_ url: URL) -> URL {
        guard let host, let h = url.host, h.hasPrefix("upos-") || h.hasSuffix(".akamaized.net"),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.host = host
        c.port = nil
        return c.url ?? url
    }
}

/// One DASH presentation exposed as HLS (fMP4 + EXT-X-BYTERANGE) on the local server.
final class HLSStream {
    struct Segment { let offset: Int; let size: Int; let duration: Double }
    struct Track {
        let dash: DashTrack
        let urls: [URL]       // CDN-rewritten primary first, then originals as fallback
        let segments: [Segment]
        /// HDR signalling for the master playlist (video only).
        var hdr: HDRSignal? = nil
        /// Bytes to overwrite as the file streams through (absolute offset → byte).
        var patches: [Int: UInt8] = [:]

        /// The same track with freshly signed URLs; the host that worked last stays first.
        func with(_ d: DashTrack, node: CDNNode) -> Track {
            var fresh = (d.urls.map(node.rewrite) + d.urls).uniqued()
            let host = urls.first?.host
            // 自动 may have moved to a host the new URLs don't list.
            if let host, !fresh.contains(where: { $0.host == host }), let f = fresh.first { fresh.insert(CDNNode.rewrite(f, host: host), at: 0) }
            return Track(dash: d, urls: fresh.filter { $0.host == host } + fresh.filter { $0.host != host },
                         segments: segments, hdr: hdr, patches: patches)
        }
    }

    let id: String
    let stats = StreamStats()
    /// The CDN node the URLs were rewritten for, to rewrite refreshed ones the same way.
    let node: CDNNode
    // The tracks' URLs change when they're refreshed, from the proxy's queue, while the player reads them.
    private let trackLock = NSLock()
    private var _video: Track
    private var _audio: Track?
    var video: Track { trackLock.lock(); defer { trackLock.unlock() }; return _video }
    var audio: Track? { trackLock.lock(); defer { trackLock.unlock() }; return _audio }

    /// Fetches the same tracks again with newly signed URLs. bilibili's CDN URLs stop working a couple of
    /// hours after the play URL was fetched (`deadline=`): a video left paused overnight, or through a sleep,
    /// could play what it had buffered and then never load another byte.
    var refresher: (@Sendable () async throws -> (video: DashTrack, audio: DashTrack?))?
    private var refreshing: Task<Bool, Never>?
    private var lastRefresh = Date.distantPast

    /// When the signed URLs stop working (the earliest `deadline` among the tracks' first URLs).
    var expiry: Date? {
        func deadline(_ u: URL?) -> Date? {
            guard let u, let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "deadline" })?.value, let t = Double(v) else { return nil }
            return Date(timeIntervalSince1970: t)
        }
        return [deadline(video.urls.first), deadline(audio?.urls.first)].compactMap { $0 }.min()
    }

    /// True when the URLs have expired or are about to.
    var isStale: Bool { expiry.map { $0.timeIntervalSinceNow < 60 } ?? false }

    /// Replaces the tracks' URLs with fresh ones. Concurrent callers share one fetch; a refresh in the last
    /// 20 s counts as done (a failure right after one isn't an expiry). Returns false if it couldn't refresh.
    func refreshURLs() async -> Bool {
        guard let task = refreshTask() else { return true }
        return await task.value
    }

    /// The fetch in flight, or a new one; nil when the URLs were refreshed moments ago.
    private func refreshTask() -> Task<Bool, Never>? {
        trackLock.lock(); defer { trackLock.unlock() }
        if let t = refreshing { return t }
        if Date().timeIntervalSince(lastRefresh) < 20 { return nil }
        let t = Task { [weak self] () -> Bool in
            guard let self, let refresher = self.refresher else { return false }
            do {
                let fresh = try await refresher()
                self.finishRefresh(fresh)
                log("\(self.id): CDN URLs refreshed, valid until \(self.expiry.map { "\($0)" } ?? "?")")
                return true
            } catch {
                self.finishRefresh(nil)
                log("\(self.id): CDN URL refresh failed: \(error)")
                return false
            }
        }
        refreshing = t
        return t
    }

    /// BILIMAC_TEST_EXPIRED: spoils the URLs the way hours of waiting would.
    func spoilURLsForTesting(_ how: String) {
        func spoil(_ t: Track) -> Track {
            let urls = t.urls.map { u -> URL in
                guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
                c.queryItems = c.queryItems?.map { q in
                    if how == "deadline", q.name == "deadline" { return URLQueryItem(name: q.name, value: "\(Int(Date().timeIntervalSince1970) - 3600)") }
                    if how == "sig", q.name == "upsig" { return URLQueryItem(name: q.name, value: String(repeating: "0", count: q.value?.count ?? 32)) }
                    return q
                }
                return c.url ?? u
            }
            return Track(dash: t.dash, urls: urls, segments: t.segments, hdr: t.hdr, patches: t.patches)
        }
        trackLock.lock(); defer { trackLock.unlock() }
        _video = spoil(_video)
        _audio = _audio.map(spoil)
    }

    private func finishRefresh(_ fresh: (video: DashTrack, audio: DashTrack?)?) {
        trackLock.lock(); defer { trackLock.unlock() }
        if let fresh {
            _video = _video.with(fresh.video, node: node)
            if let a = fresh.audio, let cur = _audio { _audio = cur.with(a, node: node) }
            lastRefresh = Date()
        }
        refreshing = nil
    }

    /// Leave audio out of the master playlist: the audio plays in its own player (音效处理).
    var videoOnly = false
    /// The whole audio file, once downloaded for the separate audio player; ranges are served from it.
    private let audioLock = NSLock()
    private var _audioData: Data?
    var audioData: Data? {
        get { audioLock.lock(); defer { audioLock.unlock() }; return _audioData }
        set { audioLock.lock(); _audioData = newValue; audioLock.unlock() }
    }
    /// 自动: video segment requests so far (the proxy's queue only), and whether the buffer can take a trial of
    /// another line (set by the player).
    var videoRequests = 0
    var exploreOK = false

    init(id: String, video: Track, audio: Track?, node: CDNNode) {
        self.id = id; self._video = video; self._audio = audio; self.node = node
    }

    /// Peak video segment bitrate from the SIDX (bits/s).
    var videoPeak: Int? {
        video.segments.compactMap { $0.duration > 0.5 ? Int(Double($0.size * 8) / $0.duration) : nil }.max()
    }

    func masterPlaylist() -> String {
        let v = video.dash
        let audio = videoOnly ? nil : self.audio
        var codecs = v.codecs
        if let a = audio { codecs += "," + a.dash.codecs }
        let fps = Double(v.frameRate).map { String(format: ",FRAME-RATE=%.3f", $0) } ?? ""
        let bw = v.bandwidth + (audio?.dash.bandwidth ?? 0)
        // DASH bandwidth is an average; HLS BANDWIDTH must be the peak segment bitrate.
        func peakRate(_ t: Track?) -> Int {
            Int(t?.segments.map { $0.duration > 0 ? Double($0.size * 8) / $0.duration : 0 }.max() ?? 0)
        }
        let peak = max(Int(Double(bw) * 1.2), peakRate(video) + peakRate(audio))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        if audio != nil {
            s += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"\(audio?.dash.codecs.hasPrefix("ec-3") == true ? "16/JOC" : "2")\",URI=\"audio.m3u8\"\n"
        }
        if let base = video.hdr?.codecs { codecs = base + (audio.map { "," + $0.dash.codecs } ?? "") }
        s += "#EXT-X-STREAM-INF:BANDWIDTH=\(peak),AVERAGE-BANDWIDTH=\(bw),CODECS=\"\(codecs)\",RESOLUTION=\(v.width)x\(v.height)\(fps)"
        if let h = video.hdr {
            if let sup = h.supplementalCodecs { s += ",SUPPLEMENTAL-CODECS=\"\(sup)\"" }
            s += ",VIDEO-RANGE=\(h.videoRange)"
        }
        s += audio != nil ? ",AUDIO=\"aud\"\n" : "\n"
        s += "video.m3u8\n"
        return s
    }

    func mediaPlaylist(_ t: Track, file: String) -> String {
        let target = Int((t.segments.map(\.duration).max() ?? 1).rounded(.up))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        s += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        let ini = t.dash.initRange
        s += "#EXT-X-MAP:URI=\"\(file)\",BYTERANGE=\"\(ini.count)@\(ini.lowerBound)\"\n"
        for seg in t.segments {
            s += String(format: "#EXTINF:%.5f,\n", seg.duration)
            s += "#EXT-X-BYTERANGE:\(seg.size)@\(seg.offset)\n\(file)\n"
        }
        s += "#EXT-X-ENDLIST\n"
        return s
    }
}

enum SIDX {
    /// Parses an ISO-BMFF `sidx` box. `anchor` is the file offset of the first byte after the box.
    static func parse(_ d: Data, anchor: Int) throws -> [HLSStream.Segment] {
        let b = [UInt8](d)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func u64(_ i: Int) -> Int { u32(i) << 32 | u32(i + 4) }
        guard b.count >= 32, String(bytes: b[4..<8], encoding: .ascii) == "sidx" else {
            throw APIError(description: "index range is not a sidx box")
        }
        let version = b[8]
        let timescale = Double(u32(16))
        var p = 20
        let firstOffset: Int
        if version == 0 { firstOffset = u32(p + 4); p += 8 } else { firstOffset = u64(p + 8); p += 16 }
        let count = Int(b[p + 2]) << 8 | Int(b[p + 3])
        p += 4
        var offset = anchor + firstOffset
        var out: [HLSStream.Segment] = []
        for _ in 0..<count {
            guard p + 12 <= b.count else { break }
            let size = u32(p) & 0x7fff_ffff
            let dur = Double(u32(p + 4)) / timescale
            out.append(.init(offset: offset, size: size, duration: dur))
            offset += size
            p += 12
        }
        return out
    }
}

/// Minimal localhost HTTP server: serves generated HLS playlists and proxies byte ranges
/// to the bilibili CDN with the Referer/User-Agent the CDN requires.
final class HLSProxy: NSObject {
    static let shared = HLSProxy()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var streams: [String: HLSStream] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hls.proxy")
    private lazy var upstream: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var pipes: [Int: Pipe] = [:]
    static let logRequests = ProcessInfo.processInfo.environment["BILIMAC_LOGSEG"] != nil  // keyed by URLSessionTask.taskIdentifier

    // Throughput stats for the status line.
    private var statBytes = 0
    private var statStart = Date()
    private(set) var lastMbps: Double = 0

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let l = try makeListener(port: .any) { ready.signal() }
        _ = ready.wait(timeout: .now() + 3)
        port = l.port?.rawValue ?? 0
        log("HLS proxy on 127.0.0.1:\(port)")
    }

    /// Listens on 127.0.0.1. If the listener fails later (it can after a sleep or a network change), it's
    /// started again on the same port, so the players' URLs keep working.
    @discardableResult
    private func makeListener(port: NWEndpoint.Port, onReady: @escaping () -> Void = {}) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        var wasReady = false
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                wasReady = true
                onReady()
            case .failed(let e):
                log("listener failed: \(e)")
                onReady()
                l?.cancel()
                guard wasReady, let self, self.port != 0 else { return }
                self.queue.asyncAfter(deadline: .now() + 1) { self.restartListener() }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
        return l
    }

    private func restartListener(attempt: Int = 1) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        do {
            try makeListener(port: p)
            log("HLS proxy restarted on 127.0.0.1:\(port)")
        } catch {
            log("HLS proxy restart failed (\(attempt)): \(error)")
            if attempt < 10 { queue.asyncAfter(deadline: .now() + 2) { self.restartListener(attempt: attempt + 1) } }
        }
    }

    func register(_ s: HLSStream) -> URL {
        lock.lock(); streams[s.id] = s; lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/s/\(s.id)/master.m3u8")!
    }

    func unregister(_ id: String) {
        lock.lock(); streams[id] = nil; lock.unlock()
    }

    /// Fetches SIDX for both tracks and builds the HLS description.
    func prepare(id: String, video: DashTrack, audio: DashTrack?, node: CDNNode) async throws -> HLSStream {
        @Sendable func build(_ d: DashTrack, video: Bool = false) async throws -> HLSStream.Track {
            // Video: fetch the init segment with the index when they're adjacent, to read its HDR signalling.
            let withInit = video && d.initRange.upperBound + 1 == d.indexRange.lowerBound
            let lo = withInit ? d.initRange.lowerBound : d.indexRange.lowerBound
            let urls = d.urls.map(node.rewrite) + d.urls
            var lastError: Error = APIError(description: "no url")
            for u in urls.uniqued() {
                do {
                    var r = URLRequest(url: u)
                    r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
                    r.setValue(biliReferer, forHTTPHeaderField: "Referer")
                    r.setValue("bytes=\(lo)-\(d.indexRange.upperBound)", forHTTPHeaderField: "Range")
                    r.timeoutInterval = 8
                    let (data, resp) = try await URLSession.shared.data(for: r)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 206 || code == 200 else { throw APIError(description: "sidx HTTP \(code) from \(u.host ?? "")") }
                    let skip = d.indexRange.lowerBound - lo
                    let segs = try SIDX.parse(data.dropFirst(skip).prefix(d.indexRange.count), anchor: d.indexRange.upperBound + 1)
                    var hdr = withInit ? await HDRSignal.read(init: data.prefix(skip), codecs: d.codecs) : nil
                    var patches: [Int: UInt8] = [:]
                    if let h = hdr, let off = h.dvTagOffset, AppSettings.shared.dolbyVisionOfficial {
                        // Rename the Dolby Vision box to "free": players then see a plain HLG / HDR10 stream.
                        for (i, byte) in Array("free".utf8).enumerated() { patches[lo + off + i] = byte }
                        hdr = h.withoutDolbyVision()
                    }
                    if let hdr { log("hdr: \(hdr.videoRange) \(hdr.supplementalCodecs ?? "") \(hdr.codecs ?? "")\(patches.isEmpty ? "" : " (Dolby metadata ignored)")") }
                    // Put the URL that worked first.
                    return .init(dash: d, urls: [u] + urls.filter { $0 != u }.uniqued(), segments: segs, hdr: hdr, patches: patches)
                } catch {
                    lastError = error
                    log("sidx fetch failed (\(u.host ?? "")): \(error)")
                }
            }
            throw lastError
        }
        async let v = build(video, video: true)
        var at: HLSStream.Track?
        if let audio { at = try await build(audio) }
        return HLSStream(id: id, video: try await v, audio: at, node: node)
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        readRequest(c, buffer: Data())
    }

    private func readRequest(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, head: String(decoding: buf[..<r.lowerBound], as: UTF8.self))
            } else if done || err != nil || buf.count > 65536 {
                c.cancel()
            } else {
                self.readRequest(c, buffer: buf)
            }
        }
    }

    private func handle(_ c: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(c, 400, "bad request") }
        let method = String(parts[0])
        let path = String(parts[1]).components(separatedBy: "?")[0]
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        // /s/<id>/<file>
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count == 3, comps[0] == "s" else { return respond(c, 404, "not found") }
        lock.lock(); let s = streams[comps[1]]; lock.unlock()
        guard let s else { return respond(c, 404, "unknown stream") }
        if Self.logRequests { log("req \(comps[2]) \(headers["range"] ?? "")") }
        switch comps[2] {
        case "master.m3u8": respond(c, 200, s.masterPlaylist(), type: "application/vnd.apple.mpegurl", head: method == "HEAD")
        case "video.m3u8": respond(c, 200, s.mediaPlaylist(s.video, file: "video.m4s"), type: "application/vnd.apple.mpegurl", head: method == "HEAD")
        case "audio.m3u8":
            guard let a = s.audio else { return respond(c, 404, "no audio") }
            respond(c, 200, s.mediaPlaylist(a, file: "audio.m4s"), type: "application/vnd.apple.mpegurl", head: method == "HEAD")
        case "video.m4s": proxy(c, stream: s, range: headers["range"], video: true)
        case "audio.m4s":
            guard s.audio != nil else { return respond(c, 404, "no audio") }
            if let data = s.audioData { return serve(c, data, range: headers["range"], head: method == "HEAD") }
            proxy(c, stream: s, range: headers["range"], video: false)
        default: respond(c, 404, "not found")
        }
    }

    /// Serves a byte range of an in-memory file.
    private func serve(_ c: NWConnection, _ data: Data, range: String?, head: Bool) {
        let total = data.count
        var lo = 0, hi = total - 1, partial = false
        if let range, range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if let a = Int(spec[0]) { lo = a; hi = Int(spec[1]) ?? total - 1 }
                else if let n = Int(spec[1]) { lo = max(0, total - n) }   // suffix range
                partial = true
            }
        }
        hi = min(hi, total - 1)
        guard lo <= hi else { return respond(c, 416, "range not satisfiable") }
        var h = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
        h += "Content-Length: \(hi - lo + 1)\r\nConnection: close\r\n"
        if partial { h += "Content-Range: bytes \(lo)-\(hi)/\(total)\r\n" }
        h += "\r\n"
        var out = Data(h.utf8)
        if !head { out.append(data.subdata(in: lo..<(hi + 1))) }
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(_ c: NWConnection, _ status: Int, _ body: String, type: String = "text/plain", head: Bool = false) {
        let b = Data(body.utf8)
        var h = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\n"
        h += "Content-Length: \(b.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var out = Data(h.utf8)
        if !head { out.append(b) }
        c.send(content: out, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    // MARK: Upstream proxying

    final class Pipe {
        let conn: NWConnection
        let stream: HLSStream?
        /// Asked the stream for fresh URLs once already (after every host refused).
        var refreshed = false
        var urls: [URL]
        let range: String?
        let label: String
        let stats: StreamStats?
        let isVideo: Bool
        var task: URLSessionDataTask?
        var headerSent = false
        var pending = 0
        var suspended = false
        var bytes = 0
        let started = Date()
        var closed = false
        var patches: [Int: UInt8] = [:]
        /// File offset of the first byte this pipe sends.
        var start = 0
        init(conn: NWConnection, stream: HLSStream?, urls: [URL], range: String?, label: String, stats: StreamStats?, isVideo: Bool) {
            self.conn = conn; self.stream = stream; self.urls = urls; self.range = range; self.label = label; self.stats = stats; self.isVideo = isVideo
            if let range, range.hasPrefix("bytes="), let a = Int(range.dropFirst(6).split(separator: "-").first ?? "") { start = a }
        }
    }

    private func proxy(_ c: NWConnection, stream s: HLSStream, range: String?, video: Bool) {
        let track = video ? s.video : s.audio
        var urls = track?.urls ?? []
        if s.node == .auto {
            let n = s.videoRequests
            if video { s.videoRequests += 1 }
            urls = LinePicker.shared.order(urls, request: n, explore: video && s.exploreOK)
        }
        let p = Pipe(conn: c, stream: s, urls: urls, range: range, label: "\(s.id)/\(video ? "v" : "a")",
                     stats: s.stats, isVideo: video)
        p.patches = track?.patches ?? [:]
        c.stateUpdateHandler = { [weak self, weak p] st in
            switch st {
            case .failed, .cancelled:
                guard let self, let p else { return }
                self.queue.async { p.closed = true; p.task?.cancel() }
            default: break
            }
        }
        // Expired URLs (the video sat paused for hours, or the Mac slept): sign new ones before asking the CDN.
        if s.isStale {
            p.refreshed = true
            refreshThenStart(p)
        } else {
            queue.async { self.startNext(p) }
        }
    }

    /// Gets the stream fresh URLs, then starts the pipe on them (or answers 502 when that fails).
    private func refreshThenStart(_ p: Pipe) {
        guard let s = p.stream else { return queue.async { self.startNext(p) } }
        Task {
            let ok = await s.refreshURLs()
            self.queue.async {
                guard !p.closed else { return }
                if ok { p.urls = (p.isVideo ? s.video.urls : s.audio?.urls) ?? [] }
                if p.urls.isEmpty { return self.respond(p.conn, 502, "all upstreams failed") }
                self.startNext(p)
            }
        }
    }

    private func startNext(_ p: Pipe) {
        guard !p.closed else { return }
        guard !p.urls.isEmpty else {
            // Every host refused (403 once the signature expires): try once more with newly signed URLs.
            if !p.headerSent, !p.refreshed, p.stream?.refresher != nil {
                p.refreshed = true
                log("all upstreams failed for \(p.label); refreshing its URLs")
                return refreshThenStart(p)
            }
            if !p.headerSent { respond(p.conn, 502, "all upstreams failed") } else { p.conn.cancel() }
            return
        }
        let u = p.urls.removeFirst()
        var r = URLRequest(url: u)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue(biliReferer, forHTTPHeaderField: "Referer")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = p.range { r.setValue(range, forHTTPHeaderField: "Range") }
        let t = upstream.dataTask(with: r)
        p.task = t
        pipes[t.taskIdentifier] = p
        t.resume()
        // A request the CDN doesn't answer at all within 1.5 s (it happens) goes to the next host: the player
        // itself waited ~5 s before asking again, which was the whole start-up of a video.
        if !p.urls.isEmpty {
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self, weak p] in
                guard let self, let p, self.pipes[t.taskIdentifier] === p, !p.headerSent, !p.closed else { return }
                log("upstream \(u.host ?? "?") silent for 1.5 s for \(p.label); trying next")
                if p.stream?.node == .auto, let h = u.host { LinePicker.shared.fail(host: h) }
                self.pipes[t.taskIdentifier] = nil
                t.cancel()
                self.startNext(p)
            }
        }
    }

    private func send(_ p: Pipe, _ data: Data, final: Bool = false) {
        p.pending += data.count
        if p.pending > 8 << 20, !p.suspended, let t = p.task { p.suspended = true; t.suspend() }
        p.conn.send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: final,
                    completion: .contentProcessed { [weak self] err in
            self?.queue.async {
                p.pending -= data.count
                if err != nil { p.closed = true; p.task?.cancel() }
                if p.suspended, p.pending < 2 << 20, !p.closed { p.suspended = false; p.task?.resume() }
                if final { p.conn.cancel() }
            }
        })
    }

    fileprivate func record(bytes: Int) {
        statBytes += bytes
        let dt = Date().timeIntervalSince(statStart)
        if dt > 2 {
            lastMbps = Double(statBytes) * 8 / dt / 1e6
            statBytes = 0
            statStart = Date()
        }
    }
}

extension HLSProxy: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        queue.async { [self] in
            guard let p = pipes[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
                return completionHandler(.cancel)
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                log("upstream \(http.statusCode) from \(response.url?.host ?? "?") for \(p.label); trying next")
                if p.stream?.node == .auto, http.statusCode != 403, let h = dataTask.originalRequest?.url?.host { LinePicker.shared.fail(host: h) }
                pipes[dataTask.taskIdentifier] = nil
                completionHandler(.cancel)
                startNext(p)
                return
            }
            var h = "HTTP/1.1 \(http.statusCode) \(http.statusCode == 206 ? "Partial Content" : "OK")\r\n"
            h += "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
            if let len = http.value(forHTTPHeaderField: "Content-Length") { h += "Content-Length: \(len)\r\n" }
            if let cr = http.value(forHTTPHeaderField: "Content-Range") { h += "Content-Range: \(cr)\r\n" }
            h += "\r\n"
            p.headerSent = true
            send(p, Data(h.utf8))
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [self] in
            guard let p = pipes[dataTask.taskIdentifier], !p.closed else { return }
            var data = data
            if !p.patches.isEmpty {
                let base = p.start + p.bytes
                for (off, byte) in p.patches where off >= base && off < base + data.count {
                    data[data.startIndex + off - base] = byte
                }
            }
            p.bytes += data.count
            record(bytes: data.count)
            p.stats?.add(bytes: data.count, host: dataTask.originalRequest?.url?.host ?? "?")
            send(p, data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [self] in
            guard let p = pipes.removeValue(forKey: task.taskIdentifier) else { return }
            if let error, !p.closed {
                log("upstream error for \(p.label) from \(task.originalRequest?.url?.host ?? "?"): \(error.localizedDescription)")
                if p.stream?.node == .auto, let h = task.originalRequest?.url?.host { LinePicker.shared.fail(host: h) }
                if !p.headerSent { return startNext(p) }
                p.conn.cancel()
                return
            }
            guard !p.closed else { return }
            let dt = Date().timeIntervalSince(p.started)
            if p.isVideo, p.stream?.node == .auto, let h = task.originalRequest?.url?.host {
                LinePicker.shared.record(host: h, bytes: p.bytes, seconds: dt)
            }
            p.stats?.segment(.init(at: Date(), bytes: p.bytes, seconds: dt, host: task.originalRequest?.url?.host ?? "?", video: p.isVideo))
            if ProcessInfo.processInfo.environment["BILIMAC_LOGSEG"] != nil { log(String(format: "seg %@ %@ %.0fKB in %.2fs = %.1f Mbps via %@", p.label, p.range ?? "-",
                       Double(p.bytes) / 1024, dt, Double(p.bytes) * 8 / max(dt, 0.001) / 1e6,
                       task.originalRequest?.url?.host ?? "?")) }
            send(p, Data(), final: true)
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Per-stream download statistics shown in the 统计信息 overlay.
final class StreamStats {
    struct Seg { let at: Date; let bytes: Int; let seconds: Double; let host: String; let video: Bool }
    private let lock = NSLock()
    private var samples: [(Date, Int)] = []
    private var hostSamples: [String: [(Date, Int)]] = [:]
    private var hostSeen: [String: Date] = [:]
    private(set) var totalBytes = 0
    private var segs: [Seg] = []

    func add(bytes: Int, host: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        totalBytes += bytes
        samples.append((now, bytes))
        hostSamples[host, default: []].append((now, bytes))
        hostSeen[host] = now
        let cutoff = now.addingTimeInterval(-10)
        if let i = samples.firstIndex(where: { $0.0 >= cutoff }), i > 0 { samples.removeFirst(i) }
        if let i = hostSamples[host]?.firstIndex(where: { $0.0 >= cutoff }), i > 0 { hostSamples[host]?.removeFirst(i) }
    }

    /// Download rate per CDN host over the last `window` seconds, for hosts used in the last minute.
    func hostRates(window: Double = 2) -> [(host: String, bps: Double)] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-window)
        return hostSeen.filter { now.timeIntervalSince($0.value) < 60 }.keys.sorted().map { h in
            (h, Double((hostSamples[h] ?? []).filter { $0.0 >= cutoff }.reduce(0) { $0 + $1.1 } * 8) / window)
        }
    }

    func segment(_ s: Seg) {
        lock.lock(); defer { lock.unlock() }
        segs.append(s)
        if segs.count > 40 { segs.removeFirst(segs.count - 40) }
    }

    /// Bits per second received over the last `window` seconds.
    func rate(window: Double = 1) -> Double {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-window)
        return Double(samples.filter { $0.0 >= cutoff }.reduce(0) { $0 + $1.1 } * 8) / window
    }

    var total: Int { lock.lock(); defer { lock.unlock() }; return totalBytes }

    /// Throughput of recent video segments big enough to measure (bytes·8 / transfer time).
    func segmentRate() -> Double? {
        lock.lock(); defer { lock.unlock() }
        let recent = segs.suffix(8).filter { $0.bytes > 64 * 1024 && $0.seconds > 0 }
        guard !recent.isEmpty else { return nil }
        return Double(recent.reduce(0) { $0 + $1.bytes } * 8) / recent.reduce(0) { $0 + $1.seconds }
    }

    var lastSegment: Seg? { lock.lock(); defer { lock.unlock() }; return segs.last(where: { $0.video }) }

    /// Throughput (bits/s) of the last few sizeable video segments from `host` in the last minute; nil with fewer than two.
    func recentRate(host: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-60)
        let recent = segs.filter { $0.video && $0.host == host && $0.at > cutoff && $0.bytes > 256 * 1024 && $0.seconds > 0 }.suffix(4)
        guard recent.count >= 2 else { return nil }
        return Double(recent.reduce(0) { $0 + $1.bytes } * 8) / recent.reduce(0) { $0 + $1.seconds }
    }
    var lastHost: String? { lock.lock(); defer { lock.unlock() }; return segs.last?.host }
}

/// How an HDR video track has to be declared in the HLS master playlist: VIDEO-RANGE, and for
/// Dolby Vision the SUPPLEMENTAL-CODECS (profile 8) or a dvh1 CODECS (profile 5).
struct HDRSignal {
    let videoRange: String            // "PQ" or "HLG"
    var supplementalCodecs: String? = nil
    /// Replaces the video entry in CODECS (Dolby Vision profile 5 has no HDR10 / HLG base layer).
    var codecs: String? = nil
    /// Where the Dolby Vision configuration box's type sits in the init data, for profiles whose
    /// base layer plays on its own (8.1 / 8.4); nil otherwise.
    var dvTagOffset: Int? = nil

    /// The same stream played the official client's way: base layer only, Dolby metadata ignored.
    func withoutDolbyVision() -> HDRSignal { HDRSignal(videoRange: videoRange) }

    /// Reads the init segment: the transfer function via AVFoundation, the Dolby Vision box by hand.
    /// nil for SDR tracks.
    static func read(init data: Data, codecs: String) async -> HDRSignal? {
        var dv: (profile: Int, level: Int, compat: Int, offset: Int)?
        for tag in ["dvvC", "dvcC", "dvwC"] {
            if let r = data.range(of: Data(tag.utf8)), data.count >= r.upperBound + 5 {
                let b = [UInt8](data[r.upperBound ..< r.upperBound + 5])
                dv = (Int(b[2] >> 1) & 0x7F, (Int(b[2] & 1) << 5) | Int(b[3] >> 3), Int(b[4] >> 4), r.lowerBound - data.startIndex)
                break
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bilimac-init-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var transfer: String?
        if (try? data.write(to: url)) != nil,
           let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let fd = try? await track.load(.formatDescriptions).first {
            let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
            transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String
        }
        let base = codecs.split(separator: ",").first.map(String.init) ?? codecs
        var range: String?
        if transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) { range = "HLG" }
        else if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) { range = "PQ" }
        guard let dv else { return range.map { HDRSignal(videoRange: $0) } }
        let tag = String(format: "dvh1.%02d.%02d", dv.profile, dv.level)
        switch (dv.profile, dv.compat) {
        case (5, _): return HDRSignal(videoRange: "PQ", codecs: tag)
        case (8, 4): return HDRSignal(videoRange: range ?? "HLG", supplementalCodecs: tag + "/db4h", codecs: base == codecs ? nil : base, dvTagOffset: dv.offset)
        case (8, 1): return HDRSignal(videoRange: range ?? "PQ", supplementalCodecs: tag + "/db1p", dvTagOffset: dv.offset)
        case (8, 2): return range.map { HDRSignal(videoRange: $0, supplementalCodecs: tag + "/db2g") }
        default: return range.map { HDRSignal(videoRange: $0) }
        }
    }
}
