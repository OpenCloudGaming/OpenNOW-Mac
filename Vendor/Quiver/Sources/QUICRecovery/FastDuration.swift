/// Fast Duration Operations
///
/// Provides optimized duration arithmetic by avoiding the overhead of
/// Duration.components decomposition on every operation.
///
/// Use `FastDuration` for internal calculations where performance is critical,
/// then convert back to `Duration` for public APIs.

import Foundation

// MARK: - FastDuration

/// A high-performance duration type for internal calculations
///
/// `Duration` operations require decomposing into (seconds, attoseconds) components,
/// which adds overhead for repeated calculations. `FastDuration` stores nanoseconds
/// directly as `Int64`, enabling efficient arithmetic.
///
/// ## Usage
/// ```swift
/// let fast = FastDuration(duration)
/// let result = (fast * 7 + otherFast) / 8
/// return result.duration  // Convert back to Duration
/// ```
@usableFromInline
struct FastDuration: Sendable, Comparable {
    /// Duration in nanoseconds
    @usableFromInline
    let nanoseconds: Int64

    /// Creates a FastDuration from nanoseconds
    @inlinable
    init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a FastDuration from a Duration
    @inlinable
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self.nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    /// Converts back to Duration
    @inlinable
    var duration: Duration {
        .nanoseconds(nanoseconds)
    }

    /// Zero duration
    @inlinable
    static var zero: FastDuration {
        FastDuration(nanoseconds: 0)
    }

    // MARK: - Arithmetic

    @inlinable
    static func + (lhs: FastDuration, rhs: FastDuration) -> FastDuration {
        FastDuration(nanoseconds: lhs.nanoseconds + rhs.nanoseconds)
    }

    @inlinable
    static func - (lhs: FastDuration, rhs: FastDuration) -> FastDuration {
        FastDuration(nanoseconds: lhs.nanoseconds - rhs.nanoseconds)
    }

    @inlinable
    static func * (lhs: FastDuration, rhs: Int) -> FastDuration {
        FastDuration(nanoseconds: lhs.nanoseconds * Int64(rhs))
    }

    @inlinable
    static func * (lhs: Int, rhs: FastDuration) -> FastDuration {
        FastDuration(nanoseconds: Int64(lhs) * rhs.nanoseconds)
    }

    @inlinable
    static func / (lhs: FastDuration, rhs: Int) -> FastDuration {
        FastDuration(nanoseconds: lhs.nanoseconds / Int64(rhs))
    }

    // MARK: - Comparable

    @inlinable
    static func < (lhs: FastDuration, rhs: FastDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    @inlinable
    static func == (lhs: FastDuration, rhs: FastDuration) -> Bool {
        lhs.nanoseconds == rhs.nanoseconds
    }

    // MARK: - Utilities

    /// Absolute value
    @inlinable
    static func abs(_ duration: FastDuration) -> FastDuration {
        FastDuration(nanoseconds: Swift.abs(duration.nanoseconds))
    }

    /// Maximum of two durations
    @inlinable
    static func max(_ lhs: FastDuration, _ rhs: FastDuration) -> FastDuration {
        lhs.nanoseconds >= rhs.nanoseconds ? lhs : rhs
    }

    /// Minimum of two durations
    @inlinable
    static func min(_ lhs: FastDuration, _ rhs: FastDuration) -> FastDuration {
        lhs.nanoseconds <= rhs.nanoseconds ? lhs : rhs
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Converts to FastDuration for optimized calculations
    @inlinable
    var fast: FastDuration {
        FastDuration(self)
    }
}
