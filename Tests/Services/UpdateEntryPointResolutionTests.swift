import AppKit
import Testing
@testable import OpenNOW

/// SwiftUI's `@NSApplicationDelegateAdaptor` installs its own `AppDelegate` as `NSApp.delegate` and
/// forwards the delegate callbacks to the adaptor's instance, so the static update entry points the
/// app menu and Settings reach must resolve that instance rather than `NSApp.delegate`.
@Suite(.serialized) @MainActor
struct UpdateEntryPointResolutionTests {
    @Test func aManualUpdateCheckReachesTheDelegateWhenSwiftUIOwnsTheApplicationDelegate() {
        let delegate = OPNAppDelegate()
        let previousDelegate = NSApplication.shared.delegate
        let defaults = OPNAppPreferenceStorage.standard
        let previousReminder = defaults.object(forKey: OPNUpdatePreferences.remindAfterKey)
        let swiftUIWrapper = ForeignApplicationDelegate()
        NSApplication.shared.delegate = swiftUIWrapper
        defer {
            NSApplication.shared.delegate = previousDelegate
            defaults.removeObject(forKey: OPNUpdatePreferences.remindAfterKey)
            if let previousReminder {
                defaults.set(previousReminder, forKey: OPNUpdatePreferences.remindAfterKey)
            }
        }

        #expect(NSApplication.shared.delegate as? OPNAppDelegate == nil)
        #expect(OPNAppDelegate.activeApplicationDelegate === delegate)

        OPNUpdatePreferences.remindTomorrow()
        OPNAppDelegate.requestApplicationUpdateCheck()

        // The request reached the delegate and cleared the snooze. Resolving through `NSApp.delegate`
        // would have found SwiftUI's wrapper and left the snooze untouched.
        #expect(defaults.object(forKey: OPNUpdatePreferences.remindAfterKey) == nil)
    }
}

@MainActor
private final class ForeignApplicationDelegate: NSObject, NSApplicationDelegate {}
