import Foundation
import Testing
@testable import OpenNOW

private func isolatedStorage() -> (storage: OPNAppPreferenceStorage, cleanup: () -> Void) {
    let suiteName = "opn-couch-coop-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    let storage = OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: suiteName)
    return (storage, { defaults.removePersistentDomain(forName: suiteName) })
}

@Suite("OPNCouchCoopPreferences")
struct OPNCouchCoopPreferencesTests {
    @Test func layoutDefaultsToSideBySide() {
        let isolated = isolatedStorage()
        defer { isolated.cleanup() }
        #expect(OPNCouchCoopPreferences.layout(storage: isolated.storage) == .sideBySide)
    }

    @Test func layoutRoundTripsUnderItsStorageKey() {
        let isolated = isolatedStorage()
        defer { isolated.cleanup() }
        for layout in OPNCouchCoopLayout.allCases {
            OPNCouchCoopPreferences.setLayout(layout, storage: isolated.storage)
            #expect(OPNCouchCoopPreferences.layout(storage: isolated.storage) == layout)
            #expect(isolated.storage.string(forKey: "OpenNOW.CouchCoop.Layout") == layout.rawValue)
        }
    }

    @Test func anUnknownStoredLayoutFallsBackToTheDefault() {
        let isolated = isolatedStorage()
        defer { isolated.cleanup() }
        isolated.storage.set("diagonal", forKey: OPNCouchCoopPreferences.layoutKey)
        #expect(OPNCouchCoopPreferences.layout(storage: isolated.storage) == .sideBySide)
    }

    @Test func everyLayoutHasALabelAndASummary() {
        for layout in OPNCouchCoopLayout.allCases {
            #expect(!layout.label.isEmpty)
            #expect(!layout.summary.isEmpty)
        }
        #expect(OPNCouchCoopLayout.allCases.map(\.label) == ["Side by Side", "Top and Bottom", "Manual"])
    }
}
