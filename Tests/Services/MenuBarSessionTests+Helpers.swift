import Foundation
import Testing
@testable import OpenNOW

/// Preference save/restore and queue-draining helpers for `MenuBarSessionTests`, in their own file so
/// the suite stays within the type- and file-length limits.
@MainActor extension MenuBarSessionTests {
    func preserveCloseBehavior() -> Any? {
        UserDefaults.standard.object(forKey: preferencesKey)
    }

    func restoreCloseBehavior(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: preferencesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferencesKey)
        }
    }

    /// A stored behavior every test can start from without depending on the order it ran in.
    func storeCloseBehavior(_ behavior: OPNWindowCloseBehavior) {
        UserDefaults.standard.set(behavior.rawValue, forKey: preferencesKey)
    }

    func preserveMenuBarItem() -> Any? {
        UserDefaults.standard.object(forKey: menuBarItemKey)
    }

    func restoreMenuBarItem(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: menuBarItemKey)
        } else {
            UserDefaults.standard.removeObject(forKey: menuBarItemKey)
        }
    }

    /// The model observes `NotificationCenter.default` so the tests exercise the real posting path;
    /// a main-queue delivery needs the run loop to turn.
    func waitForQueuedDelivery() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }
}
