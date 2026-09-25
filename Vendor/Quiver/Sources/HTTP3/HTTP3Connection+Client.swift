/// HTTP3Connection — Client Operations
///
/// Extension containing client-side request/response logic:
/// - `sendRequest` — sends an HTTP/3 request and reads the streaming response
/// - `sendRequestWithBodyWriter` — streams the request body via a writer closure
/// - `sendExtendedConnect` — sends an Extended CONNECT (RFC 9220) request
/// - `readResponseStreaming` — reads response HEADERS, returns body as AsyncStream
/// - `readExtendedConnectResponse` — reads only the response HEADERS (no FIN wait)

import Foundation
import QUIC
import QUICCore
import QPACK

// MARK: - Client Request/Response

extension HTTP3Connection {

    // MARK: - Request/Response (Client)

    /// Sends an HTTP/3 request and returns the response with a stream-backed body.
    ///
    /// Opens a new bidirectional QUIC stream, sends the HEADERS and
    /// optional DATA frames, closes the write side, and reads the
    /// response. The response body is always an `HTTP3Body` (stream-backed).
    ///
    /// - Parameter request: The HTTP/3 request to send
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func sendRequest(_ request: HTTP3Request) async throws -> HTTP3Response {
        guard state == .ready || state == .initializing else {
            throw HTTP3Error(code: .internalError, reason: "Connection not ready (state: \(state))")
        }

        // Check GOAWAY — don't send new requests past the goaway point
        if let goawayID = goawayStreamID, nextStreamID > goawayID {
            throw HTTP3Error(code: .requestRejected, reason: "Stream ID exceeds GOAWAY limit")
        }

        // Open a new bidirectional stream
        let stream = try await quicConnection.openStream()

        // Track the stream ID and advance to the next one
        // Client bidi streams: 0, 4, 8, 12, ... (increment by 4)
        // Server bidi streams: 1, 5, 9, 13, ... (increment by 4)
        nextStreamID += 4

        // Encode headers using QPACK
        let headerList = request.toHeaderList()
        let encodedHeaders = qpackEncoder.encode(headerList)

        // Send HEADERS frame
        let headersFrame = HTTP3Frame.headers(encodedHeaders)
        let headersData = HTTP3FrameCodec.encode(headersFrame)
        try await stream.write(headersData)

        // Send DATA frame if there's a body
        if let body = request.body, !body.isEmpty {
            let dataFrame = HTTP3Frame.data(body)
            let dataData = HTTP3FrameCodec.encode(dataFrame)
            try await stream.write(dataData)
        }

        // Send trailers (if any) — RFC 9114 §4.1
        if let trailers = request.trailers, !trailers.isEmpty {
            let encodedTrailers = qpackEncoder.encode(trailers)
            let trailersFrame = HTTP3Frame.headers(encodedTrailers)
            let trailersData = HTTP3FrameCodec.encode(trailersFrame)
            try await stream.write(trailersData)
        }

        // Close the write side (FIN)
        try await stream.closeWrite()

        // Read response with streaming body
        return try await readResponseStreaming(from: stream)
    }

    // MARK: - Streaming Request (Client Upload)

    /// Sends an HTTP/3 request with a streaming body and reads the response.
    ///
    /// Instead of buffering the entire body in `request.body`, the caller
    /// streams chunks via the `bodyWriter` closure. Each chunk is encoded
    /// as a DATA frame and written directly to the QUIC stream. Memory
    /// usage is flat regardless of total body size.
    ///
    /// ```swift
    /// let response = try await connection.sendRequestWithBodyWriter(
    ///     HTTP3Request(method: .post, authority: "example.com", path: "/upload",
    ///                  headers: [("content-type", "application/octet-stream")])
    /// ) { writer in
    ///     while let chunk = fileHandle.readData(ofLength: 65536) {
    ///         if chunk.isEmpty { break }
    ///         try await writer.write(chunk)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - request: The HTTP/3 request (headers only; `request.body` is ignored)
    ///   - bodyWriter: Closure that writes body chunks via ``HTTP3BodyWriter``
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request or response fails
    public func sendRequestWithBodyWriter(
        _ request: HTTP3Request,
        bodyWriter: @Sendable (HTTP3BodyWriter) async throws -> Void
    ) async throws -> HTTP3Response {
        guard state == .ready || state == .initializing else {
            throw HTTP3Error(code: .internalError, reason: "Connection not ready (state: \(state))")
        }

        if let goawayID = goawayStreamID, nextStreamID > goawayID {
            throw HTTP3Error(code: .requestRejected, reason: "Stream ID exceeds GOAWAY limit")
        }

        let stream = try await quicConnection.openStream()
        nextStreamID += 4

        // Send HEADERS frame
        let headerList = request.toHeaderList()
        let encodedHeaders = qpackEncoder.encode(headerList)
        let headersFrame = HTTP3Frame.headers(encodedHeaders)
        let headersData = HTTP3FrameCodec.encode(headersFrame)
        try await stream.write(headersData)

        // Stream body via writer — each write() sends a DATA frame
        let writer = HTTP3BodyWriter(
            _write: { [stream] chunk in
                let dataFrame = HTTP3Frame.data(chunk)
                let frameData = HTTP3FrameCodec.encode(dataFrame)
                try await stream.write(frameData)
            }
        )
        try await bodyWriter(writer)

        // Send trailers (if any)
        if let trailers = request.trailers, !trailers.isEmpty {
            let encodedTrailers = qpackEncoder.encode(trailers)
            let trailersFrame = HTTP3Frame.headers(encodedTrailers)
            let trailersData = HTTP3FrameCodec.encode(trailersFrame)
            try await stream.write(trailersData)
        }

        // Close the write side (FIN) — signals end of request
        try await stream.closeWrite()

        // Read the response with streaming body
        return try await readResponseStreaming(from: stream)
    }

    // MARK: - Extended CONNECT (RFC 9220)

    /// Sends an Extended CONNECT request and returns the response along
    /// with the open stream.
    ///
    /// Unlike `sendRequest()`, this method does NOT close the write side
    /// of the stream after sending headers. If the server responds with
    /// 200, the stream remains open for the session lifetime (e.g.,
    /// WebTransport bidirectional data exchange).
    ///
    /// Per RFC 9220 §3, Extended CONNECT requires:
    /// - The peer must have sent `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1`
    /// - The request must include `:protocol`, `:scheme`, `:authority`, `:path`
    ///
    /// - Parameter request: An Extended CONNECT request (must have `connectProtocol` set)
    /// - Returns: A tuple of the HTTP/3 response and the open QUIC stream.
    ///   If the response is 200, the stream is ready for session use.
    ///   If the response is an error, the stream has been closed.
    /// - Throws: `HTTP3Error` if the request fails or preconditions aren't met
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let request = HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt")
    /// let (response, stream) = try await connection.sendExtendedConnect(request)
    /// if response.isSuccess {
    ///     // stream is open — use for WebTransport session
    /// }
    /// ```
     public func sendExtendedConnect(_ request: HTTP3Request) async throws -> (response: HTTP3ResponseHead, stream: any QUICStreamProtocol) {
        guard request.isExtendedConnect else {
            throw HTTP3Error(
                code: .internalError,
                reason: "sendExtendedConnect requires a request with connectProtocol set"
            )
        }

        guard state == .ready || state == .initializing else {
            throw HTTP3Error(code: .internalError, reason: "Connection not ready (state: \(state))")
        }

        // Verify peer supports Extended CONNECT
        if let peer = peerSettings, !peer.enableConnectProtocol {
            throw HTTP3Error(
                code: .settingsError,
                reason: "Peer has not enabled SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 9220 §3)"
            )
        }

        // Check GOAWAY
        if let goawayID = goawayStreamID, nextStreamID > goawayID {
            throw HTTP3Error(code: .requestRejected, reason: "Stream ID exceeds GOAWAY limit")
        }

        // Open a new bidirectional stream
        let stream = try await quicConnection.openStream()
        nextStreamID += 4

        // Encode and send headers
        let headerList = request.toHeaderList()
        let encodedHeaders = qpackEncoder.encode(headerList)
        let headersFrame = HTTP3Frame.headers(encodedHeaders)
        let headersData = HTTP3FrameCodec.encode(headersFrame)
        try await stream.write(headersData)

        // NOTE: We do NOT close the write side here.
        // The stream stays open for the Extended CONNECT session lifetime.

        // Read ONLY the response headers — do NOT wait for body/FIN.
        // Extended CONNECT keeps the stream open for the session lifetime
        // (capsules, WebTransport data, etc.), so readResponseStreaming()
        // is not appropriate here — it would start a background body reader
        // that conflicts with the session's own stream usage.
        let response = try await readExtendedConnectResponse(from: stream)

        // If the server rejected, close the stream
        if !response.isSuccess {
            try? await stream.closeWrite()
        }

        return (response, stream)
    }

    // MARK: - Response Reading (Client)

    /// Reads the response HEADERS frame from an Extended CONNECT stream.
    ///
    /// Unlike `readResponseStreaming()`, this method returns as soon as the
    /// first HEADERS frame is decoded — it does NOT wait for DATA frames,
    /// trailers, or FIN. Extended CONNECT streams (RFC 9220) stay open for the session
    /// lifetime (e.g. WebTransport), so waiting for FIN would block forever
    /// and eventually hit the idle timeout.
    ///
    /// Any data beyond the HEADERS frame is left for the caller to read
    /// (e.g. capsules on the CONNECT stream).
    func readExtendedConnectResponse(from stream: any QUICStreamProtocol) async throws -> HTTP3ResponseHead {
        // NOTE: Extended CONNECT responses use buffered Data body (not streaming)
        // because the stream stays open for the session lifetime.
        var buffer = Data()

        while true {
            let data: Data
            do {
                data = try await stream.read()
            } catch {
                // Stream ended or error before we got headers
                throw HTTP3Error.messageError("Extended CONNECT stream closed before response HEADERS received")
            }

            if data.isEmpty {
                throw HTTP3Error.messageError("Extended CONNECT stream FIN before response HEADERS received")
            }

            buffer.append(data)

            // Try to decode frames from what we have so far
            let (frames, _) = try decodeFramesFromBuffer(&buffer)

            for frame in frames {
                if HTTP3ReservedFrameType.isReserved(frame.frameType) {
                    throw HTTP3Error.frameUnexpected(
                        "Reserved frame type 0x\(String(frame.frameType, radix: 16)) (HTTP/2 only)"
                    )
                }

                switch frame {
                case .headers(let headerBlock):
                    let headers = try qpackDecoder.decode(headerBlock)
                    let response = try HTTP3ResponseHead.fromHeaderList(headers)
                    return response

                case .unknown:
                    // Ignore unknown frames (forward compatibility)
                    continue

                default:
                    throw HTTP3Error.frameUnexpected(
                        "Expected HEADERS frame for Extended CONNECT response, got frame type 0x\(String(frame.frameType, radix: 16))"
                    )
                }
            }
            // If no complete HEADERS frame decoded yet, loop and read more data
        }
    }

    // MARK: - Response Reading (Streaming)

    /// Reads an HTTP/3 response with a stream-backed body.
    ///
    /// Returns the `HTTP3Response` as soon as the first HEADERS frame is
    /// decoded. The response `body` is an `HTTP3Body` wrapping an
    /// `AsyncStream<Data>` that yields each DATA frame payload.
    /// A background task continues reading from the QUIC stream and
    /// feeding the body stream until FIN.
    ///
    /// Memory usage is flat regardless of response body size because DATA
    /// frame payloads are yielded individually, never accumulated.
    func readResponseStreaming(
        from stream: any QUICStreamProtocol
    ) async throws -> HTTP3Response {
        var buffer = Data()
        var responseHeaders: [(name: String, value: String)]?
        var earlyBodyChunks: [Data] = []

        // Phase 1: Read until HEADERS frame is found
        while responseHeaders == nil {
            let data: Data
            do {
                data = try await stream.read()
            } catch {
                throw HTTP3Error.messageError("Stream closed before response HEADERS received")
            }

            if data.isEmpty {
                throw HTTP3Error.messageError("Stream FIN before response HEADERS received")
            }

            buffer.append(data)

            let (frames, _) = try decodeFramesFromBuffer(&buffer)

            for frame in frames {
                if HTTP3ReservedFrameType.isReserved(frame.frameType) {
                    throw HTTP3Error.frameUnexpected(
                        "Reserved frame type 0x\(String(frame.frameType, radix: 16)) (HTTP/2 only)"
                    )
                }

                switch frame {
                case .headers(let headerBlock):
                    if responseHeaders != nil {
                        // Trailing headers in same read as response headers (rare)
                        // Will be handled by body reader
                        continue
                    }
                    responseHeaders = try qpackDecoder.decode(headerBlock)

                case .data(let payload):
                    // DATA arrived in same read as HEADERS
                    earlyBodyChunks.append(payload)

                case .unknown:
                    continue

                default:
                    if !frame.isAllowedOnRequestStream {
                        throw HTTP3Error.frameUnexpected(
                            "Frame type 0x\(String(frame.frameType, radix: 16)) not allowed on request stream"
                        )
                    }
                }
            }
        }

        guard let headers = responseHeaders else {
            throw HTTP3Error.messageError("No HEADERS frame received in response")
        }

        let baseResponse = try HTTP3Response.fromHeaderList(headers)

        // Phase 2: Create body stream and feed it from a background task
        let (bodyStream, bodyContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded
        )

        // Yield any DATA payloads that arrived alongside HEADERS
        for chunk in earlyBodyChunks {
            bodyContinuation.yield(chunk)
        }

        // Capture buffer and decoder for the background task.
        // We need to use a reference type because the buffer is mutated.
        let capturedBuffer = BufferBox(buffer)

        // Background task: continue reading DATA frames until FIN.
        // Uses the same decodeFramesFromBuffer helper as the rest of
        // the HTTP/3 stack (handles varint frame type + length properly).
        let capturedSelf = self
        Task { [capturedBuffer] in
            defer { bodyContinuation.finish() }

            var buf = capturedBuffer.data

            while true {
                let data: Data
                do {
                    data = try await stream.read()
                } catch {
                    break
                }

                if data.isEmpty {
                    break
                }

                buf.append(data)

                do {
                    let (frames, _) = try await capturedSelf.decodeFramesFromBuffer(&buf)

                    for frame in frames {
                        switch frame {
                        case .data(let payload):
                            bodyContinuation.yield(payload)

                        default:
                            // HEADERS (trailers), unknown frames — skip in streaming path.
                            // Trailers are not critical for body consumption.
                            continue
                        }
                    }
                } catch {
                    // Decoding error — stop feeding
                    break
                }
            }
        }

        return HTTP3Response(
            status: baseResponse.status,
            headers: baseResponse.headers,
            bodyStream: bodyStream,
            trailers: baseResponse.trailers
        )
    }
}

// MARK: - Internal Helpers

/// Mutable buffer box for capturing in Sendable closures.
private final class BufferBox: @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
}
