/// Priority Header Parser
///
/// Parser for the RFC 9218 Priority header field value.
/// Extracted from StreamScheduler.swift for file size reduction.

import Foundation

// MARK: - RFC 9218 Priority Header Parsing

/// Parser for the RFC 9218 Priority header field value.
///
/// The Priority header uses the Structured Fields syntax (RFC 8941) in
/// Dictionary form. It supports the following parameters:
///
/// - `u` (urgency): Integer 0-7, default 3. Lower is higher priority.
/// - `i` (incremental): Boolean, default false. Whether the response
///   benefits from incremental delivery.
///
/// ## Wire Format
///
/// ```
/// Priority: u=3, i
/// Priority: u=0
/// Priority: i
/// Priority: u=7, i=?0
/// ```
///
/// ## Usage
///
/// ```swift
/// let priority = PriorityHeaderParser.parse("u=1, i")
/// // StreamPriority(urgency: 1, incremental: true)
///
/// let defaultPriority = PriorityHeaderParser.parse(nil)
/// // StreamPriority(urgency: 3, incremental: false) — the default
/// ```
public enum PriorityHeaderParser {

    /// Parses an RFC 9218 Priority header field value into a StreamPriority.
    ///
    /// If the header value is nil or empty, returns the default priority
    /// (urgency=3, incremental=false) per RFC 9218 Section 4.
    ///
    /// Unknown parameters are ignored per RFC 9218 Section 4.
    ///
    /// - Parameter headerValue: The raw Priority header field value
    /// - Returns: The parsed StreamPriority
    public static func parse(_ headerValue: String?) -> StreamPriority {
        guard let value = headerValue, !value.isEmpty else {
            return .default
        }

        var urgency: UInt8 = 3
        var incremental: Bool = false

        // Split on commas to get individual parameters
        let parameters = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        for param in parameters {
            if param.hasPrefix("u=") {
                // Parse urgency value
                let valueStr = String(param.dropFirst(2))
                if let parsed = UInt8(valueStr), parsed <= 7 {
                    urgency = parsed
                }
                // Invalid urgency values are ignored (use default)
            } else if param == "i" || param == "i=?1" {
                // Boolean true in Structured Fields syntax
                incremental = true
            } else if param == "i=?0" {
                // Boolean false in Structured Fields syntax
                incremental = false
            }
            // Unknown parameters are silently ignored per RFC 9218
        }

        return StreamPriority(urgency: urgency, incremental: incremental)
    }

    /// Serializes a StreamPriority into an RFC 9218 Priority header field value.
    ///
    /// Only includes parameters that differ from the defaults:
    /// - `u` is omitted if urgency == 3 (the default)
    /// - `i` is omitted if incremental == false (the default)
    ///
    /// - Parameter priority: The priority to serialize
    /// - Returns: The Priority header field value string
    public static func serialize(_ priority: StreamPriority) -> String {
        var parts: [String] = []

        if priority.urgency != 3 {
            parts.append("u=\(priority.urgency)")
        }

        if priority.incremental {
            parts.append("i")
        }

        if parts.isEmpty {
            // All defaults — return minimal representation
            // An empty value is technically valid, but some implementations
            // prefer at least one parameter, so we include the default urgency.
            return "u=3"
        }

        return parts.joined(separator: ", ")
    }
}