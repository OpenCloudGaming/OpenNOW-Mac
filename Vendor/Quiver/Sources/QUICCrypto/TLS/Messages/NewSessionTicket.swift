/// TLS 1.3 NewSessionTicket Message (RFC 8446 Section 4.6.1)
///
/// ```
/// struct {
///     uint32 ticket_lifetime;
///     uint32 ticket_age_add;
///     opaque ticket_nonce<0..255>;
///     opaque ticket<1..2^16-1>;
///     Extension extensions<0..2^16-2>;
/// } NewSessionTicket;
/// ```
///
/// The server sends this message after the handshake to establish
/// a PSK that can be used for session resumption.

import Foundation

// MARK: - NewSessionTicket Message

/// TLS 1.3 NewSessionTicket message for session resumption
public struct NewSessionTicket: Sendable {
    /// Ticket lifetime in seconds (max: 604800 = 7 days)
    public let ticketLifetime: UInt32

    /// Random value added to ticket age to obscure real age
    public let ticketAgeAdd: UInt32

    /// Per-ticket nonce for PSK derivation
    public let ticketNonce: Data

    /// The ticket value (opaque to client)
    public let ticket: Data

    /// Extensions (e.g., early_data max size)
    public let extensions: [TLSExtension]

    /// Maximum ticket lifetime (7 days)
    public static let maxLifetime: UInt32 = 604800

    // MARK: - Initialization

    public init(
        ticketLifetime: UInt32,
        ticketAgeAdd: UInt32,
        ticketNonce: Data,
        ticket: Data,
        extensions: [TLSExtension] = []
    ) {
        self.ticketLifetime = min(ticketLifetime, Self.maxLifetime)
        self.ticketAgeAdd = ticketAgeAdd
        self.ticketNonce = ticketNonce
        self.ticket = ticket
        self.extensions = extensions
    }

    // MARK: - Encoding

    /// Encode the message content (without handshake header)
    public func encode() -> Data {
        var writer = TLSWriter(capacity: 256)

        // ticket_lifetime (4 bytes)
        writer.writeUInt32(ticketLifetime)

        // ticket_age_add (4 bytes)
        writer.writeUInt32(ticketAgeAdd)

        // ticket_nonce<0..255>
        writer.writeVector8(ticketNonce)

        // ticket<1..2^16-1>
        writer.writeVector16(ticket)

        // extensions<0..2^16-2>
        var extensionsData = Data()
        for ext in extensions {
            extensionsData.append(ext.encode())
        }
        writer.writeVector16(extensionsData)

        return writer.finish()
    }

    /// Encode as complete handshake message
    public func encodeMessage() -> Data {
        let content = encode()
        return HandshakeCodec.encode(type: .newSessionTicket, content: content)
    }

    // MARK: - Decoding

    /// Decode from message content (without handshake header)
    public static func decode(from data: Data) throws -> NewSessionTicket {
        var reader = TLSReader(data: data)

        // ticket_lifetime
        let ticketLifetime = try reader.readUInt32()

        // ticket_age_add
        let ticketAgeAdd = try reader.readUInt32()

        // ticket_nonce
        let ticketNonce = try reader.readVector8()

        // ticket
        let ticket = try reader.readVector16()
        guard !ticket.isEmpty else {
            throw TLSDecodeError.invalidFormat("NewSessionTicket: ticket must not be empty")
        }

        // extensions (use NewSessionTicket-specific decoding for early_data)
        var extensions: [TLSExtension] = []
        let extensionsData = try reader.readVector16()
        if !extensionsData.isEmpty {
            var extReader = TLSReader(data: extensionsData)
            while extReader.hasMore {
                let ext = try TLSExtension.decodeForNewSessionTicket(from: &extReader)
                extensions.append(ext)
            }
        }

        return NewSessionTicket(
            ticketLifetime: ticketLifetime,
            ticketAgeAdd: ticketAgeAdd,
            ticketNonce: ticketNonce,
            ticket: ticket,
            extensions: extensions
        )
    }
}

// MARK: - Session Ticket Data

/// Stored session ticket for resumption
public struct SessionTicketData: Sendable {
    /// The ticket value to send to server
    public let ticket: Data

    /// Resumption PSK derived from resumption_master_secret
    public let resumptionPSK: Data

    /// Maximum early data size (0 if not supported)
    public let maxEarlyDataSize: UInt32

    /// Ticket age add value (for obfuscation)
    public let ticketAgeAdd: UInt32

    /// Time when ticket was received
    public let receiveTime: Date

    /// Ticket lifetime in seconds
    public let lifetime: UInt32

    /// The cipher suite used in the original connection
    public let cipherSuite: CipherSuite

    /// Server name for this ticket (for matching)
    public let serverName: String?

    /// ALPN protocol used
    public let alpn: String?

    // MARK: - Initialization

    public init(
        ticket: Data,
        resumptionPSK: Data,
        maxEarlyDataSize: UInt32 = 0,
        ticketAgeAdd: UInt32,
        receiveTime: Date = Date(),
        lifetime: UInt32,
        cipherSuite: CipherSuite,
        serverName: String? = nil,
        alpn: String? = nil
    ) {
        self.ticket = ticket
        self.resumptionPSK = resumptionPSK
        self.maxEarlyDataSize = maxEarlyDataSize
        self.ticketAgeAdd = ticketAgeAdd
        self.receiveTime = receiveTime
        self.lifetime = lifetime
        self.cipherSuite = cipherSuite
        self.serverName = serverName
        self.alpn = alpn
    }

    // MARK: - Validity

    /// Check if the ticket is still valid
    public func isValid(at date: Date = Date()) -> Bool {
        let elapsed = date.timeIntervalSince(receiveTime)
        return elapsed >= 0 && elapsed < Double(lifetime)
    }

    /// Get obfuscated ticket age for pre_shared_key extension
    /// - Parameter now: Current time
    /// - Returns: Obfuscated age in milliseconds
    public func obfuscatedAge(at now: Date = Date()) -> UInt32 {
        let ageMs = UInt32(now.timeIntervalSince(receiveTime) * 1000)
        // Add ticketAgeAdd with wrapping to obfuscate
        return ageMs &+ ticketAgeAdd
    }
}

// MARK: - Early Data Extension in NewSessionTicket

/// Early data indication extension (RFC 8446 Section 4.2.10)
/// When present in NewSessionTicket, contains max_early_data_size.
public struct EarlyDataIndication: Sendable {
    /// Maximum size of early data (in bytes)
    /// Only present in NewSessionTicket, not in ClientHello/EncryptedExtensions
    public let maxEarlyDataSize: UInt32?

    public init(maxEarlyDataSize: UInt32? = nil) {
        self.maxEarlyDataSize = maxEarlyDataSize
    }

    public func encode() -> Data {
        if let size = maxEarlyDataSize {
            var writer = TLSWriter(capacity: 4)
            writer.writeUInt32(size)
            return writer.finish()
        } else {
            return Data()
        }
    }

    public static func decode(from data: Data) throws -> EarlyDataIndication {
        if data.isEmpty {
            return EarlyDataIndication(maxEarlyDataSize: nil)
        }

        var reader = TLSReader(data: data)
        let size = try reader.readUInt32()
        return EarlyDataIndication(maxEarlyDataSize: size)
    }
}
