import Foundation

/// A vendor-shaped ISO-8601 instant relative to now. The completion time a patch record carries is
/// what decides whether it still asserts a patch, so the tests move around it rather than the clock.
func vendorTimestamp(secondsFromNow seconds: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
}
