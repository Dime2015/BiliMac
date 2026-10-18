import AVFoundation
import CoreVideo
import Metal
import MetalFX
import QuartzCore
import SwiftUI
import VideoToolbox

/// 画质增强 (super resolution). Pulls frames from the player and draws them itself:
///
/// 1. Sources up to 720p go through VideoToolbox's ML low-latency super-resolution first
///    (2× up to 854×480, 1.5× for 720p; about 1–2.5 ms a frame on Apple silicon).
/// 2. YUV → RGB in a Metal shader.
/// 3. MetalFX spatial scaling to exactly the pixels the picture covers on screen (1080p sources
///    go straight here: the real-time ML model takes at most 1280 px).
/// 4. Drawn aspect-fit into a CAMetalLayer.
///
/// Only used when the picture is shown noticeably larger than the source and the stream is SDR;
/// otherwise the normal AVPlayerLayer shows through and nothing here runs.
final class SuperResLayerView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var convertPipeline: MTLComputePipelineState?
    private var link: CADisplayLink?

    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var sourceSize: CGSize = .zero

    // ML stage (macOS 26+): an MLUpscaler, kept untyped so the view still builds for macOS 14.
    private var ml: AnyObject?

    // MetalFX stage.
    private var scaler: MTLFXSpatialScaler?
    private var scalerIn: CGSize = .zero
    private var scalerOut: CGSize = .zero
    private var rgbTexture: MTLTexture?
    private var scaledTexture: MTLTexture?

    private var lastFrame: CVPixelBuffer?
    /// Reported to the stats panel.
    var onStatus: ((String) -> Void)?
    /// True once frames are being drawn (the AVPlayerLayer underneath can hide).
    var onDrawing: ((Bool) -> Void)?
    private var drawing = false { didSet { if drawing != oldValue { onDrawing?(drawing) } } }
    private var frameMs: Double = 0
    private var lastStatus = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        metalLayer.isOpaque = false
        layer = metalLayer
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        buildPipelines()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    func attach(item newItem: AVPlayerItem?, sourceSize size: CGSize) {
        guard newItem !== item || size != sourceSize else { return }
        if let item, let output, item.outputs.contains(output) { item.remove(output) }
        item = newItem
        sourceSize = size
        lastFrame = nil
        drawing = false
        ml = nil
        guard let newItem, size.width > 0 else { return }
        let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        o.suppressesPlayerRendering = false
        newItem.add(o)
        output = o
        prepareML(for: size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        // Video is 24–60 fps; no need to wake 120 times a second on ProMotion screens.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layout() {
        super.layout()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale, height: bounds.height * metalLayer.contentsScale)
    }

    func stop() {
        link?.invalidate(); link = nil
        attach(item: nil, sourceSize: .zero)
    }

    // MARK: ML stage setup

    private func prepareML(for size: CGSize) {
        guard #available(macOS 26.0, *) else { return }
        MLUpscaler.make(for: size) { [weak self] up in
            guard let self, self.sourceSize == size else { return }
            self.ml = up
        }
    }

    // MARK: Per frame

    @objc private func tick(_ link: CADisplayLink) {
        guard let output, metalLayer.drawableSize.width > 0 else { return }
        let t = output.itemTime(forHostTime: link.targetTimestamp)
        if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            lastFrame = pb
            render(pb)
        } else if !drawing, let pb = lastFrame {
            render(pb)
        }
    }

    private func render(_ frame: CVPixelBuffer) {
        guard let pipeline, let convertPipeline, let cache = textureCache,
              let cb = queue.makeCommandBuffer(), let drawable = metalLayer.nextDrawable() else { return }
        let start = CACurrentMediaTime()

        // 1. ML super resolution (YUV in, YUV out).
        var stage = frame
        var visible = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        var engine = "MetalFX"
        var mlLabel: String?
        if #available(macOS 26.0, *), let up = ml as? MLUpscaler, let out = up.encode(frame, into: cb) {
            stage = out
            visible = up.outputSize
            mlLabel = String(format: "ML %.1f×", up.scale)
            engine = mlLabel! + " + MetalFX"
        }

        // 2. YUV → RGB.
        let sw = CVPixelBufferGetWidthOfPlane(stage, 0), sh = CVPixelBufferGetHeightOfPlane(stage, 0)
        guard let y = texture(stage, plane: 0, format: .r8Unorm, cache: cache),
              let uv = texture(stage, plane: 1, format: .rg8Unorm, cache: cache) else { return }
        let rgb = reuse(&rgbTexture, CGSize(width: sw, height: sh), usage: [.shaderRead, .shaderWrite])
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(convertPipeline)
            enc.setTexture(y, index: 0); enc.setTexture(uv, index: 1); enc.setTexture(rgb, index: 2)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreadgroups(MTLSize(width: (sw + 15) / 16, height: (sh + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 3. MetalFX to the on-screen size.
        let fit = AVMakeRect(aspectRatio: visible, insideRect: CGRect(origin: .zero, size: metalLayer.drawableSize)).integral
        var final = rgb
        var finalSize = visible
        if fit.width > visible.width * 1.02, let s = spatialScaler(input: visible, output: fit.size) {
            let out = reuse(&scaledTexture, fit.size, usage: [.shaderRead, .renderTarget, .shaderWrite], storage: .private)
            s.colorTexture = rgb
            s.outputTexture = out
            s.inputContentWidth = Int(visible.width)
            s.inputContentHeight = Int(visible.height)
            s.encode(commandBuffer: cb)
            final = out
            finalSize = fit.size
        } else {
            engine = mlLabel ?? "—"
        }

        // 4. Draw aspect-fit.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(pipeline)
            enc.setViewport(MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1))
            enc.setFragmentTexture(final, index: 0)
            var uvScale = SIMD2<Float>(Float(finalSize.width) / Float(final.width), Float(finalSize.height) / Float(final.height))
            enc.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        cb.present(drawable)
        let label = engine
        cb.addCompletedHandler { [weak self] _ in
            let ms = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async {
                guard let self else { return }
                self.frameMs = self.frameMs == 0 ? ms : self.frameMs * 0.9 + ms * 0.1
                // Once a second: the status is @Published on the controller, and every change redraws the chrome.
                let now = CACurrentMediaTime()
                guard now - self.lastStatus > 1 else { return }
                self.lastStatus = now
                self.onStatus?(String(format: "%@ · %dx%d → %dx%d · %.1f ms", label, Int(self.sourceSize.width), Int(self.sourceSize.height),
                                      Int(fit.width), Int(fit.height), self.frameMs))
            }
        }
        cb.commit()
        drawing = true
    }

    // MARK: Helpers

    private func spatialScaler(input: CGSize, output: CGSize) -> MTLFXSpatialScaler? {
        if let scaler, scalerIn == input, scalerOut == output { return scaler }
        let d = MTLFXSpatialScalerDescriptor()
        d.inputWidth = Int(input.width); d.inputHeight = Int(input.height)
        d.outputWidth = Int(output.width); d.outputHeight = Int(output.height)
        d.colorTextureFormat = .bgra8Unorm
        d.outputTextureFormat = .bgra8Unorm
        d.colorProcessingMode = .perceptual
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device), let s = d.makeSpatialScaler(device: device) else { return nil }
        scaler = s; scalerIn = input; scalerOut = output
        return s
    }

    private func reuse(_ slot: inout MTLTexture?, _ size: CGSize, usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture {
        if let t = slot, t.width == Int(size.width), t.height == Int(size.height) { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        let t = device.makeTexture(descriptor: d)!
        slot = t
        return t
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> MTLTexture? {
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &tex)
        return tex.flatMap(CVMetalTextureGetTexture)
    }

    private func buildPipelines() {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        // BT.709 video range → R'G'B'.
        kernel void yuvToRGB(texture2d<float, access::read> y [[texture(0)]],
                             texture2d<float, access::sample> uv [[texture(1)]],
                             texture2d<float, access::write> out [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
            float2 tc = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());
            float Y = (y.read(gid).r - 16.0 / 255.0) * (255.0 / 219.0);
            float2 C = (uv.sample(s, tc).rg - 128.0 / 255.0) * (255.0 / 224.0);
            float3 rgb = float3(Y + 1.5748 * C.y, Y - 0.1873 * C.x - 0.4681 * C.y, Y + 1.8556 * C.x);
            out.write(float4(saturate(rgb), 1.0), gid);
        }
        struct V { float4 pos [[position]]; float2 uv; };
        vertex V srQuad(uint vid [[vertex_id]]) {
            float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
            V v; v.pos = float4(p, 0, 1); v.uv = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
            return v;
        }
        fragment float4 srShow(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float2 &scale [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return tex.sample(s, in.uv * scale);
        }
        """
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            convertPipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "yuvToRGB")!)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "srQuad")
            d.fragmentFunction = lib.makeFunction(name: "srShow")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            log("super res: shader build failed: \(error)")
        }
    }
}

/// VideoToolbox low-latency super-resolution for sources up to 1280 px (macOS 26+).
@available(macOS 26.0, *)
final class MLUpscaler {
    let scale: Float
    let outputSize: CGSize
    private let processor: VTFrameProcessor
    private let transfer: VTPixelTransferSession
    private let srcPool: CVPixelBufferPool
    private let dstPool: CVPixelBufferPool

    private init(scale: Float, outputSize: CGSize, processor: VTFrameProcessor, transfer: VTPixelTransferSession,
                 srcPool: CVPixelBufferPool, dstPool: CVPixelBufferPool) {
        self.scale = scale; self.outputSize = outputSize; self.processor = processor
        self.transfer = transfer; self.srcPool = srcPool; self.dstPool = dstPool
    }
    deinit { processor.endSession() }

    /// Builds the session off the main thread (model loading can take a couple of seconds) and
    /// calls back on the main thread; nothing is called back when the size isn't supported.
    static func make(for size: CGSize, ready: @escaping (MLUpscaler) -> Void) {
        let w = Int(size.width), h = Int(size.height)
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              let scale = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: w, frameHeight: h).max()
        else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let cfg = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: w, frameHeight: h, scaleFactor: scale)
            let p = VTFrameProcessor()
            do { try p.startSession(configuration: cfg) } catch {
                log("super res: ML session failed: \(error)")
                return
            }
            func pool(_ a: [String: Any]) -> CVPixelBufferPool? {
                var a = a
                a[kCVPixelBufferMetalCompatibilityKey as String] = true
                var pool: CVPixelBufferPool?
                CVPixelBufferPoolCreate(nil, nil, a as CFDictionary, &pool)
                return pool
            }
            var t: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
            guard let t, let src = pool(cfg.sourcePixelBufferAttributes), let dst = pool(cfg.destinationPixelBufferAttributes) else { return }
            let out = CGSize(width: (size.width * CGFloat(scale)).rounded(), height: (size.height * CGFloat(scale)).rounded())
            let up = MLUpscaler(scale: scale, outputSize: out, processor: p, transfer: t, srcPool: src, dstPool: dst)
            log(String(format: "super res: ML %.1f× ready (%dx%d → %dx%d)", scale, w, h, Int(out.width), Int(out.height)))
            DispatchQueue.main.async { ready(up) }
        }
    }

    /// Encodes the upscale of `frame` into `cb`; returns the (padded) output buffer.
    func encode(_ frame: CVPixelBuffer, into cb: MTLCommandBuffer) -> CVPixelBuffer? {
        var src: CVPixelBuffer?, dst: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, srcPool, &src)
        CVPixelBufferPoolCreatePixelBuffer(nil, dstPool, &dst)
        guard let src, let dst, VTPixelTransferSessionTransferImage(transfer, from: frame, to: src) == noErr else { return nil }
        let pts = CMTime(value: 0, timescale: 1)
        guard let sf = VTFrameProcessorFrame(buffer: src, presentationTimeStamp: pts),
              let df = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: pts) else { return nil }
        processor.process(with: cb, parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: sf, destinationFrame: df))
        return dst
    }
}

/// The picture: the system AVPlayerLayer, with the super-resolution layer on top when it applies.
struct PlayerPicture: View {
    @ObservedObject var controller: PlayerController
    var mode: PlayerMode = .normal
    @ObservedObject private var settings = AppSettings.shared
    @State private var srDrawing = false

    var body: some View {
        GeometryReader { g in
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let source = controller.pictureSourceSize
            let fitHeight = source.width > 0 ? min(g.size.height, g.size.width * source.height / source.width) * scale : 0
            // Only when the picture is drawn noticeably larger than the source, and not HDR.
            let wanted = settings.superResolution && source.height > 0 && fitHeight > source.height * 1.15 && !controller.isHDR
            ZStack {
                VideoLayer(player: controller.player, dynamicRange: effectiveRange).opacity(wanted && srDrawing ? 0 : 1)
                if wanted {
                    SuperResRepresentable(controller: controller, drawing: $srDrawing)
                }
            }
            .onChange(of: wanted) { _, on in if !on { srDrawing = false; controller.superResStatus = nil } }
        }
    }

    /// 自动: soft next to the interface, full when the video fills the window or screen.
    private var effectiveRange: HDRBrightness {
        switch settings.hdrBrightness {
        case .auto: return mode == .normal ? .soft : .full
        default: return settings.hdrBrightness
        }
    }
}

private struct SuperResRepresentable: NSViewRepresentable {
    @ObservedObject var controller: PlayerController
    @Binding var drawing: Bool

    func makeNSView(context: Context) -> SuperResLayerView {
        let v = SuperResLayerView()
        v.onDrawing = { on in DispatchQueue.main.async { drawing = on } }
        let c = controller
        v.onStatus = { s in c.superResStatus = s }
        v.attach(item: controller.player.currentItem, sourceSize: controller.pictureSourceSize)
        return v
    }

    func updateNSView(_ v: SuperResLayerView, context: Context) {
        v.attach(item: controller.player.currentItem, sourceSize: controller.pictureSourceSize)
    }

    static func dismantleNSView(_ v: SuperResLayerView, coordinator: ()) {
        v.stop()
    }
}
