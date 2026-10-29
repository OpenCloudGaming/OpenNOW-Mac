import AppKit
import GameController
import Testing
@testable import OpenNOW

@MainActor
final class StreamWindowGeometryDeferralView: NSView {
    var isResizeHeld = false

    override var inLiveResize: Bool { isResizeHeld || super.inLiveResize }
}

@MainActor
final class StreamWindowTransitionFixture {
    let window: OPNStreamWindow
    let geometryView: StreamWindowGeometryDeferralView
    let defaults: UserDefaults
    private let suite: String

    init(isShown: Bool = true) throws {
        _ = NSApplication.shared
        let suite = "OpenNOWTests.WindowTransition.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let window = OPNStreamWindowFactory.make(sessionID: UUID(), defaults: defaults)
        let geometryView = StreamWindowGeometryDeferralView(frame: window.contentView?.bounds ?? .zero)
        self.suite = suite
        self.defaults = defaults
        self.window = window
        self.geometryView = geometryView
        window.contentView = geometryView
        window.alphaValue = 0
        if isShown { window.orderFront(nil) }
    }

    func close() {
        window.stopPersistingFrame()
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            child.close()
        }
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class StreamWindowLayoutFixture {
    let presenter: OPNStreamWindowPresenter
    let sessions: [UUID]
    let fixtures: [StreamWindowTransitionFixture]
    let originalFrames: [NSRect]
    private let previousFlag = OPNLabs.isCouchCoopEnabled
    private let previousCoverage = OPNStreamTileCoverage.stored
    private let previousOrientation = OPNStreamTileOrientation.stored
    private let wasMonitoringBackgroundEvents = GCController.shouldMonitorBackgroundEvents

    var windows: [OPNStreamWindow] { fixtures.map(\.window) }

    init(count: Int, isCouchCoopEnabled: Bool = true,
         isNativeFullScreen: @escaping @MainActor (OPNStreamWindow) -> Bool = { $0.styleMask.contains(.fullScreen) }) throws {
        presenter = OPNStreamWindowPresenter(isNativeFullScreen: isNativeFullScreen)
        #expect(!NSScreen.screens.isEmpty)
        let fixtures = try (0..<count).map { _ in try StreamWindowTransitionFixture() }
        self.fixtures = fixtures
        sessions = fixtures.map { _ in UUID() }
        originalFrames = fixtures.map { $0.window.frame }
        OPNLabs.setEnabled(OPNLabs.couchCoop, isCouchCoopEnabled)
        OPNStreamTileCoverage.store(.fullScreen)
        OPNStreamTileOrientation.store(.sideBySide)
        for (sessionID, window) in zip(sessions, windows) { presenter.register(window, for: sessionID) }
        presenter.retileWindows()
    }

    func close() {
        for sessionID in sessions { presenter.dismiss(sessionID) }
        for fixture in fixtures { fixture.close() }
        OPNLabs.setEnabled(OPNLabs.couchCoop, previousFlag)
        OPNStreamTileCoverage.store(previousCoverage)
        OPNStreamTileOrientation.store(previousOrientation)
        GCController.shouldMonitorBackgroundEvents = wasMonitoringBackgroundEvents
    }

    func expectedTiles(count: Int) -> [NSRect] {
        OPNStreamTileLayout.tiles(
            screens: OPNStreamTileCoverage.stored.areas(
                frames: NSScreen.screens.map(\.frame), visibleFrames: NSScreen.screens.map(\.visibleFrame)
            ),
            windowCount: count,
            orientation: OPNStreamTileOrientation.stored
        ).map(\.frame)
    }
}

@MainActor
final class StreamWindowFullScreenFixture {
    let layout: StreamWindowLayoutFixture
    let fullScreen: StreamWindowTransitionFixture
    let windowed: StreamWindowTransitionFixture
    let returnFrame: NSRect
    private let fullScreenSessionID: UUID
    private let windowedSessionID: UUID
    private let fullScreenStatus: StreamWindowFullScreenStatus

    var isNativeFullScreen: Bool { fullScreenStatus.isFullScreen }

    init() throws {
        let fullScreen = try StreamWindowTransitionFixture(isShown: false)
        let fullScreenStatus = StreamWindowFullScreenStatus()
        let layout = try StreamWindowLayoutFixture(count: 0, isNativeFullScreen: { window in
            if window === fullScreen.window { return fullScreenStatus.isFullScreen }
            return window.styleMask.contains(.fullScreen)
        })
        let fullScreenSessionID = UUID()
        let windowedSessionID = UUID()
        let returnFrame = fullScreen.window.frame
        #expect(!fullScreen.window.isVisible)
        #expect(!fullScreen.window.styleMask.contains(.fullScreen))
        layout.presenter.register(fullScreen.window, for: fullScreenSessionID)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: fullScreen.window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: fullScreen.window)
        let windowed = try StreamWindowTransitionFixture()
        layout.presenter.register(windowed.window, for: windowedSessionID)
        layout.presenter.retileWindows()
        self.layout = layout
        self.fullScreen = fullScreen
        self.windowed = windowed
        self.returnFrame = returnFrame
        self.fullScreenSessionID = fullScreenSessionID
        self.windowedSessionID = windowedSessionID
        self.fullScreenStatus = fullScreenStatus
    }

    func beginExit() {
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: fullScreen.window)
    }

    func landExit() {
        #expect(!fullScreen.window.isVisible)
        #expect(!fullScreen.window.styleMask.contains(.fullScreen))
        fullScreenStatus.isFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: fullScreen.window)
    }

    func close() {
        if isNativeFullScreen {
            beginExit()
            landExit()
        }
        layout.presenter.dismiss(fullScreenSessionID)
        layout.presenter.dismiss(windowedSessionID)
        fullScreen.close()
        windowed.close()
        layout.close()
    }
}

@MainActor
private final class StreamWindowFullScreenStatus {
    var isFullScreen = true
}

@MainActor
func settleStreamWindowChanges() async {
    try? await Task.sleep(for: .milliseconds(200))
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
