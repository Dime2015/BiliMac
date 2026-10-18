import Foundation

// MARK: - 线路

@MainActor
final class SpeedTest: ObservableObject {
    @Published var results: [CDNNode: Double] = [:]
    @Published var failed: Set<CDNNode> = []
    @Published var running: CDNNode?
    @Published var defaultHost: String?
    @Published var error: String?

    func run() async {
        results = [:]
        failed = []
        error = nil
        do {
            let pop = try await BiliAPI.shared.popular(page: 1)
            guard let v = pop.items.first(where: { $0.cid != nil }), let cid = v.cid else { throw APIError(description: L("没有可测速的视频")) }
            let info = try await BiliAPI.shared.playInfo(bvid: v.bvid, cid: cid)
            let track = info.pickVideo(qn: 80, codec: .avc)
            guard let base = track.urls.first else { throw APIError(description: L("没有视频地址")) }
            defaultHost = base.host
            for node in CDNNode.allCases {
                running = node
                let url = node == .off ? base : node.rewrite(base)
                if let mbps = await RangeProbe.measure(url, seconds: 6) { results[node] = mbps } else { failed.insert(node) }
            }
        } catch {
            self.error = error.localizedDescription
        }
        running = nil
    }

    var fastest: CDNNode? { results.max { $0.value < $1.value }?.key }
}

/// Downloads from a URL for up to `seconds` and reports the throughput in Mbps.
final class RangeProbe: NSObject, URLSessionDataDelegate {
    private var bytes = 0
    private var firstByte: Date?
    private var cont: CheckedContinuation<Double?, Never>?
    private var ok = false

    static func measure(_ url: URL, seconds: Double) async -> Double? {
        let p = RangeProbe()
        let s = URLSession(configuration: .ephemeral, delegate: p, delegateQueue: nil)
        defer { s.invalidateAndCancel() }
        var r = URLRequest(url: url)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue(biliReferer, forHTTPHeaderField: "Referer")
        r.setValue("bytes=0-40000000", forHTTPHeaderField: "Range")
        r.timeoutInterval = 8
        return await withCheckedContinuation { c in
            p.cont = c
            let t = s.dataTask(with: r)
            t.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { t.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        ok = code == 200 || code == 206
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if firstByte == nil { firstByte = Date() }
        bytes += data.count
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let c = cont else { return }
        cont = nil
        guard ok, let f = firstByte, bytes > 100_000 else { return c.resume(returning: nil) }
        c.resume(returning: Double(bytes * 8) / max(Date().timeIntervalSince(f), 0.05) / 1e6)
    }
}

