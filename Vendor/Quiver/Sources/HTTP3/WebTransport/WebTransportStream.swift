/// WebTransport Stream (draft-ietf-webtrans-http3)
///
/// Wraps a QUIC stream to provide WebTransport-scoped stream I/O.
/// Each WebTransport stream is associated with a session via a session ID
/// that is written as the first bytes on the stream.
///
/// ## Stream Types
///
/// WebTransport defines two stream association mechanisms:
///
/// ### Bidirectional Streams
///
/// The initiator opens a QUIC bidirectional stream and writes the
/// session ID as the first varint:
///
/// ```
/// WebTransport Bidirectional Stream {
///   Session ID (i),       // QUIC variable-length integer
///   Stream Body (..)      // Application data
/// }
/// ```
///
/// ### Unidirectional Streams
///
/// The initiator opens a QUIC unidirectional stream with stream type
/// 0x54 (WEBTRANSPORT_STREAM), followed by the session ID:
///
/// ```
/// WebTransport Unidirectional Stream {
///   Stream Type (i) = 0x54,
///   Session ID (i),
///   Stream Body (..)      // Application data
/// }
/// ```
///
/// ## Usage
///
/// ```swift
/// // Opening a bidirectional stream
/// let stream = try await session.openBidirectionalStream()
/// try await stream.write(Data("Hello".utf8))
/// let response = try await stream.read()
///
/// // Opening a unidirectional stream (send-only)
/// let uniStream = try await session.openUnidirectionalStream()
/// try await uniStream.write(Data("Fire and forget".utf8))
/// try await uniStream.closeWrite()
/// ```
///
/// ## Thread Safety
///
/// `WebTransportStream` is `Sendable` because it wraps a `Sendable`
/// QUIC stream protocol and holds only immutable metadata.
///
/// ## References
///
/// - [draft-ietf-webtrans-http3 §4.4](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)

import Foundation
import QUICCore
import QUICStream
import QUIC

// MARK: - WebTransport Stream Type Identifier

/// The HTTP/3 unidirectional stream type for WebTransport streams.
///
/// Per draft-ietf-webtrans-http3 §4.4, WebTransport unidirectional streams
/// use stream type 0x54. This is written as the first varint on the
/// unidirectional stream, followed by the session ID.
public let kWebTransportUniStreamType: UInt64 = 0x54

/// The signal value that opens a bidirectional WebTransport stream
/// (draft-ietf-webtrans-http3 §4.4). Both directions send it before the session ID.
public let kWebTransportBidiSignal: UInt64 = 0x41

// MARK: - Stream Direction

/// The direction of a WebTransport stream.
///
/// Determines whether the stream supports reading, writing, or both.
public enum WebTransportStreamDirection: Sendable, Hashable {
    /// Bidirectional stream — supports both reading and writing.
    case bidirectional

    /// Unidirectional stream — supports only one direction.
    ///
    /// - For locally-initiated uni streams: write-only
    /// - For remotely-initiated uni streams: read-only
    case unidirectional
}

extension WebTransportStreamDirection: CustomStringConvertible {
    public var description: String {
        switch self {
        case .bidirectional:
            return "bidirectional"
        case .unidirectional:
            return "unidirectional"
        }
    }
}

// MARK: - WebTransport Stream

/// A WebTransport stream associated with a session.
///
/// Wraps an underlying QUIC stream and provides application-level
/// read/write operations. The session ID framing (first varint on
/// bidi streams, stream type + session ID on uni streams) is handled
/// automatically during stream creation — the application only sees
/// the stream body.
///
/// ## Lifecycle
///
/// 1. Stream is opened (by `WebTransportSession.openBidirectionalStream()` etc.)
/// 2. Session ID framing is written automatically
/// 3. Application reads/writes data freely
/// 4. Stream is closed via `closeWrite()` (sends FIN) or `reset()`
///
/// For incoming streams, the session ID framing has already been consumed
/// before the stream is delivered to the application.
public struct WebTransportStream: Sendable {
    /// The underlying QUIC stream.
    ///
    /// Exposed for advanced use cases (e.g., accessing stream ID for
    /// debugging). Prefer using the `WebTransportStream` API methods.
    public let quicStream: any QUICStreamProtocol

    /// The WebTransport session ID this stream belongs to.
    ///
    /// This is the QUIC stream ID of the CONNECT stream that
    /// established the parent WebTransport session.
    public let sessionID: UInt64

    /// The direction of this stream.
    public let direction: WebTransportStreamDirection

    /// Whether this stream was initiated locally (by us) or by the peer.
    public let isLocal: Bool

    /// The scheduling priority for this stream.
    ///
    /// Determines the order in which data for this stream is sent
    /// relative to other streams. Based on RFC 9218 Extensible Priorities.
    ///
    /// - Bidirectional streams default to `StreamPriority.webTransportBidi`
    ///   (urgency 3, incremental)
    /// - Unidirectional streams default to `StreamPriority.webTransportUni`
    ///   (urgency 4, non-incremental)
    ///
    /// Use `WebTransportSession.setStreamPriority(_:for:)` to change
    /// priority after creation.
    public let priority: StreamPriority

    /// Buffer for data that was already read from the QUIC stream during
    /// stream routing (e.g., payload bytes that arrived in the same STREAM
    /// frame as the WebTransport framing header). This data is returned
    /// on the first `read()` call before reading more from the QUIC stream.
    private let _initialDataBuffer: InitialDataBuffer

    /// Creates a WebTransport stream wrapper.
    ///
    /// This initializer is used internally by `WebTransportSession`.
    /// The session ID framing should already have been written (for
    /// outgoing streams) or consumed (for incoming streams) before
    /// the stream is wrapped.
    ///
    /// - Parameters:
    ///   - quicStream: The underlying QUIC stream
    ///   - sessionID: The WebTransport session ID
    ///   - direction: The stream direction (bidi or uni)
    ///   - isLocal: Whether we initiated this stream
    ///   - priority: The scheduling priority (defaults to direction-appropriate value)
    ///   - initialData: Any data already read from the QUIC stream during
    ///     routing that should be returned on the first `read()` call
    public init(
        quicStream: any QUICStreamProtocol,
        sessionID: UInt64,
        direction: WebTransportStreamDirection,
        isLocal: Bool,
        priority: StreamPriority? = nil,
        initialData: Data = Data()
    ) {
        self.quicStream = quicStream
        self.sessionID = sessionID
        self.direction = direction
        self.isLocal = isLocal
        self.priority = priority ?? (direction == .bidirectional
            ? .webTransportBidi
            : .webTransportUni)
        self._initialDataBuffer = InitialDataBuffer(initialData)
    }

    // MARK: - Stream Identity

    /// The underlying QUIC stream ID.
    public var id: UInt64 {
        quicStream.id
    }

    /// Whether this is a bidirectional stream.
    public var isBidirectional: Bool {
        direction == .bidirectional
    }

    /// Whether this is a unidirectional stream.
    public var isUnidirectional: Bool {
        direction == .unidirectional
    }

    // MARK: - Read Operations

    /// Reads data from the stream.
    ///
    /// On the first call, returns any data that was buffered during stream
    /// routing (i.e., payload bytes that arrived in the same QUIC STREAM
    /// frame as the WebTransport framing header). Subsequent calls read
    /// directly from the underlying QUIC stream.
    ///
    /// Blocks until data is available or the stream ends.
    /// Returns empty `Data` when the stream has been fully read (FIN received).
    ///
    /// - Returns: The data read from the stream
    /// - Throws: If the stream has been reset or an I/O error occurs
    public func read() async throws -> Data {
        // Return buffered initial data first (from stream routing)
        if let buffered = _initialDataBuffer.drain() {
            return buffered
        }
        return try await quicStream.read()
    }

    /// Reads up to a maximum number of bytes from the stream.
    ///
    /// - Parameter maxBytes: Maximum number of bytes to read
    /// - Returns: The data read (may be fewer than maxBytes)
    /// - Throws: If the stream has been reset or an I/O error occurs
    public func read(maxBytes: Int) async throws -> Data {
        // Return buffered initial data first (from stream routing)
        if let buffered = _initialDataBuffer.drain(maxBytes: maxBytes) {
            return buffered
        }
        return try await quicStream.read(maxBytes: maxBytes)
    }

    // MARK: - Write Operations

    /// Writes data to the stream.
    ///
    /// - Parameter data: The data to write
    /// - Throws: If the stream has been closed for writing or an I/O error occurs
    public func write(_ data: Data) async throws {
        try await quicStream.write(data)
    }

    /// Closes the write side of the stream (sends FIN).
    ///
    /// After calling this, no more data can be written to the stream.
    /// The read side remains open (for bidirectional streams) until
    /// the peer sends FIN or resets the stream.
    ///
    /// - Throws: If closing fails
    public func closeWrite() async throws {
        try await quicStream.closeWrite()
    }

    // MARK: - Reset Operations

    /// Resets the stream with a WebTransport application error code.
    ///
    /// Sends a RESET_STREAM frame with the error code mapped to the
    /// WebTransport error code space (base + applicationCode).
    ///
    /// - Parameter applicationErrorCode: The application-level error code (default: 0)
    public func reset(applicationErrorCode: UInt32 = 0) async {
        let http3Code = WebTransportStreamErrorCode.toHTTP3ErrorCode(applicationErrorCode)
        await quicStream.reset(errorCode: http3Code)
    }

    /// Signals that no more data will be read from this stream.
    ///
    /// Sends a STOP_SENDING frame with the error code mapped to the
    /// WebTransport error code space.
    ///
    /// - Parameter applicationErrorCode: The application-level error code (default: 0)
    /// - Throws: If the operation fails
    public func stopReading(applicationErrorCode: UInt32 = 0) async throws {
        let http3Code = WebTransportStreamErrorCode.toHTTP3ErrorCode(applicationErrorCode)
        try await quicStream.stopSending(errorCode: http3Code)
    }
}

// MARK: - CustomStringConvertible

extension WebTransportStream: CustomStringConvertible {
    public var description: String {
        let locality = isLocal ? "local" : "remote"
        return "WebTransportStream(id=\(id), session=\(sessionID), \(direction), \(locality), \(priority))"
    }
}

// MARK: - WebTransport Stream Framing Helpers

/// Helpers for writing and reading the WebTransport stream framing
/// (session ID prefix on bidi streams, stream type + session ID on uni streams).
///
/// These are used internally by `WebTransportSession` when opening or
/// accepting streams. Application code should not need to use these directly.
public enum WebTransportStreamFraming {

    /// Writes the session ID framing for a new outgoing bidirectional stream.
    ///
    /// For WebTransport bidirectional streams, the first varint on the
    /// stream is the session ID.
    ///
    /// - Parameters:
    ///   - stream: The QUIC bidirectional stream
    ///   - sessionID: The WebTransport session ID
    /// - Throws: If writing fails
    public static func writeBidirectionalHeader(
        to stream: any QUICStreamProtocol,
        sessionID: UInt64
    ) async throws {
        var header = Data()
        Varint(kWebTransportBidiSignal).encode(to: &header)
        Varint(sessionID).encode(to: &header)
        try await stream.write(header)
    }

    /// Writes the stream type and session ID framing for a new outgoing
    /// unidirectional stream.
    ///
    /// For WebTransport unidirectional streams:
    /// 1. Stream type = 0x54 (WEBTRANSPORT_STREAM) as varint
    /// 2. Session ID as varint
    ///
    /// - Parameters:
    ///   - stream: The QUIC unidirectional stream
    ///   - sessionID: The WebTransport session ID
    /// - Throws: If writing fails
    public static func writeUnidirectionalHeader(
        to stream: any QUICStreamProtocol,
        sessionID: UInt64
    ) async throws {
        var header = Data()
        Varint(kWebTransportUniStreamType).encode(to: &header)
        Varint(sessionID).encode(to: &header)
        try await stream.write(header)
    }

    /// Reads and validates the session ID from an incoming bidirectional stream.
    ///
    /// Reads the first varint from the stream data, which should be the
    /// session ID. Returns the session ID and any remaining data after it.
    ///
    /// - Parameter data: The initial data read from the stream
    /// - Returns: A tuple of (sessionID, remaining data after the session ID varint),
    ///   or `nil` if the data is too short to contain a varint
    /// - Throws: If the varint is malformed
    public static func readBidirectionalSessionID(
        from data: Data
    ) throws -> (sessionID: UInt64, remaining: Data)? {
        guard !data.isEmpty else { return nil }

        let (varint, consumed) = try Varint.decode(from: data)
        let remaining: Data
        if consumed < data.count {
            remaining = Data(data.dropFirst(consumed))
        } else {
            remaining = Data()
        }

        return (varint.value, remaining)
    }

    /// Reads and validates the session ID from an incoming unidirectional stream.
    ///
    /// The stream type byte (0x54) should already have been consumed by
    /// the HTTP/3 connection's stream classification logic. This reads
    /// the session ID varint from the remaining data.
    ///
    /// - Parameter data: The data after the stream type byte has been consumed
    /// - Returns: A tuple of (sessionID, remaining data), or `nil` if insufficient data
    /// - Throws: If the varint is malformed
    public static func readUnidirectionalSessionID(
        from data: Data
    ) throws -> (sessionID: UInt64, remaining: Data)? {
        // Same format as bidi — just a session ID varint
        return try readBidirectionalSessionID(from: data)
    }
}

// MARK: - HTTP/3 Stream Type Classification Extension

// MARK: - Initial Data Buffer

/// Thread-safe buffer for initial data read during stream routing.
///
/// When the HTTP/3 layer reads framing headers from an incoming WebTransport
/// stream, payload bytes that arrived in the same QUIC STREAM frame are
/// consumed from the QUIC stream's buffer. This class holds those bytes
/// so they can be returned on the first application-level `read()` call.
private final class InitialDataBuffer: @unchecked Sendable {
    private var data: Data
    private let lock = NSLock()

    init(_ data: Data) {
        self.data = data
    }

    /// Drains all buffered data, returning `nil` if the buffer is empty.
    func drain() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        let result = data
        data = Data()
        return result
    }

    /// Drains up to `maxBytes` from the buffer.
    /// Any remaining bytes stay buffered for the next call.
    func drain(maxBytes: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        if data.count <= maxBytes {
            let result = data
            data = Data()
            return result
        } else {
            let result = Data(data.prefix(maxBytes))
            data = Data(data.dropFirst(maxBytes))
            return result
        }
    }
}

/// Adds WebTransport stream type recognition to the HTTP/3 stream
/// classification system.
///
/// When the HTTP/3 connection encounters unidirectional stream type 0x54,
/// it should route the stream to the WebTransport session manager.
public enum WebTransportStreamClassification {
    /// Checks if a unidirectional stream type is a WebTransport stream.
    ///
    /// - Parameter streamType: The stream type varint value
    /// - Returns: `true` if this is a WebTransport unidirectional stream (type 0x54)
    public static func isWebTransportStream(_ streamType: UInt64) -> Bool {
        return streamType == kWebTransportUniStreamType
    }
}