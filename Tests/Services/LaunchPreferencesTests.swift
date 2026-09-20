import Foundation
import Testing
@testable import OpenNOW

/// The launch preferences: a new install starts with the window and no login item, and each choice
/// round-trips through the store.
@MainActor @Suite(.serialized) struct LaunchPreferencesTests {
    private func preserve(_ key: String) -> Any? {
        UserDefaults.standard.object(forKey: key)
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Test func unsetLaunchPreferencesStartWithTheWindowAndNoLoginItem() {
        let atLogin = preserve(OPNLaunchPreferences.launchesAtLoginKey)
        let presentation = preserve(OPNLaunchPreferences.startupPresentationKey)
        defer {
            restore(atLogin, forKey: OPNLaunchPreferences.launchesAtLoginKey)
            restore(presentation, forKey: OPNLaunchPreferences.startupPresentationKey)
        }

        UserDefaults.standard.removeObject(forKey: OPNLaunchPreferences.launchesAtLoginKey)
        UserDefaults.standard.removeObject(forKey: OPNLaunchPreferences.startupPresentationKey)

        #expect(!OPNLaunchPreferences.launchesAtLogin)
        #expect(OPNLaunchPreferences.startupPresentation == .window)
    }

    @Test func startupPresentationRoundTripsAndAnnouncesItself() {
        let existing = preserve(OPNLaunchPreferences.startupPresentationKey)
        let menuBarItem = preserve(OPNMenuBarPreferences.showsStatusItemKey)
        let closeBehavior = preserve(OPNWindowClosePreferences.behaviorKey)
        defer {
            restore(existing, forKey: OPNLaunchPreferences.startupPresentationKey)
            restore(menuBarItem, forKey: OPNMenuBarPreferences.showsStatusItemKey)
            restore(closeBehavior, forKey: OPNWindowClosePreferences.behaviorKey)
        }

        // The menu-bar-only choice only resolves while the status item can be reached, so the
        // prerequisites are set explicitly rather than left to whatever another suite last wrote.
        OPNMenuBarPreferences.showsStatusItem = true
        OPNWindowClosePreferences.behavior = .keepRunningInDock
        OPNLaunchPreferences.startupPresentation = .window
        let counter = AnnouncementCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: OPNLaunchPreferences.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in counter.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        OPNLaunchPreferences.startupPresentation = .menuBarOnly
        #expect(OPNLaunchPreferences.startupPresentation == .menuBarOnly)
        #expect(counter.count == 1)

        // Writing the same value again is not a change and must not republish it.
        OPNLaunchPreferences.startupPresentation = .menuBarOnly
        #expect(counter.count == 1)
    }

    /// A menu-bar-only launch suppresses the window, so with no status item to reach the app by it is
    /// withheld and the window opens instead.
    @Test func menuBarOnlyLaunchIsWithheldWhenTheStatusItemCannotBeReached() {
        #expect(OPNLaunchPreferences.resolvedStartupPresentation(storedRawValue: "menuBarOnly", canReachMenuBar: false) == .window)
        #expect(OPNLaunchPreferences.resolvedStartupPresentation(storedRawValue: "menuBarOnly", canReachMenuBar: true) == .menuBarOnly)
        // Opening the window is always valid, reachable or not.
        #expect(OPNLaunchPreferences.resolvedStartupPresentation(storedRawValue: "window", canReachMenuBar: false) == .window)
        // An unknown or missing value falls back to the window.
        #expect(OPNLaunchPreferences.resolvedStartupPresentation(storedRawValue: "picture-in-picture", canReachMenuBar: true) == .window)
        #expect(OPNLaunchPreferences.resolvedStartupPresentation(storedRawValue: nil, canReachMenuBar: true) == .window)
    }

    @Test func unknownStoredPresentationFallsBackToTheWindow() {
        let existing = preserve(OPNLaunchPreferences.startupPresentationKey)
        defer { restore(existing, forKey: OPNLaunchPreferences.startupPresentationKey) }

        UserDefaults.standard.set("picture-in-picture", forKey: OPNLaunchPreferences.startupPresentationKey)
        #expect(OPNLaunchPreferences.startupPresentation == .window)
    }
}

private final class AnnouncementCounter: @unchecked Sendable {
    var count = 0
}
