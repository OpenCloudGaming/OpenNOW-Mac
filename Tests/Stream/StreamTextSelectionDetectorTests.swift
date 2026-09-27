import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

/// The selection detector on synthetic frames: a flat highlight can be asserted exactly, which is
/// what the heuristic needs beside the OCR end-to-end path.
struct StreamTextSelectionDetectorTests {
    private func makeImage(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let unwrapped = context!
        unwrapped.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        unwrapped.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(unwrapped)
        return unwrapped.makeImage()!
    }

    private func fill(_ context: CGContext, _ rect: CGRect, red: CGFloat, green: CGFloat, blue: CGFloat) {
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(rect)
    }

    private func close(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.04) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    @Test func aHighlightedLineIsFoundWhereItWasDrawn() {
        let image = makeImage(width: 400, height: 200) { context in
            fill(context, CGRect(x: 40, y: 60, width: 240, height: 30), red: 0.16, green: 0.38, blue: 0.85)
        }
        let rects = StreamTextSelectionDetector.selectionRects(in: image)
        #expect(rects.count == 1)
        let rect = rects.first!
        #expect(close(rect.minX, 0.1))
        #expect(close(rect.width, 0.6))
        #expect(close(rect.minY, 0.3))
        #expect(close(rect.height, 0.15))
    }

    @Test func twoSeparateHighlightsAreBothFound() {
        let image = makeImage(width: 400, height: 200) { context in
            fill(context, CGRect(x: 40, y: 130, width: 240, height: 26), red: 0.16, green: 0.38, blue: 0.85)
            fill(context, CGRect(x: 40, y: 40, width: 160, height: 26), red: 0.16, green: 0.38, blue: 0.85)
        }
        let rects = StreamTextSelectionDetector.selectionRects(in: image)
        #expect(rects.count == 2)
        #expect(rects.allSatisfy { $0.height > 0.1 })
    }

    @Test func aPlainFrameHasNoSelection() {
        let image = makeImage(width: 400, height: 200) { _ in }
        #expect(StreamTextSelectionDetector.selectionRects(in: image).isEmpty)
    }

    @Test func aFlatColouredFrameIsNotOneGiantSelection() {
        let image = makeImage(width: 400, height: 200) { context in
            fill(context, CGRect(x: 0, y: 0, width: 400, height: 200), red: 0.16, green: 0.38, blue: 0.85)
        }
        #expect(StreamTextSelectionDetector.selectionRects(in: image).isEmpty)
    }

    @Test func aThinColouredLineIsNotASelection() {
        let image = makeImage(width: 400, height: 200) { context in
            fill(context, CGRect(x: 40, y: 80, width: 240, height: 2), red: 0.16, green: 0.38, blue: 0.85)
        }
        #expect(StreamTextSelectionDetector.selectionRects(in: image).isEmpty)
    }

    @Test func aSelectionWithBlackTextOnItIsStillOneBlock() {
        let image = makeImage(width: 400, height: 200) { context in
            fill(context, CGRect(x: 40, y: 60, width: 240, height: 30), red: 0.16, green: 0.38, blue: 0.85)
            fill(context, CGRect(x: 50, y: 68, width: 120, height: 14), red: 0, green: 0, blue: 0)
        }
        let rects = StreamTextSelectionDetector.selectionRects(in: image)
        #expect(rects.count == 1)
    }
}
