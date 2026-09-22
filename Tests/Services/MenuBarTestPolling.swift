import Foundation

/// Menu bar state moves with NotificationCenter delivery and a one-second elapsed-text clock, so a
/// single fixed sleep turns into a flake the moment the test process is loaded: the update lands
/// after the last sleep and the assertion reads stale state. Poll the model instead, and return the
/// moment it arrives.
@MainActor
func waitForMenuBarTransition(timeout: Duration = .seconds(4), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
