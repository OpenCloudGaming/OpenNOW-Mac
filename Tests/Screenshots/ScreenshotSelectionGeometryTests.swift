import CoreGraphics
import Testing
@testable import OpenNOW

struct ScreenshotSelectionGeometryTests {
    @Test func reverseDragsMapThroughLetterboxingToSourcePixels() throws {
        let size = CGSize(width: 3840, height: 2160)
        let frame = ScreenshotSelectionGeometry.imageFrame(in: CGSize(width: 960, height: 700), imageSize: size)
        #expect(frame == CGRect(x: 0, y: 80, width: 960, height: 540))
        let selection = try #require(ScreenshotSelectionGeometry.selection(
            from: CGPoint(x: 800, y: 530), to: CGPoint(x: 200, y: 180), imageFrame: frame, imageSize: size
        ))
        #expect(selection == CGRect(x: 800, y: 400, width: 2400, height: 1400))
        #expect(ScreenshotSelectionGeometry.displayRectangle(selection, imageFrame: frame, imageSize: size)
                == CGRect(x: 200, y: 180, width: 600, height: 350))
    }

    @Test func portraitSelectionIgnoresTheBarsButClampsADragBeyondTheImage() {
        let size = CGSize(width: 600, height: 1200)
        let frame = ScreenshotSelectionGeometry.imageFrame(in: CGSize(width: 800, height: 600), imageSize: size)
        #expect(frame == CGRect(x: 250, y: 0, width: 300, height: 600))
        #expect(ScreenshotSelectionGeometry.selection(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 400, y: 400), imageFrame: frame, imageSize: size) == nil)
        #expect(ScreenshotSelectionGeometry.selection(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 900, y: 800), imageFrame: frame, imageSize: size)
                == CGRect(x: 100, y: 200, width: 500, height: 1000))
    }

    @Test func movingPreservesSizeAtEveryImageBoundary() {
        let size = CGSize(width: 100, height: 80)
        let selection = CGRect(x: 10, y: 20, width: 40, height: 30)
        #expect(ScreenshotSelectionGeometry.moved(selection, by: CGSize(width: -1000, height: -1000), imageSize: size)
                == CGRect(x: 0, y: 0, width: 40, height: 30))
        #expect(ScreenshotSelectionGeometry.moved(selection, by: CGSize(width: 1000, height: 1000), imageSize: size)
                == CGRect(x: 60, y: 50, width: 40, height: 30))
    }

    @Test(arguments: ScreenshotSelectionHandle.allCases)
    func resizingKeepsTheOppositeEdgesFixed(_ handle: ScreenshotSelectionHandle) throws {
        let selection = CGRect(x: 10, y: 20, width: 40, height: 30)
        let resized = try #require(ScreenshotSelectionGeometry.resized(selection, handle: handle, by: CGSize(width: 5, height: 4), imageSize: CGSize(width: 100, height: 80)))
        #expect(resized.minX == (handle.isLeading ? 15 : 10))
        #expect(resized.maxX == (handle.isTrailing ? 55 : 50))
        #expect(resized.minY == (handle.isTop ? 24 : 20))
        #expect(resized.maxY == (handle.isBottom ? 54 : 50))
    }

    @Test func crossedHandlesStopAtOnePixel() {
        let selection = CGRect(x: 10, y: 20, width: 40, height: 30)
        let size = CGSize(width: 100, height: 80)
        #expect(ScreenshotSelectionGeometry.resized(selection, handle: .topLeading, by: CGSize(width: 1000, height: 1000), imageSize: size)
                == CGRect(x: 49, y: 49, width: 1, height: 1))
        #expect(ScreenshotSelectionGeometry.resized(selection, handle: .bottomTrailing, by: CGSize(width: -1000, height: -1000), imageSize: size)
                == CGRect(x: 10, y: 20, width: 1, height: 1))
    }

    @Test func invalidGeometryCannotBecomeACrop() {
        let size = CGSize(width: 100, height: 80)
        #expect(ScreenshotSelectionGeometry.bounded(.zero, imageSize: size) == nil)
        #expect(ScreenshotSelectionGeometry.bounded(CGRect(x: 0, y: 0, width: 0.9, height: 5), imageSize: size) == nil)
        #expect(ScreenshotSelectionGeometry.bounded(CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), imageSize: size) == nil)
        #expect(ScreenshotSelectionGeometry.bounded(.infinite, imageSize: size) == nil)
        #expect(ScreenshotSelectionGeometry.imageFrame(in: .zero, imageSize: size) == .zero)
    }
}
