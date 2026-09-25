/// Stream Priority (RFC 9218)
///
/// Defines priority parameters for QUIC stream scheduling.
/// Based on the HTTP/3 Extensible Priority Scheme.

import Foundation

/// Priority parameters for stream scheduling
///
/// Streams with lower urgency values are scheduled before streams with higher values.
/// The `incremental` flag indicates whether the stream benefits from incremental delivery.
///
/// ## RFC 9218 Alignment
/// - `urgency`: Maps to RFC 9218 "u" parameter (0-7, default 3)
/// - `incremental`: Maps to RFC 9218 "i" parameter (default false)
///
/// ## Usage
/// ```swift
/// // High priority, non-incremental (e.g., critical resources)
/// let high = StreamPriority.highest
///
/// // Default priority
/// let normal = StreamPriority.default
///
/// // Low priority, incremental (e.g., background streaming)
/// let background = StreamPriority(urgency: 6, incremental: true)
/// ```
public struct StreamPriority: Sendable, Hashable, Comparable {
    /// Urgency level (0 = highest priority, 7 = lowest priority)
    ///
    /// RFC 9218 defines urgency as an integer from 0 to 7, inclusive,
    /// in descending order of priority.
    public let urgency: UInt8

    /// Whether the stream benefits from incremental delivery
    ///
    /// When true, indicates that the response can be processed incrementally
    /// (e.g., progressive rendering, streaming media).
    public let incremental: Bool

    /// Creates a new StreamPriority
    /// - Parameters:
    ///   - urgency: Priority level (0-7, where 0 is highest). Clamped to valid range.
    ///   - incremental: Whether incremental delivery is beneficial
    public init(urgency: UInt8, incremental: Bool = false) {
        self.urgency = min(urgency, 7)
        self.incremental = incremental
    }

    // MARK: - Predefined Priorities

    /// Highest priority (urgency 0)
    ///
    /// Use for critical resources that should be delivered first.
    public static let highest = StreamPriority(urgency: 0, incremental: false)

    /// High priority (urgency 1)
    public static let high = StreamPriority(urgency: 1, incremental: false)

    /// Default priority (urgency 3)
    ///
    /// RFC 9218 specifies urgency 3 as the default.
    public static let `default` = StreamPriority(urgency: 3, incremental: false)

    /// Low priority (urgency 5)
    public static let low = StreamPriority(urgency: 5, incremental: false)

    /// Lowest priority (urgency 7)
    ///
    /// Use for background tasks that can be deferred.
    public static let lowest = StreamPriority(urgency: 7, incremental: false)

    /// Background priority with incremental delivery
    ///
    /// Suitable for streaming content that can be processed progressively.
    public static let background = StreamPriority(urgency: 7, incremental: true)

    // MARK: - Comparable

    /// Compares priorities based on urgency
    ///
    /// Lower urgency values are considered higher priority (come first in ordering).
    /// When urgency is equal, non-incremental streams are prioritized.
    public static func < (lhs: StreamPriority, rhs: StreamPriority) -> Bool {
        if lhs.urgency != rhs.urgency {
            return lhs.urgency < rhs.urgency
        }
        // Same urgency: non-incremental before incremental
        return !lhs.incremental && rhs.incremental
    }
}

// MARK: - CustomStringConvertible

extension StreamPriority: CustomStringConvertible {
    public var description: String {
        "StreamPriority(u=\(urgency), i=\(incremental))"
    }
}
