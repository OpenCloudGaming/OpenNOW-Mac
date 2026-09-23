import CoreVideo
import Metal
import QuartzCore
import Testing
@testable import OpenNOW

/// Drives the real fill pass over a surface that carries baked-in pillarbox columns, the way a
/// 16:9-only title arrives on a wider canvas. The shader is compiled at runtime and the detector
/// latches from measured luma, so only rendering the actual pass proves the bars get filled.
@Suite struct PillarboxFillRenderTests {
    /// 128x36 with 16:9 content across the middle half: a 64x36 picture, which is exactly 16:9, so
    /// the detector's aspect snap accepts the measurement instead of rejecting it as dark picture.
    private static let width = 128
    private static let height = 36
    private static let contentColumns = 32..<(width - 32)
    private static let barLuma: UInt8 = 0
    private static let contentLuma: UInt8 = 200

    private static func makeBarredSurface() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer, "CVPixelBufferCreate failed (\(status))")
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                luma[row * lumaStride + column] = contentColumns.contains(column) ? contentLuma : barLuma
            }
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            for column in 0..<(CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) * 2) {
                chroma[row * chromaStride + column] = 128
            }
        }
        return pixelBuffer
    }

    /// Renders `surface` offscreen through the spatial pass with `fillMode` and returns the BGRA
    /// pixel at `column`.
    @MainActor private static func renderedPixel(_ surface: CVPixelBuffer, fillMode: OPNPillarboxFillMode, column: Int) throws -> (b: UInt8, g: UInt8, r: UInt8) {
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = OPNVideoEnhancementRenderer(device: device, commandQueue: device.makeCommandQueue())
        let settings = OPNVideoEnhancementSettings()
        settings.configuredTier = .spatial
        settings.lowCostSpatial = true
        settings.pillarboxFillMode = Int(fillMode.rawValue)
        settings.pillarboxFillDim = 0
        settings.sourceSize = CGSize(width: width, height: height)
        settings.drawableSize = settings.sourceSize
        let texture = try #require(renderer.renderOffscreenSnapshot(OPNVideoFrame(pixelBuffer: surface), settings: settings, size: settings.sourceSize),
                                   "offscreen render failed")
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(column, height / 2, 1, 1), mipmapLevel: 0)
        return (bgra[0], bgra[1], bgra[2])
    }

    /// The detector must actually latch a bar rect for these fills to mean anything; without that
    /// every mode silently draws the encoded bars.
    @Test func theDetectorLatchesTheBakedBarsAt16by9() throws {
        let detector = OPNPillarboxDetector()
        let surface = try Self.makeBarredSurface()
        let now = CACurrentMediaTime()
        for step in 0..<6 { detector.update(with: surface, now: now + Double(step) * 0.3) }
        #expect(!detector.contentRect.isFull, "detector never latched the bars")
        #expect(abs(detector.contentRect.left - 0.25) < 0.01, "left edge \(detector.contentRect.left)")
        #expect(abs(detector.contentRect.right - 0.75) < 0.01, "right edge \(detector.contentRect.right)")
    }

    @MainActor @Test func theBlackModeLeavesTheBakedBarsAlone() throws {
        let pixel = try Self.renderedPixel(try Self.makeBarredSurface(), fillMode: .black, column: 2)
        #expect(Int(pixel.r) + Int(pixel.g) + Int(pixel.b) < 40, "black mode must not paint the bars")
    }

    @MainActor @Test func blurMirrorSpillsPictureIntoTheBakedBars() throws {
        let black = try Self.renderedPixel(try Self.makeBarredSurface(), fillMode: .black, column: 2)
        let filled = try Self.renderedPixel(try Self.makeBarredSurface(), fillMode: .blurredMirror, column: 2)
        #expect(Int(filled.r) + Int(filled.g) + Int(filled.b) > Int(black.r) + Int(black.g) + Int(black.b) + 30,
                "blur mirror left the bar black")
    }

    @MainActor @Test func cropFillRemovesTheBarsFromTheEdges() throws {
        let black = try Self.renderedPixel(try Self.makeBarredSurface(), fillMode: .black, column: 2)
        let filled = try Self.renderedPixel(try Self.makeBarredSurface(), fillMode: .cropFill, column: 2)
        #expect(Int(filled.r) + Int(filled.g) + Int(filled.b) > Int(black.r) + Int(black.g) + Int(black.b) + 30,
                "crop fill left the bar black")
    }

    /// A fill is reprojected against the texture the shader writes into, which the upscaler's
    /// source-sized staging is not; a selected fill therefore takes the spatial pass, and black —
    /// which has nothing to composite — leaves the upscaler alone.
    @Test @MainActor func aSelectedFillDisplacesTheUpscalerAndBlackKeepsIt() {
        for mode in OPNPillarboxFillMode.allCases {
            #expect(OPNVideoEnhancementRenderer.fillTakesSpatialPass(fillMode: mode) == (mode != .black),
                    "\(mode.label) must \(mode == .black ? "keep" : "displace") the upscaler")
        }
    }
}
