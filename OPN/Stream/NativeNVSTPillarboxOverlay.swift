import AppKit
import CoreVideo
import Darwin
import Metal
import MetalKit

/// Paints the pillarbox blur fill for the native NVST path.
///
/// NVST decodes the full canvas (a 16:9 title arrives as 3840 of picture centred in
/// a 5120-wide 10-bit frame) with the black bars baked into the pixels, and Geronimo
/// renders that straight to its own layer — we cannot touch those pixels in place.
/// Instead we tap the decoded `CVPixelBuffer` (see the frame-capture hook in the
/// Geronimo shim) and paint the bar columns here, in a transparent Metal layer laid
/// over Geronimo's video. The picture region is left fully transparent so Geronimo's
/// sharp frame shows through untouched; only the bars are repainted, mirrored or
/// zoomed from the adjacent picture, exactly like the WebRTC path's fill shader.
///
/// Rendering is two passes, matching the WebRTC fill: first the picture content is
/// drawn into a tiny history texture (the massive downscale is a strong, cheap blur),
/// then the bars sample that soft history. A per-pixel blur over the full-resolution
/// frame cannot dissolve fine wall/text detail and shimmers; the downsample does.
@MainActor
final class NativeNVSTPillarboxOverlayView: MTKView, MTKViewDelegate {
    // Tiny history keeps the fill a soft ambient wash, as in the WebRTC path. The
    // downscale is the blur; this resolution reads smooth without blocky banding.
    private static let historyWidth = 96
    private static let historyHeight = 54

    private let commandQueue: (any MTLCommandQueue)?
    private var downsamplePipeline: (any MTLRenderPipelineState)?
    private var fillPipeline: (any MTLRenderPipelineState)?
    private var historyTexture: (any MTLTexture)?
    private var textureCache: CVMetalTextureCache?
    private let detector = OPNPillarboxDetector()

    // MTKView's internal display link invokes `draw(in:)` on a background render
    // thread, so everything it reads that `setFill` mutates on the main thread lives
    // in this lock-guarded snapshot. AppKit state (isHidden) must never be touched
    // from the draw callback.
    private struct RenderState {
        var active = false
        var geometryOnly = false
        var fillMode: OPNPillarboxFillMode = .black
        var fillDim: Float = 0.55
        var detectorResetPending = false
    }

    nonisolated(unsafe) private var renderStateLock = os_unfair_lock_s()
    nonisolated(unsafe) private var renderState = RenderState()
    // Fixed softening that reads clean without showing the history's texel grid.
    private static let fillSoftness: Float = 0.12

    init() {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)

        isPaused = true
        enableSetNeedsDisplay = false
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        wantsLayer = true
        delegate = self

        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            buildPipelines(device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.historyWidth, height: Self.historyHeight, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            historyTexture = device.makeTexture(descriptor: descriptor)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Reports the detected picture content rect (left/right fractions) so the host
    /// can drive the crop/stretch layer geometry. Fired only in geometry modes.
    var onContentRect: ((Double, Double) -> Void)?

    /// Selects the fill. Blur modes paint the bars here; crop/stretch run the detector
    /// only (the host scales the video layer); other modes hide the overlay entirely.
    func setFill(mode: OPNPillarboxFillMode, dim: Int) {
        let blur = mode == .blurredMirror || mode == .blurredZoom
        let geometry = mode == .cropFill || mode == .stretchEdges
        let active = blur || geometry
        os_unfair_lock_lock(&renderStateLock)
        renderState = RenderState(
            active: active,
            geometryOnly: geometry,
            fillMode: mode,
            fillDim: Float(max(0, min(100, dim))) / 100.0,
            detectorResetPending: active
        )
        os_unfair_lock_unlock(&renderStateLock)
        isHidden = !active
        isPaused = !active
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        os_unfair_lock_lock(&renderStateLock)
        let state = renderState
        let detectorResetPending = renderState.detectorResetPending
        renderState.detectorResetPending = false
        os_unfair_lock_unlock(&renderStateLock)
        if detectorResetPending { detector.reset() }

        guard state.active,
              let downsamplePipeline,
              let fillPipeline,
              let commandQueue,
              let textureCache,
              let historyTexture,
              let drawable = currentDrawable,
              let passDescriptor = currentRenderPassDescriptor,
              let pixelBufferPtr = OpenNOWNativeNVSTGeronimoCopyLatestVideoFrame() else { return }

        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(pixelBufferPtr)).takeRetainedValue()
        detector.update(with: pixelBuffer)
        let rect = detector.contentRect

        // Crop/stretch: only measure the content rect and hand it to the host, which
        // scales the video layer. Present a cleared (transparent) frame ourselves.
        if state.geometryOnly {
            // The host applies AppKit/layer geometry; deliver on the main actor.
            let contentLeft = rect.left, contentRight = rect.right
            Task { @MainActor [weak self] in
                self?.onContentRect?(contentLeft, contentRight)
            }
            if let commandBuffer = commandQueue.makeCommandBuffer(),
               let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            return
        }

        // Nothing to fill when the detector sees no bars.
        guard !rect.isFull else { return }

        // Plane containers follow the frame's bit depth, not its chroma subsampling:
        // 4:4:4 arrives as `x444`, 10 bits in the high bits of 16, exactly like the
        // `x420` 4:2:0 frames — but an 8-bit format would put one byte per sample and
        // fail texture creation against a 16-bit view. Chroma being full-resolution in
        // 4:4:4 needs no handling; both passes sample it with normalised coordinates.
        let tenBit = OPNPillarboxDetector.lumaBytesPerSample(pixelBuffer) == 2
        guard let luma = makeTexture(pixelBuffer, plane: 0, cache: textureCache, format: tenBit ? .r16Unorm : .r8Unorm),
              let chroma = makeTexture(pixelBuffer, plane: 1, cache: textureCache, format: tenBit ? .rg16Unorm : .rg8Unorm),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        var uniforms = OverlayUniforms(
            contentLeft: Float(rect.left),
            contentRight: Float(rect.right),
            mode: Float(state.fillMode.rawValue),
            dim: state.fillDim,
            softness: Self.fillSoftness,
            // Normalises either container onto the same 0...1 code scale: a 16-bit view
            // of 10-bit-high-packed samples reads code/1024, an 8-bit view reads the
            // code directly.
            sampleScale: tenBit ? 65535.0 / 64.0 / 1023.0 : 1.0
        )

        // Pass 1: downsample the picture content into the tiny history texture.
        let historyPass = MTLRenderPassDescriptor()
        historyPass.colorAttachments[0].texture = historyTexture
        historyPass.colorAttachments[0].loadAction = .dontCare
        historyPass.colorAttachments[0].storeAction = .store
        if let downEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: historyPass) {
            downEncoder.setRenderPipelineState(downsamplePipeline)
            downEncoder.setFragmentTexture(luma, index: 0)
            downEncoder.setFragmentTexture(chroma, index: 1)
            downEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            downEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            downEncoder.endEncoding()
        }

        // Pass 2: paint the bars from the soft history; leave the picture transparent.
        guard let fillEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        fillEncoder.setRenderPipelineState(fillPipeline)
        fillEncoder.setFragmentTexture(historyTexture, index: 0)
        fillEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
        fillEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        fillEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeTexture(_ pixelBuffer: CVPixelBuffer, plane: Int, cache: CVMetalTextureCache, format: MTLPixelFormat) -> (any MTLTexture)? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func buildPipelines(device: any MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return }
        let vertex = library.makeFunction(name: "opn_nvst_fill_vertex")

        let downDescriptor = MTLRenderPipelineDescriptor()
        downDescriptor.vertexFunction = vertex
        downDescriptor.fragmentFunction = library.makeFunction(name: "opn_nvst_downsample_fragment")
        downDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        downsamplePipeline = try? device.makeRenderPipelineState(descriptor: downDescriptor)

        let fillDescriptor = MTLRenderPipelineDescriptor()
        fillDescriptor.vertexFunction = vertex
        fillDescriptor.fragmentFunction = library.makeFunction(name: "opn_nvst_fill_fragment")
        fillDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        fillPipeline = try? device.makeRenderPipelineState(descriptor: fillDescriptor)
    }

    private struct OverlayUniforms {
        var contentLeft: Float
        var contentRight: Float
        var mode: Float
        var dim: Float
        var softness: Float
        var sampleScale: Float
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct Uniforms { float contentLeft; float contentRight; float mode; float dim; float softness; float sampleScale; };

    // Cubic B-spline upsample of the tiny history from four bilinear taps. C2
    // continuous and mildly smoothing, so the history magnifies into the bars as a
    // soft wash instead of showing its texel grid as squares.
    static float3 opn_history_bspline(texture2d<float> history, sampler s, float2 uv) {
        float2 size = float2((float)history.get_width(), (float)history.get_height());
        float2 coord = uv * size - 0.5;
        float2 f = fract(coord);
        float2 base = floor(coord);
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (-f3 + 3.0 * f2 - 3.0 * f + 1.0) / 6.0;
        float2 w1 = (3.0 * f3 - 6.0 * f2 + 4.0) / 6.0;
        float2 w2 = (-3.0 * f3 + 3.0 * f2 + 3.0 * f + 1.0) / 6.0;
        float2 w3 = f3 / 6.0;
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 h0 = (base - 0.5 + w1 / g0) / size;
        float2 h1 = (base + 1.5 + w3 / g1) / size;
        float3 s00 = history.sample(s, float2(h0.x, h0.y)).rgb;
        float3 s10 = history.sample(s, float2(h1.x, h0.y)).rgb;
        float3 s01 = history.sample(s, float2(h0.x, h1.y)).rgb;
        float3 s11 = history.sample(s, float2(h1.x, h1.y)).rgb;
        return mix(mix(s11, s01, g0.x), mix(s10, s00, g0.x), g0.y);
    }

    // Softness adds a round, gaussian-weighted wash of B-spline samples so higher
    // values dissolve further without a boxy kernel edge.
    static float3 opn_history_soft(texture2d<float> history, sampler s, float2 uv, float softness) {
        if (softness <= 0.001) { return opn_history_bspline(history, s, uv); }
        float r = softness * 0.22;
        float sigma = max(r * 0.6, 1e-4);
        float3 acc = float3(0.0);
        float wsum = 0.0;
        for (int i = -2; i <= 2; ++i) {
            for (int j = -2; j <= 2; ++j) {
                float2 d = float2(float(i), float(j)) * (r * 0.5);
                float w = exp(-dot(d, d) / (2.0 * sigma * sigma));
                acc += opn_history_bspline(history, s, clamp(uv + d, 0.0, 1.0)) * w;
                wsum += w;
            }
        }
        return acc / max(wsum, 1e-4);
    }

    vertex VertexOut opn_nvst_fill_vertex(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        VertexOut out;
        out.position = float4(pos[vid], 0, 1);
        out.uv = float2((pos[vid].x + 1) * 0.5, 1.0 - (pos[vid].y + 1) * 0.5);
        return out;
    }

    static float3 opn_yuv_to_rgb(texture2d<float> luma, texture2d<float> chroma, sampler s, float2 uv, float sampleScale) {
        // `sampleScale` folds the container away: 10-bit codes sit in the high bits of
        // 16 and read back as ~code/1024, 8-bit codes read back as code/255 already.
        // Both land on the same normalised scale, where video-range black is 64/1023.
        // BT.709 video-range to RGB (exactness is not needed for a blurred fill).
        float n = luma.sample(s, uv).r * sampleScale;
        float2 c = chroma.sample(s, uv).rg * sampleScale;
        float y = (n * 1023.0 - 64.0) / 876.0;
        float u = (c.x * 1023.0 - 512.0) / 896.0;
        float v = (c.y * 1023.0 - 512.0) / 896.0;
        float3 rgb = float3(y + 1.5748 * v, y - 0.1873 * u - 0.4681 * v, y + 1.8556 * u);
        return clamp(rgb, 0.0, 1.0);
    }

    // Pass 1: sample the picture content region into the tiny history. Output uv.x
    // (0..1) maps across the content columns; the huge downscale is the blur.
    fragment float4 opn_nvst_downsample_fragment(VertexOut in [[stage_in]],
                                                 texture2d<float> luma [[texture(0)]],
                                                 texture2d<float> chroma [[texture(1)]],
                                                 constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float fx = mix(u.contentLeft, u.contentRight, clamp(in.uv.x, 0.0, 1.0));
        return float4(opn_yuv_to_rgb(luma, chroma, s, float2(fx, clamp(in.uv.y, 0.0, 1.0)), u.sampleScale), 1.0);
    }

    // Pass 2: paint the bars from the soft history; picture region stays transparent.
    fragment float4 opn_nvst_fill_fragment(VertexOut in [[stage_in]],
                                           texture2d<float> history [[texture(0)]],
                                           constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float x = in.uv.x;

        // Feather the seam: keep the fill fully opaque through the bar and the content
        // edge, then fade it a little way into the picture. This covers the thin black
        // division the encoder bakes at the picture boundary and blends the two.
        float feather = 0.01;
        float outside = max(u.contentLeft - x, x - u.contentRight);
        float inside = max(0.0, -outside);
        float alpha = 1.0 - smoothstep(0.0, feather, inside);
        if (alpha <= 0.001) { return float4(0.0); }

        float span = max(u.contentRight - u.contentLeft, 1e-4);
        float c;
        if (u.mode > 2.5) {
            // Zoom: the whole picture scaled across the full width.
            c = clamp(x, 0.0, 1.0);
        } else {
            // Mirror: reflect the picture edge outward into the bar.
            c = (x - u.contentLeft) / span;
            c = c < 0.0 ? -c : (c > 1.0 ? 2.0 - c : c);
            c = clamp(c, 0.0, 1.0);
        }
        float3 rgb = opn_history_soft(history, s, float2(c, clamp(in.uv.y, 0.0, 1.0)), u.softness);

        // Dim toward the window edge so the fill reads as ambient spill.
        float distance = x < u.contentLeft ? (u.contentLeft - x) : (x - u.contentRight);
        float edgeSpan = max(x < u.contentLeft ? u.contentLeft : (1.0 - u.contentRight), 1e-4);
        float dim = mix(1.0, u.dim, clamp(distance / edgeSpan, 0.0, 1.0));
        // Premultiplied alpha: CAMetalLayer composites the overlay over Geronimo's
        // video with premultiplied blending, so the feathered edge must scale rgb by a.
        return float4(rgb * dim * alpha, alpha);
    }
    """
}
