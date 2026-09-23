import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

struct ScreenshotEditorFixture {
    let directory: URL
    let screenshot: StreamScreenshot

    static func make(width: Int = 64, height: Int = 40) throws -> ScreenshotEditorFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotEditor-\(UUID().uuidString)", isDirectory: true)
        do {
            let pixels = (0..<height).flatMap { y in
                (0..<width).flatMap { x -> [UInt8] in
                    [UInt8(x % 256), UInt8(y % 256), 80, 255]
                }
            }
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try #require(CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ))
            let screenshot = try StreamScreenshotLibrary.save(
                StreamScreenshotImage(cgImage: image), title: "Test Capture", applicationID: "test-app",
                albumIDs: [UUID()], directory: directory
            )
            return ScreenshotEditorFixture(directory: directory, screenshot: screenshot)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

@MainActor
func selectScreenshotArea(_ rectangle: CGRect, in model: ScreenshotEditorViewModel) {
    model.beginSelectionChange()
    model.updateSelection(rectangle)
    model.endSelectionChange()
}
