import Foundation
import Testing
@testable import OpenNOW

/// The first automatic update check used to fire at +5 s, inside the launch splash hold, which is
/// capped at `StartupReadiness.maximumTimeout`. That put its GitHub request in the middle of the
/// catalog and login fetches the delay exists to avoid. The delay has to stay clear of the hold;
/// dropping it back under the cap reintroduces the contention the hold exists to measure.
@Test @MainActor func theFirstAutomaticUpdateCheckWaitsOutTheLaunchSplashHold() {
    let holdSeconds = Double(StartupReadiness.maximumTimeout.components.seconds)
    #expect(OPNAppDelegate.initialUpdateCheckDelaySeconds > holdSeconds)
}
