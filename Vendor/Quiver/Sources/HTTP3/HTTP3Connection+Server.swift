/// HTTP3Connection — Server Operations
///
/// Extension containing server-side request handling and response sending:
/// - `handleIncomingRequestStream` — reads and dispatches HTTP/3 requests
/// - `handleIncomingRequestStreamWithBuffer` — same, with pre-read buffer
/// - `routeExtendedConnectRequest` — routes Extended CONNECT to handler
/// - `sendResponse` — sends a full HTTP/3 response (HEADERS + DATA + FIN)
/// - `sendResponseStreaming` — sends HEADERS then chunked DATA via writer + FIN
/// - `sendResponseHeadersOnly` — sends response headers without FIN (Extended CONNECT)

import Foundation
import Synchronization
import QUIC
import QUICCore
import QUICStream
import QPACK

// MARK: - Server Request Handling & Response Sending

extension HTTP3Connection {

    // MARK: - Request Stream Handling (Server)

    /// Handles an incoming HTTP/3 request stream with pre-read buffer data.
    ///
    /// This variant is called when `handleIncomingBidiStream` has already
    /// read the first chunk of data (to check for WebTransport session ID)
    /// and determined the stream is an HTTP/3 request stream.
    ///
    /// The handler is fired as soon as HEADERS are parsed. The request body
    /// is delivered as an `AsyncStream<Data>` on the context, so the handler
    /// can consume it incrementally with flat memory usage.
    func handleIncomingRequestStreamWithBuffer(
        _ stream: any QUICStreamProtocol,
        initialBuffer: Data
    ) async {
        do {
            var buffer = initialBuffer

            // ----------------------------------------------------------
            // Phase 1: Find the HEADERS frame (may span multiple reads)
            // ----------------------------------------------------------
            let headerResult = try await readUntilHeaders(
                stream: stream,
                buffer: &buffer
            )

            guard let headerResult else {
                // No HEADERS frame received — incomplete request
                await stream.reset(errorCode: HTTP3ErrorCode.requestIncomplete.rawValue)
                return
            }

            var request = try HTTP3Request.fromHeaderList(headerResult.headers)

            // ----------------------------------------------------------
            // Extended CONNECT — route immediately, no body streaming
            // ----------------------------------------------------------
            if headerResult.isExtendedConnect {
                // Attach any DATA already seen in the initial buffer
                if !headerResult.earlyBodyData.isEmpty {
                    request.body = headerResult.earlyBodyData
                }
                request.trailers = headerResult.earlyTrailers
                await routeExtendedConnectRequest(request, stream: stream)
                return
            }

            // ----------------------------------------------------------
            // Phase 2: Regular request — create body stream & fire handler
            // ----------------------------------------------------------
            let (bodyStream, bodyContinuation) = AsyncStream<Data>.makeStream(
                bufferingPolicy: .unbounded
            )

            // Yield any DATA payloads that arrived in the same read as HEADERS
            if !headerResult.earlyBodyData.isEmpty {
                bodyContinuation.yield(headerResult.earlyBodyData)
            }

            // If trailers were already seen (unlikely but possible for
            // tiny requests where HEADERS + DATA + trailing-HEADERS + FIN
            // all arrive in one read), finish the body stream now.
            if headerResult.earlyTrailers != nil || headerResult.streamFinished {
                bodyContinuation.finish()
                request.trailers = headerResult.earlyTrailers
                try await dispatchRegularRequest(
                    request: request,
                    stream: stream,
                    bodyStream: bodyStream
                )
                return
            }

            // ----------------------------------------------------------
            // Phase 3: Continue reading DATA frames in the background,
            //          feeding them into the body stream.
            // ----------------------------------------------------------
            // We dispatch the request context FIRST so the handler starts
            // running. Then we continue reading from the QUIC stream in
            // THIS task (the per-stream Task), yielding DATA payloads
            // into the body stream. When FIN arrives, we finish the stream.
            //
            // The handler runs in a separate Task (dispatched by
            // HTTP3Server.handleConnection), so there is no deadlock.
            // ----------------------------------------------------------

            // Fire handler immediately (headers only)
            let trailerBox = TrailerBox()
            try await dispatchRegularRequest(
                request: request,
                stream: stream,
                bodyStream: bodyStream
            )

            // Continue feeding body
            await feedBodyStream(
                stream: stream,
                buffer: &buffer,
                continuation: bodyContinuation,
                trailerBox: trailerBox
            )

        } catch {
            await stream.reset(errorCode: HTTP3ErrorCode.messageError.rawValue)
        }
    }

    /// Handles an incoming HTTP/3 request stream (no pre-read buffer).
    ///
    /// Same streaming semantics as the buffered variant: the handler fires
    /// at HEADERS, body is delivered via `AsyncStream<Data>`.
    func handleIncomingRequestStream(_ stream: any QUICStreamProtocol) async {
        do {
            var buffer = Data()

            // ----------------------------------------------------------
            // Phase 1: Find the HEADERS frame
            // ----------------------------------------------------------
            let headerResult = try await readUntilHeaders(
                stream: stream,
                buffer: &buffer
            )

            guard let headerResult else {
                await stream.reset(errorCode: HTTP3ErrorCode.requestIncomplete.rawValue)
                return
            }

            var request = try HTTP3Request.fromHeaderList(headerResult.headers)

            // ----------------------------------------------------------
            // Extended CONNECT
            // ----------------------------------------------------------
            if headerResult.isExtendedConnect {
                if !headerResult.earlyBodyData.isEmpty {
                    request.body = headerResult.earlyBodyData
                }
                request.trailers = headerResult.earlyTrailers
                await routeExtendedConnectRequest(request, stream: stream)
                return
            }

            // ----------------------------------------------------------
            // Regular request — body stream
            // ----------------------------------------------------------
            let (bodyStream, bodyContinuation) = AsyncStream<Data>.makeStream(
                bufferingPolicy: .unbounded
            )

            if !headerResult.earlyBodyData.isEmpty {
                bodyContinuation.yield(headerResult.earlyBodyData)
            }

            if headerResult.earlyTrailers != nil || headerResult.streamFinished {
                bodyContinuation.finish()
                request.trailers = headerResult.earlyTrailers
                try await dispatchRegularRequest(
                    request: request,
                    stream: stream,
                    bodyStream: bodyStream
                )
                return
            }

            let trailerBox = TrailerBox()
            try await dispatchRegularRequest(
                request: request,
                stream: stream,
                bodyStream: bodyStream
            )

            await feedBodyStream(
                stream: stream,
                buffer: &buffer,
                continuation: bodyContinuation,
                trailerBox: trailerBox
            )

        } catch {
            await stream.reset(errorCode: HTTP3ErrorCode.messageError.rawValue)
        }
    }

    // MARK: - Internal Helpers

    /// Result of reading until the first HEADERS frame is found.
    private struct HeaderReadResult {
        /// The decoded header list.
        let headers: [(name: String, value: String)]
        /// Whether the request is an Extended CONNECT.
        let isExtendedConnect: Bool
        /// Any DATA payload bytes that arrived in the same read(s) as HEADERS.
        var earlyBodyData: Data
        /// Trailing headers if already received (rare).
        var earlyTrailers: [(String, String)]?
        /// True if the stream FIN was received during header reading.
        var streamFinished: Bool
    }

    /// Reads from `stream` (appending to `buffer`) until the first HEADERS
    /// frame is decoded. Any DATA or trailing-HEADERS frames that happen to
    /// be in the same read are captured in the result.
    ///
    /// Returns `nil` if the stream ends before HEADERS are found.
    private func readUntilHeaders(
        stream: any QUICStreamProtocol,
        buffer: inout Data
    ) async throws -> HeaderReadResult? {
        var headersDecoded: [(name: String, value: String)]?
        var isExtendedConnect = false
        var earlyBody = Data()
        var earlyTrailers: [(String, String)]?
        var headersReceived = false
        var streamFinished = false

        // First, try to decode from whatever is already in the buffer
        // (covers the handleIncomingRequestStreamWithBuffer path where
        // initialBuffer may already contain the full HEADERS).
        if !buffer.isEmpty {
            let (frames, _) = try decodeFramesFromBuffer(&buffer)
            for frame in frames {
                if HTTP3ReservedFrameType.isReserved(frame.frameType) {
                    throw HTTP3Error.frameUnexpected(
                        "Reserved frame type 0x\(String(frame.frameType, radix: 16)) (HTTP/2 only)"
                    )
                }
                switch frame {
                case .headers(let headerBlock):
                    if headersReceived {
                        let decoded = try qpackDecoder.decode(headerBlock)
                        earlyTrailers = try validateTrailers(decoded)
                        continue
                    }
                    let decoded = try qpackDecoder.decode(headerBlock)
                    headersDecoded = decoded
                    headersReceived = true

                    if let h = headersDecoded {
                        let hasProtocol = h.contains(where: { $0.name == ":protocol" })
                        let isConnect = h.contains(where: { $0.name == ":method" && $0.value == "CONNECT" })
                        if hasProtocol && isConnect {
                            isExtendedConnect = true
                        }
                    }

                case .data(let payload):
                    guard headersReceived else {
                        throw HTTP3Error.frameUnexpected("DATA frame before HEADERS")
                    }
                    earlyBody.append(payload)

                case .unknown:
                    continue

                default:
                    if !frame.isAllowedOnRequestStream {
                        throw HTTP3Error.frameUnexpected(
                            "Frame type 0x\(String(frame.frameType, radix: 16)) on request stream"
                        )
                    }
                }
            }
        }

        // If HEADERS already found from the buffer, return
        if let headers = headersDecoded {
            return HeaderReadResult(
                headers: headers,
                isExtendedConnect: isExtendedConnect,
                earlyBodyData: earlyBody,
                earlyTrailers: earlyTrailers,
                streamFinished: false
            )
        }

        // Continue reading from the stream until HEADERS arrive
        while true {
            let data: Data
            do {
                data = try await stream.read()
            } catch {
                // Stream ended or error before HEADERS
                return nil
            }

            if data.isEmpty {
                // FIN before HEADERS
                streamFinished = true
                break
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
                    if headersReceived {
                        let decoded = try qpackDecoder.decode(headerBlock)
                        earlyTrailers = try validateTrailers(decoded)
                        continue
                    }
                    let decoded = try qpackDecoder.decode(headerBlock)
                    headersDecoded = decoded
                    headersReceived = true

                    if let h = headersDecoded {
                        let hasProtocol = h.contains(where: { $0.name == ":protocol" })
                        let isConnect = h.contains(where: { $0.name == ":method" && $0.value == "CONNECT" })
                        if hasProtocol && isConnect {
                            isExtendedConnect = true
                        }
                    }

                case .data(let payload):
                    guard headersReceived else {
                        throw HTTP3Error.frameUnexpected("DATA frame before HEADERS")
                    }
                    earlyBody.append(payload)

                case .unknown:
                    continue

                default:
                    if !frame.isAllowedOnRequestStream {
                        throw HTTP3Error.frameUnexpected(
                            "Frame type 0x\(String(frame.frameType, radix: 16)) on request stream"
                        )
                    }
                }
            }

            if headersDecoded != nil {
                break
            }
        }

        guard let headers = headersDecoded else {
            return nil
        }

        return HeaderReadResult(
            headers: headers,
            isExtendedConnect: isExtendedConnect,
            earlyBodyData: earlyBody,
            earlyTrailers: earlyTrailers,
            streamFinished: streamFinished
        )
    }

    /// Mutable box for trailers discovered during body feeding.
    /// Needed because the feedBodyStream caller may want the trailers
    /// after the stream is done, but actors require sendable captures.
    private final class TrailerBox: Sendable {
        private let _storage = Mutex<Optional<[(String, String)]>>(.none)
        var value: [(String, String)]? {
            get { _storage.withLock { $0 } }
            set { _storage.withLock { $0 = newValue } }
        }
    }

    /// Continues reading DATA frames from the QUIC stream and yields
    /// each payload into the body stream continuation.
    ///
    /// Finishes the continuation when FIN is received or the stream errors.
    private func feedBodyStream(
        stream: any QUICStreamProtocol,
        buffer: inout Data,
        continuation: AsyncStream<Data>.Continuation,
        trailerBox: TrailerBox
    ) async {
        defer { continuation.finish() }

        while true {
            let data: Data
            do {
                data = try await stream.read()
            } catch {
                // Stream error — finish the body stream
                break
            }

            if data.isEmpty {
                // FIN received — body is complete
                break
            }

            buffer.append(data)

            do {
                let (frames, _) = try decodeFramesFromBuffer(&buffer)

                for frame in frames {
                    if HTTP3ReservedFrameType.isReserved(frame.frameType) {
                        // Protocol error — stop feeding
                        return
                    }

                    switch frame {
                    case .data(let payload):
                        continuation.yield(payload)

                    case .headers(let headerBlock):
                        // Trailing HEADERS after body
                        if let decoded = try? qpackDecoder.decode(headerBlock),
                           let validated = try? validateTrailers(decoded) {
                            trailerBox.value = validated
                        }

                    case .unknown:
                        continue

                    default:
                        if !frame.isAllowedOnRequestStream {
                            return
                        }
                    }
                }
            } catch {
                // Decoding error — stop
                break
            }
        }
    }

    /// Dispatches a regular (non-Extended-CONNECT) request to the handler
    /// via `incomingRequestsContinuation`. The body stream is attached to
    /// the context so the handler can consume it incrementally.
    ///
    /// This method returns immediately after yielding the context; the
    /// handler runs in a separate task (dispatched by HTTP3Server).
    private func dispatchRegularRequest(
        request: HTTP3Request,
        stream: any QUICStreamProtocol,
        bodyStream: AsyncStream<Data>
    ) async throws {
        let headers = request.toHeaderList()

        // Extract Priority header (RFC 9218 Section 5.1)
        let priorityHeaderValue = headers.first(where: { $0.0.lowercased() == "priority" })?.1
        let initialPriority = StreamPriority.fromHeader(priorityHeaderValue)

        // Check for pending PRIORITY_UPDATE (may have arrived before the stream)
        let effectivePriority: StreamPriority
        if let pendingPriority = pendingPriorityUpdates.removeValue(forKey: stream.id) {
            effectivePriority = pendingPriority
        } else if let dynamicPriority = streamPriorities[stream.id] {
            effectivePriority = dynamicPriority
        } else {
            effectivePriority = initialPriority
        }
        streamPriorities[stream.id] = effectivePriority

        // Buffered respond closure — takes raw parameters (status, headers, body Data, trailers)
        let respondClosure: @Sendable (Int, [(String, String)], Data, [(String, String)]?) async throws -> Void = { [weak self] status, responseHeaders, body, trailers in
            guard let self = self else { return }
            await self.sendResponse(
                status: status,
                headers: responseHeaders,
                body: body,
                trailers: trailers,
                on: stream
            )
        }

        // Streaming respond closure
        let respondStreamingClosure: @Sendable (
            Int, [(String, String)], [(String, String)]?, @Sendable (HTTP3BodyWriter) async throws -> Void
        ) async throws -> Void = { [weak self] status, responseHeaders, trailers, writerBlock in
            guard let self = self else { return }
            await self.sendResponseStreaming(
                status: status,
                headers: responseHeaders,
                trailers: trailers,
                on: stream,
                writer: writerBlock
            )
        }

        let context = HTTP3RequestContext(
            request: request,
            streamID: stream.id,
            bodyStream: bodyStream,
            respond: respondClosure,
            respondStreaming: respondStreamingClosure
        )

        incomingRequestsContinuation?.yield(context)
    }

    // MARK: - Extended CONNECT Routing

    /// Routes an Extended CONNECT request to the appropriate handler.
    func routeExtendedConnectRequest(
        _ request: HTTP3Request,
        stream: any QUICStreamProtocol
    ) async {
        guard localSettings.enableConnectProtocol else {
            Self.logger.warning(
                "Received Extended CONNECT but SETTINGS_ENABLE_CONNECT_PROTOCOL is not enabled"
            )
            await stream.reset(errorCode: HTTP3ErrorCode.settingsError.rawValue)
            return
        }

        let sendResponseClosure: @Sendable (consuming HTTP3ResponseHead) async throws -> Void = { [weak self] resp in
            guard let self = self else { return }
            await self.sendResponseHeadersOnly(resp, on: stream)
        }

        let context = ExtendedConnectContext(
            request: request,
            streamID: stream.id,
            stream: stream,
            connection: self,
            sendResponse: sendResponseClosure
        )

        incomingExtendedConnectContinuation?.yield(context)
    }

    // MARK: - Response Sending (Server)

    /// Sends a buffered HTTP/3 response on a request stream.
    ///
    /// Encodes the response headers with QPACK, sends a HEADERS frame,
    /// then sends a DATA frame with the body, and closes the stream.
    ///
    /// - Parameters:
    ///   - status: HTTP status code
    ///   - headers: Response header fields
    ///   - body: Response body data
    ///   - trailers: Optional trailing header fields
    ///   - stream: The QUIC stream to send on
    func sendResponse(
        status: Int,
        headers: [(String, String)],
        body: Data,
        trailers: [(String, String)]?,
        on stream: any QUICStreamProtocol
    ) async {
        do {
            // Build response header list
            var headerList: [(name: String, value: String)] = [
                (name: ":status", value: String(status))
            ]
            for (name, value) in headers {
                headerList.append((name: name, value: value))
            }

            // Encode and send HEADERS frame
            let encodedHeaders = qpackEncoder.encode(headerList)
            let headersFrame = HTTP3Frame.headers(encodedHeaders)
            let headersData = HTTP3FrameCodec.encode(headersFrame)
            try await stream.write(headersData)

            // Send DATA frame if there's a body
            if !body.isEmpty {
                let dataFrame = HTTP3Frame.data(body)
                let dataData = HTTP3FrameCodec.encode(dataFrame)
                try await stream.write(dataData)
            }

            // Send trailers (if any) — RFC 9114 §4.1
            if let trailers = trailers, !trailers.isEmpty {
                let encodedTrailers = qpackEncoder.encode(trailers)
                let trailersFrame = HTTP3Frame.headers(encodedTrailers)
                let trailersData = HTTP3FrameCodec.encode(trailersFrame)
                try await stream.write(trailersData)
            }

            // Close the write side (FIN)
            try await stream.closeWrite()

        } catch {
            // Error sending response — reset the stream
            await stream.reset(errorCode: HTTP3ErrorCode.internalError.rawValue)
        }
    }

    /// Sends a streaming HTTP/3 response on a request stream.
    ///
    /// Sends the HEADERS frame immediately, then invokes the `writer`
    /// closure. Each call to `HTTP3BodyWriter.write()` inside the closure
    /// encodes a DATA frame and sends it on the stream. When the closure
    /// returns, optional trailers are sent and the stream is closed (FIN).
    ///
    /// Memory usage is flat regardless of total response size because
    /// body data is never accumulated — each chunk is written directly
    /// to the QUIC stream as a DATA frame.
    ///
    /// - Parameters:
    ///   - status: HTTP status code
    ///   - headers: Response headers
    ///   - trailers: Optional trailing headers sent after body
    ///   - stream: The QUIC stream to send on
    ///   - writer: Closure that writes body chunks via `HTTP3BodyWriter`
    func sendResponseStreaming(
        status: Int,
        headers: [(String, String)],
        trailers: [(String, String)]?,
        on stream: any QUICStreamProtocol,
        writer: @Sendable (HTTP3BodyWriter) async throws -> Void
    ) async {
        do {
            // Build response header list
            var headerList: [(name: String, value: String)] = [
                (name: ":status", value: String(status))
            ]
            for (name, value) in headers {
                headerList.append((name: name, value: value))
            }

            // Encode and send HEADERS frame
            let encodedHeaders = qpackEncoder.encode(headerList)
            let headersFrame = HTTP3Frame.headers(encodedHeaders)
            let headersData = HTTP3FrameCodec.encode(headersFrame)
            try await stream.write(headersData)

            // Create a body writer that encodes each chunk as a DATA frame
            let bodyWriter = HTTP3BodyWriter(
                _write: { [stream] chunk in
                    let dataFrame = HTTP3Frame.data(chunk)
                    let frameData = HTTP3FrameCodec.encode(dataFrame)
                    try await stream.write(frameData)
                }
            )

            // Invoke the writer closure — handler streams body through this
            try await writer(bodyWriter)

            // Send trailers if provided
            if let trailers = trailers, !trailers.isEmpty {
                let encodedTrailers = qpackEncoder.encode(
                    trailers.map { (name: $0.0, value: $0.1) }
                )
                let trailersFrame = HTTP3Frame.headers(encodedTrailers)
                let trailersData = HTTP3FrameCodec.encode(trailersFrame)
                try await stream.write(trailersData)
            }

            // Close the write side (FIN)
            try await stream.closeWrite()

        } catch {
            await stream.reset(errorCode: HTTP3ErrorCode.internalError.rawValue)
        }
    }

    /// Sends response headers only on a stream, WITHOUT closing the write side.
    ///
    /// Used for Extended CONNECT (RFC 9220) responses where the stream must
    /// remain open after the response headers are sent (e.g., for WebTransport
    /// session lifetime). Also sends the body if present, but does NOT send FIN.
    ///
    /// - Parameters:
    ///   - response: The HTTP/3 response to send
    ///   - stream: The QUIC stream to send on
    /// Sends an HTTP/3 response (headers + optional body) WITHOUT closing the stream.
    ///
    /// Used for Extended CONNECT where the stream stays open after the
    /// initial response (e.g. WebTransport session).
    ///
    /// Accepts `HTTP3Response` for compatibility with `ExtendedConnectContext`.
    /// Extracts buffered body data directly from the response.
    func sendResponseHeadersOnly(_ response: HTTP3ResponseHead, on stream: any QUICStreamProtocol) async {
        do {
            let headerList = response.toHeaderList()
            let encodedHeaders = qpackEncoder.encode(headerList)
            let headersFrame = HTTP3Frame.headers(encodedHeaders)
            let headersData = HTTP3FrameCodec.encode(headersFrame)
            try await stream.write(headersData)

            //TODO Cleanup later
            // let bodyData = response.bufferedBodyData
            // if !bodyData.isEmpty {
            //     let dataFrame = HTTP3Frame.data(bodyData)
            //     let dataData = HTTP3FrameCodec.encode(dataFrame)
            //     try await stream.write(dataData)
            // }

            // NOTE: Do NOT close the write side. The stream stays open
            // for the Extended CONNECT session (e.g., WebTransport).

        } catch {
            // Error sending response — reset the stream
            await stream.reset(errorCode: HTTP3ErrorCode.internalError.rawValue)
        }
    }
}
