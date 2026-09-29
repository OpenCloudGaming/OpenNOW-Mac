import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

/// Region mode's arithmetic: where the frozen frame is drawn, and which rectangle of it a drag names.
struct StreamRegionCaptureGeometryTests {
    @Test func theFrameIsFittedAndCentred() {
        let fitted = StreamRegionCaptureGeometry.fittedRect(imageSize: CGSize(width: 5120, height: 2160), in: CGSize(width: 1000, height: 600))
        // 5120:2160 is wider than 1000:600, so the width is the constraint and bars sit above and below.
        #expect(fitted.width == 1000)
        #expect(abs(fitted.minX) < 0.001)
        #expect(fitted.height < 600)
        #expect(abs(fitted.midY - 300) < 0.001)
    }

    @Test func aDegenerateFrameDoesNotDivideByZero() {
        let fitted = StreamRegionCaptureGeometry.fittedRect(imageSize: .zero, in: CGSize(width: 100, height: 50))
        #expect(fitted == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    /// A drag down-right from the top-left of the picture names the top-left of the frame — Vision
    /// measures from the bottom, so the vertical axis flips exactly once.
    @Test func aDragNamesTheSameAreaInVisionsSpace() {
        let fitted = CGRect(x: 0, y: 0, width: 800, height: 450)
        let rect = StreamRegionCaptureGeometry.visionRect(
            dragStart: CGPoint(x: 80, y: 45),
            dragEnd: CGPoint(x: 400, y: 225),
            in: fitted
        )
        #expect(rect == CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.4))
    }

    @Test func aBackwardsDragNamesTheSameArea() {
        let fitted = CGRect(x: 0, y: 0, width: 800, height: 450)
        let rect = StreamRegionCaptureGeometry.visionRect(
            dragStart: CGPoint(x: 400, y: 225),
            dragEnd: CGPoint(x: 80, y: 45),
            in: fitted
        )
        #expect(rect == CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.4))
    }

    /// Dragging into the letterbox bars still reads the picture, not the bars.
    @Test func aDragPastTheFrameIsClampedToIt() {
        let fitted = CGRect(x: 100, y: 50, width: 800, height: 400)
        let rect = StreamRegionCaptureGeometry.visionRect(
            dragStart: CGPoint(x: 0, y: 0),
            dragEnd: CGPoint(x: 500, y: 250),
            in: fitted
        )
        #expect(rect == CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test func aClickIsNotARegion() {
        let fitted = CGRect(x: 0, y: 0, width: 800, height: 450)
        #expect(StreamRegionCaptureGeometry.visionRect(dragStart: CGPoint(x: 100, y: 100), dragEnd: CGPoint(x: 102, y: 101), in: fitted) == nil)
        #expect(StreamRegionCaptureGeometry.visionRect(dragStart: CGPoint(x: 100, y: 100), dragEnd: CGPoint(x: 100, y: 100), in: fitted) == nil)
    }

    @Test func aDragOutsideTheFrameIsNotARegion() {
        let fitted = CGRect(x: 100, y: 50, width: 800, height: 400)
        #expect(StreamRegionCaptureGeometry.visionRect(dragStart: CGPoint(x: 0, y: 0), dragEnd: CGPoint(x: 40, y: 30), in: fitted) == nil)
    }
}
