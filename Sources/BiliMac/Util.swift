import AppKit
import ImageIO
import SwiftUI

let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
let biliReferer = "https://www.bilibili.com/"

/// Debug / screenshot switches (environment variables).
enum Env {
    private static let e = ProcessInfo.processInfo.environment
    /// Lists, recommendations and search run signed-out (nothing personal on screen); only play URLs use the login.
    static let demo = e["BILIMAC_DEMO"] != nil
    /// Start on a page: featured | settings | dynamics | search:<q> | video:<BV…>
    static let route = e["BILIMAC_ROUTE"]
    /// Keep player chrome visible.
    static let pinChrome = e["BILIMAC_PIN_CHROME"] != nil
    /// Pretend the pointer hovers the progress bar at this fraction (screenshots / checks), e.g. 0.4.
    static let scrubHover = e["BILIMAC_SCRUB_HOVER"].flatMap(Double.init)
    /// Start the first video paused at this many seconds (screenshots / A-B checks of one frame).
    static let startAt = e["BILIMAC_START"].flatMap(Double.init)
    /// Open the player's danmaku panel on launch (screenshots / checks).
    static let openDanmakuPanel = e["BILIMAC_DANMAKU_PANEL"] != nil
    /// Open UP 主主页 on a tab: videos | collections (screenshots / checks).
    static let spaceTab = e["BILIMAC_SPACE_TAB"]
    /// Window content size, e.g. 1440x900.
    static let windowSize: CGSize? = e["BILIMAC_WINDOW"].flatMap { s in
        let p = s.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
}

// MARK: - Localization (zh-Hans is the development language; keys are the Chinese strings)

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Localized format string; arguments are already-formatted strings (translations may reorder with %1$@).
func Lf(_ key: String, _ args: String...) -> String {
    String(format: L(key), arguments: args.map { $0 as CVarArg })
}

enum AppLanguage {
    /// The language the UI is actually running in.
    static let current: String = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
    static var isEnglish: Bool { current.hasPrefix("en") }

    /// "" = follow the system.
    static let choices: [(String, String)] = [("", "跟随系统 / System"), ("zh-Hans", "简体中文"), ("en", "English"), ("ja", "日本語")]
    static var override: String { (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { code in
        choices.first { !$0.0.isEmpty && code.hasPrefix($0.0) }?.0 } ?? "" }
    private(set) static var pendingRestart = false

    static func set(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        pendingRestart = true
    }

    static func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

func log(_ s: String) {
    let t = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write("[\(t)] \(s)\n".data(using: .utf8)!)
}

struct APIError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

// MARK: - Loose JSON access

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber { return n.intValue }
        if let s = self[k] as? String { return Int(s) }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let n = self[k] as? NSNumber { return n.doubleValue }
        if let s = self[k] as? String { return Double(s) }
        return nil
    }
    func str(_ k: String) -> String? {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = self[k] as? Bool { return b }
        if let n = self[k] as? NSNumber { return n.intValue != 0 }
        return nil
    }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
}

func imageURL(_ s: String?) -> URL? {
    guard var s, !s.isEmpty else { return nil }
    if s.hasPrefix("//") { s = "https:" + s }
    if s.hasPrefix("http://") { s = "https://" + s.dropFirst(7) }
    return URL(string: s)
}

/// bilibili image CDN can resize on the fly; keeps grids light.
func thumbnail(_ u: URL?, width: Int) -> URL? {
    guard let u, u.host?.hasSuffix("hdslb.com") == true, !u.path.contains("@") else { return u }
    return URL(string: u.absoluteString + "@\(width)w_\(width * 9 / 16)h_1c.webp")
}

func plainTitle(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<em class=\"keyword\">", with: "").replacingOccurrences(of: "</em>", with: "")
    for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
        t = t.replacingOccurrences(of: a, with: b)
    }
    return t
}

// MARK: - Formatting

func formatCount(_ n: Int?) -> String {
    guard let n else { return "-" }
    if AppLanguage.isEnglish {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1e9) }
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1e6) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1e3) }
        return "\(n)"
    }
    // 万 / 亿 (Japanese uses 万 / 億 via the translation).
    if n >= 100_000_000 { return String(format: L("%.1f亿"), Double(n) / 1e8) }
    if n >= 10000 { return String(format: L("%.1f万"), Double(n) / 1e4) }
    return "\(n)"
}

func formatDuration(_ s: Int?) -> String {
    guard let s, s >= 0 else { return "" }
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func formatTime(_ secs: Double) -> String {
    guard secs.isFinite, secs >= 0 else { return "00:00" }
    return formatDuration(Int(secs))
}

/// "137:7" / "1:02:03" → seconds (search results use this format).
func parseDurationText(_ s: String?) -> Int? {
    guard let s else { return nil }
    let parts = s.split(separator: ":").compactMap { Int($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

func formatRelativeDate(_ d: Date?) -> String {
    guard let d else { return "" }
    let secs = Date().timeIntervalSince(d)
    if secs < 60 { return L("刚刚") }
    if secs < 3600 { return Lf("%@分钟前", "\(Int(secs / 60))") }
    if secs < 86400 { return Lf("%@小时前", "\(Int(secs / 3600))") }
    if secs < 86400 * 2 { return L("昨天") }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "M-d" : "yyyy-M-d"
    return f.string(from: d)
}

func formatBitrate(_ bps: Double) -> String {
    if bps <= 0 { return "-" }
    if bps >= 1e6 { return String(format: "%.2f Mbps", bps / 1e6) }
    return String(format: "%.0f kbps", bps / 1e3)
}

func formatBytes(_ b: Int) -> String {
    let d = Double(b)
    if d >= 1_073_741_824 { return String(format: "%.2f GB", d / 1_073_741_824) }
    if d >= 1_048_576 { return String(format: "%.1f MB", d / 1_048_576) }
    return String(format: "%.0f KB", d / 1024)
}

// MARK: - Theme

enum Theme {
    static let pink = Color(red: 0.984, green: 0.447, blue: 0.6)        // #FB7299
    static let blue = Color(red: 0.0, green: 0.682, blue: 0.925)        // #00AEEC
    static let corner: CGFloat = 10
}

// MARK: - Image cache

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    init() { cache.totalCostLimit = 200 << 20 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let i = cached(url) { return i }
        var r = URLRequest(url: url)
        r.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r.setValue(biliReferer, forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await session.data(for: r) else { return nil }
        // Decode now, off the main thread; NSImage(data:) would decode lazily while drawing on main.
        let decoded: NSImage? = await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return NSImage(data: data) }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        guard let img = decoded else { return nil }
        cache.setObject(img, forKey: url as NSURL, cost: data.count * 4)
        return img
    }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let i = ImageCache.shared.cached(url) { if image !== i { image = i }; return }
            let i = await ImageCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.25)) { image = i }
        }
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        RemoteImage(url: url.flatMap { URL(string: $0.absoluteString + "@\(Int(size * 2))w_\(Int(size * 2))h_1c.webp") })
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
    }
}

extension View {
    func hoverCursor() -> some View {
        onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}

struct TimeoutError: Error, LocalizedError { var errorDescription: String? { "timed out" } }

/// Runs `work`, giving up after `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await work() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimeoutError() }
        defer { g.cancelAll() }
        return try await g.next()!
    }
}
