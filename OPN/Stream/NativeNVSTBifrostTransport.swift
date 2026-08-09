import Foundation

public actor NativeNVSTBifrostTransport: NativeNVSTTransport {
    private let bridgeConfiguration: NVSTNativeBridgeConfiguration
    private let inputEncoder: NativeNVSTInputEncoder
    private var bridge: NVSTNativeBridge?
    private var activeConnection: NativeNVSTTransportConnection?
    private var encodedInputEvents: [NativeNVSTEncodedInputEvent] = []

    public init(bridgeConfiguration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration(),
                inputEncoder: NativeNVSTInputEncoder = NativeNVSTInputEncoder()) {
        self.bridgeConfiguration = bridgeConfiguration
        self.inputEncoder = inputEncoder
    }

    public func prepare() async throws -> NVSTNativeBridgeStatus {
        if let bridge { return bridge.status }
        do {
            let bridge = try NVSTNativeBridge(configuration: bridgeConfiguration)
            self.bridge = bridge
            WebRTCMediaTelemetry.capture("nvst.bifrost.runtime.ready", level: .info, message: "Bundled Bifrost runtime loaded.", attributes: ["library": bridge.status.libraryURL.lastPathComponent, "symbols": String(bridge.status.resolvedSymbols.count)])
            return bridge.status
        } catch let error as NVSTNativeBridgeError {
            throw NativeNVSTError.runtimeUnavailable(error.errorDescription ?? "Bundled native NVST runtime is unavailable.")
        } catch {
            throw NativeNVSTError.runtimeUnavailable(error.localizedDescription.isEmpty ? "Bundled native NVST runtime is unavailable." : error.localizedDescription)
        }
    }

    public func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        let status = try await prepare()
        guard !allocation.session.id.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a session id.") }
        guard !allocation.signalingURL.isEmpty || !allocation.signalingServer.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing signaling endpoint data.") }
        let message = "Bundled Bifrost loaded, but OpenNOW has not recovered the private nvstCreateClient/nvstConnectToServer configuration and callback ABI needed to start media safely."
        WebRTCMediaTelemetry.capture("nvst.bifrost.abi_unavailable", level: .error, message: message, attributes: ["sessionId": allocation.session.id, "library": status.libraryURL.lastPathComponent])
        throw NativeNVSTError.privateABIUnavailable(message)
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeConnection != nil else { throw NativeNVSTError.notRunning }
        guard let encoded = inputEncoder.encode(event) else { return }
        encodedInputEvents.append(encoded)
    }

    public func disconnect() async {
        activeConnection = nil
        encodedInputEvents.removeAll()
    }
}
