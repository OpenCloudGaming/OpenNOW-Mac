import Foundation
import Testing
@testable import OpenNOW

/// The first automatic update check must clear the splash hold, capped at
/// `StartupReadiness.maximumTimeout`; firing inside it puts the GitHub request in the launch fetches.
@Test @MainActor func theFirstAutomaticUpdateCheckWaitsOutTheLaunchSplashHold() {
    let holdSeconds = Double(StartupReadiness.maximumTimeout.components.seconds)
    #expect(OPNAppDelegate.initialUpdateCheckDelaySeconds > holdSeconds)
}
