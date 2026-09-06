import CoreVideo
import Metal
import Testing
@testable import OpenNOW
import WebRTC

/// Renders solid-colour bi-planar surfaces through the same Metal pass the stream uses and reads
/// the pixels back. Exists because an 8-bit 4:4:4 stream drew a flat green screen: the surface
/// bypassed this path and landed in WebRTC's I420 renderer, which cannot convert it. Rendering the
/// actual shader is the only check that proves colour survives; the library compiles at runtime,
/// so a successful build says nothing.
@Suite struct BiPlanarSurfaceRenderTests {
    private static let width = 64
    private static let height = 32

    /// Full-range BT.709 pure red. Chroma far from the neutral 128 on both axes, so a chroma plane
    /// read as zero (the green-screen failure) or sampled at the wrong scale cannot pass by luck.
    private static let red: (y: UInt8, cb: UInt8, cr: UInt8) = (54, 99, 255)

    private static func makeSurface(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer, "CVPixelBufferCreate failed (\(status)) for \(OPNVideoTextureSource.pixelFormatName(format))")
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
        memset(luma, Int32(red.y), CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            for column in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) {
                chroma[row * chromaStride + column * 2] = red.cb
                chroma[row * chromaStride + column * 2 + 1] = red.cr
            }
        }
        return pixelBuffer
    }

    /// The centre pixel of `surface` after the plain spatial pass, as BGRA bytes.
    @MainActor private static func renderCentrePixel(_ surface: CVPixelBuffer) throws -> (b: UInt8, g: UInt8, r: UInt8) {
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
        let renderer = OPNVideoEnhancementRenderer(device: device, commandQueue: device.makeCommandQueue())
        let settings = OPNVideoEnhancementSettings()
        settings.configuredTier = .spatial
        settings.lowCostSpatial = true
        settings.sourceSize = CGSize(width: width, height: height)
        settings.drawableSize = settings.sourceSize
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: surface), rotation: ._0, timeStampNs: 0)
        let texture = try #require(renderer.renderOffscreenSnapshot(frame, settings: settings, size: settings.sourceSize),
                                   "offscreen render failed for \(OPNVideoTextureSource.pixelFormatName(CVPixelBufferGetPixelFormatType(surface)))")
        var bgra = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bgra, bytesPerRow: 4, from: MTLRegionMake2D(width / 2, height / 2, 1, 1), mipmapLevel: 0)
        return (bgra[0], bgra[1], bgra[2])
    }

    @MainActor @Test(arguments: [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
    ])
    func solidRedSurvivesTheRenderPass(format: OSType) throws {
        let pixel = try Self.renderCentrePixel(try Self.makeSurface(format))
        let name = OPNVideoTextureSource.pixelFormatName(format)
        #expect(pixel.r > 230, "\(name) red channel \(pixel.r)")
        #expect(pixel.g < 25, "\(name) green channel \(pixel.g)")
        #expect(pixel.b < 25, "\(name) blue channel \(pixel.b)")
    }
}
