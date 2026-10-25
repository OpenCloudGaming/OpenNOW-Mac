import Foundation

/// The vendor's patching record for one variant. Its published completion time is the only freshness
/// signal the record carries, and a record past its own ETA is what kept a playable title blocked.
public enum CatalogPatchRecord {
    /// The completion time the vendor published, or nil when it sent none this can read. Parsed once
    /// per payload: availability is read per card per render, so it must not parse there.
    public static func completionDate(from endTime: String) -> Date? {
        let trimmed = endTime.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = Self.fractionalSecondsFormatter.date(from: trimmed) { return date }
        return Self.internetDateTimeFormatter.date(from: trimmed)
    }

    /// Whether a completion time has passed. No time is "no signal" rather than an elapsed one, so a
    /// malformed payload cannot unblock a real patch.
    public static func isElapsed(completion: Date?, now: Date = Date()) -> Bool {
        guard let completion else { return false }
        return completion <= now
    }

    public static func isElapsed(endTime: String, now: Date = Date()) -> Bool {
        isElapsed(completion: completionDate(from: endTime), now: now)
    }

    /// The completion time as the reader sees it, or empty when there is none. The vendor's raw ISO
    /// string reads as a database timestamp.
    public static func completionText(endTime: String) -> String {
        guard let completion = completionDate(from: endTime) else { return "" }
        return completion.formatted(date: .abbreviated, time: .shortened)
    }

    // ISO8601DateFormatter is not Sendable, but these instances only ever parse; formatter parsing
    // is documented thread-safe since macOS 10.9, so a shared read-only instance cannot race.
    private nonisolated(unsafe) static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let internetDateTimeFormatter = ISO8601DateFormatter()
}
