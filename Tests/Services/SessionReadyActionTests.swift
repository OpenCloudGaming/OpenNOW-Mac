import Foundation
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized) struct SessionReadyActionTests {
    private let key = OPNSessionReadyAction.modeKey

    private func withPreservedMode(_ body: () -> Void) {
        let existing = UserDefaults.standard.object(forKey: key)
        defer { restoreMode(existing) }
        body()
    }

    private func restoreMode(_ existing: Any?) {
        guard let existing else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(existing, forKey: key)
    }

    @Test func unsetModeDefaultsToNotification() {
        withPreservedMode {
            UserDefaults.standard.removeObject(forKey: key)
            #expect(OPNSessionReadyAction.mode == .notification)
            #expect(!OPNSessionReadyAction.isFullScreenRequestedWhenReady)
        }
    }

    @Test func unknownStoredModeFallsBackToNotification() {
        withPreservedMode {
            UserDefaults.standard.set("bring-to-front-and-full-screen", forKey: key)
            #expect(OPNSessionReadyAction.mode == .notification)
        }
    }
}
