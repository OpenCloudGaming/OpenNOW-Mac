/// HTTP3Connection — Stream Setup & Incoming Dispatch
///
/// Control stream, QPACK stream setup, and incoming stream routing
/// (both unidirectional and bidirectional).

import Foundation
import QUIC
import QUICCore
import QUICStream
import QPACK

extension HTTP3Connection {

    // MARK: - Control Stream Setup

    /// Opens our local control stream and sends the initial SETTINGS frame.
    func openControlStream() async throws {
        let stream = try await quicConnection.openUniStream()
        localControlStream = stream

        // Write stream type (Control = 0x00)
        let streamTypeData = HTTP3StreamType.control.encode()
        try await stream.write(streamTypeData)

        // Write SETTINGS frame
        let settingsFrame = HTTP3Frame.settings(localSettings)
        let settingsData = HTTP3FrameCodec.encode(settingsFrame)
        try await stream.write(settingsData)
    }

    /// Opens QPACK encoder and decoder unidirectional streams.
    ///
    /// These streams are required even in literal-only mode (RFC 9204 Section 4.2).
    /// In literal-only mode, no instructions are sent on these streams.
    func openQPACKStreams() async throws {
        // Open QPACK encoder stream
        let encoderStream = try await quicConnection.openUniStream()
        localQPACKEncoderStream = encoderStream
        let encoderTypeData = HTTP3StreamType.qpackEncoder.encode()
        try await encoderStream.write(encoderTypeData)

        // Open QPACK decoder stream
        let decoderStream = try await quicConnection.openUniStream()
        localQPACKDecoderStream = decoderStream
        let decoderTypeData = HTTP3StreamType.qpackDecoder.encode()
        try await decoderStream.write(decoderTypeData)
    }

    // MARK: - Incoming Stream Processing

    /// Processes incoming QUIC streams (both bidirectional and unidirectional).
    ///
    /// Bidirectional streams are request streams. Unidirectional streams
    /// are classified by their stream type byte and routed accordingly.
    func processIncomingStreams(from connection: any QUICConnectionProtocol) async {
        Self.logger.debug("processIncomingStreams started (role=\(role))")
        for await stream in connection.incomingStreams {
            Self.logger.trace("Received incoming stream id=\(stream.id), isUni=\(stream.isUnidirectional) (role=\(role))")
            if stream.isUnidirectional {
                Task { [weak self] in
                    Self.logger.trace("handleIncomingUniStream task starting for stream \(stream.id)")
                    await self?.handleIncomingUniStream(stream)
                    Self.logger.trace("handleIncomingUniStream task finished for stream \(stream.id)")
                }
            } else {
                // Bidirectional stream — could be HTTP/3 request or WebTransport bidi
                Task { [weak self] in
                    Self.logger.trace("handleIncomingBidiStream task starting for stream \(stream.id)")
                    await self?.handleIncomingBidiStream(stream)
                    Self.logger.trace("handleIncomingBidiStream task finished for stream \(stream.id)")
                }
            }
        }
        Self.logger.debug("processIncomingStreams ended (role=\(role))")
    }

    // MARK: - Unidirectional Stream Handling

    /// Handles an incoming unidirectional stream by reading its type byte
    /// and routing it to the appropriate handler.
    ///
    /// The stream type is sent as the first varint on the stream. Any
    /// remaining bytes after the type varint are forwarded to the handler
    /// as initial buffered data to avoid data loss.
    ///
    /// WebTransport unidirectional streams use stream type 0x54. When
    /// detected, the session ID varint is read and the stream is routed
    /// to the corresponding `WebTransportSession`.
    func handleIncomingUniStream(_ stream: any QUICStreamProtocol) async {
        do {
            // Read the stream type (first varint on the stream)
            // We read a small amount — the varint is typically 1 byte,
            // but the read may also contain subsequent frame data.
            Self.logger.trace("handleIncomingUniStream: reading type from stream \(stream.id)")
            let typeData = try await stream.read()
            Self.logger.trace("handleIncomingUniStream: got \(typeData.count) bytes from stream \(stream.id): \(typeData.map { String(format: "%02x", $0) }.joined())")
            guard !typeData.isEmpty else {
                Self.logger.trace("handleIncomingUniStream: empty data from stream \(stream.id), returning")
                return
            }

            guard let (streamTypeValue, consumed) = try HTTP3StreamType.decode(from: typeData) else {
                Self.logger.warning("handleIncomingUniStream: failed to decode stream type from stream \(stream.id)")
                return
            }

            // Extract any remaining data after the stream type varint.
            // This data belongs to the first frame on the stream and
            // must NOT be discarded.
            let remainingData: Data
            if consumed < typeData.count {
                remainingData = Data(typeData.dropFirst(consumed))
            } else {
                remainingData = Data()
            }

            // Check for WebTransport unidirectional stream (type 0x54)
            if WebTransportStreamClassification.isWebTransportStream(streamTypeValue) {
                Self.logger.debug("handleIncomingUniStream: stream \(stream.id) is WebTransport uni stream (type 0x54)")
                await routeWebTransportUniStream(stream, initialData: remainingData)
                return
            }

            let classification = HTTP3StreamClassification.classify(streamTypeValue)
            Self.logger.trace("handleIncomingUniStream: stream \(stream.id) classified as \(classification), remainingData=\(remainingData.count) bytes")

            switch classification {
            case .known(let streamType):
                switch streamType {
                case .control:
                    Self.logger.debug("handleIncomingUniStream: stream \(stream.id) is CONTROL stream, calling handleIncomingControlStream")
                    try await handleIncomingControlStream(stream, remainingData: remainingData)
                case .qpackEncoder:
                    await handleIncomingQPACKEncoderStream(stream)
                case .qpackDecoder:
                    await handleIncomingQPACKDecoderStream(stream)
                case .push:
                    if role == .server {
                        // Servers don't receive push streams
                        await stream.reset(
                            errorCode: HTTP3ErrorCode.streamCreationError.rawValue
                        )
                    }
                    // Client-side push handling not implemented
                }

            case .grease:
                // GREASE streams must be silently ignored
                // Drain and discard the stream
                _ = try? await stream.read()

            case .unknown:
                // Unknown stream types must be silently ignored
                _ = try? await stream.read()
            }
        } catch {
            // Stream read error — log and ignore
        }
    }

    /// Handles the peer's incoming control stream.
    ///
    /// Validates that only one control stream exists, reads the SETTINGS
    /// frame (with buffering to tolerate fragmentation), and then continues
    /// reading control frames (GOAWAY, etc.).
    ///
    /// - Parameters:
    ///   - stream: The QUIC stream for the peer's control stream
    ///   - remainingData: Any data read after the stream type varint
    ///     (may contain part or all of the first SETTINGS frame)
    func handleIncomingControlStream(
        _ stream: any QUICStreamProtocol,
        remainingData: Data
    ) async throws {
        Self.logger.debug("handleIncomingControlStream: stream \(stream.id), remainingData=\(remainingData.count) bytes: \(remainingData.map { String(format: "%02x", $0) }.joined())")
        // Only one control stream per peer
        guard !peerControlStreamReceived else {
            throw HTTP3Error(
                code: .streamCreationError,
                reason: "Duplicate peer control stream"
            )
        }

        peerControlStreamReceived = true
        peerControlStream = stream

        // Start a buffer with any leftover data from the stream type read
        var buffer = remainingData

        // Read the first frame — MUST be SETTINGS (RFC 9114 Section 6.2.1)
        // The SETTINGS frame may arrive across multiple reads, so we buffer
        // until a complete frame is available.
        Self.logger.debug("handleIncomingControlStream: reading SETTINGS frame (buffer=\(buffer.count) bytes)")
        let settingsFrame = try await readNextFrame(from: stream, buffer: &buffer)
        Self.logger.trace("handleIncomingControlStream: got frame: \(settingsFrame)")

        guard case .settings(let settings) = settingsFrame else {
            Self.logger.warning("handleIncomingControlStream: first frame is NOT settings: \(settingsFrame)")
            throw HTTP3Error.missingSettings
        }

        Self.logger.info("handleIncomingControlStream: received peer SETTINGS: \(settings)")
        peerSettings = settings

        // Transition to ready state
        if state == .initializing {
            state = .ready
            Self.logger.debug("handleIncomingControlStream: state -> ready")
        }

        // Continue reading control frames
        await readControlFrames(from: stream, initialBuffer: buffer)
    }

    /// Reads and processes control frames from the peer's control stream.
    ///
    /// This runs for the lifetime of the connection, processing GOAWAY
    /// and other control frames as they arrive. Uses buffered reading
    /// to tolerate frame fragmentation across QUIC stream reads.
    ///
    /// - Parameters:
    ///   - stream: The peer's control stream
    ///   - initialBuffer: Any unconsumed bytes from previous reads
    func readControlFrames(
        from stream: any QUICStreamProtocol,
        initialBuffer: Data = Data()
    ) async {
        var buffer = initialBuffer

        while true {
            // First, try to decode frames already in the buffer
            do {
                let (frames, _) = try decodeFramesFromBuffer(&buffer)

                for frame in frames {
                    // Check for reserved HTTP/2 frame types
                    if HTTP3ReservedFrameType.isReserved(frame.frameType) {
                        await close(error: .frameUnexpected)
                        return
                    }

                    switch frame {
                    case .goaway(let streamID):
                        goawayStreamID = streamID
                        state = .goingAway(lastStreamID: streamID)

                    case .settings:
                        // Duplicate SETTINGS is a connection error
                        await close(error: .frameUnexpected)
                        return

                    case .maxPushID:
                        // Only valid if we're a server
                        if role != .server {
                            await close(error: .frameUnexpected)
                            return
                        }

                    case .priorityUpdateRequest(let streamID, let priority):
                        // RFC 9218: Dynamic reprioritization of request streams
                        // Only valid from a client (received by server)
                        if role == .server {
                            handlePriorityUpdate(streamID: streamID, priority: priority)
                        } else {
                            // Clients shouldn't receive request PRIORITY_UPDATE
                            await close(error: .frameUnexpected)
                            return
                        }

                    case .priorityUpdatePush(let pushID, let priority):
                        // RFC 9218: Dynamic reprioritization of push streams
                        // Only valid from a client (received by server)
                        if role == .server {
                            handlePriorityUpdate(streamID: pushID, priority: priority)
                        } else {
                            // Clients shouldn't receive push PRIORITY_UPDATE
                            await close(error: .frameUnexpected)
                            return
                        }

                    case .cancelPush:
                        // Push cancellation — not implemented yet
                        break

                    case .data, .headers, .pushPromise:
                        // These frames are NOT allowed on control streams
                        await close(error: .frameUnexpected)
                        return

                    case .unknown:
                        // Unknown frames on control stream are allowed
                        break
                    }
                }
            } catch {
                // Malformed frame on control stream
                await close(error: .frameError)
                return
            }

            // Read more data from the stream
            do {
                let data = try await stream.read()
                if data.isEmpty {
                    // Control stream closed — this is a connection error
                    await close(error: .closedCriticalStream)
                    return
                }
                buffer.append(data)
            } catch {
                // Error reading from control stream
                await close(error: .closedCriticalStream)
                return
            }
        }
    }

    // MARK: - QPACK Stream Handling

    /// Handles the peer's incoming QPACK encoder stream.
    ///
    /// In literal-only mode, no instructions are expected. The stream
    /// is drained and discarded.
    func handleIncomingQPACKEncoderStream(_ stream: any QUICStreamProtocol) async {
        guard !peerQPACKEncoderStreamReceived else {
            // Duplicate — connection error
            await close(error: .streamCreationError)
            return
        }

        peerQPACKEncoderStreamReceived = true
        peerQPACKEncoderStream = stream

        // In literal-only mode, drain the stream
        do {
            while true {
                let data = try await stream.read()
                if data.isEmpty { break }
                // In full QPACK mode, we'd process encoder instructions here
            }
        } catch {
            // Stream closed or error — for critical streams this is an error
            // but in literal-only mode we tolerate it
        }
    }

    /// Handles the peer's incoming QPACK decoder stream.
    ///
    /// In literal-only mode, no instructions are expected. The stream
    /// is drained and discarded.
    func handleIncomingQPACKDecoderStream(_ stream: any QUICStreamProtocol) async {
        guard !peerQPACKDecoderStreamReceived else {
            // Duplicate — connection error
            await close(error: .streamCreationError)
            return
        }

        peerQPACKDecoderStreamReceived = true
        peerQPACKDecoderStream = stream

        // In literal-only mode, drain the stream
        do {
            while true {
                let data = try await stream.read()
                if data.isEmpty { break }
                // In full QPACK mode, we'd process decoder instructions here
            }
        } catch {
            // Stream closed or error
        }
    }

    // MARK: - Incoming Bidirectional Stream Routing

    /// Upper bound on the bytes consumed while reading WebTransport
    /// bidirectional framing (two varints, at most 8 bytes each).
    private static let maxWebTransportFramingBytes = 16

    /// Routes an incoming bidirectional stream to either WebTransport or
    /// HTTP/3 request handling.
    ///
    /// The 0x41 signal and session ID may straddle STREAM frames, so reads continue until both
    /// are complete or the framing cap is reached. A peer that predates the signal sends the ID alone.
    func handleIncomingBidiStream(_ stream: any QUICStreamProtocol) async {
        guard !webTransportSessions.isEmpty else {
            await handleIncomingRequestStream(stream)
            return
        }

        var buffer = Data()
        while true {
            do {
                let chunk = try await stream.read()
                if chunk.isEmpty {
                    return
                }
                buffer.append(chunk)
            } catch {
                return
            }

            guard let (firstVarint, firstLength) = try? Varint.decode(from: buffer) else {
                if buffer.count >= Self.maxWebTransportFramingBytes {
                    await stream.reset(errorCode: HTTP3ErrorCode.messageError.rawValue)
                    return
                }
                continue
            }

            if firstVarint.value != kWebTransportBidiSignal {
                // Without the signal the first varint is an older peer's session ID or an HTTP/3
                // frame type; a valid frame type is request framing, never a session.
                guard HTTP3FrameType(rawValue: firstVarint.value) == nil,
                      let session = webTransportSessions[firstVarint.value] else {
                    await handleIncomingRequestStreamWithBuffer(stream, initialBuffer: buffer)
                    return
                }
                let remaining = buffer.count > firstLength
                    ? Data(buffer.dropFirst(firstLength))
                    : Data()
                await session.deliverIncomingBidirectionalStream(stream, initialData: remaining)
                return
            }

            let afterSignal = Data(buffer.dropFirst(firstLength))
            guard let (sessionVarint, sessionLength) = try? Varint.decode(from: afterSignal) else {
                if buffer.count >= Self.maxWebTransportFramingBytes {
                    await stream.reset(errorCode: HTTP3ErrorCode.messageError.rawValue)
                    return
                }
                continue
            }

            // The signal makes this unambiguously WebTransport, so an unknown session ID is
            // reset rather than rerouted to request handling.
            guard let session = webTransportSessions[sessionVarint.value] else {
                await stream.reset(errorCode: HTTP3ErrorCode.messageError.rawValue)
                return
            }
            let remaining = afterSignal.count > sessionLength
                ? Data(afterSignal.dropFirst(sessionLength))
                : Data()
            await session.deliverIncomingBidirectionalStream(stream, initialData: remaining)
            return
        }
    }
}