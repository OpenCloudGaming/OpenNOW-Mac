import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct InterfacePreferencesTests {
    private let key = OpenNOWInterfacePreferences.uiScaleKey

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
        #expect(OpenNOWInterfacePreferences.clampedUIScale(0.2) == 0.75)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(0.75) == 0.75)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(1.25) == 1.25)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(2.0) == 2.0)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(3.5) == 2.0)
    }

    @Test func nonFiniteScaleFallsBackToDefault() {
        #expect(OpenNOWInterfacePreferences.clampedUIScale(.nan) == 1.0)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(.infinity) == 1.0)
        #expect(OpenNOWInterfacePreferences.clampedUIScale(-.infinity) == 1.0)
    }

    @Test func unsetScaleDefaultsToHundredPercent() {
        withPreservedScale {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(OpenNOWInterfacePreferences.uiScale == OpenNOWInterfacePreferences.defaultUIScale)
        }
    }

    @Test func storedScaleIsClampedOnReadAndWrite() {
        withPreservedScale {
            OpenNOWInterfacePreferences.uiScale = 4.0
            #expect(OpenNOWInterfacePreferences.uiScale == 2.0)
            #expect(UserDefaults.standard.double(forKey: key) == 2.0)

            OpenNOWInterfacePreferences.uiScale = 0.1
            #expect(OpenNOWInterfacePreferences.uiScale == 0.75)

            OpenNOWInterfacePreferences.uiScale = 1.5
            #expect(OpenNOWInterfacePreferences.uiScale == 1.5)

            UserDefaults.standard.set(9.0, forKey: key)
            #expect(OpenNOWInterfacePreferences.uiScale == 2.0)
        }
    }
}
