import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite(.serialized, .streamLifecycleExclusive,
       .disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
struct StreamWindowModeTransitionTests {
    private let tile = NSRect(x: 100, y: 100, width: 800, height: 450)

    @Test func theHostRestoresBorderlessBeforePictureInPictureCapturesItsReturnPlacement() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        let originalStyle = window.styleMask
        let originalBehavior = window.collectionBehavior
        let carrier = makeCarrier(for: window)
        let model = makeHost(in: window)
        let configuredAspectRatio = CGFloat(
            OPNStreamPreferences.launchProfile(forGame: model.configuration.applicationID,
                                              capabilities: OPNStreamPreferences.loadDeviceCapabilities()).aspectRatio
        )
        let expectedSize = OPNStreamPictureInPicture.contentSize(aspectRatio: configuredAspectRatio)
        window.contentAspectRatio = NSSize(width: configuredAspectRatio, height: 1)
        OPNStreamBorderless.enter(window, frame: tile, coversMenuBar: true)
        await settleStreamWindowChanges()
        #expect(window.frame == tile)

        model.togglePictureInPicture()
        #expect(window.isPictureInPicturePending)
        await settleStreamWindowChanges()

        #expect(window.isPictureInPicture && model.isPictureInPicture)
        #expect(model.nativeView?.isPictureInPictureMode == true)
        #expect(abs(window.frame.width - expectedSize.width) < 1)
        #expect(abs(window.frame.height - expectedSize.height) < 1)
        #expect(window.windowedState?.frame == original)
        #expect(window.windowedState?.level == .normal)
        #expect(window.level == .floating)
        #expect(window.collectionBehavior == [.canJoinAllSpaces])
        #expect(carrier.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(carrier.level.rawValue >= window.level.rawValue)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.styleMask == originalStyle)
        #expect(!window.isPictureInPicturePending && !window.hasPendingLayoutChange)
        #expect(OPNStreamWindowFrameStore.rememberedFrame(isPictureInPicture: false, defaults: fixture.defaults) == original)

        model.togglePictureInPicture()
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicture && !model.isPictureInPicture)
        #expect(window.frame == original)
        #expect(window.level == .normal && window.collectionBehavior == originalBehavior)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(!carrier.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(carrier.collectionBehavior.contains(.ignoresCycle))
        #expect(!carrier.collectionBehavior.contains(.fullScreenPrimary))
    }

    @Test func pictureInPictureWaitsForLiveResizeWithoutChangingTheWindowOrLosingItsOriginalFrame() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        OPNStreamBorderless.enter(window, frame: tile, coversMenuBar: true)
        await settleStreamWindowChanges()
        fixture.geometryView.isResizeHeld = true
        var isCompleted = false
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0, completion: { isCompleted = true })

        await settleStreamWindowChanges()

        #expect(!isCompleted && !window.isPictureInPicture)
        #expect(window.isPictureInPicturePending && window.hasPendingLayoutChange)
        #expect(window.frame == tile && window.level == OPNStreamBorderless.coveringLevel)
        #expect(window.borderlessRestoreState?.frame == original)
        fixture.geometryView.isResizeHeld = false
        await settleStreamWindowChanges()

        #expect(isCompleted && window.isPictureInPicture)
        #expect(window.frame.size == NSSize(width: 640, height: 360))
        #expect(window.windowedState?.frame == original)
        #expect(!window.hasPendingLayoutChange)
    }

    @Test func aSupersededTileCannotOverwritePictureInPictureAfterQueuedWorkLands() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        OPNStreamBorderless.enter(window, frame: tile)
        OPNStreamBorderless.enter(window, frame: tile.offsetBy(dx: 50, dy: 0), coversMenuBar: true)
        var entryKeyWindow: NSWindow?
        OPNStreamPictureInPicture.enter(window, aspectRatio: 4.0 / 3.0, prepareForEntry: {
            entryKeyWindow = NSApp.keyWindow
            return true
        }, completion: {
            #expect(NSApp.keyWindow === entryKeyWindow)
            #expect(window.canBecomeKey)
        })
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        #expect(window.frame.size == NSSize(width: 640, height: 480))
        #expect(window.windowedState?.frame == original)
        #expect(window.level == .floating && !window.layoutState.isBorderless)
        #expect(window.resizeIncrements == NSSize(width: 1, height: 1))
        #expect(window.contentResizeIncrements == NSSize(width: 1, height: 1))
        OPNStreamPictureInPicture.exit(window)
        await settleStreamWindowChanges()
        #expect(window.frame == original)
    }

    @Test func aNewBorderlessRequestSupersedesPendingPictureInPictureWithoutLosingTheRestoreState() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        OPNStreamBorderless.enter(window, frame: tile)
        await settleStreamWindowChanges()
        fixture.geometryView.isResizeHeld = true
        var isObsoleteEntryCompleted = false
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0, completion: { isObsoleteEntryCompleted = true })
        let replacement = tile.offsetBy(dx: 30, dy: 0)
        OPNStreamBorderless.enter(window, frame: replacement, coversMenuBar: true)
        fixture.geometryView.isResizeHeld = false
        await settleStreamWindowChanges()

        #expect(!isObsoleteEntryCompleted && !window.isPictureInPicturePending)
        #expect(!window.isPictureInPicture && window.layoutState.isBorderless)
        #expect(window.frame == replacement)
        #expect(window.borderlessRestoreState?.frame == original)
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        await settleStreamWindowChanges()
        #expect(window.isPictureInPicture && window.windowedState?.frame == original)
    }

    @Test func cancellingADeferredEntryRestoresWindowedModeAndAllowsTheNextEntry() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        OPNStreamBorderless.enter(window, frame: tile)
        await settleStreamWindowChanges()
        fixture.geometryView.isResizeHeld = true
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        OPNStreamPictureInPicture.exit(window)
        fixture.geometryView.isResizeHeld = false
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicture && !window.isPictureInPicturePending)
        #expect(window.frame == original && !window.layoutState.isBorderless)
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        await settleStreamWindowChanges()
        #expect(window.isPictureInPicture && window.windowedState?.frame == original)
    }

    @Test func rapidBorderlessTogglesReverseThePendingExitWithoutReplacingTheOriginalReturnFrame() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        OPNStreamBorderless.toggleByReader(window)
        await settleStreamWindowChanges()
        OPNStreamBorderless.toggleByReader(window)
        #expect(window.isBorderlessExitPending)
        OPNStreamBorderless.toggleByReader(window)
        await settleStreamWindowChanges()

        #expect(window.layoutState.isBorderless && !window.isBorderlessExitPending)
        #expect(window.frame == OPNStreamBorderless.targetFrame(for: window))
        #expect(window.borderlessRestoreState?.frame == original)
        OPNStreamBorderless.toggleByReader(window)
        await settleStreamWindowChanges()
        #expect(window.frame == original && !window.layoutState.isBorderless)
    }

    @Test(arguments: [false, true])
    func closingOrEndingTheSessionCancelsADeferredEntry(isClosing: Bool) async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        OPNStreamBorderless.enter(window, frame: tile)
        await settleStreamWindowChanges()
        fixture.geometryView.isResizeHeld = true
        var isCompleted = false
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0, completion: { isCompleted = true })
        if isClosing { window.close() }
        if !isClosing { window.endPresentation() }
        fixture.geometryView.isResizeHeld = false
        await settleStreamWindowChanges()

        #expect(!isCompleted && !window.isPictureInPicture && !window.isPictureInPicturePending)
        #expect(!window.hasPendingLayoutChange && window.frame == tile)
        #expect(window.windowedState == nil)
    }

    @Test func anInvalidatedHostCannotEnterAfterItsBorderlessRestorationCompletes() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let original = window.frame
        let model = makeHost(in: window)
        OPNStreamBorderless.enter(window, frame: tile)
        await settleStreamWindowChanges()
        model.togglePictureInPicture()
        model.isEnding = true
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicture && !model.isPictureInPicture)
        #expect(!window.isPictureInPicturePending && window.frame == original)
    }

    @Test func cancellingTheHostsFullScreenSequenceDoesNotEnterPictureInPictureLater() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let model = makeHost(in: window)
        let original = window.frame
        model.isFullScreenTransitioning = true
        model.togglePictureInPicture()
        #expect(window.isPictureInPicturePending)
        model.togglePictureInPicture()
        model.isFullScreenTransitioning = false
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicture && !model.isPictureInPicture)
        #expect(!window.isPictureInPicturePending && window.frame == original)
    }

    @Test func aNativeFullScreenPictureInPictureRequestSurvivesRetilingAfterASecondStreamLaunches() async throws {
        let fixture = try StreamWindowFullScreenFixture()
        defer { fixture.close() }
        let window = fixture.fullScreen.window
        let survivor = fixture.windowed.window
        let survivorFrame = survivor.frame
        let model = makeHost(in: window)
        #expect(fixture.isNativeFullScreen && !window.isVisible)
        #expect(!window.styleMask.contains(.fullScreen))
        #expect(!window.layoutState.isManuallyPlaced && !window.layoutState.isAutoTiled)
        #expect(!survivor.layoutState.isAutoTiled)
        model.isFullScreenTransitioning = true
        model.togglePictureInPicture()
        let requestID = window.pictureInPictureRequestID
        #expect(requestID != nil)
        fixture.beginExit()
        fixture.landExit()
        await settleStreamWindowChanges()
        fixture.layout.presenter.retileWindows()
        await settleStreamWindowChanges()

        #expect(window.isPictureInPicturePending && window.pictureInPictureRequestID == requestID)
        #expect(!fixture.isNativeFullScreen && !window.styleMask.contains(.fullScreen))
        #expect(!window.layoutState.isManuallyPlaced && !window.layoutState.isAutoTiled)
        #expect(window.frame == fixture.returnFrame && !window.hasPendingLayoutChange)
        #expect(survivor.frame == survivorFrame && !survivor.layoutState.isAutoTiled)
        model.isFullScreenTransitioning = false
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        let expectedSize = OPNStreamPictureInPicture.contentSize(aspectRatio: CGFloat(
            OPNStreamPreferences.launchProfile(forGame: model.configuration.applicationID,
                                              capabilities: OPNStreamPreferences.loadDeviceCapabilities()).aspectRatio
        ))
        #expect(window.isPictureInPicture && model.isPictureInPicture)
        #expect(model.nativeView?.isPictureInPictureMode == true)
        #expect(window.windowedState?.frame == fixture.returnFrame)
        #expect(abs(window.frame.width - expectedSize.width) < 1)
        #expect(abs(window.frame.height - expectedSize.height) < 1)
        #expect(window.level == .floating && window.collectionBehavior == [.canJoinAllSpaces])
        #expect(!window.isPictureInPicturePending && !window.layoutState.isAutoTiled && !window.hasPendingLayoutChange)
        #expect(survivor.frame == survivorFrame && survivor.level == .normal)
        #expect(!survivor.layoutState.isAutoTiled && !survivor.layoutState.isManuallyPlaced)
    }

    @Test(arguments: [false, true])
    func anAbortedFullScreenPictureInPictureRequestReturnsItsPlacementToThePresenter(isHostInvalidated: Bool) async throws {
        let fixture = try StreamWindowFullScreenFixture()
        defer { fixture.close() }
        let window = fixture.fullScreen.window
        let survivor = fixture.windowed.window
        let model = makeHost(in: window)
        model.isFullScreenTransitioning = true
        model.togglePictureInPicture()
        fixture.beginExit()
        fixture.landExit()
        await settleStreamWindowChanges()
        #expect(window.isPictureInPicturePending && !window.layoutState.isManuallyPlaced)

        if isHostInvalidated { model.nativeView = nil }
        if !isHostInvalidated { model.togglePictureInPicture() }
        model.isFullScreenTransitioning = false
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicture && !model.isPictureInPicture && !window.isPictureInPicturePending)
        #expect(!window.layoutState.isManuallyPlaced && !survivor.layoutState.isManuallyPlaced)
        #expect(window.layoutState.isAutoTiled && survivor.layoutState.isAutoTiled)
        #expect([window.frame, survivor.frame] == fixture.layout.expectedTiles(count: 2))
        #expect(!window.hasPendingLayoutChange && !survivor.hasPendingLayoutChange)
    }

    @Test func anUnconfirmedFullScreenExitReleasesItsPlacementWhenPictureInPictureRetriesExpire() async throws {
        let fixture = try StreamWindowFullScreenFixture()
        defer { fixture.close() }
        let window = fixture.fullScreen.window
        let survivor = fixture.windowed.window
        let model = makeHost(in: window)
        model.isFullScreenTransitioning = true
        model.togglePictureInPicture()
        fixture.beginExit()
        fixture.landExit()
        await settleStreamWindowChanges()
        #expect(window.isPictureInPicturePending && !window.layoutState.isAutoTiled)

        for _ in 0..<(NativeNVSTHostViewModel.sessionReadyFullScreenAttemptLimit * 2) {
            guard window.isPictureInPicturePending else { break }
            try await Task.sleep(for: NativeNVSTHostViewModel.sessionReadyFullScreenRetryDelay)
        }
        model.isFullScreenTransitioning = false
        await settleStreamWindowChanges()
        await settleStreamWindowChanges()

        #expect(!window.isPictureInPicturePending && !window.isPictureInPicture && !model.isPictureInPicture)
        #expect(!window.layoutState.isManuallyPlaced && !survivor.layoutState.isManuallyPlaced)
        #expect(window.layoutState.isAutoTiled && survivor.layoutState.isAutoTiled)
        #expect([window.frame, survivor.frame] == fixture.layout.expectedTiles(count: 2))
        #expect(!window.hasPendingLayoutChange && !survivor.hasPendingLayoutChange)
    }

    @Test func theAccountHandoffFollowsSettledCoveringLevelsThroughEntryPictureInPictureAndClosure() async throws {
        let fixture = try StreamWindowTransitionFixture()
        defer { fixture.close() }
        let window = fixture.window
        let main = NSWindow(contentRect: tile, styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: {
            window.isVisible && window.layoutState.isBorderless ? [window.level] : []
        })
        defer {
            handoff.end()
            main.close()
        }
        handoff.begin(from: nil)
        handoff.attach(main)
        OPNStreamBorderless.enter(window, frame: tile, coversMenuBar: true)
        await settleStreamWindowChanges()

        #expect(window.level == OPNStreamBorderless.coveringLevel)
        #expect(main.level.rawValue > window.level.rawValue)
        OPNStreamPictureInPicture.enter(window, aspectRatio: 16.0 / 9.0)
        await settleStreamWindowChanges()
        #expect(window.isPictureInPicture && main.level == .normal)
        OPNStreamPictureInPicture.exit(window)
        OPNStreamBorderless.enter(window, frame: tile, coversMenuBar: true)
        await settleStreamWindowChanges()
        #expect(main.level.rawValue > window.level.rawValue)
        window.close()
        await settleStreamWindowChanges()

        #expect(!window.isVisible && main.level == .normal)
    }

    private func makeHost(in window: OPNStreamWindow) -> NativeNVSTHostViewModel {
        let model = NativeNVSTHostViewModel(
            configuration: StreamLaunchConfiguration(title: "Geometry", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam"),
            sessionProvider: StubNativeNVSTSessionProvider(), preventDisplaySleep: false,
            onProgress: nil, onEnd: { _, _, _ in }
        )
        let view = NativeStreamView(frame: window.contentView?.bounds ?? .zero)
        view.cursorAssociationHandler = { _ in .success }
        view.cursorWarpHandler = { _ in }
        view.hidesCursorWhilePointerLocked = false
        window.contentView = view
        model.nativeView = view
        return model
    }

    private func makeCarrier(for window: OPNStreamWindow) -> NSWindow {
        let carrier = NSWindow(contentRect: tile, styleMask: .borderless, backing: .buffered, defer: false)
        carrier.isReleasedWhenClosed = false
        carrier.alphaValue = 0
        carrier.ignoresMouseEvents = true
        window.addChildWindow(carrier, ordered: .above)
        return carrier
    }
}
