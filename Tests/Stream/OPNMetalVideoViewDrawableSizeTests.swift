import AppKit
import Metal
import QuartzCore
import Testing
@testable import OpenNOW

@Suite(.serialized, .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
@MainActor struct OPNMetalVideoViewDrawableSizeTests {
    @Test func vrrStartsWithBackingSizedDrawablesWithoutAnMTKDraw() throws {
        try withVideoSurface { _, surface in
            try expectDrawableSize(CGSize(width: 1280, height: 720), on: surface)
        }
    }

    @Test(arguments: [OPNVideoPresentationMode.balanced, .smooth, .lowestLatency, .vrr])
    func backingScaleChangesReachTheLayerWithoutAnMTKDraw(mode: OPNVideoPresentationMode) throws {
        try withVideoSurface(backingScale: 1, mode: mode) { window, surface in
            for scale: CGFloat in [1, 2, 1] {
                window.simulatedBackingScale = scale
                surface.viewDidChangeBackingProperties()
                let expectedSize = CGSize(width: 640 * scale, height: 360 * scale)
                try expectDrawableSize(expectedSize, on: surface)
                if mode != .vrr {
                    surface.metalView.draw()
                    try expectDrawableSize(expectedSize, on: surface)
                }
            }
        }
    }

    @Test func resizingUpdatesDirectDrawablesInBackingPixels() throws {
        try withVideoSurface { _, surface in
            surface.frame.size = CGSize(width: 960, height: 540)
            surface.layout()
            try expectDrawableSize(CGSize(width: 1920, height: 1080), on: surface)
        }
    }

    @Test func enhancementCapsTheLayerAtTheConfiguredHeight() throws {
        try withVideoSurface(upscalingMode: 2, targetHeight: 360) { _, surface in
            try expectDrawableSize(CGSize(width: 640, height: 360), on: surface)
            surface.frame.size = CGSize(width: 1280, height: 720)
            surface.layout()
            try expectDrawableSize(CGSize(width: 640, height: 360), on: surface)
        }
    }

    @Test func layoutRepairsAStaleLayerWhenTheViewSizeIsAlreadyCorrect() throws {
        try withVideoSurface { _, surface in
            let layer = try #require(surface.metalLayer)
            let expectedSize = CGSize(width: 1280, height: 720)
            try #require(surface.metalView.drawableSize == expectedSize)
            layer.drawableSize = CGSize(width: 64, height: 36)
            surface.layout()
            try expectDrawableSize(expectedSize, on: surface)
        }
    }

    @Test func anEmptyLayoutPreservesTheLastUsableDrawableSize() throws {
        try withVideoSurface { _, surface in
            let expectedSize = CGSize(width: 1280, height: 720)
            try expectDrawableSize(expectedSize, on: surface)
            surface.frame.size = .zero
            surface.layout()
            try expectDrawableSize(expectedSize, on: surface)
        }
    }

    private func withVideoSurface(
        backingScale: CGFloat = 2,
        mode: OPNVideoPresentationMode = .vrr,
        upscalingMode: Int32 = 0,
        targetHeight: Int32 = 2160,
        _ body: (DrawableSizeTestWindow, OPNMetalVideoView) throws -> Void
    ) rethrows {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let window = DrawableSizeTestWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.simulatedBackingScale = backingScale
        let surface = OPNMetalVideoView(frame: frame, targetFps: 60)
        surface.setLocalVideoEnhancementOverride(mode: upscalingMode, sharpness: 0, denoise: 0, targetHeight: targetHeight,
                                                pillarboxFillMode: 0, pillarboxFillDim: 55, pillarboxFillColor: 0)
        surface.setPresentationMode(mode)
        surface.metalView.isPaused = true
        window.contentView = surface
        defer {
            window.contentView = nil
            surface.updateRenderThread()
            window.close()
        }
        surface.layout()
        try body(window, surface)
    }

    private func expectDrawableSize(_ expectedSize: CGSize, on surface: OPNMetalVideoView) throws {
        let layer = try #require(surface.metalLayer)
        #expect(surface.metalView.drawableSize == expectedSize)
        #expect(layer.drawableSize == expectedSize)
        guard layer.drawableSize == expectedSize else { return }
        let isTimeoutAllowed = layer.allowsNextDrawableTimeout
        layer.allowsNextDrawableTimeout = true
        defer { layer.allowsNextDrawableTimeout = isTimeoutAllowed }
        try autoreleasepool {
            let drawable = try #require(layer.nextDrawable())
            #expect(drawable.texturePixelSize == expectedSize)
        }
    }

    private final class DrawableSizeTestWindow: NSWindow {
        var simulatedBackingScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { simulatedBackingScale }
    }
}
