import Foundation
import Network

/// The session guest's media connection: connect to the host's UDP media port, announce the token with
/// a `hello`, render and play what arrives, and send controller input back on the same socket.
///
/// It is the outbound counterpart of the host's broadcaster and shares the media engine with nothing
/// else, so the media path is the same however the guest was invited.
final class RemoteCoOpNativeGuestConnection: @unchecked Sendable {
    typealias Stats = RemoteCoOpNativeGuestMediaEngine.Stats

    var onFrame: (@Sendable (OPNVideoFrame) -> Void)? {
        get { engine.onFrame }
        set { engine.onFrame = newValue }
    }
    var onStats: (@Sendable (Stats) -> Void)? {
        get { engine.onStats }
        set { engine.onStats = newValue }
    }
    var onState: (@Sendable (String) -> Void)? {
        get { engine.onState }
        set { engine.onState = newValue }
    }
    var onConnected: (@Sendable () -> Void)?
    var onFailed: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-guest-connection")
    private let engine: RemoteCoOpNativeGuestMediaEngine
    private let host: String
    private let port: UInt16
    private let token: String
    private let cipher: OPNRemoteCoOpNativeCipher
    private let lock = NSLock()
    private var connection: NWConnection?
    private var helloTask: Task<Void, Never>?

    init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
        cipher = OPNRemoteCoOpNativeCipher(token: token, role: .guest)
        engine = RemoteCoOpNativeGuestMediaEngine(queue: queue)
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onFailed?("The host's media port is not usable.")
            return
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendHello()
                self?.onConnected?()
            case .failed(let error):
                self?.onFailed?("The host's media connection failed: \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        lock.lock(); self.connection = connection; lock.unlock()
        receiveNext(on: connection)
        // The hello is repeated: it is the only thing that binds the host's flow, and a single lost
        // datagram would otherwise leave the guest dark with nothing to retry.
        helloTask?.cancel()
        helloTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self?.sendHello()
            }
        }
    }

    func sendInput(_ packet: OPNRemoteCoOpInputPacket) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection, let datagram = cipher.seal(OPNRemoteCoOpNativeControlPacket.input(token: token, payload: OPNRemoteCoOpInputBinaryCodec.encode(packet))) else { return }
        connection.send(content: datagram, contentContext: .defaultMessage, isComplete: true, completion: .idempotent)
    }

    func close() {
        helloTask?.cancel()
        helloTask = nil
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
        engine.reset()
    }

    private func sendHello() {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection, let datagram = cipher.seal(OPNRemoteCoOpNativeControlPacket.hello(token: token)) else { return }
        connection.send(content: datagram, contentContext: .defaultMessage, isComplete: true, completion: .idempotent)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let opened = cipher.open(data) { engine.ingest(opened) }
            if error == nil { receiveNext(on: connection) }
        }
    }
}
