import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized) struct InterfacePreferencesTests {
    private let key = OPNInterfacePreferences.uiScaleKey

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
        #expect(OPNInterfacePreferences.clampedUIScale(0.2) == 0.75)
        #expect(OPNInterfacePreferences.clampedUIScale(0.75) == 0.75)
        #expect(OPNInterfacePreferences.clampedUIScale(1.25) == 1.25)
        #expect(OPNInterfacePreferences.clampedUIScale(2.0) == 2.0)
        #expect(OPNInterfacePreferences.clampedUIScale(3.5) == 2.0)
    }

    @Test func nonFiniteScaleFallsBackToDefault() {
        #expect(OPNInterfacePreferences.clampedUIScale(.nan) == 1.0)
        #expect(OPNInterfacePreferences.clampedUIScale(.infinity) == 1.0)
        #expect(OPNInterfacePreferences.clampedUIScale(-.infinity) == 1.0)
    }

    @Test func unsetScaleDefaultsToHundredPercent() {
        withPreservedScale {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(OPNInterfacePreferences.uiScale == OPNInterfacePreferences.defaultUIScale)
        }
    }

    @Test func storedScaleIsClampedOnReadAndWrite() {
        withPreservedScale {
            OPNInterfacePreferences.uiScale = 4.0
            #expect(OPNInterfacePreferences.uiScale == 2.0)
            #expect(UserDefaults.standard.double(forKey: key) == 2.0)

            OPNInterfacePreferences.uiScale = 0.1
            #expect(OPNInterfacePreferences.uiScale == 0.75)

            OPNInterfacePreferences.uiScale = 1.5
            #expect(OPNInterfacePreferences.uiScale == 1.5)

            UserDefaults.standard.set(9.0, forKey: key)
            #expect(OPNInterfacePreferences.uiScale == 2.0)
        }
    }
}
