import AppKit
import Testing
@testable import OpenNOW

@MainActor
@Suite(.serialized) struct CouchCoopBorderlessTests {
    private let screens = [
        NSRect(x: 0, y: 0, width: 1920, height: 1080),
        NSRect(x: 1920, y: 0, width: 2560, height: 1440),
    ]

    @Test func aWindowThatFillsAScreenCoversTheMenuBar() {
        #expect(OPNStreamBorderless.coversWholeScreen(screens[1], screenFrames: screens))
        #expect(OPNStreamBorderless.level(for: screens[0], screenFrames: screens) == OPNStreamBorderless.coveringLevel)
        #expect(OPNStreamBorderless.coveringLevel.rawValue > NSWindow.Level.mainMenu.rawValue)
    }

    @Test func aTileThatSharesAScreenStaysAnOrdinaryWindow() {
        let half = NSRect(x: 0, y: 0, width: 960, height: 1080)
        #expect(!OPNStreamBorderless.coversWholeScreen(half, screenFrames: screens))
        #expect(OPNStreamBorderless.level(for: half, screenFrames: screens) == .normal)
    }

    @Test func aReachableWindowSitsAboveTheCoveringStreams() {
        #expect(OPNStreamBorderless.aboveCoveringLevel.rawValue > OPNStreamBorderless.coveringLevel.rawValue)
    }

    @Test func borderlessAndTiledWindowsLetterboxAndNeverEnterNativeFullScreenOrPersistAFrame() {
        let state = OPNStreamWindowLayoutState()
        #expect(!state.releasesAspectLock && !state.suppressesNativeFullScreen && state.persistsFrame)

        state.isBorderless = true
        #expect(state.releasesAspectLock && state.suppressesNativeFullScreen && !state.persistsFrame)

        state.isBorderless = false
        state.isAutoTiled = true
        #expect(state.releasesAspectLock && state.suppressesNativeFullScreen && !state.persistsFrame)

        state.isAutoTiled = false
        #expect(!state.releasesAspectLock && !state.suppressesNativeFullScreen && state.persistsFrame)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func enteringBorderlessHidesTheButtonsKeepsTheStyleMaskAndLeavingRestoresTheWindow() async throws {
        let suite = "OpenNOWTests.Borderless.\(UUID().uuidString)"
        let window = OPNStreamWindowFactory.make(sessionID: UUID(), defaults: UserDefaults(suiteName: suite) ?? .standard)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let before = window.frame
        let level = window.level
        let styleMask = window.styleMask
        let target = NSRect(x: 100, y: 100, width: 800, height: 450)

        OPNStreamBorderless.enter(window, frame: target, screenFrames: screens)
        try await Task.sleep(for: .milliseconds(200))

        #expect(window.layoutState.isBorderless)
        #expect(window.styleMask == styleMask)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.frame == target)
        #expect(window.level == .normal)

        OPNStreamBorderless.exit(window)
        try await Task.sleep(for: .milliseconds(200))

        #expect(!window.layoutState.isBorderless)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.level == level)
        #expect(window.frame == before)
        #expect(window.borderlessRestoreState == nil)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func aBorderlessWindowDoesNotWriteItsFrameToThePlacementStore() async throws {
        let suite = "OpenNOWTests.BorderlessStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = OPNStreamWindowFactory.make(sessionID: UUID(), defaults: defaults)
        OPNStreamWindowFrameStore.forget(isPictureInPicture: false, defaults: defaults)

        window.layoutState.isAutoTiled = true
        window.setFrame(NSRect(x: 10, y: 10, width: 700, height: 400), display: false)
        try await Task.sleep(for: .milliseconds(200))

        #expect(OPNStreamWindowFrameStore.rememberedFrame(isPictureInPicture: false, defaults: defaults) == nil)
        window.stopPersistingFrame()
    }

    @Test func aWindowMovedAwayFromItsLayoutFrameIsNotAtIt() {
        let window = OPNStreamWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!window.isAtLayoutFrame)
        window.setFrameFromLayout(NSRect(x: 50, y: 50, width: 640, height: 360))
        #expect(window.isAtLayoutFrame)
        window.setFrame(NSRect(x: 80, y: 50, width: 640, height: 360), display: false)
        #expect(!window.isAtLayoutFrame)
        window.clearLayoutFrame()
        #expect(!window.isAtLayoutFrame)
    }

    @Test func tileCoverageDividesTheVisibleAreaOrTheWholeFrame() {
        let frames = [NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let visible = [NSRect(x: 0, y: 70, width: 1920, height: 985)]
        #expect(OPNStreamTileCoverage.visibleArea.areas(frames: frames, visibleFrames: visible) == visible)
        #expect(OPNStreamTileCoverage.fullScreen.areas(frames: frames, visibleFrames: visible) == frames)
        #expect(OPNStreamTileCoverage.visibleArea.flipped == .fullScreen)
        #expect(OPNStreamTileCoverage.fullScreen.flipped == .visibleArea)
    }

    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func aTileThatCoversTheMenuBarIsRaisedEvenWhenItSharesAScreen() async throws {
        let suite = "OpenNOWTests.BorderlessCover.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = OPNStreamWindowFactory.make(sessionID: UUID(), defaults: defaults)
        let half = NSRect(x: 0, y: 0, width: 960, height: 1080)

        OPNStreamBorderless.enter(window, frame: half, coversMenuBar: true, screenFrames: screens)
        #expect(window.level == OPNStreamBorderless.coveringLevel)

        OPNStreamBorderless.enter(window, frame: half, coversMenuBar: false, screenFrames: screens)
        #expect(window.level == .normal)
        OPNStreamBorderless.exit(window)
    }

    @Test func enteringAndLeavingBorderlessAnnouncesTheCoveringStateChange() async throws {
        let window = OPNStreamWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: OPNStreamBorderless.coveringStateDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        OPNStreamBorderless.enter(window, frame: NSRect(x: 0, y: 0, width: 640, height: 360), screenFrames: screens)
        OPNStreamBorderless.exit(window)

        #expect(posts == 2)
    }

    /// A tile whose placement is still waiting on the geometry gate has no layout frame yet. A move
    /// that lands in that gap is not the reader taking the window.
    @Test func aMoveBeforeTheFirstTileLandsKeepsTheWindowTiled() {
        let window = OPNStreamWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.layoutState.isAutoTiled = true

        #expect(!OPNStreamWindowPresenter.noteFrameChange(window))

        #expect(window.layoutState.isAutoTiled)
        #expect(!window.layoutState.isManuallyPlaced)
    }

    @Test func aMoveAwayFromAPlacedTileHandsTheWindowToTheReader() {
        let window = OPNStreamWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.layoutState.isAutoTiled = true
        window.setFrameFromLayout(NSRect(x: 50, y: 50, width: 640, height: 360))

        #expect(!OPNStreamWindowPresenter.noteFrameChange(window))
        #expect(window.layoutState.isAutoTiled)

        window.setFrame(NSRect(x: 90, y: 50, width: 640, height: 360), display: false)
        #expect(OPNStreamWindowPresenter.noteFrameChange(window))

        #expect(!window.layoutState.isAutoTiled)
        #expect(window.layoutState.isManuallyPlaced)
    }

    @Test func theRelaunchHelperWaitsForThisProcessAndOpensTheBundleFromAnArgument() {
        let arguments = OPNAppRelaunch.helperArguments(pid: 4242)
        #expect(arguments.first == "-c")
        #expect(arguments[1].contains("kill -0 4242"))
        #expect(arguments[1].contains("open \"$0\""))
        #expect(arguments.last == Bundle.main.bundlePath)
    }

    @Test func onlyTheCouchCoopFlagAsksForARestart() {
        #expect(OPNLabs.couchCoop.requiresRestart)
        #expect(!OPNLabs.clipboardCapture.requiresRestart)
    }
}
