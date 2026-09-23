import CoreGraphics
import Foundation
import ImageIO

extension StreamScreenshotLibrary {
    static func loadImage(for screenshot: StreamScreenshot) throws -> StreamScreenshotImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(screenshot.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw StreamScreenshotLibraryError.imageReadFailed
        }
        try Task.checkCancellation()
        return StreamScreenshotImage(cgImage: image)
    }

    static func saveCroppedScreenshot(_ screenshot: StreamScreenshot, image: StreamScreenshotImage, crop: CGRect) throws -> StreamScreenshot {
        try Task.checkCancellation()
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let bounded = ScreenshotSelectionGeometry.bounded(crop, imageSize: imageSize), bounded == crop,
              let croppedImage = image.cgImage.cropping(to: bounded) else {
            throw StreamScreenshotLibraryError.invalidCrop
        }
        return try save(
            StreamScreenshotImage(cgImage: croppedImage),
            title: "\(screenshot.title) (Cropped)",
            applicationID: screenshot.applicationID,
            albumIDs: screenshot.albumIDs,
            directory: screenshot.imageURL.deletingLastPathComponent()
        )
    }
}
