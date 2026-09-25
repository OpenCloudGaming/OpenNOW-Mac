/// QUICConnectionHandler — Frame Processing
///
/// Extension containing frame processing logic:
/// - `processFrames` — processes all frames from a decrypted packet
/// - `processAckFrame` — RFC 9002 compliant ACK processing
/// - `processCryptoFrame` — buffers and reads CRYPTO data
/// - `processConnectionClose` — handles CONNECTION_CLOSE frames
/// - `processHandshakeDone` — handles HANDSHAKE_DONE frames

import Foundation
import QUICCore
import QUICRecovery
import QUICCrypto
import QUICStream
import QUICTransport

// MARK: - Frame Processing

extension QUICConnectionHandler {

    /// Processes frames from a decrypted packet
    /// - Parameters:
    ///   - frames: The frames to process
    ///   - level: The encryption level
    /// - Returns: Processing result
    /// - Throws: ProtocolViolation if a frame is not valid at the encryption level
    package func processFrames(
        _ frames: [Frame],
        level: EncryptionLevel
    ) throws -> FrameProcessingResult {
        var result = FrameProcessingResult()

        for frame in frames {
            // RFC 9000 §12.4: Validate frame type is allowed at this encryption level
            guard frame.isValid(at: level) else {
                throw QUICError.frameNotAllowed(
                    frameType: UInt64(frame.frameType.rawValue),
                    packetType: "\(level)"
                )
            }

            Self.logger.trace("Processing frame: \(frame) at level: \(level)")

            switch frame {
            case .ack(let ackFrame):
                try processAckFrame(ackFrame, level: level)

            case .crypto(let cryptoFrame):
                try processCryptoFrame(cryptoFrame, level: level, result: &result)

            case .connectionClose(let closeFrame):
                Self.logger.warning("CONNECTION_CLOSE received: errorCode=\(closeFrame.errorCode), frameType=\(String(describing: closeFrame.frameType)), reason=\(closeFrame.reasonPhrase), isAppError=\(closeFrame.isApplicationError)")
                processConnectionClose(closeFrame)
                result.connectionClosed = true

            case .handshakeDone:
                Self.logger.debug("Received HANDSHAKE_DONE frame")
                processHandshakeDone()
                result.handshakeComplete = true

            case .stream(let streamFrame):
                // Check if this is a new peer-initiated stream
                let isNewStream = !streamManager.hasStream(id: streamFrame.streamID)
                let isRemote = isRemoteStream(streamFrame.streamID)
                Self.logger.trace("STREAM frame: streamID=\(streamFrame.streamID), isNew=\(isNewStream), isRemote=\(isRemote), dataLen=\(streamFrame.data.count), fin=\(streamFrame.fin)")

                try streamManager.receive(frame: streamFrame)

                // Track new peer-initiated streams
                if isNewStream {
                    if isRemote {
                        Self.logger.debug("Adding streamID=\(streamFrame.streamID) to newStreams")
                        result.newStreams.append(streamFrame.streamID)
                    } else {
                        Self.logger.trace("Skipping streamID=\(streamFrame.streamID) - locally initiated")
                    }
                }

                // Read available data from the stream
                if let data = streamManager.read(streamID: streamFrame.streamID) {
                    Self.logger.trace("Read \(data.count) bytes from stream \(streamFrame.streamID)")
                    result.streamData.append((streamFrame.streamID, data))
                } else {
                    Self.logger.trace("No data available from stream \(streamFrame.streamID) after receive")
                }

                // Check if the stream's receive side is now complete (FIN
                // received and all contiguous data consumed).  Tracking this
                // allows ManagedConnection to resume any blocked reader with
                // an end-of-stream signal instead of letting it hang forever.
                if streamManager.isStreamReceiveComplete(streamID: streamFrame.streamID) {
                    Self.logger.debug("Stream \(streamFrame.streamID) receive complete (FIN)")
                    result.finishedStreams.append(streamFrame.streamID)
                }

            case .resetStream(let resetFrame):
                try streamManager.handleResetStream(resetFrame)

            case .stopSending(let stopFrame):
                streamManager.handleStopSending(stopFrame)

            case .maxData(let maxData):
                streamManager.handleMaxData(MaxDataFrame(maxData: maxData))

            case .maxStreamData(let maxStreamDataFrame):
                streamManager.handleMaxStreamData(maxStreamDataFrame)

            case .maxStreams(let maxStreamsFrame):
                streamManager.handleMaxStreams(maxStreamsFrame)

            case .dataBlocked, .streamDataBlocked, .streamsBlocked:
                // Generate flow control frames as needed
                break

            case .padding, .ping:
                // No action needed
                break

            // MARK: - Connection Migration Frames

            case .pathChallenge(let data):
                // Handle challenge using PathValidationManager
                // Queue PATH_RESPONSE frame to send back
                let responseFrame = pathValidationManager.handleChallenge(data)
                queueFrame(responseFrame, level: level)
                result.pathChallengeData.append(data)

            case .pathResponse(let data):
                // Check DPLPMTUD probes first — a PATH_RESPONSE may be
                // acknowledging a PMTUD probe rather than a migration
                // PATH_CHALLENGE.  If it matches, record the new MTU
                // and skip the migration path validation manager.
                if pmtuDiscovery.isProbeResponse(data) {
                    if let newMTU = pmtuDiscovery.probeAcknowledged(challengeData: data) {
                        result.discoveredPLPMTU = newMTU
                    }
                } else {
                    // Handle response using PathValidationManager
                    if let validatedPath = pathValidationManager.handleResponse(data) {
                        result.pathValidated = validatedPath
                    }
                }
                result.pathResponseData.append(data)

            case .newConnectionID(let frame):
                Self.logger.debug("Received NEW_CONNECTION_ID: CID=\(frame.connectionID), seq=\(frame.sequenceNumber), retirePriorTo=\(frame.retirePriorTo)")
                // Process using ConnectionIDManager
                // RFC 9000 §5.1.1: Validates duplicate sequence numbers and limit
                try connectionIDManager.handleNewConnectionID(frame)
                // Register the stateless reset token
                statelessResetManager.registerReceivedToken(frame.statelessResetToken)
                result.newConnectionIDs.append(frame)

            case .retireConnectionID(let sequenceNumber):
                // Process using ConnectionIDManager
                if let retired = connectionIDManager.handleRetireConnectionID(sequenceNumber) {
                    // Remove the associated reset token
                    statelessResetManager.removeReceivedToken(retired.statelessResetToken)
                }
                result.retiredConnectionIDs.append(sequenceNumber)

            case .datagram(let datagramFrame):
                // RFC 9221: DATAGRAM frames carry unreliable application data
                Self.logger.trace("DATAGRAM frame received: \(datagramFrame.data.count) bytes")
                result.datagramsReceived.append(datagramFrame.data)

            default:
                // Other frames handled as needed
                break
            }
        }

        return result
    }

    /// Processes an ACK frame
    ///
    /// RFC 9002 compliant ACK processing:
    /// 1. Process ACK to detect acked/lost packets and update RTT
    /// 2. Notify congestion controller of acknowledged packets
    /// 3. Handle packet loss with congestion control
    ///
    /// - Note: Uses internally managed `peerMaxAckDelay` for RTT/PTO calculations.
    func processAckFrame(_ ackFrame: AckFrame, level: EncryptionLevel) throws {
        let now = ContinuousClock.Instant.now

        let result = pnSpaceManager.onAckReceived(
            ackFrame: ackFrame,
            level: level,
            receiveTime: now
        )

        // ECN feedback processing (RFC 9000 §13.4.2.1)
        //
        // When the peer includes ECN counts in its ACK frame, feed them
        // into the ECNManager for validation and congestion detection.
        // ECNCounts (QUICCore wire format) -> ECNCountState (QUICTransport bookkeeping).
        if let wireECN = ackFrame.ecnCounts {
            let peerCounts = ECNCountState(
                ect0: wireECN.ect0Count,
                ect1: wireECN.ect1Count,
                ce: wireECN.ecnCECount
            )
            let newCEMarks = ecnManager.processACKFeedback(peerCounts, level: level)
            if newCEMarks > 0 {
                // CE marks indicate congestion on the path — signal the
                // congestion controller the same way a packet loss would.
                congestionController.onECNCongestionEvent(now: now)
            }
        }

        // Congestion Control: process acknowledged packets
        if !result.ackedPackets.isEmpty {
            congestionController.onPacketsAcknowledged(
                packets: result.ackedPackets,
                now: now,
                rtt: pnSpaceManager.rttEstimator
            )
        }

        // Congestion Control: process lost packets
        if !result.lostPackets.isEmpty {
            // RFC 9002 Section 7.6.2 - Persistent Congestion
            //
            // Per the RFC, persistent congestion detection happens AFTER loss detection,
            // and causes an ADDITIONAL response beyond normal loss handling:
            // - Normal loss: cwnd reduced by half, enter recovery
            // - Persistent congestion: cwnd collapsed to minimum, ssthresh reset
            //
            // Implementation note:
            // We use if-else here because persistent congestion subsumes normal loss:
            // - Both would enter recovery, but persistent congestion also resets ssthresh
            // - Applying loss first (cwnd/2) then persistent congestion (cwnd=minimum)
            //   would give the same result as applying persistent congestion alone
            // - The key difference is ssthresh reset, which only persistent congestion does
            //
            // This optimization is valid because:
            // - minimum_window (2*MSS) < cwnd/2 for any cwnd > 4*MSS (always true after slow start)
            // - Persistent congestion resets to slow start (ssthresh=∞), which is the desired behavior
            if pnSpaceManager.checkPersistentCongestion(lostPackets: result.lostPackets) {
                congestionController.onPersistentCongestion()
            } else {
                congestionController.onPacketsLost(
                    packets: result.lostPackets,
                    now: now,
                    rtt: pnSpaceManager.rttEstimator
                )
            }
        }
    }

    /// Processes a CRYPTO frame
    func processCryptoFrame(
        _ cryptoFrame: CryptoFrame,
        level: EncryptionLevel,
        result: inout FrameProcessingResult
    ) throws {
        // Buffer the crypto data
        try cryptoStreamManager.receive(cryptoFrame, at: level)

        // Try to read complete data
        if let data = cryptoStreamManager.read(at: level) {
            result.cryptoData.append((level, data))
        }
    }

    /// Processes CONNECTION_CLOSE frame
    func processConnectionClose(_ closeFrame: ConnectionCloseFrame) {
        connectionState.withLock { state in
            state.status = .draining
        }
    }

    /// Processes HANDSHAKE_DONE frame
    func processHandshakeDone() {
        handshakeComplete.withLock { $0 = true }
        connectionState.withLock { $0.status = .established }
        pnSpaceManager.handshakeConfirmed = true
    }
}