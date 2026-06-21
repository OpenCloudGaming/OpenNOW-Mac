import AppKit
import Metal
@preconcurrency import MetalKit
import QuartzCore
import SwiftUI
import simd

struct OpenNOWStartupLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620

            ZStack {
                OpenNOWStartupMetalSurface(reduceMotion: reduceMotion)
                    .ignoresSafeArea()

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0.00),
                        .init(color: .black.opacity(0.14), location: 0.34),
                        .init(color: .black.opacity(0.10), location: 0.62),
                        .init(color: .black.opacity(0.86), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    stops: [
                        .init(color: Color.openNowGreen.opacity(0.24), location: 0.00),
                        .init(color: Color.openNowGreen.opacity(0.08), location: 0.36),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.62
                )
                .blendMode(.screen)

                VStack(spacing: compact ? 14 : 20) {
                    Spacer(minLength: compact ? 42 : 72)

                    VendorResourceImage(name: "logo", fileExtension: "png")
                        .scaledToFit()
                        .frame(width: compact ? 82 : 118, height: compact ? 82 : 118)
                        .shadow(color: Color.openNowGreen.opacity(0.52), radius: 24)

                    VStack(spacing: compact ? 8 : 10) {
                        Text("OPENNOW")
                            .font(.system(size: compact ? 25 : 36, weight: .black, design: .rounded))
                            .tracking(compact ? 7 : 11)
                            .foregroundStyle(.white)
                            .shadow(color: Color.openNowGreen.opacity(0.58), radius: 18)

                        Text("STARTING GEFORCE NOW CLIENT")
                            .font(.system(size: compact ? 10 : 12, weight: .bold))
                            .tracking(compact ? 2.2 : 3.4)
                            .foregroundStyle(.white.opacity(0.70))
                    }

                    OpenNOWStartupProgressRail(reduceMotion: reduceMotion)
                        .frame(width: compact ? 210 : 320, height: 5)
                        .padding(.top, compact ? 4 : 10)

                    Text("Preparing your cloud gaming session hub")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))
                        .padding(.top, 2)

                    Spacer(minLength: compact ? 52 : 82)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenNOW is starting")
    }
}

private struct OpenNOWStartupProgressRail: View {
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { timeline in
                let width = max(proxy.size.width, 1)
                let phase = reduceMotion ? 0.62 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.45) / 1.45
                let sweepWidth = max(width * 0.36, 88)
                let offset = (-sweepWidth) + ((width + sweepWidth * 2) * phase)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.16))
                    Capsule()
                        .fill(Color.openNowGreen.opacity(0.26))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.openNowGreen.opacity(0.62), Color.openNowGreen, Color.openNowGreen.opacity(0.62), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: sweepWidth)
                        .offset(x: offset)
                        .shadow(color: Color.openNowGreen.opacity(0.72), radius: 8)
                }
                .clipShape(Capsule())
            }
        }
    }
}

private struct OpenNOWStartupMetalSurface: NSViewRepresentable {
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = reduceMotion ? 24 : 60
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        guard let device = MTLCreateSystemDefaultDevice(), let renderer = OpenNOWStartupMetalRenderer(device: device, pixelFormat: view.colorPixelFormat, reduceMotion: reduceMotion) else {
            return view
        }

        view.device = device
        context.coordinator.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.setReduceMotion(reduceMotion)
        view.preferredFramesPerSecond = reduceMotion ? 24 : 60
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.renderer = nil
    }

    final class Coordinator {
        var renderer: OpenNOWStartupMetalRenderer?
    }
}

@MainActor
private final class OpenNOWStartupMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: any MTLCommandQueue
    private let backgroundPipeline: any MTLRenderPipelineState
    private let scenePipeline: any MTLRenderPipelineState
    private let vertexBuffer: any MTLBuffer
    private let vertexCount: Int
    private let startTime = CACurrentMediaTime()
    private var reduceMotion: Bool
    private var viewportSize = SIMD2<Float>(1, 1)

    init?(device: any MTLDevice, pixelFormat: MTLPixelFormat, reduceMotion: Bool) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let backgroundPipeline = Self.makePipeline(device: device, library: library, pixelFormat: pixelFormat, vertexName: "opn_startup_background_vertex", fragmentName: "opn_startup_background_fragment", blended: false),
              let scenePipeline = Self.makePipeline(device: device, library: library, pixelFormat: pixelFormat, vertexName: "opn_startup_scene_vertex", fragmentName: "opn_startup_scene_fragment", blended: true) else {
            return nil
        }

        let vertices = Self.makeSceneVertices()
        guard let vertexBuffer = Self.makeVertexBuffer(device: device, vertices: vertices) else { return nil }

        self.commandQueue = commandQueue
        self.backgroundPipeline = backgroundPipeline
        self.scenePipeline = scenePipeline
        self.vertexBuffer = vertexBuffer
        self.vertexCount = vertices.count
        self.reduceMotion = reduceMotion
        super.init()
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let drawableSize = view.drawableSize
        viewportSize = SIMD2<Float>(Float(max(drawableSize.width, 1)), Float(max(drawableSize.height, 1)))

        var uniforms = OpenNOWStartupMetalUniforms(
            viewportSize: viewportSize,
            time: Float(CACurrentMediaTime() - startTime),
            reduceMotion: reduceMotion ? 1 : 0,
            opacity: 1
        )

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(scenePipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OpenNOWStartupMetalUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(device: any MTLDevice, library: any MTLLibrary, pixelFormat: MTLPixelFormat, vertexName: String, fragmentName: String, blended: Bool) -> (any MTLRenderPipelineState)? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = blended
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = blended ? .one : .zero
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = blended ? .oneMinusSourceAlpha : .zero
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeVertexBuffer(device: any MTLDevice, vertices: [OpenNOWStartupMetalVertex]) -> (any MTLBuffer)? {
        vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
        }
    }

    private static func makeSceneVertices() -> [OpenNOWStartupMetalVertex] {
        var vertices: [OpenNOWStartupMetalVertex] = []
        vertices.reserveCapacity(720)

        appendRing(to: &vertices, radius: 1.08, thickness: 0.045, z: -0.08, segments: 64, phase: 0.0, color: SIMD4<Float>(0.46, 0.90, 0.10, 0.34), intensity: 1.0)
        appendRing(to: &vertices, radius: 0.77, thickness: 0.028, z: 0.04, segments: 48, phase: 1.4, color: SIMD4<Float>(0.78, 1.00, 0.42, 0.27), intensity: 0.82)
        appendRing(to: &vertices, radius: 1.38, thickness: 0.020, z: -0.22, segments: 72, phase: 2.2, color: SIMD4<Float>(0.30, 0.82, 0.12, 0.20), intensity: 0.62)

        appendPanel(to: &vertices, center: SIMD3<Float>(-0.38, 0.02, 0.00), width: 0.22, height: 0.96, yaw: -0.18, roll: -0.12, color: SIMD4<Float>(0.46, 0.90, 0.10, 0.58), intensity: 1.20, phase: 0.1)
        appendPanel(to: &vertices, center: SIMD3<Float>(0.02, 0.12, 0.08), width: 0.20, height: 0.74, yaw: 0.20, roll: 0.10, color: SIMD4<Float>(0.62, 1.00, 0.18, 0.52), intensity: 1.05, phase: 1.2)
        appendPanel(to: &vertices, center: SIMD3<Float>(0.39, -0.02, -0.02), width: 0.22, height: 0.92, yaw: 0.30, roll: 0.13, color: SIMD4<Float>(0.46, 0.90, 0.10, 0.55), intensity: 1.16, phase: 2.3)
        appendPanel(to: &vertices, center: SIMD3<Float>(0.03, 0.47, 0.12), width: 0.86, height: 0.13, yaw: 0.12, roll: 0.04, color: SIMD4<Float>(0.82, 1.00, 0.46, 0.46), intensity: 0.95, phase: 3.0)
        appendPanel(to: &vertices, center: SIMD3<Float>(0.15, -0.40, 0.02), width: 0.72, height: 0.12, yaw: -0.16, roll: -0.03, color: SIMD4<Float>(0.46, 0.90, 0.10, 0.42), intensity: 0.90, phase: 4.2)

        for index in 0..<18 {
            let progress = Float(index) / 18
            let angle = progress * .pi * 2
            let radius: Float = index.isMultiple(of: 2) ? 1.54 : 1.68
            let center = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius * 0.58, sin(angle * 1.7) * 0.28)
            let width: Float = index.isMultiple(of: 3) ? 0.22 : 0.15
            let height: Float = index.isMultiple(of: 4) ? 0.040 : 0.030
            appendPanel(to: &vertices, center: center, width: width, height: height, yaw: angle * 0.35, roll: angle + .pi / 2, color: SIMD4<Float>(0.54, 0.96, 0.18, 0.22), intensity: 0.76, phase: angle)
        }

        return vertices
    }

    private static func appendRing(to vertices: inout [OpenNOWStartupMetalVertex], radius: Float, thickness: Float, z: Float, segments: Int, phase: Float, color: SIMD4<Float>, intensity: Float) {
        for segment in 0..<segments where segment % 11 != 8 && segment % 13 != 6 {
            let start = (Float(segment) / Float(segments)) * .pi * 2
            let end = (Float(segment + 1) / Float(segments)) * .pi * 2
            let inner = radius - thickness
            let outer = radius + thickness
            let localPhase = phase + Float(segment) * 0.17

            let a = ringPoint(angle: start, radius: inner, z: z, phase: phase)
            let b = ringPoint(angle: end, radius: inner, z: z, phase: phase)
            let c = ringPoint(angle: end, radius: outer, z: z, phase: phase)
            let d = ringPoint(angle: start, radius: outer, z: z, phase: phase)
            appendQuad(to: &vertices, a: a, b: b, c: c, d: d, color: color, intensity: intensity, phase: localPhase)
        }
    }

    private static func ringPoint(angle: Float, radius: Float, z: Float, phase: Float) -> SIMD3<Float> {
        SIMD3<Float>(cos(angle) * radius, sin(angle) * radius, z + sin(angle * 3.0 + phase) * 0.045)
    }

    private static func appendPanel(to vertices: inout [OpenNOWStartupMetalVertex], center: SIMD3<Float>, width: Float, height: Float, yaw: Float, roll: Float, color: SIMD4<Float>, intensity: Float, phase: Float) {
        let rollCos = cos(roll)
        let rollSin = sin(roll)
        let yawCos = cos(yaw)
        let yawSin = sin(yaw)

        func yawed(_ vector: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(vector.x * yawCos + vector.z * yawSin, vector.y, -vector.x * yawSin + vector.z * yawCos)
        }

        let right = yawed(SIMD3<Float>(rollCos, rollSin, 0)) * (width * 0.5)
        let up = yawed(SIMD3<Float>(-rollSin, rollCos, 0)) * (height * 0.5)
        appendQuad(to: &vertices, a: center - right - up, b: center + right - up, c: center + right + up, d: center - right + up, color: color, intensity: intensity, phase: phase)
    }

    private static func appendQuad(to vertices: inout [OpenNOWStartupMetalVertex], a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, d: SIMD3<Float>, color: SIMD4<Float>, intensity: Float, phase: Float) {
        let material = SIMD2<Float>(intensity, phase)
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(a.x, a.y, a.z, phase), color: color, uv: SIMD2<Float>(0, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(b.x, b.y, b.z, phase), color: color, uv: SIMD2<Float>(1, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(c.x, c.y, c.z, phase), color: color, uv: SIMD2<Float>(1, 1), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(a.x, a.y, a.z, phase), color: color, uv: SIMD2<Float>(0, 0), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(c.x, c.y, c.z, phase), color: color, uv: SIMD2<Float>(1, 1), material: material))
        vertices.append(OpenNOWStartupMetalVertex(position: SIMD4<Float>(d.x, d.y, d.z, phase), color: color, uv: SIMD2<Float>(0, 1), material: material))
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct StartupUniforms {
    float2 viewportSize;
    float time;
    float reduceMotion;
    float opacity;
};

struct StartupVertex {
    float4 position;
    float4 color;
    float2 uv;
    float2 material;
};

struct SceneOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float2 material;
    float3 world;
};

struct BackgroundOut {
    float4 position [[position]];
    float2 uv;
};

static float opn_line(float value, float thickness) {
    float cell = abs(fract(value - 0.5) - 0.5);
    return 1.0 - smoothstep(thickness, thickness + fwidth(value) * 1.65, cell);
}

vertex BackgroundOut opn_startup_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 uvs[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
    BackgroundOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 opn_startup_background_fragment(BackgroundOut in [[stage_in]], constant StartupUniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv;
    float aspect = uniforms.viewportSize.x / max(uniforms.viewportSize.y, 1.0);
    float motion = 1.0 - uniforms.reduceMotion * 0.86;
    float t = uniforms.time * motion;
    float2 p = uv * 2.0 - 1.0;
    p.x *= aspect;

    float horizon = 0.16 + sin(t * 0.18) * 0.025;
    float depth = 1.0 / max(0.055, horizon - p.y);
    float floorMask = (1.0 - smoothstep(horizon - 0.02, horizon + 0.16, p.y)) * smoothstep(-1.05, -0.08, p.y);
    float2 gridCoordinate = float2(p.x * depth * 1.15, depth * 0.82 + t * 0.26);
    float grid = max(opn_line(gridCoordinate.x, 0.018), opn_line(gridCoordinate.y, 0.014)) * floorMask;
    float horizonGlow = exp(-abs(p.y - horizon) * 7.5);

    float centerGlow = exp(-dot(p, p) * 1.55);
    float beamMask = 1.0 - smoothstep(-0.35, 0.7, p.y);
    float leftBeam = exp(-abs(p.x + 0.72 + sin(t * 0.33) * 0.12) * 4.0) * beamMask;
    float rightBeam = exp(-abs(p.x - 0.72 + cos(t * 0.29) * 0.10) * 4.0) * beamMask;
    float scan = 0.5 + 0.5 * sin((uv.y * 68.0) - t * 7.5);

    float3 base = float3(0.002, 0.004, 0.003);
    float3 green = float3(0.46, 0.90, 0.10);
    float3 acid = float3(0.78, 1.00, 0.28);
    float3 color = base;
    color += green * centerGlow * 0.14;
    color += green * horizonGlow * 0.18;
    color += acid * grid * (0.38 + scan * 0.22);
    color += green * (leftBeam + rightBeam) * 0.028;
    color *= 1.0 - smoothstep(0.62, 1.42, length(p)) * 0.68;
    return float4(color, 1.0);
}

vertex SceneOut opn_startup_scene_vertex(const device StartupVertex *vertices [[buffer(0)]], constant StartupUniforms &uniforms [[buffer(1)]], uint vertexID [[vertex_id]]) {
    StartupVertex startupVertex = vertices[vertexID];
    float motion = 1.0 - uniforms.reduceMotion;
    float aspect = uniforms.viewportSize.x / max(uniforms.viewportSize.y, 1.0);
    float3 position = startupVertex.position.xyz;
    float phase = startupVertex.position.w;
    position.y += sin(uniforms.time * 1.7 + phase * 1.3) * 0.035 * motion;
    position.z += cos(uniforms.time * 1.25 + phase) * 0.045 * motion;

    float yaw = 0.42 + uniforms.time * 0.34 * motion;
    float pitch = -0.08 + sin(uniforms.time * 0.38) * 0.035 * motion;
    float cy = cos(yaw);
    float sy = sin(yaw);
    float cp = cos(pitch);
    float sp = sin(pitch);

    position = float3(position.x * cy + position.z * sy, position.y, -position.x * sy + position.z * cy);
    position = float3(position.x, position.y * cp - position.z * sp, position.y * sp + position.z * cp);

    float cameraDepth = position.z + 3.75;
    float perspective = 1.58 / max(cameraDepth, 1.15);
    float2 clip = position.xy * perspective;
    clip.x /= aspect;

    SceneOut out;
    out.position = float4(clip, 0.25 + cameraDepth * 0.02, 1.0);
    out.color = startupVertex.color;
    out.uv = startupVertex.uv;
    out.material = startupVertex.material;
    out.world = position;
    return out;
}

fragment float4 opn_startup_scene_fragment(SceneOut in [[stage_in]], constant StartupUniforms &uniforms [[buffer(1)]]) {
    float2 centered = abs(in.uv - 0.5) * 2.0;
    float edge = max(centered.x, centered.y);
    float rim = smoothstep(0.62, 1.0, edge);
    float core = 1.0 - smoothstep(0.10, 0.92, edge);
    float diagonal = 1.0 - smoothstep(0.012, 0.09, abs((in.uv.x - in.uv.y) + sin(in.material.y) * 0.16));
    float shimmer = 0.70 + 0.30 * sin(uniforms.time * 3.2 + in.material.y * 2.7 + in.world.z * 1.6);
    float3 green = float3(0.46, 0.90, 0.10);
    float3 acid = float3(0.82, 1.00, 0.36);
    float3 color = in.color.rgb * (0.56 + in.material.x * 0.34);
    color += acid * rim * 0.58;
    color += green * diagonal * 0.22;
    color += green * core * 0.12;
    float alpha = in.color.a * (0.36 + rim * 0.74 + core * 0.26 + diagonal * 0.20) * shimmer * uniforms.opacity;
    return float4(color, alpha);
}
"""
}

private struct OpenNOWStartupMetalUniforms {
    var viewportSize: SIMD2<Float>
    var time: Float
    var reduceMotion: Float
    var opacity: Float
}

private struct OpenNOWStartupMetalVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var uv: SIMD2<Float>
    var material: SIMD2<Float>
}
