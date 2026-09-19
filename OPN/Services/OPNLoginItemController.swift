import Foundation
import ServiceManagement

/// The app's own login item, as `SMAppService` sees it.
///
/// Registering the main app is the modern replacement for the deprecated `SMLoginItemSetEnabled`, and
/// needs no helper bundle. `status` is the system's answer, not the stored preference: a user who
/// removes the item in System Settings, or whose registration is waiting for approval, is reflected
/// here.
enum OPNLoginItemController {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        case .notRegistered, .notFound: return false
        @unknown default: return false
        }
    }

    /// Whether the system has the item registered but still needs the user to approve it in System
    /// Settings before it will run at login.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the app, returning the intent so the settings toggle shows what was
    /// asked for. Registration is best-effort: a signing or consent failure is logged and leaves the
    /// preference unchanged, rather than presenting a crash.
    @discardableResult
    static func setEnabled(_ isEnabled: Bool) -> Bool {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            OPNLog.info(.app, "Login item \(isEnabled ? "registered" : "unregistered")")
        } catch {
            OPNLog.error(.app, "Login item \(isEnabled ? "registration" : "unregistration") failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
