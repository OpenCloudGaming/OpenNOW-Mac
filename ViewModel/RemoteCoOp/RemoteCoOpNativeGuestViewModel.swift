//  Drives the native Co-Op guest window: listen on a UDP port for the host's forwarded source video
//  and show what arrives. It is the app-side twin of the `coop-spike-guest` CLI and shares its
//  receiver, so the command-line proof and this window cannot drift apart.
//

import Combine
import Foundation

@MainActor
final class RemoteCoOpNativeGuestViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case failed(String)
    }

    @Published var portText: String
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusText = "Enter the UDP port the host is forwarding to, then listen."
    @Published private(set) var stats: RemoteCoOpNativeGuestReceiver.Stats?

    let receiver = RemoteCoOpNativeGuestReceiver()

    private static let portDefaultsKey = "remoteCoOpNativeGuestPort"

    init() {
        portText = UserDefaults.standard.string(forKey: Self.portDefaultsKey) ?? "9000"
        receiver.onState = { [weak self] text in
            Task { @MainActor in self?.statusText = text }
        }
        receiver.onStats = { [weak self] stats in
            Task { @MainActor in self?.stats = stats }
        }
    }

    func startListening() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = UInt16(trimmed), port > 0 else {
            let message = "Enter a port between 1 and 65535."
            phase = .failed(message)
            statusText = message
            return
        }
        UserDefaults.standard.set(trimmed, forKey: Self.portDefaultsKey)
        do {
            try receiver.start(port: port)
            phase = .listening
            statusText = "Listening on UDP \(port). Waiting for the host…"
        } catch {
            phase = .failed(error.localizedDescription)
            statusText = error.localizedDescription
        }
    }

    func stopListening() {
        receiver.stop()
        phase = .idle
        stats = nil
        statusText = "Stopped."
    }
}
