import AppKit
import Testing
@testable import OpenNOW

/// Picture-in-Picture is a mode of the dedicated stream window, so most of what can go wrong is
/// window-server state rather than view state. These tests split the two: the pure decisions run
/// everywhere, and the ones that need a real window are gated the same way the other AppKit tests
/// are.
@MainActor
struct OPNStreamPictureInPictureTests {

    // MARK: - Aspect sizing

    /// `StreamStageLayout.contentSize` is already pure, and PiP is that function with a zero titlebar
    /// strip. The point of reusing it is that the small window keeps the stream's aspect ratio.
    @Test func pictureInPictureKeepsTheStreamAspectRatio() {
        for aspectRatio in [16.0 / 9.0, 4.0 / 3.0, 21.0 / 9.0, 1.0] as [CGFloat] {
            let size = OPNStreamPictureInPicture.contentSize(aspectRatio: aspectRatio)
            #expect(abs(size.width / size.height - aspectRatio) < 0.001, "\(aspectRatio) did not hold")
            #expect(size.width <= OPNStreamPictureInPicture.box.width + 0.001)
            #expect(size.height <= OPNStreamPictureInPicture.box.height + 0.001)
        }
    }

    /// 16:9 is the ordinary case and the one the HUD's dock width was measured against: at 320pt
    /// wide the dock (`min(344, max(268, width * 0.72))`) is 268pt, most of the window, which is why
    /// PiP suppresses it rather than scaling it.
    @Test func aSixteenByNinePictureIsThreeHundredAndTwentyWide() {
        let size = OPNStreamPictureInPicture.contentSize(aspectRatio: 16.0 / 9.0)
        #expect(abs(size.width - 320) < 0.001)
        #expect(abs(size.height - 180) < 0.001)
        #expect(StreamHUDTheme.dockWidth(for: size.width) == 268)
    }

    @Test func pictureInPictureSitsInTheBottomTrailingCornerOfTheVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let size = CGSize(width: 320, height: 180)
        let frame = OPNStreamPictureInPicture.frame(contentSize: size, visibleFrame: visibleFrame)
        #expect(abs(frame.maxX - (visibleFrame.maxX - OPNStreamPictureInPicture.margin)) < 0.001)
        #expect(abs(frame.minY - (visibleFrame.minY + OPNStreamPictureInPicture.margin)) < 0.001)
        #expect(frame.size == size)
    }

    /// A visible frame narrower than the margin pair must clamp rather than place the window off
    /// screen, the same way the full-screen geometry helpers already clamp.
    @Test func pictureInPictureStaysOnScreenInATinyVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 200, height: 120)
        let size = CGSize(width: 320, height: 180)
        let frame = OPNStreamPictureInPicture.frame(contentSize: size, visibleFrame: visibleFrame)
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.minY >= visibleFrame.minY)
    }

    // MARK: - Request routing

    /// The full-screen interaction the issue bakes in: pressing the tile while full screen leaves
    /// full screen, then enters PiP - one action for one user intent.
    @Test func theTileSequencesFullScreenBeforePictureInPicture() {
        #expect(OPNStreamPictureInPicture.request(isPictureInPicture: false, isFullScreen: true, isFullScreenTransitioning: false) == .leaveFullScreenThenEnter)
        #expect(OPNStreamPictureInPicture.request(isPictureInPicture: false, isFullScreen: false, isFullScreenTransitioning: true) == .leaveFullScreenThenEnter)
        #expect(OPNStreamPictureInPicture.request(isPictureInPicture: false, isFullScreen: false, isFullScreenTransitioning: false) == .enter)
    }

    @Test func theTileLeavesPictureInPictureFromPictureInPicture() {
        #expect(OPNStreamPictureInPicture.request(isPictureInPicture: true, isFullScreen: false, isFullScreenTransitioning: false) == .leave)
        #expect(OPNStreamPictureInPicture.request(isPictureInPicture: true, isFullScreen: true, isFullScreenTransitioning: false) == .leave)
    }

    // MARK: - Close-button contract

    /// Always prompts when there is a session, never shows a dialog when there is not.
    @Test func theCloseButtonPromptsForALiveSessionOnly() {
        #expect(OPNStreamWindowPresenter.closeDecision(isConnected: true) == .prompt)
        #expect(OPNStreamWindowPresenter.closeDecision(isConnected: false) == .cancelLaunchAndDismiss)
        #expect(OPNStreamWindowPresenter.closeDecision(isConnected: nil) == .cancelLaunchAndDismiss)
    }

    // MARK: - Capability gate

    /// The gate exists so PiP can be switched off if one render path cannot survive the mode change;
    /// a feature that ships disabled silently is worse than one that is off on purpose.
    @Test func pictureInPictureIsSupportedByTheNativeTransport() {
        #expect(StreamSidebarCapabilities.nativeNVST.supports(.pictureInPicture))
        #expect(StreamSidebarCapabilities.nativeNVST.visibleFeatures == StreamSidebarFeature.allCases)
    }

    /// A missing SF Symbol renders a blank tile rather than failing to compile, so the glyph is
    /// asserted rather than assumed. `pip` is documented as SF Symbols 2 / macOS 11+, below the
    /// 15.6 deployment target; this asserts the name resolves on the running system, which is what
    /// catches a typo.
    @Test func thePictureInPictureGlyphResolves() {
        #expect(NSImage(systemSymbolName: "pip", accessibilityDescription: nil) != nil)
    }

    // MARK: - Dock accounting

    /// A borderless window is invisible to `OPNDockIconController`, and with a dedicated stream
    /// window it can now be the only window on screen. It is titled precisely so the arithmetic that
    /// used to belong to the catalog window alone keeps working.
    @Test func theStreamWindowCountsTowardsTheDockIcon() {
        #expect(OPNDockIconController.countsAsAppWindow(styleMask: OPNStreamWindowFactory.styleMask))
        #expect(!OPNDockIconController.shouldHideDockIcon(
            behavior: .menuBarOnly,
            showsStatusItem: true,
            hasVisibleAppWindow: true
        ))
    }

    // MARK: - Window mode change

    /// The mode change on a real window: same window, shrunk, floated, joined to every Space, and
    /// non-activating - then put back exactly as it was.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func pictureInPictureIsAModeOfTheSameWindow() {
        let window = OPNStreamWindowFactory.make()
        let originalFrame = window.frame
        defer { window.close() }

        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.canBecomeKey)

        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        #expect(window.isPictureInPicture)
        #expect(window.windowedState != nil)
        #expect(window.level == .floating)
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        // Windowed-only: PiP never floats over full-screen apps.
        #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))
        // A viewing surface, so clicking it neither activates the app nor takes focus.
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(abs(window.frame.width / window.frame.height - 16.0 / 9.0) < 0.001)

        OPNStreamPictureInPicture.exit(window)
        #expect(!window.isPictureInPicture)
        #expect(window.windowedState == nil)
        #expect(window.canBecomeKey)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(abs(window.frame.width - originalFrame.width) < 0.001)
        #expect(abs(window.frame.height - originalFrame.height) < 0.001)
    }

    /// The sharpest risk in the issue. `NativeStreamView`'s borderless carrier is a child window, and
    /// AppKit rewrites a child's `collectionBehavior` to `.ignoresCycle` on attach - dropping
    /// `.canJoinAllSpaces`. A carrier left that way is pinned to the Space it was created on while the
    /// picture floats across every Space. Live-measured on macOS 27.0; this pins the re-application.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func theCarrierChildWindowFollowsTheParentIntoEverySpace() {
        let window = OPNStreamWindowFactory.make()
        defer { window.close() }
        let carrier = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        carrier.alphaValue = 0
        carrier.ignoresMouseEvents = true
        window.addChildWindow(carrier, ordered: .above)
        // What AppKit leaves behind: not `.canJoinAllSpaces`.
        #expect(!carrier.collectionBehavior.contains(.canJoinAllSpaces))

        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        #expect(carrier.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(carrier.level.rawValue >= window.level.rawValue)

        OPNStreamPictureInPicture.exit(window)
        #expect(!carrier.collectionBehavior.contains(.canJoinAllSpaces))
        // Only the one flag is ever touched: the carrier keeps the `.ignoresCycle` AppKit gave it,
        // and never picks up the parent's `.fullScreenPrimary`.
        #expect(carrier.collectionBehavior.contains(.ignoresCycle))
        #expect(!carrier.collectionBehavior.contains(.fullScreenPrimary))
    }
}
