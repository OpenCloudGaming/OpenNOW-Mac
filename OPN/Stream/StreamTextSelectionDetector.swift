//  Finding the reader's text selection in a captured frame.
//
//  A copy should copy what is selected, not the whole screen. The client only sees the game as video
//  and the seat's clipboard is not on the wire, so the one signal available is visual: a selected run
//  of text sits on a highlight — a line-shaped block of near-uniform saturated colour that stands out
//  from what surrounds it. This finds those blocks so the recognizer can read only them.
//
//  Deliberately heuristic, and deliberately generous about what it will not claim: a component that
//  is not wide, not filled, or not locally contrasting is left alone, because a false positive hides
//  every unselected line from the reader while a miss only falls back to the whole frame.
//

import CoreGraphics
import Foundation

/// A rectangle on a captured frame that looks like a selection highlight, in Vision's normalized
/// coordinates (origin bottom-left), which is the space `VNRecognizedTextObservation.boundingBox`
/// uses.
enum StreamTextSelectionDetector {
    /// The frame is downscaled before it is scanned. A highlight is a large flat block, so it survives
    /// the reduction, and the scan stays cheap enough to run inside a capture.
    static let maximumDownscaleWidth = 480
    /// At most this many highlights are read, so a frame full of coloured panels cannot turn one copy
    /// into a page of text.
    static let maximumHighlights = 8

    static func selectionRects(in image: CGImage) -> [CGRect] {
        guard image.width > 0, image.height > 0 else { return [] }
        let targetWidth = min(image.width, maximumDownscaleWidth)
        let scale = Double(targetWidth) / Double(image.width)
        let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }

        let width = targetWidth
        let height = targetHeight
        var mask = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            mask[index] = Self.isHighlightTone(data, at: index * 4)
        }

        var visited = [Bool](repeating: false, count: width * height)
        var candidates: [CGRect] = []
        for start in 0..<(width * height) where mask[start] && !visited[start] {
            guard let component = flood(data: data, mask: mask, visited: &visited, start: start, width: width, height: height) else { continue }
            guard isSelectionShaped(component, width: width, height: height) else { continue }
            guard hasLocalContrast(data: data, component: component, width: width, height: height) else { continue }
            candidates.append(normalizedRect(component, width: width, height: height))
        }
        return candidates
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .prefix(maximumHighlights)
            .map { $0 }
    }

    /// A pixel worth grouping: bright enough not to be a shadow, and carrying enough colour that a
    /// grey page cannot be mistaken for a highlight.
    private static func isHighlightTone(_ data: UnsafePointer<UInt8>, at offset: Int) -> Bool {
        let r = Int(data[offset])
        let g = Int(data[offset + 1])
        let b = Int(data[offset + 2])
        let high = max(r, max(g, b))
        let low = min(r, min(g, b))
        guard high >= 48 else { return false }
        let spread = high - low
        // A muted blue page theme (Steam's dark navy, a game's sky panel) clears a low bar and then
        // every panel on it reads as a selection. The bar is set where a genuinely coloured highlight
        // sits, not where tinted chrome does.
        guard spread >= 60 else { return false }
        return Double(spread) / Double(high) >= 0.16
    }

    private struct Component {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let pixelCount: Int
        let meanRed: Int
        let meanGreen: Int
        let meanBlue: Int
    }

    private static func flood(
        data: UnsafePointer<UInt8>,
        mask: [Bool],
        visited: inout [Bool],
        start: Int,
        width: Int,
        height: Int
    ) -> Component? {
        var stack = [start]
        visited[start] = true
        var count = 0
        var minX = width, maxX = -1, minY = height, maxY = -1
        var sumR = 0, sumG = 0, sumB = 0
        while let index = stack.popLast() {
            let x = index % width
            let y = index / width
            count += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            let offset = index * 4
            sumR += Int(data[offset]); sumG += Int(data[offset + 1]); sumB += Int(data[offset + 2])
            if x > 0, mask[index - 1], !visited[index - 1] { visited[index - 1] = true; stack.append(index - 1) }
            if x + 1 < width, mask[index + 1], !visited[index + 1] { visited[index + 1] = true; stack.append(index + 1) }
            if y > 0, mask[index - width], !visited[index - width] { visited[index - width] = true; stack.append(index - width) }
            if y + 1 < height, mask[index + width], !visited[index + width] { visited[index + width] = true; stack.append(index + width) }
        }
        guard count > 0 else { return nil }
        return Component(
            minX: minX, maxX: maxX, minY: minY, maxY: maxY,
            pixelCount: count,
            meanRed: sumR / count, meanGreen: sumG / count, meanBlue: sumB / count
        )
    }

    /// A text selection is a wide, shallow, mostly filled block. A filled panel that happens to be
    /// coloured is normally taller or squarer than a line of text, and coloured artwork is not filled
    /// enough to pass.
    private static func isSelectionShaped(_ component: Component, width: Int, height: Int) -> Bool {
        let boxWidth = component.maxX - component.minX + 1
        let boxHeight = component.maxY - component.minY + 1
        guard boxWidth >= max(4, Int(0.05 * Double(width))), boxHeight >= 3 else { return false }
        guard Double(boxWidth) / Double(boxHeight) >= 2.5 else { return false }
        let heightFraction = Double(boxHeight) / Double(height)
        guard heightFraction >= 0.012, heightFraction <= 0.45 else { return false }
        let fill = Double(component.pixelCount) / Double(boxWidth * boxHeight)
        return fill >= 0.45
    }

    /// A selection stands out from the page it sits on. Without this, a game whose whole frame is one
    /// saturated colour — a loading screen, a flat menu background — would read as an endless
    /// selection. The neighbouring strip is sampled just outside the block, and only a block that
    /// differs from it is claimed.
    private static func hasLocalContrast(
        data: UnsafePointer<UInt8>,
        component: Component,
        width: Int,
        height: Int
    ) -> Bool {
        let ring = 2
        let minX = max(0, component.minX - ring)
        let maxX = min(width - 1, component.maxX + ring)
        let minY = max(0, component.minY - ring)
        let maxY = min(height - 1, component.maxY + ring)
        var count = 0
        var sumR = 0, sumG = 0, sumB = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let inside = x >= component.minX && x <= component.maxX && y >= component.minY && y <= component.maxY
                guard !inside else { continue }
                let offset = (y * width + x) * 4
                sumR += Int(data[offset]); sumG += Int(data[offset + 1]); sumB += Int(data[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return true }
        let deltaR = component.meanRed - sumR / count
        let deltaG = component.meanGreen - sumG / count
        let deltaB = component.meanBlue - sumB / count
        let distance = (Double(deltaR * deltaR + deltaG * deltaG + deltaB * deltaB)).squareRoot()
        return distance >= 40
    }

    private static func normalizedRect(_ component: Component, width: Int, height: Int) -> CGRect {
        CGRect(
            x: Double(component.minX) / Double(width),
            y: 1 - Double(component.maxY + 1) / Double(height),
            width: Double(component.maxX - component.minX + 1) / Double(width),
            height: Double(component.maxY - component.minY + 1) / Double(height)
        )
    }
}
