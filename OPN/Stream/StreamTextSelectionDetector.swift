//  Finding the reader's text selection in a captured frame, by colour and shape alone.
//

import CoreGraphics
import Foundation

/// Finds a selection highlight — a line-shaped block of saturated colour that stands out from what
/// surrounds it — and returns it in Vision's normalized space (origin bottom-left).
enum StreamTextSelectionDetector {
    /// Scan width. A 5120-wide stream squashes a text line to two pixels at 480, where rounding alone
    /// decides; 640 keeps a plausible line resolvable on the widest frames the client streams.
    static let maximumDownscaleWidth = 640
    /// At most this many highlights are read, so a frame full of coloured panels cannot flood a copy.
    static let maximumHighlights = 8

    static func selectionRects(in image: CGImage) -> [CGRect] {
        guard image.width > 0, image.height > 0 else { return [] }
        let scanWidth = min(image.width, maximumDownscaleWidth)
        let scale = Double(scanWidth) / Double(image.width)
        let scanHeight = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = makeScanContext(width: scanWidth, height: scanHeight) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: scanWidth, height: scanHeight))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }

        var highlightMask = [Bool](repeating: false, count: scanWidth * scanHeight)
        for index in 0..<(scanWidth * scanHeight) {
            highlightMask[index] = isHighlightTone(pixels, at: index * 4)
        }

        var visited = [Bool](repeating: false, count: scanWidth * scanHeight)
        var highlightRects: [CGRect] = []
        for index in 0..<(scanWidth * scanHeight) where highlightMask[index] && !visited[index] {
            guard let block = collectBlock(pixels: pixels, mask: highlightMask, visited: &visited, start: index, width: scanWidth, height: scanHeight) else { continue }
            guard isSelectionShaped(block, width: scanWidth, height: scanHeight) else { continue }
            guard hasLocalContrast(pixels: pixels, block: block, width: scanWidth, height: scanHeight) else { continue }
            highlightRects.append(normalizedRect(block, width: scanWidth, height: scanHeight))
        }
        return Array(highlightRects.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(maximumHighlights))
    }

    private static func makeScanContext(width: Int, height: Int) -> CGContext? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .low
        return context
    }

    /// A pixel worth grouping: bright enough not to be shadow, and coloured enough not to be grey.
    private static func isHighlightTone(_ pixels: UnsafePointer<UInt8>, at offset: Int) -> Bool {
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        let brightest = max(red, max(green, blue))
        let darkest = min(red, min(green, blue))
        guard brightest >= 48 else { return false }
        let spread = brightest - darkest
        // A muted themed page clears a low bar and then every panel on it reads as a selection.
        guard spread >= 60 else { return false }
        return Double(spread) / Double(brightest) >= 0.16
    }

    private struct HighlightBlock {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let pixelCount: Int
        let meanRed: Int
        let meanGreen: Int
        let meanBlue: Int
    }

    /// Walks one connected run of highlight-coloured pixels and measures it.
    private static func collectBlock(
        pixels: UnsafePointer<UInt8>,
        mask: [Bool],
        visited: inout [Bool],
        start: Int,
        width: Int,
        height: Int
    ) -> HighlightBlock? {
        var pendingIndices = [start]
        visited[start] = true
        var pixelCount = 0
        var minX = width, maxX = -1, minY = height, maxY = -1
        var sumRed = 0, sumGreen = 0, sumBlue = 0
        while let index = pendingIndices.popLast() {
            let x = index % width
            let y = index / width
            pixelCount += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            let offset = index * 4
            sumRed += Int(pixels[offset]); sumGreen += Int(pixels[offset + 1]); sumBlue += Int(pixels[offset + 2])
            appendNeighbours(of: index, mask: mask, visited: &visited, pendingIndices: &pendingIndices, width: width, height: height)
        }
        guard pixelCount > 0 else { return nil }
        return HighlightBlock(
            minX: minX, maxX: maxX, minY: minY, maxY: maxY,
            pixelCount: pixelCount,
            meanRed: sumRed / pixelCount, meanGreen: sumGreen / pixelCount, meanBlue: sumBlue / pixelCount
        )
    }

    private static func appendNeighbours(
        of index: Int,
        mask: [Bool],
        visited: inout [Bool],
        pendingIndices: inout [Int],
        width: Int,
        height: Int
    ) {
        let x = index % width
        let y = index / width
        if x > 0, mask[index - 1], !visited[index - 1] { visited[index - 1] = true; pendingIndices.append(index - 1) }
        if x + 1 < width, mask[index + 1], !visited[index + 1] { visited[index + 1] = true; pendingIndices.append(index + 1) }
        if y > 0, mask[index - width], !visited[index - width] { visited[index - width] = true; pendingIndices.append(index - width) }
        if y + 1 < height, mask[index + width], !visited[index + width] { visited[index + width] = true; pendingIndices.append(index + width) }
    }

    /// A selection is a wide, shallow, mostly filled block; artwork is not filled enough to pass.
    private static func isSelectionShaped(_ block: HighlightBlock, width: Int, height: Int) -> Bool {
        let blockWidth = block.maxX - block.minX + 1
        let blockHeight = block.maxY - block.minY + 1
        // The floor only drops specks: a short word is a small share of a wide frame.
        guard blockWidth >= max(4, Int(0.012 * Double(width))), blockHeight >= 3 else { return false }
        guard Double(blockWidth) / Double(blockHeight) >= 2.5 else { return false }
        let heightFraction = Double(blockHeight) / Double(height)
        guard heightFraction >= 0.012, heightFraction <= 0.45 else { return false }
        return Double(block.pixelCount) / Double(blockWidth * blockHeight) >= 0.45
    }

    /// Only a block that differs from the strip just outside it is claimed, so a frame painted one
    /// saturated colour does not read as one endless selection.
    private static func hasLocalContrast(
        pixels: UnsafePointer<UInt8>,
        block: HighlightBlock,
        width: Int,
        height: Int
    ) -> Bool {
        let ring = 2
        let ringMinX = max(0, block.minX - ring)
        let ringMaxX = min(width - 1, block.maxX + ring)
        let ringMinY = max(0, block.minY - ring)
        let ringMaxY = min(height - 1, block.maxY + ring)
        var ringPixelCount = 0
        var sumRed = 0, sumGreen = 0, sumBlue = 0
        for y in ringMinY...ringMaxY {
            for x in ringMinX...ringMaxX {
                guard isOutside(x: x, y: y, block: block) else { continue }
                let offset = (y * width + x) * 4
                sumRed += Int(pixels[offset]); sumGreen += Int(pixels[offset + 1]); sumBlue += Int(pixels[offset + 2])
                ringPixelCount += 1
            }
        }
        guard ringPixelCount > 0 else { return true }
        let deltaRed = block.meanRed - sumRed / ringPixelCount
        let deltaGreen = block.meanGreen - sumGreen / ringPixelCount
        let deltaBlue = block.meanBlue - sumBlue / ringPixelCount
        let colourDistance = Double(deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue).squareRoot()
        return colourDistance >= 40
    }

    private static func isOutside(x: Int, y: Int, block: HighlightBlock) -> Bool {
        x < block.minX || x > block.maxX || y < block.minY || y > block.maxY
    }

    private static func normalizedRect(_ block: HighlightBlock, width: Int, height: Int) -> CGRect {
        CGRect(
            x: Double(block.minX) / Double(width),
            y: 1 - Double(block.maxY + 1) / Double(height),
            width: Double(block.maxX - block.minX + 1) / Double(width),
            height: Double(block.maxY - block.minY + 1) / Double(height)
        )
    }
}
