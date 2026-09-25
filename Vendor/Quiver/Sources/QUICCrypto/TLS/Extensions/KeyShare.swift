/// TLS 1.3 Key Share Extension (RFC 8446 Section 4.2.8)
///
/// In ClientHello:
/// ```
/// struct {
///     KeyShareEntry client_shares<0..2^16-1>;
/// } KeyShareClientHello;
/// ```
///
/// In ServerHello:
/// ```
/// struct {
///     KeyShareEntry server_share;
/// } KeyShareServerHello;
/// ```
///
/// KeyShareEntry:
/// ```
/// struct {
///     NamedGroup group;
///     opaque key_exchange<1..2^16-1>;
/// } KeyShareEntry;
/// ```

import Foundation

// MARK: - Key Share Entry

/// A key share entry containing a named group and public key
public struct KeyShareEntry: Sendable {
    /// The named group (curve) for this key share
    public let group: NamedGroup

    /// The public key bytes
    public let keyExchange: Data

    public init(group: NamedGroup, keyExchange: Data) {
        self.group = group
        self.keyExchange = keyExchange
    }

    public func encode() -> Data {
        var writer = TLSWriter(capacity: 4 + keyExchange.count)
        writer.writeUInt16(group.rawValue)
        writer.writeVector16(keyExchange)
        return writer.finish()
    }

    public static func decode(from reader: inout TLSReader) throws -> KeyShareEntry {
        let groupValue = try reader.readUInt16()
        guard let group = NamedGroup(rawValue: groupValue) else {
            throw TLSDecodeError.invalidFormat("Unknown named group: \(groupValue)")
        }
        let keyExchange = try reader.readVector16()
        return KeyShareEntry(group: group, keyExchange: keyExchange)
    }

    /// Try to decode a key share entry, returning nil for unrecognized named groups.
    /// This allows callers (e.g. ClientHello parsing) to skip post-quantum or other
    /// unknown key shares instead of treating them as fatal errors (RFC 8446 §4.2.8).
    public static func tryDecode(from reader: inout TLSReader) throws -> KeyShareEntry? {
        let groupValue = try reader.readUInt16()
        let keyExchange = try reader.readVector16()
        guard let group = NamedGroup(rawValue: groupValue) else {
            // Unknown group — skip this entry gracefully
            return nil
        }
        return KeyShareEntry(group: group, keyExchange: keyExchange)
    }
}

// MARK: - Key Share Extension (wrapper)

/// Key share extension (can be client or server variant)
public enum KeyShareExtension: Sendable, TLSExtensionValue {
    case clientHello(KeyShareClientHello)
    case serverHello(KeyShareServerHello)
    case helloRetryRequest(KeyShareHelloRetryRequest)

    public static var extensionType: TLSExtensionType { .keyShare }

    public func encode() -> Data {
        switch self {
        case .clientHello(let ext): return ext.encode()
        case .serverHello(let ext): return ext.encode()
        case .helloRetryRequest(let ext): return ext.encode()
        }
    }

    /// Decode - context determines which variant
    /// Note: Caller should use specific decode methods based on message type
    public static func decode(from data: Data) throws -> KeyShareExtension {
        // Default to ClientHello parsing (has 2-byte length prefix for list)
        // ServerHello has no length prefix, just group + key_exchange
        // HRR has just 2 bytes (NamedGroup)

        // Try to detect: if data starts with a valid 2-byte length that matches remaining,
        // it's likely ClientHello format
        if data.count >= 2 {
            let possibleLength = Int(data[0]) << 8 | Int(data[1])
            if possibleLength == data.count - 2 {
                return .clientHello(try KeyShareClientHello.decode(from: data))
            }
        }

        // If exactly 2 bytes, it's HelloRetryRequest format (just NamedGroup)
        if data.count == 2 {
            return .helloRetryRequest(try KeyShareHelloRetryRequest.decode(from: data))
        }

        // Otherwise assume ServerHello format (group + key_exchange)
        return .serverHello(try KeyShareServerHello.decode(from: data))
    }

    public static func decodeClientHello(from data: Data) throws -> KeyShareClientHello {
        try KeyShareClientHello.decode(from: data)
    }

    public static func decodeServerHello(from data: Data) throws -> KeyShareServerHello {
        try KeyShareServerHello.decode(from: data)
    }
}

// MARK: - Client Hello Variant

/// Key share extension for ClientHello
public struct KeyShareClientHello: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .keyShare }

    /// List of key shares offered by the client
    public let clientShares: [KeyShareEntry]

    public init(clientShares: [KeyShareEntry]) {
        self.clientShares = clientShares
    }

    public func encode() -> Data {
        var entriesData = Data()
        for entry in clientShares {
            entriesData.append(entry.encode())
        }

        var writer = TLSWriter(capacity: 2 + entriesData.count)
        writer.writeVector16(entriesData)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> KeyShareClientHello {
        var reader = TLSReader(data: data)
        let entriesData = try reader.readVector16()

        var entries: [KeyShareEntry] = []
        var entryReader = TLSReader(data: entriesData)
        while entryReader.hasMore {
            // Use tryDecode to skip key shares for unrecognized groups (e.g. post-quantum
            // hybrid groups like X25519Kyber768) instead of failing the entire handshake.
            if let entry = try KeyShareEntry.tryDecode(from: &entryReader) {
                entries.append(entry)
            }
        }

        return KeyShareClientHello(clientShares: entries)
    }

    /// Find a key share for a specific group
    public func keyShare(for group: NamedGroup) -> KeyShareEntry? {
        clientShares.first { $0.group == group }
    }
}

// MARK: - Server Hello Variant

/// Key share extension for ServerHello
public struct KeyShareServerHello: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .keyShare }

    /// The server's selected key share
    public let serverShare: KeyShareEntry

    public init(serverShare: KeyShareEntry) {
        self.serverShare = serverShare
    }

    public func encode() -> Data {
        serverShare.encode()
    }

    public static func decode(from data: Data) throws -> KeyShareServerHello {
        var reader = TLSReader(data: data)
        let entry = try KeyShareEntry.decode(from: &reader)
        return KeyShareServerHello(serverShare: entry)
    }
}

// MARK: - Hello Retry Request Variant

/// Key share extension for HelloRetryRequest (only contains selected group)
public struct KeyShareHelloRetryRequest: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .keyShare }

    /// The group the server wants the client to use
    public let selectedGroup: NamedGroup

    public init(selectedGroup: NamedGroup) {
        self.selectedGroup = selectedGroup
    }

    public func encode() -> Data {
        var writer = TLSWriter(capacity: 2)
        writer.writeUInt16(selectedGroup.rawValue)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> KeyShareHelloRetryRequest {
        var reader = TLSReader(data: data)
        let groupValue = try reader.readUInt16()
        guard let group = NamedGroup(rawValue: groupValue) else {
            throw TLSDecodeError.invalidFormat("Unknown named group: \(groupValue)")
        }
        return KeyShareHelloRetryRequest(selectedGroup: group)
    }
}
