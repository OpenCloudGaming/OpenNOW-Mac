/// QPACK Static Table (RFC 9204 Appendix A)
///
/// The QPACK static table consists of 99 predefined header field entries
/// that are always available for reference. These entries represent the
/// most commonly used HTTP header fields and their values.
///
/// Unlike HPACK's static table (RFC 7541), the QPACK static table uses
/// 0-based indexing and contains entries specifically chosen for HTTP/3.
///
/// ## Usage
///
/// ```swift
/// // Look up an entry by index
/// let entry = QPACKStaticTable.entry(at: 0)
/// // entry.name == ":authority", entry.value == ""
///
/// // Find exact name+value match
/// if let index = QPACKStaticTable.findExact(name: ":method", value: "GET") {
///     // index == 17
/// }
///
/// // Find name-only match
/// if let index = QPACKStaticTable.findName("content-type") {
///     // index == 44
/// }
/// ```

import Foundation

// MARK: - Static Table Entry

/// A single entry in the QPACK static table
public struct QPACKStaticTableEntry: Sendable, Hashable {
    /// The header field name (lowercase)
    public let name: String

    /// The header field value (may be empty)
    public let value: String

    /// Creates a static table entry
    @inlinable
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

// MARK: - Static Table

/// The QPACK static table (RFC 9204 Appendix A)
///
/// This table contains 99 entries (indices 0-98) of commonly used
/// HTTP header field name-value pairs. Entries with empty values
/// represent header names that are frequently used with varying values.
///
/// The table is designed for HTTP/3 and differs from the HPACK static
/// table used in HTTP/2.
public enum QPACKStaticTable {

    /// The number of entries in the static table
    public static let count = 99

    // MARK: - Lookup

    /// Returns the static table entry at the given index.
    ///
    /// - Parameter index: The 0-based index (0...98)
    /// - Returns: The static table entry, or nil if the index is out of range
    @inlinable
    public static func entry(at index: Int) -> QPACKStaticTableEntry? {
        guard index >= 0 && index < entries.count else {
            return nil
        }
        return entries[index]
    }

    /// Finds the index of an exact name+value match in the static table.
    ///
    /// - Parameters:
    ///   - name: The header field name (case-insensitive for matching)
    ///   - value: The header field value (case-sensitive)
    /// - Returns: The 0-based index, or nil if no exact match is found
    ///
    /// ## Complexity
    ///
    /// O(1) amortized using the pre-built lookup dictionary.
    public static func findExact(name: String, value: String) -> Int? {
        let lowercaseName = name.lowercased()
        return exactMatchIndex[ExactMatchKey(name: lowercaseName, value: value)]
    }

    /// Finds the index of a name-only match in the static table.
    ///
    /// When multiple entries share the same name, the first (lowest index)
    /// is returned. This is useful for "Literal Field Line With Name Reference"
    /// encoding where only the name is referenced from the table.
    ///
    /// - Parameter name: The header field name (case-insensitive)
    /// - Returns: The 0-based index of the first entry with this name, or nil
    ///
    /// ## Complexity
    ///
    /// O(1) amortized using the pre-built lookup dictionary.
    public static func findName(_ name: String) -> Int? {
        return nameMatchIndex[name.lowercased()]
    }

    /// Finds the best match for a header field in the static table.
    ///
    /// Prefers an exact (name+value) match. Falls back to a name-only match.
    ///
    /// - Parameters:
    ///   - name: The header field name
    ///   - value: The header field value
    /// - Returns: A tuple of (index, isExactMatch), or nil if no match at all
    public static func findBestMatch(name: String, value: String) -> (index: Int, isExactMatch: Bool)? {
        let lowercaseName = name.lowercased()

        // Try exact match first
        if let index = exactMatchIndex[ExactMatchKey(name: lowercaseName, value: value)] {
            return (index, true)
        }

        // Fall back to name-only match
        if let index = nameMatchIndex[lowercaseName] {
            return (index, false)
        }

        return nil
    }

    // MARK: - Lookup Indices (pre-built for O(1) access)

    /// Key for exact name+value lookup
    private struct ExactMatchKey: Hashable {
        let name: String
        let value: String
    }

    /// Pre-built index: (name, value) → table index
    private static let exactMatchIndex: [ExactMatchKey: Int] = {
        var dict = [ExactMatchKey: Int]()
        dict.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let key = ExactMatchKey(name: entry.name, value: entry.value)
            // First occurrence wins (lower index preferred)
            if dict[key] == nil {
                dict[key] = index
            }
        }
        return dict
    }()

    /// Pre-built index: name → first table index with that name
    private static let nameMatchIndex: [String: Int] = {
        var dict = [String: Int]()
        dict.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            // First occurrence wins (lower index preferred)
            if dict[entry.name] == nil {
                dict[entry.name] = index
            }
        }
        return dict
    }()

    // MARK: - Table Data

    /// All 99 static table entries (RFC 9204 Appendix A)
    ///
    /// Index assignments follow RFC 9204 exactly:
    /// - Indices 0-14: Pseudo-headers and common request headers
    /// - Indices 15-71: Common header field name-value pairs
    /// - Indices 72-98: Additional common header names with empty values
    public static let entries: [QPACKStaticTableEntry] = [
        // 0
        QPACKStaticTableEntry(name: ":authority", value: ""),
        // 1
        QPACKStaticTableEntry(name: ":path", value: "/"),
        // 2
        QPACKStaticTableEntry(name: "age", value: "0"),
        // 3
        QPACKStaticTableEntry(name: "content-disposition", value: ""),
        // 4
        QPACKStaticTableEntry(name: "content-length", value: "0"),
        // 5
        QPACKStaticTableEntry(name: "cookie", value: ""),
        // 6
        QPACKStaticTableEntry(name: "date", value: ""),
        // 7
        QPACKStaticTableEntry(name: "etag", value: ""),
        // 8
        QPACKStaticTableEntry(name: "if-modified-since", value: ""),
        // 9
        QPACKStaticTableEntry(name: "if-none-match", value: ""),
        // 10
        QPACKStaticTableEntry(name: "last-modified", value: ""),
        // 11
        QPACKStaticTableEntry(name: "link", value: ""),
        // 12
        QPACKStaticTableEntry(name: "location", value: ""),
        // 13
        QPACKStaticTableEntry(name: "referer", value: ""),
        // 14
        QPACKStaticTableEntry(name: "set-cookie", value: ""),
        // 15
        QPACKStaticTableEntry(name: ":method", value: "CONNECT"),
        // 16
        QPACKStaticTableEntry(name: ":method", value: "DELETE"),
        // 17
        QPACKStaticTableEntry(name: ":method", value: "GET"),
        // 18
        QPACKStaticTableEntry(name: ":method", value: "HEAD"),
        // 19
        QPACKStaticTableEntry(name: ":method", value: "OPTIONS"),
        // 20
        QPACKStaticTableEntry(name: ":method", value: "POST"),
        // 21
        QPACKStaticTableEntry(name: ":method", value: "PUT"),
        // 22
        QPACKStaticTableEntry(name: ":scheme", value: "http"),
        // 23
        QPACKStaticTableEntry(name: ":scheme", value: "https"),
        // 24
        QPACKStaticTableEntry(name: ":status", value: "103"),
        // 25
        QPACKStaticTableEntry(name: ":status", value: "200"),
        // 26
        QPACKStaticTableEntry(name: ":status", value: "304"),
        // 27
        QPACKStaticTableEntry(name: ":status", value: "404"),
        // 28
        QPACKStaticTableEntry(name: ":status", value: "503"),
        // 29
        QPACKStaticTableEntry(name: "accept", value: "*/*"),
        // 30
        QPACKStaticTableEntry(name: "accept", value: "application/dns-message"),
        // 31
        QPACKStaticTableEntry(name: "accept-encoding", value: "gzip, deflate, br"),
        // 32
        QPACKStaticTableEntry(name: "accept-ranges", value: "bytes"),
        // 33
        QPACKStaticTableEntry(name: "access-control-allow-headers", value: "cache-control"),
        // 34
        QPACKStaticTableEntry(name: "access-control-allow-headers", value: "content-type"),
        // 35
        QPACKStaticTableEntry(name: "access-control-allow-origin", value: "*"),
        // 36
        QPACKStaticTableEntry(name: "cache-control", value: "max-age=0"),
        // 37
        QPACKStaticTableEntry(name: "cache-control", value: "max-age=2592000"),
        // 38
        QPACKStaticTableEntry(name: "cache-control", value: "max-age=604800"),
        // 39
        QPACKStaticTableEntry(name: "cache-control", value: "no-cache"),
        // 40
        QPACKStaticTableEntry(name: "cache-control", value: "no-store"),
        // 41
        QPACKStaticTableEntry(name: "cache-control", value: "public, max-age=31536000"),
        // 42
        QPACKStaticTableEntry(name: "content-encoding", value: "br"),
        // 43
        QPACKStaticTableEntry(name: "content-encoding", value: "gzip"),
        // 44
        QPACKStaticTableEntry(name: "content-type", value: "application/dns-message"),
        // 45
        QPACKStaticTableEntry(name: "content-type", value: "application/javascript"),
        // 46
        QPACKStaticTableEntry(name: "content-type", value: "application/json"),
        // 47
        QPACKStaticTableEntry(name: "content-type", value: "application/x-www-form-urlencoded"),
        // 48
        QPACKStaticTableEntry(name: "content-type", value: "image/gif"),
        // 49
        QPACKStaticTableEntry(name: "content-type", value: "image/jpeg"),
        // 50
        QPACKStaticTableEntry(name: "content-type", value: "image/png"),
        // 51
        QPACKStaticTableEntry(name: "content-type", value: "text/css"),
        // 52
        QPACKStaticTableEntry(name: "content-type", value: "text/html; charset=utf-8"),
        // 53
        QPACKStaticTableEntry(name: "content-type", value: "text/plain"),
        // 54
        QPACKStaticTableEntry(name: "content-type", value: "text/plain;charset=utf-8"),
        // 55
        QPACKStaticTableEntry(name: "range", value: "bytes=0-"),
        // 56
        QPACKStaticTableEntry(name: "strict-transport-security", value: "max-age=31536000"),
        // 57
        QPACKStaticTableEntry(name: "strict-transport-security", value: "max-age=31536000; includesubdomains"),
        // 58
        QPACKStaticTableEntry(name: "strict-transport-security", value: "max-age=31536000; includesubdomains; preload"),
        // 59
        QPACKStaticTableEntry(name: "vary", value: "accept-encoding"),
        // 60
        QPACKStaticTableEntry(name: "vary", value: "origin"),
        // 61
        QPACKStaticTableEntry(name: "x-content-type-options", value: "nosniff"),
        // 62
        QPACKStaticTableEntry(name: "x-xss-protection", value: "1; mode=block"),
        // 63
        QPACKStaticTableEntry(name: ":status", value: "100"),
        // 64
        QPACKStaticTableEntry(name: ":status", value: "204"),
        // 65
        QPACKStaticTableEntry(name: ":status", value: "206"),
        // 66
        QPACKStaticTableEntry(name: ":status", value: "302"),
        // 67
        QPACKStaticTableEntry(name: ":status", value: "400"),
        // 68
        QPACKStaticTableEntry(name: ":status", value: "403"),
        // 69
        QPACKStaticTableEntry(name: ":status", value: "421"),
        // 70
        QPACKStaticTableEntry(name: ":status", value: "425"),
        // 71
        QPACKStaticTableEntry(name: ":status", value: "500"),
        // 72
        QPACKStaticTableEntry(name: "accept-language", value: ""),
        // 73
        QPACKStaticTableEntry(name: "access-control-allow-credentials", value: "FALSE"),
        // 74
        QPACKStaticTableEntry(name: "access-control-allow-credentials", value: "TRUE"),
        // 75
        QPACKStaticTableEntry(name: "access-control-allow-headers", value: "*"),
        // 76
        QPACKStaticTableEntry(name: "access-control-allow-methods", value: "get"),
        // 77
        QPACKStaticTableEntry(name: "access-control-allow-methods", value: "get, post, options"),
        // 78
        QPACKStaticTableEntry(name: "access-control-allow-methods", value: "options"),
        // 79
        QPACKStaticTableEntry(name: "access-control-expose-headers", value: "content-length"),
        // 80
        QPACKStaticTableEntry(name: "access-control-request-headers", value: "content-type"),
        // 81
        QPACKStaticTableEntry(name: "access-control-request-method", value: "get"),
        // 82
        QPACKStaticTableEntry(name: "access-control-request-method", value: "post"),
        // 83
        QPACKStaticTableEntry(name: "alt-svc", value: "clear"),
        // 84
        QPACKStaticTableEntry(name: "authorization", value: ""),
        // 85
        QPACKStaticTableEntry(name: "content-security-policy", value: "script-src 'none'; object-src 'none'; base-uri 'none'"),
        // 86
        QPACKStaticTableEntry(name: "early-data", value: "1"),
        // 87
        QPACKStaticTableEntry(name: "expect-ct", value: ""),
        // 88
        QPACKStaticTableEntry(name: "forwarded", value: ""),
        // 89
        QPACKStaticTableEntry(name: "if-range", value: ""),
        // 90
        QPACKStaticTableEntry(name: "origin", value: ""),
        // 91
        QPACKStaticTableEntry(name: "purpose", value: "prefetch"),
        // 92
        QPACKStaticTableEntry(name: "server", value: ""),
        // 93
        QPACKStaticTableEntry(name: "timing-allow-origin", value: "*"),
        // 94
        QPACKStaticTableEntry(name: "upgrade-insecure-requests", value: "1"),
        // 95
        QPACKStaticTableEntry(name: "user-agent", value: ""),
        // 96
        QPACKStaticTableEntry(name: "x-forwarded-for", value: ""),
        // 97
        QPACKStaticTableEntry(name: "x-frame-options", value: "deny"),
        // 98
        QPACKStaticTableEntry(name: "x-frame-options", value: "sameorigin"),
    ]
}

// MARK: - CustomStringConvertible

extension QPACKStaticTableEntry: CustomStringConvertible {
    public var description: String {
        if value.isEmpty {
            return "\(name): (empty)"
        }
        return "\(name): \(value)"
    }
}