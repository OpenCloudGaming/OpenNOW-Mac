import AppKit
import Foundation
import Observation
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized) struct MenuBarLabelIntegrationTests {
    @Test(.enabled(if: Bundle.main.bundleIdentifier == "io.github.opencloudgaming.opennow.dev"))
    func statusItemRemainsResponsiveAcrossLaunchPhases() async throws {
        let closeKey = OPNWindowClosePreferences.behaviorKey
        let statusItemKey = OPNMenuBarPreferences.showsStatusItemKey
        let storedCloseBehavior = UserDefaults.standard.object(forKey: closeKey)
        let storedStatusItemPreference = UserDefaults.standard.object(forKey: statusItemKey)
        defer {
            UserDefaults.standard.set(storedCloseBehavior, forKey: closeKey)
            UserDefaults.standard.set(storedStatusItemPreference, forKey: statusItemKey)
            NotificationCenter.default.post(name: OPNWindowClosePreferences.didChangeNotification, object: nil)
            NotificationCenter.default.post(name: OPNMenuBarPreferences.didChangeNotification, object: nil)
        }
        OPNMenuBarPreferences.showsStatusItem = true
        OPNWindowClosePreferences.behavior = .keepRunningInDock

        try await Task.sleep(for: .seconds(1))
        let session = OPNMenuBarSessionModel.shared
        let source = MenuBarLabelTestSource()
        session.attach(source: source)
        defer { session.detachSource(source) }
        try await Task.sleep(for: .milliseconds(200))

        let button = try #require(statusButton())
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(200))
        session.requestLaunch(source.game)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .connecting)
        #expect(button.image != nil)

        source.snapshot.phase = .queued(position: 3)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .queued(position: 3))

        // A queue position outranks the live stream: the launch flow owns the phase until it goes
        // quiet, so it is cleared here rather than left for the lifecycle to fight.
        source.snapshot = OPNMenuBarSessionSnapshot()
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .idle)

        let streamID = UUID()
        StreamSessionLifecycle.activate(streamID, quitRequestHandler: { _ in true })
        defer { StreamSessionLifecycle.deactivate(streamID) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .streaming)
        let initialElapsedText = session.streamElapsedText
        try await Task.sleep(for: .seconds(2))
        #expect(session.streamElapsedText != initialElapsedText)

        StreamSessionLifecycle.deactivate(streamID)
        source.snapshot = OPNMenuBarSessionSnapshot()
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.phase == .idle)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(session.streamElapsedText == nil)
        button.performClick(nil)
    }

    private func statusButton() -> NSStatusBarButton? {
        for window in NSApplication.shared.windows {
            guard let root = window.contentView else { continue }
            if let button = statusButton(in: root) { return button }
        }
        return nil
    }

    private func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews {
            if let button = statusButton(in: child) { return button }
        }
        return nil
    }
}

@MainActor @Observable private final class MenuBarLabelTestSource: OPNMenuBarSessionSource {
    let game = OPNMenuBarRecentGame(title: "Menu Bar Regression", appId: "menu-bar-regression")
    var snapshot = OPNMenuBarSessionSnapshot()
    var menuBarSnapshot: OPNMenuBarSessionSnapshot { snapshot }

    func launchRecentGame(_ game: OPNMenuBarRecentGame) {
        snapshot = OPNMenuBarSessionSnapshot(phase: .connecting, title: game.title, recentGames: [game])
    }

    func resumeSession() {}
    func refreshActiveSession() {}
    func showMainPage(_ page: OPNMainWindowPage) {}
    func switchAccount(_ account: OPNMenuBarAccount) {}
    func addAccount() {}
}
