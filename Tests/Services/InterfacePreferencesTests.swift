import Foundation
import Testing
@testable import MacForceNow

@Suite(.serialized) struct InterfacePreferencesTests {
    private let key = MacForceNowInterfacePreferences.uiScaleKey

    private func withPreservedScale(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let existing = defaults.object(forKey: key)
        defer {
            if let existing {
                defaults.set(existing, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    @Test func clampsScaleIntoSupportedRange() {
        #expect(MacForceNowInterfacePreferences.clampedUIScale(0.2) == 0.75)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(0.75) == 0.75)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(1.25) == 1.25)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(2.0) == 2.0)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(3.5) == 2.0)
    }

    @Test func nonFiniteScaleFallsBackToDefault() {
        #expect(MacForceNowInterfacePreferences.clampedUIScale(.nan) == 1.0)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(.infinity) == 1.0)
        #expect(MacForceNowInterfacePreferences.clampedUIScale(-.infinity) == 1.0)
    }

    @Test func unsetScaleDefaultsToHundredPercent() {
        withPreservedScale {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(MacForceNowInterfacePreferences.uiScale == MacForceNowInterfacePreferences.defaultUIScale)
        }
    }

    @Test func storedScaleIsClampedOnReadAndWrite() {
        withPreservedScale {
            MacForceNowInterfacePreferences.uiScale = 4.0
            #expect(MacForceNowInterfacePreferences.uiScale == 2.0)
            #expect(UserDefaults.standard.double(forKey: key) == 2.0)

            MacForceNowInterfacePreferences.uiScale = 0.1
            #expect(MacForceNowInterfacePreferences.uiScale == 0.75)

            MacForceNowInterfacePreferences.uiScale = 1.5
            #expect(MacForceNowInterfacePreferences.uiScale == 1.5)

            UserDefaults.standard.set(9.0, forKey: key)
            #expect(MacForceNowInterfacePreferences.uiScale == 2.0)
        }
    }
}
