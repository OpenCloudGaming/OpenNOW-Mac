/// NIO UDP Transport
///
/// SwiftNIO-based implementation of UDP transport.

import Foundation
import NIOCore
import NIOPosix
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// SwiftNIO-based UDP transport implementation.
///
/// Provides both unicast and multicast UDP communication using SwiftNIO's
/// `DatagramBootstrap`.
///
/// - Important: This transport is designed for **single use**. Once `stop()` is called,
///   the transport cannot be restarted. Create a new instance if you need to restart.
///
/// ## Example
/// ```swift
/// // Unicast usage
/// let transport = NIOUDPTransport(configuration: .unicast(port: 7946))
/// try await transport.start()
///
/// for await datagram in transport.incomingDatagrams {
///     print("Received: \(datagram.data)")
/// }
///
/// // Multicast usage
/// let mdns = NIOUDPTransport(configuration: .multicast(port: 5353))
/// try await mdns.start()
/// try await mdns.joinMulticastGroup("224.0.0.251", on: nil)
/// ```
public final class NIOUDPTransport: UDPTransport, MulticastCapable, @unchecked Sendable {
    // Note: @unchecked Sendable is used because:
    // - All mutable state is protected by Mutex
    // - Channel, EventLoopGroup, and NIONetworkDevice from SwiftNIO are thread-safe
    // - The class uses proper synchronization for all state access

    // MARK: - Properties

    private let configuration: UDPConfiguration
    private let eventLoopGroup: any EventLoopGroup
    private let ownsEventLoopGroup: Bool

    private let state: Mutex<State>

    /// The continuation for incoming datagrams.
    /// Using a non-optional continuation with an atomic finished flag
    /// to minimize lock contention on the hot receive path.
    private let incomingContinuation: AsyncStream<IncomingDatagram>.Continuation
    private let continuationFinished: Atomic<Bool>

    /// Stream of incoming datagrams.
    public let incomingDatagrams: AsyncStream<IncomingDatagram>

    private struct State {
        var channel: (any Channel)?
        var status: Status = .initial
        var generation: UInt64 = 0
        var joinedGroups: Set<String> = []
        var deviceCache: [String: NIONetworkDevice] = [:]

        enum Status {
            case initial
            case starting
            case started
            case stopping
            case stopped
        }
    }

    // MARK: - Initialization

    /// Creates a new UDP transport with the given configuration.
    ///
    /// - Parameters:
    ///   - configuration: UDP configuration
    ///   - eventLoopGroup: Optional event loop group (creates one if nil)
    public init(
        configuration: UDPConfiguration,
        eventLoopGroup: (any EventLoopGroup)? = nil
    ) {
        self.configuration = configuration

        if let group = eventLoopGroup {
            self.eventLoopGroup = group
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }

        self.state = Mutex(State())
        self.continuationFinished = Atomic(false)

        // Create AsyncStream with buffering policy to handle backpressure
        var continuation: AsyncStream<IncomingDatagram>.Continuation!
        self.incomingDatagrams = AsyncStream(
            bufferingPolicy: .bufferingNewest(configuration.streamBufferSize)
        ) { cont in
            continuation = cont
        }
        self.incomingContinuation = continuation
    }

    deinit {
        if ownsEventLoopGroup {
            eventLoopGroup.shutdownGracefully { _ in }
        }
    }

    // MARK: - Socket Access

    /// Provides access to the underlying NIO channel as a `SocketOptionProvider`.
    ///
    /// Returns `nil` if the transport has not been started or the channel
    /// does not conform to `SocketOptionProvider`.
    ///
    /// Used by `NIOQUICSocket` to apply platform socket options (ECN, DF)
    /// via `unsafeSetSocketOption()` after the channel is bound.
    public var socketOptionProvider: (any SocketOptionProvider)? {
        state.withLock { $0.channel as? (any SocketOptionProvider) }
    }

    // MARK: - UDPTransport

    /// The local address this transport is bound to.
    public var localAddress: SocketAddress? {
        get async {
            state.withLock { $0.channel?.localAddress }
        }
    }

    /// Starts the transport.
    ///
    /// Binds to the configured address and begins receiving datagrams.
    ///
    /// - Important: This method can only be called once. After `stop()` is called,
    ///   the transport cannot be restarted.
    ///
    /// - Throws: `UDPError.alreadyStarted` if already started or was previously stopped
    public func start() async throws {
        // Atomically check and transition state
        let startGeneration = try state.withLock { state -> UInt64 in
            switch state.status {
            case .initial:
                state.status = .starting
                state.generation += 1
                return state.generation
            case .starting, .started:
                throw UDPError.alreadyStarted
            case .stopping, .stopped:
                throw UDPError.alreadyStarted  // Cannot restart
            }
        }

        do {
            let channel = try await createChannel()

            // Check if stop() was called during createChannel()
            let shouldClose = state.withLock { state -> Bool in
                if state.generation != startGeneration || state.status != .starting {
                    // stop() was called, close the channel
                    return true
                }
                state.channel = channel
                state.status = .started
                return false
            }

            if shouldClose {
                try? await channel.close()
                throw UDPError.channelClosed
            }
        } catch {
            state.withLock { state in
                if state.generation == startGeneration {
                    state.status = .initial
                }
            }
            if let udpError = error as? UDPError {
                throw udpError
            }
            throw UDPError.bindFailed(underlying: error)
        }
    }

    /// Stops the transport.
    ///
    /// Closes the socket and stops receiving datagrams.
    /// The `incomingDatagrams` stream will complete.
    ///
    /// - Important: After calling this method, the transport cannot be restarted.
    ///   Create a new instance if you need to restart.
    public func stop() async {
        let (channel, shouldCleanup) = state.withLock { state -> ((any Channel)?, Bool) in
            switch state.status {
            case .initial:
                // Not started yet, nothing to stop - remain in initial state
                return (nil, false)
            case .starting:
                // Mark as stopping, start() will detect this via generation check
                state.status = .stopping
                state.generation += 1
                return (nil, true)
            case .started:
                state.status = .stopping
                let ch = state.channel
                state.channel = nil
                state.joinedGroups.removeAll()
                state.deviceCache.removeAll()
                return (ch, true)
            case .stopping, .stopped:
                return (nil, false)
            }
        }

        // Early return if nothing to clean up
        guard shouldCleanup else { return }

        if let channel {
            try? await channel.close()
        }

        // Finalize stop
        state.withLock { state in
            state.status = .stopped
        }

        // Mark as finished before calling finish() to prevent any new yields
        continuationFinished.store(true, ordering: .releasing)
        incomingContinuation.finish()

        if ownsEventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
    }

    /// Sends data to the specified address.
    public func send(_ data: Data, to address: SocketAddress) async throws {
        let channel = try getStartedChannel()

        guard data.count <= configuration.maxDatagramSize else {
            throw UDPError.datagramTooLarge(
                size: data.count,
                max: configuration.maxDatagramSize
            )
        }

        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        try await sendBuffer(buffer, to: address, channel: channel)
    }

    /// Sends a ByteBuffer to the specified address (zero-copy).
    public func send(_ buffer: ByteBuffer, to address: SocketAddress) async throws {
        let channel = try getStartedChannel()

        guard buffer.readableBytes <= configuration.maxDatagramSize else {
            throw UDPError.datagramTooLarge(
                size: buffer.readableBytes,
                max: configuration.maxDatagramSize
            )
        }

        try await sendBuffer(buffer, to: address, channel: channel)
    }

    /// Sends multiple datagrams in a batch (optimized for throughput).
    ///
    /// Writes all datagrams without flushing, then flushes once at the end.
    /// This reduces system call overhead and can dramatically improve throughput.
    ///
    /// - Parameters:
    ///   - datagrams: Array of (buffer, address) tuples to send
    /// - Throws: `UDPError` if any datagram is too large or transport is not started
    public func sendBatch(_ datagrams: [(ByteBuffer, SocketAddress)]) async throws {
        let channel = try getStartedChannel()

        // Validate all datagrams first
        for (buffer, _) in datagrams {
            guard buffer.readableBytes <= configuration.maxDatagramSize else {
                throw UDPError.datagramTooLarge(
                    size: buffer.readableBytes,
                    max: configuration.maxDatagramSize
                )
            }
        }

        // Write all datagrams without flushing
        for (buffer, address) in datagrams {
            let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
            channel.write(envelope, promise: nil)
        }

        // Single flush for all datagrams
        channel.flush()
    }

    /// Sends multiple Data packets in a batch (convenience wrapper).
    ///
    /// - Parameters:
    ///   - datagrams: Array of (data, address) tuples to send
    /// - Throws: `UDPError` if any datagram is too large or transport is not started
    public func sendBatch(_ datagrams: [(Data, SocketAddress)]) async throws {
        let channel = try getStartedChannel()

        // Convert to ByteBuffers and validate
        var bufferDatagrams: [(ByteBuffer, SocketAddress)] = []
        bufferDatagrams.reserveCapacity(datagrams.count)

        for (data, address) in datagrams {
            guard data.count <= configuration.maxDatagramSize else {
                throw UDPError.datagramTooLarge(
                    size: data.count,
                    max: configuration.maxDatagramSize
                )
            }

            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            bufferDatagrams.append((buffer, address))
        }

        // Write all without flushing
        for (buffer, address) in bufferDatagrams {
            let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
            channel.write(envelope, promise: nil)
        }

        // Single flush
        channel.flush()
    }

    // MARK: - MulticastCapable

    /// Joins a multicast group.
    public func joinMulticastGroup(
        _ group: String,
        on interface: String?
    ) async throws {
        let channel = try getStartedChannel()

        guard let datagramChannel = channel as? (any MulticastChannel) else {
            throw UDPError.multicastError("Channel does not support multicast")
        }

        do {
            let groupAddress = try SocketAddress(ipAddress: group, port: 0)

            if let interfaceName = interface ?? configuration.networkInterface {
                let device = try await getDevice(named: interfaceName)
                try await datagramChannel.joinGroup(groupAddress, device: device).get()
            } else {
                try await datagramChannel.joinGroup(groupAddress).get()
            }

            _ = state.withLock { $0.joinedGroups.insert(group) }
        } catch let error as UDPError {
            throw error
        } catch {
            throw UDPError.multicastError("Failed to join group \(group): \(error)")
        }
    }

    /// Leaves a multicast group.
    public func leaveMulticastGroup(
        _ group: String,
        on interface: String?
    ) async throws {
        let channel = try getStartedChannel()

        guard let datagramChannel = channel as? (any MulticastChannel) else {
            throw UDPError.multicastError("Channel does not support multicast")
        }

        do {
            let groupAddress = try SocketAddress(ipAddress: group, port: 0)

            if let interfaceName = interface ?? configuration.networkInterface {
                let device = try await getDevice(named: interfaceName)
                try await datagramChannel.leaveGroup(groupAddress, device: device).get()
            } else {
                try await datagramChannel.leaveGroup(groupAddress).get()
            }

            _ = state.withLock { $0.joinedGroups.remove(group) }
        } catch let error as UDPError {
            throw error
        } catch {
            throw UDPError.multicastError("Failed to leave group \(group): \(error)")
        }
    }

    /// Sends data to a multicast group.
    public func sendMulticast(
        _ data: Data,
        to group: String,
        port: Int
    ) async throws {
        let address = try SocketAddress(ipAddress: group, port: port)
        try await send(data, to: address)
    }

    /// Sends a ByteBuffer to a multicast group (zero-copy).
    public func sendMulticast(
        _ buffer: ByteBuffer,
        to group: String,
        port: Int
    ) async throws {
        let address = try SocketAddress(ipAddress: group, port: port)
        try await send(buffer, to: address)
    }

    // MARK: - Private

    /// Gets the channel if started, throws if not.
    @inline(__always)
    private func getStartedChannel() throws -> any Channel {
        try state.withLock { state in
            guard state.status == .started, let channel = state.channel else {
                throw UDPError.notStarted
            }
            return channel
        }
    }

    @inline(__always)
    private func sendBuffer(
        _ buffer: ByteBuffer,
        to address: SocketAddress,
        channel: any Channel
    ) async throws {
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)

        do {
            try await channel.writeAndFlush(envelope)
        } catch {
            throw UDPError.sendFailed(underlying: error)
        }
    }

    private func createChannel() async throws -> any Channel {
        var bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: configuration.reuseAddress ? 1 : 0
            )
            .channelOption(
                ChannelOptions.recvAllocator,
                value: FixedSizeRecvByteBufferAllocator(capacity: configuration.receiveBufferSize)
            )
            .channelInitializer { [weak self] channel in
                channel.pipeline.addHandler(DatagramHandler(transport: self))
            }

        // Apply SO_RCVBUF
        bootstrap = bootstrap.channelOption(
            ChannelOptions.socketOption(.so_rcvbuf),
            value: SocketOptionValue(configuration.receiveBufferSize)
        )

        // Apply SO_SNDBUF
        bootstrap = bootstrap.channelOption(
            ChannelOptions.socketOption(.so_sndbuf),
            value: SocketOptionValue(configuration.sendBufferSize)
        )

        // Enable ECN metadata on the NIO datagram channel.
        // NIO will set IP_RECVTOS / IPV6_RECVTCLASS and populate
        // AddressedEnvelope.Metadata.ecnState on received datagrams.
        if configuration.enableECN {
            bootstrap = bootstrap.channelOption(
                ChannelOptions.explicitCongestionNotification,
                value: true
            )
        }

        // Apply SO_REUSEPORT if needed (for multicast)
        #if canImport(Darwin)
        if configuration.reusePort {
            let reusePortOption = ChannelOptions.Types.SocketOption(
                level: .socket,
                name: .init(rawValue: SO_REUSEPORT)
            )
            bootstrap = bootstrap.channelOption(reusePortOption, value: 1)
        }
        #elseif os(Linux)
        if configuration.reusePort {
            let reusePortOption = ChannelOptions.Types.SocketOption(
                level: .socket,
                name: .init(rawValue: SO_REUSEPORT)
            )
            bootstrap = bootstrap.channelOption(reusePortOption, value: 1)
        }
        #endif

        // Determine bind address
        let bindAddress: SocketAddress
        let isIPv6: Bool
        switch configuration.bindAddress {
        case .any(let port):
            bindAddress = try SocketAddress(ipAddress: "0.0.0.0", port: port)
            isIPv6 = false
        case .specific(let host, let port):
            bindAddress = try SocketAddress(ipAddress: host, port: port)
            isIPv6 = host.contains(":")
        case .ipv4Any(let port):
            bindAddress = try SocketAddress(ipAddress: "0.0.0.0", port: port)
            isIPv6 = false
        case .ipv6Any(let port):
            bindAddress = try SocketAddress(ipAddress: "::", port: port)
            isIPv6 = true
        }

        // Set multicast interface for outgoing packets
        // This is required for multicast to work correctly
        if !isIPv6 {
            // IPv4: Enable IP_MULTICAST_LOOP and set multicast TTL
            #if canImport(Darwin)
            let multicastLoopOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: IPPROTO_IP),
                name: .init(rawValue: IP_MULTICAST_LOOP)
            )
            bootstrap = bootstrap.channelOption(multicastLoopOption, value: 1)

            let multicastTTLOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: IPPROTO_IP),
                name: .init(rawValue: IP_MULTICAST_TTL)
            )
            bootstrap = bootstrap.channelOption(multicastTTLOption, value: 255)
            #elseif os(Linux)
            let multicastLoopOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: CInt(IPPROTO_IP)),
                name: .init(rawValue: CInt(IP_MULTICAST_LOOP))
            )
            bootstrap = bootstrap.channelOption(multicastLoopOption, value: 1)

            let multicastTTLOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: CInt(IPPROTO_IP)),
                name: .init(rawValue: CInt(IP_MULTICAST_TTL))
            )
            bootstrap = bootstrap.channelOption(multicastTTLOption, value: 255)
            #endif
        } else {
            // IPv6: Enable IPV6_MULTICAST_LOOP and set multicast hops
            #if canImport(Darwin)
            let multicastLoopOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: IPPROTO_IPV6),
                name: .init(rawValue: IPV6_MULTICAST_LOOP)
            )
            bootstrap = bootstrap.channelOption(multicastLoopOption, value: 1)

            let multicastHopsOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: IPPROTO_IPV6),
                name: .init(rawValue: IPV6_MULTICAST_HOPS)
            )
            bootstrap = bootstrap.channelOption(multicastHopsOption, value: 255)
            #elseif os(Linux)
            let multicastLoopOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: CInt(IPPROTO_IPV6)),
                name: .init(rawValue: CInt(IPV6_MULTICAST_LOOP))
            )
            bootstrap = bootstrap.channelOption(multicastLoopOption, value: 1)

            let multicastHopsOption = ChannelOptions.Types.SocketOption(
                level: .init(rawValue: CInt(IPPROTO_IPV6)),
                name: .init(rawValue: CInt(IPV6_MULTICAST_HOPS))
            )
            bootstrap = bootstrap.channelOption(multicastHopsOption, value: 255)
            #endif
        }

        let channel = try await bootstrap.bind(to: bindAddress).get()

        // Set IP_MULTICAST_IF after binding (required for multicast send to work on macOS)
        // Only set for multicast mode (reusePort == true) to avoid interfering with unicast
        // Use NIO's SocketOptionProvider.unsafeSetSocketOption to set in_addr structure
        if !isIPv6, configuration.reusePort, let socketChannel = channel as? SocketOptionProvider {
            do {
                let interfaceAddr = try getDefaultInterfaceAddress()
                try await socketChannel.unsafeSetSocketOption(
                    level: NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IP)),
                    name: NIOBSDSocket.Option(rawValue: CInt(IP_MULTICAST_IF)),
                    value: interfaceAddr
                ).get()
            } catch {
                // Log but don't fail - multicast may still work on some systems
                #if DEBUG
                print("Warning: Failed to set IP_MULTICAST_IF: \(error)")
                #endif
            }
        }

        return channel
    }

    /// Gets the first non-loopback IPv4 address for multicast interface
    private func getDefaultInterfaceAddress() throws -> in_addr {
        #if canImport(Darwin)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return in_addr(s_addr: INADDR_ANY.bigEndian)
        }

        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family

            // Look for non-loopback IPv4 address
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name != "lo0" && (interface.ifa_flags & UInt32(IFF_UP)) != 0 {
                    let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr
                    }
                    return addr
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        return in_addr(s_addr: INADDR_ANY.bigEndian)
        #else
        return in_addr(s_addr: in_addr_t(INADDR_ANY).bigEndian)
        #endif
    }

    /// Gets a network device by name, using cache.
    private func getDevice(named name: String) async throws -> NIONetworkDevice {
        // Check cache first
        if let cached = state.withLock({ $0.deviceCache[name] }) {
            return cached
        }

        // Enumerate devices and cache
        let devices = try System.enumerateDevices()
        guard let device = devices.first(where: { $0.name == name }) else {
            throw UDPError.multicastError("Interface not found: \(name)")
        }

        state.withLock { $0.deviceCache[name] = device }
        return device
    }

    /// Called by DatagramHandler when a datagram is received.
    @inline(__always)
    fileprivate func handleIncomingDatagram(_ datagram: IncomingDatagram) {
        // Fast path: check atomic flag without locking
        guard !continuationFinished.load(ordering: .acquiring) else { return }
        _ = incomingContinuation.yield(datagram)
    }
}

// MARK: - Channel Handler

/// Channel handler for processing incoming datagrams.
private final class DatagramHandler: ChannelInboundHandler, @unchecked Sendable {
    // Note: @unchecked Sendable because weak reference to transport is thread-safe
    // and the handler is only accessed from the NIO event loop.
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private weak var transport: NIOUDPTransport?

    init(transport: NIOUDPTransport?) {
        self.transport = transport
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)

        // Pass ByteBuffer directly (zero-copy).
        // Extract ECN metadata from the envelope when available
        // (requires ChannelOptions.explicitCongestionNotification = true).
        let datagram = IncomingDatagram(
            buffer: envelope.data,
            remoteAddress: envelope.remoteAddress,
            ecnState: envelope.metadata?.ecnState
        )

        transport?.handleIncomingDatagram(datagram)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log error but keep channel open for UDP
        // UDP is connectionless, so individual errors shouldn't close the channel
        #if DEBUG
        print("NIOUDPTransport channel error: \(error)")
        #endif
    }
}
