/// QUICEndpoint — I/O Loop
///
/// Extension containing the UDP I/O loop, packet receive loop,
/// outbound send loop, timer processing loop, and stop logic.

import Foundation
import QUICCore
import QUICConnection
@_exported import QUICTransport
import NIOUDPTransport

// MARK: - UDP I/O Loop

extension QUICEndpoint {

    /// Runs the main I/O loop with a real UDP socket
    ///
    /// This method starts the event loop that:
    /// - Receives UDP datagrams from the socket
    /// - Processes them through the QUIC state machine
    /// - Sends response packets
    /// - Handles timer events
    ///
    /// The loop runs until `stop()` is called.
    ///
    /// - Parameter socket: The UDP socket to use for I/O
    /// - Throws: QUICEndpointError.alreadyRunning if already running
    public func run(socket: any QUICSocket) async throws {
        guard !isRunning else {
            throw QUICEndpointError.alreadyRunning
        }

        self.socket = socket
        self.isRunning = true
        self.shouldStop = false

        // Start the socket
        try await socket.start()

        // Update local address
        if let nioAddr = await socket.localAddress,
           let addr = SocketAddress(nioAddr) {
            _localAddress = addr
        }

        // Start the I/O loop with cancellation handling
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                // Packet receiving task
                group.addTask {
                    await self.packetReceiveLoop(socket: socket)
                }

                // Timer processing task
                group.addTask {
                    await self.timerProcessingLoop(socket: socket)
                }

                // Wait for both tasks to complete
                await group.waitForAll()
            }
        } onCancel: {
            // When the task is cancelled, stop the socket to unblock the I/O loops
            Task { [socket] in
                await socket.stop()
            }
        }

        // Cleanup
        if !shouldStop {
            // Only stop socket if not already stopped by stop()
            await socket.stop()
        }
        self.socket = nil
        self.isRunning = false
    }

    /// Internal method to run packet loop without setup (for use by dial())
    ///
    /// - Parameter socket: The already-started socket
    func runPacketLoop(socket: any QUICSocket) async throws {
        self.shouldStop = false

        // Update local address
        if let nioAddr = await socket.localAddress,
           let addr = SocketAddress(nioAddr) {
            _localAddress = addr
        }

        // Start the I/O loop with cancellation handling
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                // Packet receiving task
                group.addTask {
                    await self.packetReceiveLoop(socket: socket)
                }

                // Timer processing task
                group.addTask {
                    await self.timerProcessingLoop(socket: socket)
                }

                // Wait for both tasks to complete
                await group.waitForAll()
            }
        } onCancel: {
            // When the task is cancelled, stop the socket to unblock the I/O loops
            Task { [socket] in
                await socket.stop()
            }
        }

        // Cleanup
        if !shouldStop {
            await socket.stop()
        }
        self.socket = nil
        self.isRunning = false
    }

    /// Stops the I/O loop
    ///
    /// This method signals the I/O tasks to stop and finishes the socket's
    /// incoming stream, allowing the packet receive loop to exit gracefully.
    public func stop() async {
        guard isRunning else { return }
        shouldStop = true

        // Finish the incoming connections stream
        incomingConnectionContinuation?.finish()
        incomingConnectionContinuation = nil

        // Stop the socket to finish its AsyncStream
        // This will cause the packetReceiveLoop's for-await to exit
        if let socket = socket {
            await socket.stop()
        }
    }

    /// The packet receive loop
    func packetReceiveLoop(socket: any QUICSocket) async {
        for await packet in socket.incomingPackets {
            guard !shouldStop else { break }

            // Convert NIO address to QUIC address
            guard let remoteAddress = SocketAddress(packet.remoteAddress) else {
                continue
            }

            do {
                let responses = try await processIncomingPacket(
                    Data(buffer: packet.buffer),
                    from: remoteAddress,
                    ecnCodepoint: packet.ecnCodepoint
                )
                for response in responses {
                    try await socket.send(response, to: packet.remoteAddress)
                }
            } catch {
                logger.warning("Error processing packet from \(remoteAddress): \(error)")
            }
        }
    }

    /// The outbound send loop for a connection
    ///
    /// Monitors the connection's sendSignal and sends packets when data is available.
    /// This enables immediate packet transmission when stream data is written,
    /// rather than waiting for incoming packets or timer events.
    ///
    /// The loop exits when:
    /// - The connection is shut down (sendSignal finishes)
    /// - The endpoint stops (shouldStop becomes true)
    ///
    /// - Parameters:
    ///   - connection: The connection to monitor
    ///   - sendSignal: The pre-initialized send signal stream
    ///   - socket: The socket to send packets through
    func outboundSendLoop(
        connection: ManagedConnection,
        sendSignal: AsyncStream<Void>,
        socket: any QUICSocket
    ) async {
        logger.debug("outboundSendLoop STARTED for connection SCID=\(connection.sourceConnectionID)")
        var iterationCount = 0
        for await _ in sendSignal {
            iterationCount += 1
            logger.trace("outboundSendLoop signal #\(iterationCount) for SCID=\(connection.sourceConnectionID), shouldStop=\(shouldStop)")
            guard !shouldStop else { logger.debug("outboundSendLoop breaking due to shouldStop"); break }

            do {
                // Generate and send packets in a loop.
                // `generateStreamFrames(maxBytes:)` caps each round at the
                // configured maxDatagramSize bytes of stream frames, so when
                // multiple streams have data queued (or a single stream has
                // a large write) a single round may not drain everything.
                // Re-check after each send and keep going until no pending
                // stream data remains.  This avoids relying on another
                // `signalNeedsSend()` (which may have been coalesced away
                // by `bufferingNewest(1)`).
                var rounds = 0
                let nioAddress = try connection.remoteAddress.toNIOAddress()
                repeat {
                    let packets = try connection.generateOutboundPackets()
                    if !packets.isEmpty {
                        rounds += 1
                        logger.trace("Sending \(packets.count) packets, round \(rounds) (total \(packets.map(\.count).reduce(0, +)) bytes)")
                    }

                    // Batch-send all packets in a single syscall (sendmmsg on Linux).
                    // NIO coalesces N write() + 1 flush() into one kernel transition.
                    if !packets.isEmpty {
                        try await socket.sendBatch(packets, to: nioAddress)
                        logger.trace("Batch-sent \(packets.count) packets")
                    }

                    // If no packets were produced this round we're done
                    // regardless of what hasPendingStreamData says (the
                    // remaining data may be flow-control blocked).
                    if packets.isEmpty { break }
                } while connection.hasPendingStreamData && !shouldStop
            } catch {
                // Log error but continue - don't break the loop for transient errors
                logger.warning(
                    "Failed to send outbound packets",
                    metadata: [
                        "error": "\(error)",
                        "remoteAddress": "\(connection.remoteAddress)"
                    ]
                )
            }
        }

        // Loop ended: sendSignal was finished (connection closing or endpoint stopping).
        // Flush any final queued packets — in particular the CONNECTION_CLOSE frame
        // that handler.close() queued just before shutdown() finished the signal.
        // Without this flush the peer never learns the connection was closed and
        // keeps sending packets to a DCID that we are about to unregister.
        //
        // Skip the flush when the endpoint is stopping (`shouldStop` is true) —
        // the socket is already torn down or about to be, so sending will fail
        // with "UDP transport not started" and the peer will time out anyway.
        if !shouldStop {
            do {
                let finalPackets = try connection.generateOutboundPackets()
                if !finalPackets.isEmpty {
                    logger.debug("outboundSendLoop flushing \(finalPackets.count) final packets for SCID=\(connection.sourceConnectionID)")
                    let finalNioAddress = try connection.remoteAddress.toNIOAddress()
                    try await socket.sendBatch(finalPackets, to: finalNioAddress)
                }
            } catch {
                // Best-effort — if we can't send the final packets, just log and proceed.
                // Use trace level: the most common cause is the socket already being
                // stopped (e.g. dial() timeout cleanup), which is expected.
                logger.trace(
                    "Failed to flush final packets on connection close",
                    metadata: [
                        "error": "\(error)",
                        "remoteAddress": "\(connection.remoteAddress)"
                    ]
                )
            }
        } else {
            logger.trace("outboundSendLoop skipping final flush — endpoint is stopping (SCID=\(connection.sourceConnectionID))")
        }

        logger.debug("outboundSendLoop EXITED for connection SCID=\(connection.sourceConnectionID) after \(iterationCount) iterations, shouldStop=\(shouldStop)")
        router.unregister(connection)
        timerManager.markClosed(connection)
    }

    /// The timer processing loop
    func timerProcessingLoop(socket: any QUICSocket) async {
        while !shouldStop {
            // Calculate time until next timer
            let nextDeadline = timerManager.nextDeadline()
            let waitDuration: Duration

            if let deadline = nextDeadline {
                let now = ContinuousClock.now
                if deadline <= now {
                    waitDuration = .zero
                } else {
                    waitDuration = deadline - now
                }
            } else {
                // No active timers, wait for a reasonable interval
                waitDuration = .milliseconds(100)
            }

            // Wait until next timer or timeout
            do {
                try await Task.sleep(for: waitDuration)
            } catch {
                // Task was cancelled
                break
            }

            // Process timer events
            do {
                let packets = try await processTimers()
                for (data, address) in packets {
                    let nioAddress = try address.toNIOAddress()
                    try await socket.send(data, to: nioAddress)
                }
            } catch {
                // Log error but continue
            }
        }
    }
}