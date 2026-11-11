import Foundation

/// 视频线路「自动」: a video opens on the play URL's own host (the nearest edge, quickest to start); after that each
/// segment request goes to the line whose real segments have been arriving fastest. Every few requests, while the
/// buffer has room for a slow one, a line without recent numbers is tried, so a line that slows down (the default
/// one often does after the first segments) or one that gets faster is noticed. What's learned carries over to the
/// next video, and expires after a few minutes.
///
/// A one-off speed test was tried first; its ranking flipped from run to run and often disagreed with what the
/// segments then did, so the real requests are the measurement.
final class LinePicker: @unchecked Sendable {
    static let shared = LinePicker()

    private struct Stat { var mbps: Double; var at: Date }
    private let lock = NSLock()
    private var stats: [String: Stat] = [:]

    /// Numbers older than this don't count (the network may have changed).
    static let fresh: TimeInterval = 3 * 60
    /// Requests that go to the play URL's own host before anything else is used.
    static let opening = 2

    /// The lines for a track: its own hosts, then the play URL rewritten to each fixed node.
    static func candidates(_ urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        var out = urls
        for n in CDNNode.allCases where n.host != nil { out.append(n.rewrite(first)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.host ?? "").inserted }
    }

    /// `urls` in the order to try them for the `n`th request of a stream. `explore`: the buffer can take a slow request.
    func order(_ urls: [URL], request n: Int, explore: Bool) -> [URL] {
        let all = Self.candidates(urls)
        guard n >= Self.opening else { return all }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        func known(_ u: URL) -> Stat? { stats[u.host ?? ""].flatMap { now.timeIntervalSince($0.at) < Self.fresh ? $0 : nil } }
        if explore, n % 4 == 0, let unknown = all.first(where: { known($0) == nil }) {
            return [unknown] + all.filter { $0 != unknown }
        }
        guard let best = all.filter({ known($0) != nil }).max(by: { known($0)!.mbps < known($1)!.mbps }),
              known(best)!.mbps > 0 else { return all }
        return [best] + all.filter { $0 != best }
    }

    /// A finished segment: bytes in `seconds`, request latency included (that's what the player waits for).
    func record(host: String, bytes: Int, seconds: Double) {
        guard bytes > 512 * 1024, seconds > 0 else { return }
        let mbps = Double(bytes * 8) / seconds / 1e6
        lock.lock(); defer { lock.unlock() }
        if let s = stats[host], Date().timeIntervalSince(s.at) < Self.fresh {
            stats[host] = Stat(mbps: s.mbps * 0.6 + mbps * 0.4, at: Date())
        } else {
            stats[host] = Stat(mbps: mbps, at: Date())
        }
    }

    /// A request that failed or got no answer: the line is avoided until its numbers expire.
    func fail(host: String) {
        lock.lock(); stats[host] = Stat(mbps: 0, at: Date()); lock.unlock()
    }

    /// The line doing best lately, if any (settings, downloads).
    var recentBest: String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return stats.filter { now.timeIntervalSince($0.value.at) < Self.fresh && $0.value.mbps > 0 }.max { $0.value.mbps < $1.value.mbps }?.key
    }

    static func short(_ host: String) -> String {
        host.replacingOccurrences(of: ".bilivideo.com", with: "").replacingOccurrences(of: ".akamaized.net", with: "")
            .replacingOccurrences(of: "upos-sz-mirror", with: "").replacingOccurrences(of: "upos-hz-mirror", with: "")
    }
}
