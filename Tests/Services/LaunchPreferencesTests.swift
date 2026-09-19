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
        defer { restore(existing, forKey: OPNLaunchPreferences.startupPresentationKey) }

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
