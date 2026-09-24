import Foundation
import Network

/// The listening guest receiver: bind a UDP port, feed every datagram into the media engine. This is
/// the shape the `coop-spike-guest` CLI and the in-app manual spike window use; the session path
/// connects out instead (see `RemoteCoOpNativeGuestConnection`) and shares the same engine.
final class RemoteCoOpNativeGuestReceiver: @unchecked Sendable {
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

    private let queue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.native-guest")
    private let engine: RemoteCoOpNativeGuestMediaEngine
    private let lock = NSLock()
    private var listener: NWListener?

    init() {
        engine = RemoteCoOpNativeGuestMediaEngine(queue: queue)
    }

    var isListening: Bool {
        lock.lock(); defer { lock.unlock() }
        return listener != nil
    }

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteCoOpNativeGuestError.invalidPort(port)
        }
        stop()
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            receiveNext(on: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("Listening on UDP \(port). Waiting for the host…")
            case .failed(let error): self?.onState?("Listener failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.start(queue: queue)
        lock.lock(); self.listener = listener; lock.unlock()
        engine.reset()
        onState?("Listening on UDP \(port). Waiting for the host…")
    }

    func stop() {
        lock.lock()
        let existing = listener
        listener = nil
        lock.unlock()
        existing?.cancel()
        engine.reset()
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { engine.ingest(data) }
            if error == nil { receiveNext(on: connection) }
        }
    }
}
