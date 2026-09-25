/// Safe Integer Conversion Utilities for QUIC
///
/// Provides safe conversion methods for untrusted network data.
/// Prevents integer overflow and enforces protocol limits.
///
/// RFC 9000 does not specify maximum values for many length fields,
/// but practical limits are necessary to prevent memory exhaustion
/// and integer overflow attacks.

import Foundation

/// Safe integer conversion utilities for parsing untrusted network data
public enum SafeConversions {

    /// Converts UInt64 to Int with overflow checking
    ///
    /// - Parameter value: The UInt64 value to convert
    /// - Returns: The value as Int
    /// - Throws: `ConversionError.overflow` if value exceeds Int.max
    ///
    /// Use this for network data that doesn't have a specific protocol limit,
    /// but must fit in an Int for array indexing or Data operations.
    @inlinable
    public static func toInt(_ value: UInt64) throws(ConversionError) -> Int {
        guard value <= UInt64(Int.max) else {
            throw ConversionError.overflow(value: value, targetType: "Int")
        }
        return Int(value)
    }

    /// Converts UInt64 to Int with protocol limit enforcement
    ///
    /// - Parameters:
    ///   - value: The UInt64 value to convert
    ///   - limit: Maximum allowed value (protocol-defined limit)
    ///   - context: Description of what this value represents (for error messages)
    /// - Returns: The value as Int
    /// - Throws: `ConversionError.exceedsLimit` if value exceeds the limit
    ///
    /// Prefer this over `toInt(_:)` when a protocol limit is known.
    /// This provides better error messages and enforces RFC compliance.
    @inlinable
    public static func toInt(
        _ value: UInt64,
        maxAllowed limit: Int,
        context: String
    ) throws(ConversionError) -> Int {
        guard value <= UInt64(limit) else {
            throw ConversionError.exceedsLimit(
                value: value,
                limit: limit,
                context: context
            )
        }
        return Int(value)
    }

    /// Safely subtracts two Int values with underflow checking
    ///
    /// - Parameters:
    ///   - a: The minuend
    ///   - b: The subtrahend
    /// - Returns: a - b
    /// - Throws: `ConversionError.underflow` if b > a
    ///
    /// Use this when computing lengths or offsets from untrusted data
    /// where a negative result would be invalid.
    @inlinable
    public static func subtract(_ a: Int, _ b: Int) throws(ConversionError) -> Int {
        guard a >= b else {
            throw ConversionError.underflow(minuend: a, subtrahend: b)
        }
        return a - b
    }

    /// Safely subtracts with underflow checking, returning zero on underflow
    ///
    /// - Parameters:
    ///   - a: The minuend
    ///   - b: The subtrahend
    /// - Returns: max(0, a - b)
    ///
    /// Use this when underflow should clamp to zero rather than throw.
    /// Useful for flow control calculations where negative values are meaningless.
    @inlinable
    public static func saturatingSubtract(_ a: Int, _ b: Int) -> Int {
        return max(0, a - b)
    }

    /// Safely adds two Int values with overflow checking
    ///
    /// - Parameters:
    ///   - a: First operand
    ///   - b: Second operand
    /// - Returns: a + b
    /// - Throws: `ConversionError.additionOverflow` if result exceeds Int.max
    @inlinable
    public static func add(_ a: Int, _ b: Int) throws(ConversionError) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else {
            throw ConversionError.additionOverflow(a: a, b: b)
        }
        return result
    }
}

/// Errors that can occur during safe conversions
public enum ConversionError: Error, Sendable, Equatable {
    /// Value exceeds Int.max and cannot be safely converted
    case overflow(value: UInt64, targetType: String)

    /// Value exceeds the protocol-defined limit
    case exceedsLimit(value: UInt64, limit: Int, context: String)

    /// Subtraction would result in a negative value
    case underflow(minuend: Int, subtrahend: Int)

    /// Addition would overflow Int.max
    case additionOverflow(a: Int, b: Int)
}

// MARK: - CustomStringConvertible

extension ConversionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .overflow(let value, let targetType):
            return "Integer overflow: \(value) exceeds \(targetType).max"

        case .exceedsLimit(let value, let limit, let context):
            return "\(context): \(value) exceeds maximum allowed value \(limit)"

        case .underflow(let minuend, let subtrahend):
            return "Integer underflow: \(minuend) - \(subtrahend) would be negative"

        case .additionOverflow(let a, let b):
            return "Integer overflow: \(a) + \(b) exceeds Int.max"
        }
    }
}
