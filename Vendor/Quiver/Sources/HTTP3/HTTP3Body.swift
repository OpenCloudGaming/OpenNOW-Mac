/// HTTP/3 Body — stream-backed request/response body.
///
/// `HTTP3Body` is a move-only (`~Copyable`) struct wrapping an `AsyncStream<Data>`.
/// Each consumer is a `consuming func`, meaning the compiler enforces single-use
/// at compile time — you cannot call `.data()` and then `.text()` on the same value.
///
/// Design mirrors JavaScript's `Response.body` / `.json()` / `.text()` /
/// `.arrayBuffer()` pattern, but with compile-time enforcement instead of
/// a runtime `bodyUsed` flag.
///
/// ## Usage
///
/// Pick exactly **one** consumer per body instance:
///
/// ```swift
/// let data = try await body.data()              // full body as Data
/// let text = try await body.text()              // full body as String (UTF-8)
/// let obj  = try await body.json(MyType.self)   // full body decoded as JSON
/// let raw  = body.stream()                      // raw AsyncStream<Data>
/// ```

import Foundation

// MARK: - Error

/// Errors thrown by `HTTP3Body` consumption methods.
public enum HTTP3BodyError: Error, Sendable, CustomStringConvertible {
    /// The body exceeded the `maxBytes` limit during consumption.
    case bodyTooLarge(limit: Int)

    /// The body data could not be decoded as a valid UTF-8 string.
    case invalidUTF8

    public var description: String {
        switch self {
        case .bodyTooLarge(let limit):
            return "HTTP3Body exceeded maximum allowed size of \(limit) bytes."
        case .invalidUTF8:
            return "HTTP3Body data is not valid UTF-8."
        }
    }
}

// MARK: - HTTP3Body

/// A move-only, stream-backed HTTP body consumed exactly once at compile time.
///
/// Backed by `AsyncStream<Data>` — chunks arrive at frame granularity,
/// not byte-by-byte, preserving zero-copy semantics from QUIC DATA frames.
public struct HTTP3Body: ~Copyable, Sendable {

    /// The underlying async stream of body data chunks.
    private let _stream: AsyncStream<Data>

    // MARK: - Initializers

    /// Creates a body backed by a live `AsyncStream<Data>`.
    ///
    /// Used internally by the framework when reading DATA frames
    /// from a QUIC stream.
    ///
    /// - Parameter stream: The async stream of body data chunks.
    public init(stream: AsyncStream<Data>) {
        self._stream = stream
    }

    /// Creates a body wrapping pre-buffered `Data`.
    ///
    /// The data is yielded as a single chunk and the stream finishes
    /// immediately. Suitable for small/known-size bodies and tests.
    ///
    /// - Parameter data: The body data. Defaults to empty `Data()`.
    public init(data: Data = Data()) {
        if data.isEmpty {
            self._stream = AsyncStream<Data> { $0.finish() }
        } else {
            let captured = data
            self._stream = AsyncStream<Data> { continuation in
                continuation.yield(captured)
                continuation.finish()
            }
        }
    }

    // MARK: - Consumers

    /// Reads the entire body into `Data`.
    ///
    /// Accumulates all chunks from the underlying stream. Throws if the
    /// total size exceeds `maxBytes`.
    ///
    /// - Parameter maxBytes: Maximum allowed body size (default 100 MB).
    /// - Returns: The complete body data. May be empty.
    /// - Throws: `HTTP3BodyError.bodyTooLarge` if the body exceeds `maxBytes`.
    public consuming func data(maxBytes: Int = 104_857_600) async throws -> Data {
        var result = Data()
        for await chunk in _stream {
            result.append(chunk)
            if result.count > maxBytes {
                throw HTTP3BodyError.bodyTooLarge(limit: maxBytes)
            }
        }
        return result
    }

    /// Reads the entire body as a UTF-8 `String`.
    ///
    /// - Parameter maxBytes: Maximum allowed body size (default 100 MB).
    /// - Returns: The body decoded as a UTF-8 string.
    /// - Throws: `HTTP3BodyError.bodyTooLarge` if the body exceeds `maxBytes`.
    ///           `HTTP3BodyError.invalidUTF8` if the data is not valid UTF-8.
    public consuming func text(maxBytes: Int = 104_857_600) async throws -> String {
        let rawData = try await data(maxBytes: maxBytes)
        guard let string = String(data: rawData, encoding: .utf8) else {
            throw HTTP3BodyError.invalidUTF8
        }
        return string
    }

    /// Reads the entire body and decodes it as JSON.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to decode into.
    ///   - maxBytes: Maximum allowed body size (default 100 MB).
    /// - Returns: The decoded value.
    /// - Throws: `HTTP3BodyError.bodyTooLarge` if the body exceeds `maxBytes`.
    ///           `DecodingError` if JSON decoding fails.
    public consuming func json<T: Decodable>(_ type: T.Type, maxBytes: Int = 104_857_600) async throws -> T {
        let rawData = try await data(maxBytes: maxBytes)
        return try JSONDecoder().decode(T.self, from: rawData)
    }

    /// Returns the raw `AsyncStream<Data>` for chunk-by-chunk iteration.
    ///
    /// Use this for large or unbounded bodies where buffering the full
    /// payload into memory is not desirable.
    ///
    /// ```swift
    /// for await chunk in body.stream() {
    ///     process(chunk)
    /// }
    /// ```
    ///
    /// - Returns: The underlying `AsyncStream<Data>`.
    public consuming func stream() -> AsyncStream<Data> {
        return _stream
    }
}