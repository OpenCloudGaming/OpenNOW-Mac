@preconcurrency import Accelerate
import CoreVideo
@preconcurrency import WebRTC

final class WebRTCI420BGRAConverter {
    private var ypCbCrToARGBInfo = vImage_YpCbCrToARGB()
    private var ypCbCrConversionReady = false

    func copy(_ i420: RTCI420Buffer, toBGRAOutput output: CVPixelBuffer) -> Bool {
        guard ensureYpCbCrConversionReady() else { return false }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else { return false }
        let width = min(CVPixelBufferGetWidth(output), Int(i420.width))
        let height = min(CVPixelBufferGetHeight(output), Int(i420.height))
        guard width > 0, height > 0 else { return false }
        var sourceY = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataY), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: Int(i420.strideY))
        var sourceCb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataU), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2), rowBytes: Int(i420.strideU))
        var sourceCr = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: i420.dataV), height: vImagePixelCount((height + 1) / 2), width: vImagePixelCount((width + 1) / 2), rowBytes: Int(i420.strideV))
        var destination = vImage_Buffer(data: baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(output))
        var argbMap: [UInt8] = [0, 1, 2, 3]
        let conversionStatus = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
            &sourceY,
            &sourceCb,
            &sourceCr,
            &destination,
            &ypCbCrToARGBInfo,
            &argbMap,
            255,
            vImage_Flags(kvImageNoFlags)
        )
        guard conversionStatus == kvImageNoError else { return false }
        var bgraMap: [UInt8] = [3, 2, 1, 0]
        return vImagePermuteChannels_ARGB8888(&destination, &destination, &bgraMap, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }

    private func ensureYpCbCrConversionReady() -> Bool {
        if ypCbCrConversionReady { return true }
        var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 1)
        let status = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &pixelRange,
            &ypCbCrToARGBInfo,
            kvImage420Yp8_Cb8_Cr8,
            kvImageARGB8888,
            vImage_Flags(kvImageNoFlags)
        )
        ypCbCrConversionReady = status == kvImageNoError
        return ypCbCrConversionReady
    }
}
