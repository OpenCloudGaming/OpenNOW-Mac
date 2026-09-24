import Foundation
import Network
import Testing
@testable import OpenNOW

/// The host→guest UDP path, proven on loopback: a forwarded frame must arrive as datagrams and
/// reassemble byte-for-byte. This is the network half of the M0 spike, so a live LAN run only has to
/// confirm what this already establishes on one machine.
@Suite(.serialized) struct RemoteCoOpSpikeForwarderTests {
    private final class UDPDatagramCollector: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private var received: [Data] = []
        private var port: UInt16?

        init() throws {
            listener = try NWListener(using: NWParameters.udp, on: .any)
        }

        var boundPort: UInt16? {
            lock.lock(); defer { lock.unlock() }
            return port
        }

        func start() {
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                guard case .ready = state, let bound = listener.port?.rawValue else { return }
                lock.lock(); port = bound; lock.unlock()
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.receive(on: connection)
            }
            listener.start(queue: .global())
        }

        func takeDatagrams() -> [Data] {
            lock.lock(); defer { lock.unlock() }
            let datagrams = received
            received = []
            return datagrams
        }

        func stop() {
            listener.cancel()
        }

        private func receive(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    lock.lock(); received.append(data); lock.unlock()
                }
                if error == nil { receive(on: connection) }
            }
        }
    }

    private func frame(payload: Data) -> NativeNVSTVideoFrame {
        NativeNVSTVideoFrame(streamID: 11,
                             codec: .h264,
                             timestamp: MediaTimestamp(nanoseconds: 4_000_000_000),
                             durationNanoseconds: 16_666_667,
                             width: 0,
                             height: 0,
                             isKeyFrame: true,
                             payload: payload)
    }

    @Test func aForwardedFrameArrivesAndReassemblesOverUDP() async throws {
        let collector = try UDPDatagramCollector()
        defer { collector.stop() }
        collector.start()
        var port: UInt16?
        let readinessDeadline = Date().addingTimeInterval(5)
        while Date() < readinessDeadline, port == nil {
            port = collector.boundPort
            if port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let boundPort = try #require(port)

        let forwarder = try #require(OPNRemoteCoOpSpikeForwarder(destination: "127.0.0.1:\(boundPort)"))
        defer { forwarder.stop() }

        let payload = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let source = frame(payload: payload)
        forwarder.forward(source)

        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        var reassembled: NativeNVSTVideoFrame?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, reassembled == nil {
            for datagram in collector.takeDatagrams() {
                if let completed = reassembler.ingest(datagram) { reassembled = completed }
            }
            if reassembled == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }

        let result = try #require(reassembled, "no frame reassembled from the forwarded datagrams")
        #expect(result.payload == payload)
        #expect(result.isKeyFrame)
        #expect(result.codec == .h264)
        #expect(forwarder.snapshot.framesForwarded == 1)
        #expect(forwarder.snapshot.datagramsSent >= 5)
    }

    @Test func anUnparseableDestinationYieldsNoForwarder() {
        #expect(OPNRemoteCoOpSpikeForwarder(destination: "not-a-destination") == nil)
        #expect(OPNRemoteCoOpSpikeForwarder(destination: ":9000") == nil)
        #expect(OPNRemoteCoOpSpikeForwarder(destination: "127.0.0.1:0") == nil)
    }
}
