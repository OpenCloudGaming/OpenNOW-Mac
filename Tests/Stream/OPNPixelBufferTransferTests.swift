import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

struct OPNPixelBufferTransferTests {
    private func makeBuffer(_ format: OSType, width: Int = 64, height: Int = 32) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    @Test func tenBitFourFourFourBecomesNV12ForLibWebRTC() throws {
        let source = try #require(makeBuffer(kCVPixelFormatType_444YpCbCr10BiPlanarFullRange))
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        let transfer = OPNPixelBufferTransfer()
        let converted = try #require(transfer.convert(source, to: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(CVPixelBufferGetPixelFormatType(converted) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVPixelBufferGetWidth(converted) == 64)
        #expect(CVPixelBufferGetHeight(converted) == 32)
        // The colour tag rides along, so a 2020-tagged frame is not re-read as 709 downstream.
        #expect(CVBufferCopyAttachment(converted, kCVImageBufferYCbCrMatrixKey, nil) as? String == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
    }

    @Test func matchingFormatIsHandedBackUntouched() throws {
        let source = try #require(makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        let transfer = OPNPixelBufferTransfer()
        let result = try #require(transfer.convert(source, to: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(result === source)
    }

    @Test func libWebRTCReadableFormatsAreNV12AndBGRAOnly() {
        #expect(OPNPixelBufferTransfer.isLibWebRTCReadable(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(OPNPixelBufferTransfer.isLibWebRTCReadable(kCVPixelFormatType_32BGRA))
        #expect(!OPNPixelBufferTransfer.isLibWebRTCReadable(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange))
        #expect(!OPNPixelBufferTransfer.isLibWebRTCReadable(kCVPixelFormatType_444YpCbCr10BiPlanarFullRange))
    }
}
