import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite(.serialized, .streamLifecycleExclusive,
       .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
struct StreamWindowLayoutMembershipTests {
    @Test func draggingOneOfTwoTilesKeepsTheReadersPlacementAndReleasesTheSurvivor() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let moved = fixture.windows[0]
        let survivor = fixture.windows[1]
        #expect(moved.layoutState.isAutoTiled && survivor.layoutState.isAutoTiled)

        moved.setFrame(moved.frame.offsetBy(dx: 28, dy: 32), display: true)
        let readerFrame = moved.frame
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        #expect(moved.frame == readerFrame)
        #expect(moved.layoutState.isManuallyPlaced && !moved.layoutState.isAutoTiled)
        #expect(!moved.layoutState.isBorderless && moved.level == .normal)
        #expect(moved.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(survivor.frame == fixture.originalFrames[1])
        #expect(!survivor.layoutState.isAutoTiled && !survivor.layoutState.isBorderless)
        #expect(!survivor.layoutState.isManuallyPlaced && survivor.level == .normal)
        #expect(!moved.hasPendingLayoutChange && !survivor.hasPendingLayoutChange)
    }

    @Test func resizingOneOfThreeTilesRetilesOnlyTheSurvivorsWithoutAProgrammaticFeedbackLoop() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 3)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let resized = fixture.windows[0]
        let survivors = Array(fixture.windows.dropFirst())
        var changes = 0
        let center = NotificationCenter.default
        let tokens = survivors.flatMap { window in
            [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                center.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { changes += 1 }
                }
            }
        }
        defer { for token in tokens { center.removeObserver(token) } }
        var readerFrame = resized.frame
        readerFrame.size.height -= 60
        resized.setFrame(readerFrame, display: true)
        readerFrame = resized.frame
        await settleStreamWindowChanges()
        let settledChanges = changes
        let expected = fixture.expectedTiles(count: 2)
        await settleStreamWindowChanges()

        #expect(resized.frame == readerFrame && resized.layoutState.isManuallyPlaced)
        #expect(!resized.layoutState.isAutoTiled && resized.level == .normal)
        #expect(survivors.map(\.frame) == expected)
        #expect(survivors.allSatisfy { $0.layoutState.isAutoTiled && !$0.layoutState.isManuallyPlaced })
        #expect(survivors.allSatisfy { $0.level == OPNStreamBorderless.coveringLevel && !$0.hasPendingLayoutChange })
        #expect(changes == settledChanges)
    }

    @Test func enteringPictureInPictureNotifiesTheOwningPresenterBeforeQueuedRestorationLands() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let picture = fixture.windows[0]
        let survivor = fixture.windows[1]
        OPNStreamPictureInPicture.enter(picture, aspectRatio: 16.0 / 9.0)
        await settleStreamWindowChanges()

        #expect(picture.isPictureInPicture && picture.frame.size == NSSize(width: 640, height: 360))
        #expect(picture.windowedState?.frame == fixture.originalFrames[0])
        #expect(survivor.frame == fixture.originalFrames[1])
        #expect(!survivor.layoutState.isAutoTiled && !survivor.layoutState.isBorderless)
        #expect(survivor.level == .normal)
        OPNStreamPictureInPicture.exit(picture)
        await settleStreamWindowChanges()

        #expect(picture.frame == fixture.originalFrames[0])
        #expect(picture.layoutState.isManuallyPlaced && !picture.layoutState.isAutoTiled)
        #expect(survivor.frame == fixture.originalFrames[1] && !survivor.layoutState.isAutoTiled)
    }

    @Test func theReadersBorderlessToggleReleasesTheOtherTileThroughItsOwner() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let window = fixture.windows[0]
        let survivor = fixture.windows[1]
        OPNStreamBorderless.toggleByReader(window)
        await settleStreamWindowChanges()

        #expect(window.frame == fixture.originalFrames[0] && window.layoutState.isManuallyPlaced)
        #expect(survivor.frame == fixture.originalFrames[1])
        #expect(!survivor.layoutState.isAutoTiled && survivor.level == .normal)
        OPNStreamBorderless.toggleByReader(window)
        await settleStreamWindowChanges()

        #expect(window.layoutState.isBorderless && !window.layoutState.isAutoTiled)
        #expect(window.frame == OPNStreamBorderless.targetFrame(for: window))
        #expect(survivor.frame == fixture.originalFrames[1] && !survivor.layoutState.isAutoTiled)
    }

    @Test func nativeFullScreenNotificationsReleaseSurvivorsWithoutRestoringOverTheTransition() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let transitioning = fixture.windows[0]
        let tileFrame = transitioning.frame
        let survivor = fixture.windows[1]
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: transitioning)
        fixture.presenter.retileWindows()
        await settleStreamWindowChanges()

        #expect(transitioning.frame == tileFrame)
        #expect(transitioning.layoutState.isManuallyPlaced && !transitioning.hasPendingLayoutChange)
        #expect(!transitioning.layoutState.isBorderless && !transitioning.layoutState.isAutoTiled)
        #expect(survivor.frame == fixture.originalFrames[1] && survivor.level == .normal)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: transitioning)
        center.post(name: NSWindow.willExitFullScreenNotification, object: transitioning)
        center.post(name: NSWindow.didExitFullScreenNotification, object: transitioning)
        await settleStreamWindowChanges()

        #expect(transitioning.frame == tileFrame && !transitioning.layoutState.isAutoTiled)
        #expect(survivor.frame == fixture.originalFrames[1] && !survivor.layoutState.isAutoTiled)
    }

    @Test func minimizingATileDoesNotBringItBackWhenTheSurvivorIsReleased() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let minimized = fixture.windows[0]
        minimized.miniaturize(nil)
        await settleStreamWindowChanges()
        fixture.presenter.retileWindows()
        await settleStreamWindowChanges()

        #expect(minimized.isMiniaturized)
        #expect(minimized.layoutState.isManuallyPlaced && !minimized.layoutState.isAutoTiled)
        #expect(fixture.windows[1].frame == fixture.originalFrames[1])
        #expect(!fixture.windows[1].layoutState.isAutoTiled && fixture.windows[1].level == .normal)
        minimized.deminiaturize(nil)
        await settleStreamWindowChanges()
        #expect(!minimized.layoutState.isAutoTiled && !fixture.windows[1].layoutState.isAutoTiled)
    }

    @Test func coverageAndOrientationChangesRemainProgrammaticPlacements() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 3)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        fixture.presenter.setTileCoverage(.visibleArea)
        OPNStreamTileOrientation.store(.topAndBottom)
        fixture.presenter.retileWindows()
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        #expect(fixture.windows.map(\.frame) == fixture.expectedTiles(count: 3))
        #expect(fixture.windows.allSatisfy { $0.layoutState.isAutoTiled && !$0.layoutState.isManuallyPlaced })
        #expect(fixture.windows.allSatisfy { $0.level == .normal && !$0.hasPendingLayoutChange })
    }

    @Test func flagOffLeavesOrdinaryWindowsUntiledAcrossPlacementAndModeChanges() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2, isCouchCoopEnabled: false)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let moved = fixture.windows[0]
        moved.setFrame(moved.frame.offsetBy(dx: 20, dy: 0), display: true)
        let readerFrame = moved.frame
        OPNStreamPictureInPicture.enter(fixture.windows[1], aspectRatio: 16.0 / 9.0)
        await settleStreamWindowChanges()
        OPNStreamPictureInPicture.exit(fixture.windows[1])
        await settleStreamWindowChanges()

        #expect(moved.frame == readerFrame)
        #expect(fixture.windows[1].frame == fixture.originalFrames[1])
        #expect(fixture.windows.allSatisfy { !$0.layoutState.isAutoTiled && !$0.layoutState.isBorderless })
        #expect(fixture.windows.allSatisfy { $0.level == .normal })
    }

    @Test func dismissingDuringDeferredPictureInPictureCancelsItsGeometryAndReleasesTheSurvivor() async throws {
        let fixture = try StreamWindowLayoutFixture(count: 2)
        defer { fixture.close() }
        await settleStreamWindowChanges()
        let ending = fixture.windows[0]
        fixture.fixtures[0].geometryView.isResizeHeld = true
        OPNStreamPictureInPicture.enter(ending, aspectRatio: 16.0 / 9.0)
        fixture.presenter.dismiss(fixture.sessions[0])
        fixture.fixtures[0].geometryView.isResizeHeld = false
        await settleStreamWindowChanges()

        #expect(fixture.presenter.windows[fixture.sessions[0]] == nil)
        #expect(!ending.isVisible && ending.contentView == nil)
        #expect(!ending.isPictureInPicture && !ending.isPictureInPicturePending && !ending.hasPendingLayoutChange)
        #expect(fixture.windows[1].frame == fixture.originalFrames[1])
        #expect(!fixture.windows[1].layoutState.isAutoTiled && fixture.windows[1].level == .normal)
    }
}
