/// QUIC UDP Socket Integration
///
/// Integrates swift-nio-udp for QUIC packet I/O.
///
/// ## ECN Support
///
/// `IncomingPacket` carries an optional ``ECNCodepoint`` extracted from
/// the IP TOS / traffic-class byte via `recvmsg()` ancillary data.
/// When the underlying transport does not provide ECN metadata the
/// field defaults to `.notECT`.
///
/// Outgoing ECN marking is set via `IP_TOS` / `IPV6_TCLASS` socket
/// options at socket creation time (see ``PlatformSocketOptions``).

import Foundation
import NIOCore
import NIOUDPTransport
import QUICCore
import Synchronization

// MARK: - QUIC Socket

/// A UDP socket for QUIC communication
public protocol QUICSocket: Sendable {
    /// The local address bound to
    var localAddress: SocketAddress? { get async }

    /// Sends a QUIC packet
    /// - Parameters:
    ///   - data: The packet data
    ///   - address: The destination address
    func send(_ data: Data, to address: SocketAddress) async throws

    /// Sends multiple QUIC packets in a single batch (reduced syscall overhead).
    ///
    /// On Linux, NIO coalesces the writes into a single `sendmmsg()` syscall.
    /// Implementations that do not support batching should fall back to
    /// sequential `send()` calls.
    ///
    /// - Parameters:
    ///   - packets: The packet data array
    ///   - address: The shared destination address for all packets
    func sendBatch(_ packets: [Data], to address: SocketAddress) async throws

    /// Receives incoming packets
    var incomingPackets: AsyncStream<IncomingPacket> { get }

    /// Starts the socket
    func start() async throws

    /// Stops the socket
    func stop() async
}

/// An incoming QUIC packet
public struct IncomingPacket: Sendable {
    /// The packet data as ByteBuffer (zero-copy from NIO).
    public let buffer: ByteBuffer

    /// The remote address that sent this packet
    public let remoteAddress: SocketAddress

    /// The time the packet was received
    public let receivedAt: ContinuousClock.Instant

    /// ECN codepoint extracted from the IP TOS / traffic-class byte.
    ///
    /// Populated from `recvmsg()` ancillary data (`IP_RECVTOS` /
    /// `IPV6_RECVTCLASS`) when the socket is configured for ECN.
    /// Defaults to `.notECT` when the transport layer does not
    /// provide ECN metadata.
    ///
    /// Fed into ``ECNManager/recordIncoming(_:level:)`` during
    /// packet processing.
    public let ecnCodepoint: ECNCodepoint

    /// Creates an incoming packet with full metadata.
    public init(
        buffer: ByteBuffer,
        remoteAddress: SocketAddress,
        receivedAt: ContinuousClock.Instant,
        ecnCodepoint: ECNCodepoint = .notECT
    ) {
        self.buffer = buffer
        self.remoteAddress = remoteAddress
        self.receivedAt = receivedAt
        self.ecnCodepoint = ecnCodepoint
    }

    /// The packet data as Data (convenience, copies bytes).
    @inlinable
    public var data: Data {
        Data(buffer: buffer)
    }
}

// MARK: - NIO QUIC Socket

/// A QUIC socket using NIOUDPTransport
public final class NIOQUICSocket: QUICSocket, Sendable {
    private let transport: NIOUDPTransport
    private let incomingStream: AsyncStream<IncomingPacket>
    private let incomingContinuation: AsyncStream<IncomingPacket>.Continuation

    /// The forwarding task handle, stored to allow cancellation on stop.
    private let forwardingTask: Mutex<Task<Void, Never>?>

    /// Platform socket options applied at start (for ECN / DF).
    ///
    /// Stored so that callers can inspect whether ECN or DF was
    /// actually enabled after socket creation.
    public let platformOptions: PlatformSocketOptions?

    /// The local address
    public var localAddress: SocketAddress? {
        get async {
            await transport.localAddress
        }
    }

    /// Incoming packets stream
    public var incomingPackets: AsyncStream<IncomingPacket> {
        incomingStream
    }

    /// Creates a new QUIC socket
    /// - Parameters:
    ///   - configuration: UDP configuration
    ///   - platformOptions: Platform-specific socket options (ECN, DF).
    ///     Pass `nil` to skip platform option application.
    public init(
        configuration: UDPConfiguration,
        platformOptions: PlatformSocketOptions? = nil
    ) {
        self.transport = NIOUDPTransport(configuration: configuration)
        self.platformOptions = platformOptions

        let (stream, continuation) = AsyncStream<IncomingPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        self.incomingStream = stream
        self.incomingContinuation = continuation
        self.forwardingTask = Mutex(nil)
    }

    /// Starts the socket and begins receiving packets
    ///
    /// After the underlying NIO transport is started, platform socket
    /// options (ECN, DF) are applied if ``platformOptions`` was provided.
    /// Failures applying individual options are logged but do not prevent
    /// the socket from operating — ECN or DF will simply be unavailable.
    public func start() async throws {
        try await transport.start()

        // Apply platform socket options (ECN, DF) to the live channel.
        // This must happen after start() because the channel doesn't
        // exist until the bootstrap has bound.
        if let opts = platformOptions {
            await applyPlatformOptions(opts)
        }

        // Forward incoming datagrams to our stream.
        // The Task is stored so it can be cancelled in stop().
        // The Task owns stream termination via finish() when the loop exits.
        //
        // ECN codepoint is extracted from the NIO envelope metadata
        // (requires ChannelOptions.explicitCongestionNotification = true
        // on the datagram channel, enabled via UDPConfiguration.enableECN).
        let continuation = self.incomingContinuation
        let transport = self.transport
        let task = Task {
            for await datagram in transport.incomingDatagrams {
                let ecn = Self.mapECNState(datagram.ecnState)
                let packet = IncomingPacket(
                    buffer: datagram.buffer,
                    remoteAddress: datagram.remoteAddress,
                    receivedAt: .now,
                    ecnCodepoint: ecn
                )
                continuation.yield(packet)
            }
            continuation.finish()
        }
        forwardingTask.withLock { $0 = task }
    }

    /// Stops the socket
    ///
    /// This method stops the underlying transport, which finishes
    /// its incoming datagrams stream, causing the forwarding task
    /// to exit and call finish() on the packets stream.
    public func stop() async {
        await transport.stop()

        // Cancel the forwarding task in case transport.stop()
        // didn't cause the for-await loop to exit promptly.
        let task = forwardingTask.withLock { t -> Task<Void, Never>? in
            let existing = t
            t = nil
            return existing
        }
        task?.cancel()

        // Defensive finish — idempotent if the task already called it.
        incomingContinuation.finish()
    }

    /// Sends packet data to the specified address
    public func send(_ data: Data, to address: SocketAddress) async throws {
        try await transport.send(data, to: address)
    }

    /// Sends multiple packets in a single batch via `sendmmsg()`.
    ///
    /// Converts `QUICCore.SocketAddress` to `NIOCore.SocketAddress` once,
    /// then delegates to `NIOUDPTransport.sendBatch()` which does
    /// N `channel.write()` + 1 `channel.flush()`.
    public func sendBatch(_ packets: [Data], to address: SocketAddress) async throws {
        guard !packets.isEmpty else { return }
        let datagrams = packets.map { ($0, address) }
        try await transport.sendBatch(datagrams)
    }

    // MARK: - ECN Mapping

    /// Maps NIO's `NIOExplicitCongestionNotificationState` to our
    /// `ECNCodepoint` used throughout the QUIC stack.
    @inline(__always)
    private static func mapECNState(
        _ state: NIOExplicitCongestionNotificationState?
    ) -> ECNCodepoint {
        guard let state else { return .notECT }
        switch state {
        case .transportNotCapable:
            return .notECT
        case .transportCapableFlag0:
            return .ect0
        case .transportCapableFlag1:
            return .ect1
        case .congestionExperienced:
            return .ce
        }
    }

    // MARK: - Platform Socket Options

    /// Applies platform-specific socket options to the live NIO channel.
    ///
    /// Called once during `start()` after the channel is bound.
    /// Each option is applied independently — a failure on one does not
    /// block the others.
    private func applyPlatformOptions(_ opts: PlatformSocketOptions) async {
        guard let provider = transport.socketOptionProvider else {
            #if DEBUG
            print("[NIOQUICSocket] socketOptionProvider unavailable — channel not started or not a SocketOptionProvider")
            #endif
            return
        }

        for opt in opts.options {
            let level = NIOBSDSocket.OptionLevel(rawValue: opt.level)
            let name = NIOBSDSocket.Option(rawValue: opt.name)
            do {
                try await provider.unsafeSetSocketOption(
                    level: level,
                    name: name,
                    value: opt.value
                ).get()
                #if DEBUG
                print("[NIOQUICSocket] Applied \(opt.description)")
                #endif
            } catch {
                #if DEBUG
                print("[NIOQUICSocket] Failed to apply \(opt.description): \(error)")
                #endif
            }
        }
    }
}
