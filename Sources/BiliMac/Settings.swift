import AppKit
import Foundation
import VideoToolbox

enum CodecPref: String, CaseIterable, Identifiable {
    case auto, hevc, avc, av1
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("自动（优先硬解）")
        case .hevc: return "HEVC / H.265"
        case .avc: return "AVC / H.264"
        case .av1: return "AV1"
        }
    }

    /// Codec prefixes in order of preference.
    var order: [String] {
        let hevcHW = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1HW = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        switch self {
        case .auto:
            // AV1 is the smallest stream for the same picture; use it whenever it's decoded in hardware (M3 and later).
            var o: [String] = []
            if av1HW { o += ["av01"] }
            if hevcHW { o += ["hvc1", "hev1"] }
            o += ["avc1"]
            if !hevcHW { o += ["hvc1", "hev1"] }
            if !av1HW { o += ["av01"] }
            return o
        case .hevc: return ["hvc1", "hev1", "avc1", "av01"]
        case .avc: return ["avc1", "hvc1", "hev1", "av01"]
        case .av1: return ["av01", "hvc1", "hev1", "avc1"]
        }
    }
}

/// Where the player's controls and info live.
enum ChromeLayout: String, CaseIterable, Identifiable {
    case outside, overlay
    var id: String { rawValue }
}

/// How the info strip above the video behaves.
enum InfoOverlayMode: String, CaseIterable, Identifiable {
    case always, auto, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .always: return L("一直显示")
        case .auto: return L("自动隐藏")
        case .off: return L("不显示")
        }
    }
}

/// Light / dark / follow the system. The player itself always stays dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// How bright HDR / Dolby Vision video may get next to the rest of the screen.
enum HDRBrightness: String, CaseIterable, Identifiable {
    /// Soft in a window, full in 应用内全屏 / 屏幕全屏.
    case auto, full, soft, sdr
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("自动")
        case .full: return L("完整")
        case .soft: return L("柔和")
        case .sdr: return L("转成 SDR")
        }
    }
}

/// Danmaku-density heat curve above the progress bar (YouTube "most replayed" style).
enum HeatMode: String, CaseIterable, Identifiable {
    case hover, always, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hover: return L("悬停时显示")
        case .always: return L("一直显示")
        case .off: return L("不显示")
        }
    }
}

/// Global quality strategy: an ordered list; each video plays the first entry it actually has.
enum QualityPreset: String, CaseIterable, Identifiable {
    case max, hd, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .max: return L("极致")
        case .hd: return L("高清")
        case .saver: return L("省流")
        }
    }
    var detail: String {
        switch self {
        case .max: return L("大会员画质优先：4K，其次 1080P 高码率")
        case .hd: return L("最高到 1080P，优先高码率")
        case .saver: return L("720P 及以下，适合流量受限的网络")
        }
    }
    /// 4K first, then 1080P 高码率 (112) *before* 1080P60 (116) — bitrate over frame rate.
    func order(hdr: Bool) -> [Int] {
        let base: [Int]
        switch self {
        case .max: base = [120, 112, 116, 80, 74, 64, 32, 16]
        case .hd: base = [112, 116, 80, 74, 64, 32, 16]
        case .saver: base = [64, 32, 16]
        }
        return hdr && self == .max ? [126, 125] + base : base
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // 线路
    @Published var cdnNode: CDNNode { didSet { d.set(cdnNode.rawValue, forKey: "cdnNode") } }
    // 播放
    @Published var qualityPreset: QualityPreset { didSet { d.set(qualityPreset.rawValue, forKey: "qualityPreset") } }
    @Published var preferHDR: Bool { didSet { d.set(preferHDR, forKey: "preferHDR") } }
    @Published var hdrBrightness: HDRBrightness { didSet { d.set(hdrBrightness.rawValue, forKey: "hdrBrightness") } }
    /// Play Dolby Vision profile 8 like the official client: the HLG / HDR10 base layer without the
    /// Dolby dynamic metadata (brighter); off lets macOS map it to the display with the metadata.
    @Published var dolbyVisionOfficial: Bool { didSet { d.set(dolbyVisionOfficial, forKey: "dolbyVisionOfficial") } }
    /// Step down one entry in the order when playback keeps stalling.
    @Published var autoDowngrade: Bool { didSet { d.set(autoDowngrade, forKey: "autoDowngrade") } }
    var qualityOrder: [Int] { qualityPreset.order(hdr: preferHDR) }
    @Published var codec: CodecPref { didSet { d.set(codec.rawValue, forKey: "codec") } }
    @Published var resumePlayback: Bool { didSet { d.set(resumePlayback, forKey: "resumePlayback") } }
    @Published var reportHistory: Bool { didSet { d.set(reportHistory, forKey: "reportHistory") } }
    @Published var featuredAutoNext: Bool { didSet { d.set(featuredAutoNext, forKey: "featuredAutoNext") } }
    @Published var detailAutoNext: Bool { didSet { d.set(detailAutoNext, forKey: "detailAutoNext") } }
    @Published var volume: Float { didSet { d.set(volume, forKey: "volume") } }
    // 弹幕
    @Published var danmakuOn: Bool { didSet { d.set(danmakuOn, forKey: "danmakuOn") } }
    @Published var danmakuOpacity: Double { didSet { d.set(danmakuOpacity, forKey: "danmakuOpacity") } }
    @Published var danmakuScale: Double { didSet { d.set(danmakuScale, forKey: "danmakuScale") } }
    @Published var danmakuSpeed: Double { didSet { d.set(danmakuSpeed, forKey: "danmakuSpeed") } }
    @Published var danmakuArea: Double { didSet { d.set(danmakuArea, forKey: "danmakuArea") } }
    // 弹幕屏蔽 (like the official player's 屏蔽设定)
    @Published var danmakuBlockScroll: Bool { didSet { d.set(danmakuBlockScroll, forKey: "danmakuBlockScroll") } }
    @Published var danmakuBlockTop: Bool { didSet { d.set(danmakuBlockTop, forKey: "danmakuBlockTop") } }
    @Published var danmakuBlockBottom: Bool { didSet { d.set(danmakuBlockBottom, forKey: "danmakuBlockBottom") } }
    @Published var danmakuBlockColor: Bool { didSet { d.set(danmakuBlockColor, forKey: "danmakuBlockColor") } }
    /// 屏蔽等级 0–10: hide danmaku whose weight is below this (0 = off).
    @Published var danmakuLevel: Int { didSet { d.set(danmakuLevel, forKey: "danmakuLevel") } }
    /// 防挡弹幕: leave people in the picture uncovered.
    @Published var danmakuAvoidPeople: Bool { didSet { d.set(danmakuAvoidPeople, forKey: "danmakuAvoidPeople") } }
    /// Rules: plain keyword, "/regex/", or "u:<sender hash>".
    @Published var danmakuBlocklist: [String] { didSet { d.set(danmakuBlocklist, forKey: "danmakuBlocklist") } }
    // 显示
    @Published var showStats: Bool { didSet { d.set(showStats, forKey: "showStats") } }
    @Published var showFeaturedInfo: Bool { didSet { d.set(showFeaturedInfo, forKey: "showFeaturedInfo") } }
    /// outside: bars above/below the picture, always visible. overlay: on the picture, auto-hiding.
    @Published var chromeLayout: ChromeLayout { didSet { d.set(chromeLayout.rawValue, forKey: "chromeLayout") } }
    @Published var infoOverlay: InfoOverlayMode { didSet { d.set(infoOverlay.rawValue, forKey: "infoOverlay") } }
    @Published var heatMode: HeatMode { didSet { d.set(heatMode.rawValue, forKey: "heatMode") } }
    // 音效
    @Published var audioLoudness: Bool { didSet { d.set(audioLoudness, forKey: "audioLoudness") } }
    @Published var audioVoice: Bool { didSet { d.set(audioVoice, forKey: "audioVoice") } }
    /// 画质增强 (super resolution) when the picture is shown larger than the source.
    @Published var superResolution: Bool { didSet { d.set(superResolution, forKey: "superResolution") } }
    @Published var appearance: AppAppearance {
        didSet {
            d.set(appearance.rawValue, forKey: "appearance")
            let a = appearance
            Task { @MainActor in a.apply() }
        }
    }
    /// 精选 / video page: icon rail slides in from the left edge instead of staying put.
    @Published var railAutoHide: Bool { didSet { d.set(railAutoHide, forKey: "railAutoHide") } }
    /// Double-click on the video: false = 应用内全屏, true = 屏幕全屏.
    @Published var doubleClickScreenFull: Bool { didSet { d.set(doubleClickScreenFull, forKey: "doubleClickScreenFull") } }

    private init() {
        let d = UserDefaults.standard
        // One-time copy of settings from the pre-release bundle id.
        if !d.bool(forKey: "migratedFromLocal"), let old = d.persistentDomain(forName: "local.bilimac") {
            for (k, v) in old where !k.hasPrefix("NS") { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromLocal")
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func n(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        cdnNode = CDNNode(rawValue: d.string(forKey: "cdnNode") ?? "") ?? .c08
        qualityPreset = QualityPreset(rawValue: d.string(forKey: "qualityPreset") ?? "") ?? .max
        preferHDR = b("preferHDR", false)
        // 1.1.x defaulted to 自动 (soft in a window); the default is now 完整, like the official client.
        if !d.bool(forKey: "migratedHDRFull") {
            if d.string(forKey: "hdrBrightness") == HDRBrightness.auto.rawValue { d.removeObject(forKey: "hdrBrightness") }
            d.set(true, forKey: "migratedHDRFull")
        }
        hdrBrightness = HDRBrightness(rawValue: d.string(forKey: "hdrBrightness") ?? "") ?? .full
        dolbyVisionOfficial = b("dolbyVisionOfficial", true)
        autoDowngrade = b("autoDowngrade", true)
        codec = CodecPref(rawValue: d.string(forKey: "codec") ?? "") ?? .auto
        resumePlayback = b("resumePlayback", true)
        reportHistory = b("reportHistory", true)
        featuredAutoNext = b("featuredAutoNext", true)
        detailAutoNext = b("detailAutoNext", false)
        volume = Float(n("volume", 1))
        danmakuOn = b("danmakuOn", true)
        danmakuOpacity = n("danmakuOpacity", 0.85)
        danmakuScale = n("danmakuScale", 1)
        danmakuSpeed = n("danmakuSpeed", 1)
        danmakuArea = n("danmakuArea", 0.5)
        // Older builds had one switch for top + bottom.
        let fixedOn = b("danmakuTopBottom", true)
        danmakuBlockScroll = b("danmakuBlockScroll", false)
        danmakuBlockTop = b("danmakuBlockTop", !fixedOn)
        danmakuBlockBottom = b("danmakuBlockBottom", !fixedOn)
        danmakuBlockColor = b("danmakuBlockColor", false)
        danmakuLevel = d.object(forKey: "danmakuLevel") == nil ? 0 : d.integer(forKey: "danmakuLevel")
        danmakuBlocklist = d.stringArray(forKey: "danmakuBlocklist") ?? []
        danmakuAvoidPeople = b("danmakuAvoidPeople", true)
        showStats = b("showStats", false)
        showFeaturedInfo = b("showFeaturedInfo", true)
        chromeLayout = ChromeLayout(rawValue: d.string(forKey: "chromeLayout") ?? "") ?? .outside
        infoOverlay = InfoOverlayMode(rawValue: d.string(forKey: "infoOverlay") ?? "") ?? .auto
        heatMode = HeatMode(rawValue: d.string(forKey: "heatMode") ?? "") ?? .hover
        audioLoudness = b("audioLoudness", false)
        audioVoice = b("audioVoice", false)
        superResolution = b("superResolution", false)
        appearance = AppAppearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        railAutoHide = b("railAutoHide", true)
        doubleClickScreenFull = b("doubleClickScreenFull", false)
    }
}
