import AVFoundation
import CoreImage
import Vision
import VideoToolbox

/// 防挡弹幕: finds people in the playing video on-device (Vision person segmentation) so the danmaku layer
/// can be cut out around them. Works for any video; the official web player instead downloads masks that
/// bilibili precomputes for some popular videos.
///
/// Frames come from an AVPlayerItemVideoOutput scaled down to 512×288, at most ~15 per second, and only
/// while the feature is in use.
final class PersonMasker: ObservableObject, @unchecked Sendable {
    /// Bumped on the main thread whenever a new mask is ready (so a paused frame still gets cut out).
    @Published private(set) var version = 0

    private let lock = NSLock()
    private var _mask: CGImage?
    /// Latest mask: opaque where a person is, stretched over the picture rect when drawn.
    var mask: CGImage? { lock.lock(); defer { lock.unlock() }; return _mask }

    /// Native-size 10-bit YUV. Asking AVFoundation for scaled 8-bit BGRA here made it reconfigure the
    /// shared decode path, and HLG / Dolby Vision video then showed blown-out in the player itself;
    /// so the output stays close to the decoder's format and we scale on our side.
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ])
    private lazy var transfer: VTPixelTransferSession? = {
        var t: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
        return t
    }()
    private var small: CVPixelBuffer?
    private let queue = DispatchQueue(label: "bilimac.person-mask", qos: .userInitiated)
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?
    private weak var item: AVPlayerItem?
    private var active = false

    /// Call with each new player item (quality switch, next video) and with nil on unload.
    @MainActor func attach(_ newItem: AVPlayerItem?) {
        if let old = item, old.outputs.contains(output) { old.remove(output) }
        item = newItem
        setMask(nil)
        if active, let newItem { newItem.add(output) }
    }

    @MainActor func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            if let item, !item.outputs.contains(output) { item.add(output) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(66), leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else {
            timer?.cancel()
            timer = nil
            if let item, item.outputs.contains(output) { item.remove(output) }
            setMask(nil)
        }
    }

    private func tick() {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let full = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        // Scale down to 512 px wide BGRA for Vision (GPU, keeps the aspect ratio).
        let w = 512, h = max(2, Int(512 * Double(CVPixelBufferGetHeight(full)) / Double(max(1, CVPixelBufferGetWidth(full)))) & ~1)
        if small == nil || CVPixelBufferGetWidth(small!) != w || CVPixelBufferGetHeight(small!) != h {
            small = nil
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &small)
        }
        guard let transfer, let frame = small, VTPixelTransferSessionTransferImage(transfer, from: full, to: frame) == noErr else { return }
        do {
            try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
        } catch { return }
        guard let m = request.results?.first?.pixelBuffer else { return }
        let base = CIImage(cvPixelBuffer: m)
        let extent = base.extent
        // Keep only confident pixels (dark, busy scenes give faint grey guesses that would half-hide
        // danmaku all over the place): v' = 3v − 1.2, so below 0.4 is nothing and above ~0.73 is solid.
        // Then grow the silhouette a little, feather it, and turn "white = person" into alpha.
        let soft = base
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0), "inputBiasVector": CIVector(x: -1.2, y: -1.2, z: -1.2, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 4])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
            .cropped(to: extent)
            .applyingFilter("CIMaskToAlpha")
        setMask(ci.createCGImage(soft, from: extent))
    }

    private func setMask(_ m: CGImage?) {
        lock.lock()
        _mask = m
        lock.unlock()
        DispatchQueue.main.async { self.version &+= 1 }
    }
}
