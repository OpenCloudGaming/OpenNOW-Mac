import Foundation

struct ControllerInputHUDState: Equatable {
    var backend = ControllerInputBackendPreference.load()
    var statusRows: [ControllerInputStatusRow] = []

    /// The per-pad rows exist to check the Gamepad API choice, so they are noise on the default.
    var isDiagnosticsVisible: Bool { backend == .gamepadAPI }
}

struct ControllerInputStatusRow: Identifiable, Equatable {
    let id: Int
    let label: String
    let controllerName: String
    let source: ControllerInputSource
    let stickOutput: String?
}

@MainActor
extension NativeNVSTHostViewModel {
    func toggleControllerInputBackend() {
        let nextBackend = controllerInput.backend.toggled
        controllerInput.backend = nextBackend
        GamepadHIDMonitor.shared.applyPreference(nextBackend)
        refreshControllerInputStatus()
        OPNStreamTelemetry.capture("nvst.ui.controller.backend", level: .info, message: "Controller input backend changed.",
                                   attributes: ["applicationID": configuration.applicationID, "backend": nextBackend.rawValue])
    }

    /// Keeps the HUD's controller rows live while they are on screen. The rows exist only in the
    /// open HUD, so with it down this idles at 1 Hz instead of waking the main actor 10×/s.
    func pollControllerInputStatus() async {
        while !Task.isCancelled {
            guard unifiedHUDVisible else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            refreshControllerInputStatus()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func refreshControllerInputStatus() {
        syncControllerInputBackend()
        guard let nativeView else {
            clearControllerInputRows()
            return
        }
        let states = nativeView.latestGamepadStates
        let rows = nativeView.controllerInputPaths().map { path in
            // The source travels on the state the wire sends, so the label and the stick values
            // below cannot describe a different deadzone from the one applied.
            let state = states[path.playerIndex]
            let source = state?.inputSource ?? path.source
            let stickOutput = state.map { Self.stickOutputText(NvstBifrostFreeTransport.wireSticks($0, source: source)) }
            return ControllerInputStatusRow(id: path.playerIndex,
                                            label: "P\(path.playerIndex + 1)",
                                            controllerName: path.name,
                                            source: source,
                                            stickOutput: stickOutput)
        }
        guard rows != controllerInput.statusRows else { return }
        controllerInput.statusRows = rows
    }

    private func syncControllerInputBackend() {
        let backend = ControllerInputBackendPreference.load()
        guard backend != controllerInput.backend else { return }
        controllerInput.backend = backend
    }

    private func clearControllerInputRows() {
        guard !controllerInput.statusRows.isEmpty else { return }
        controllerInput.statusRows = []
    }

    nonisolated static func stickOutputText(_ sticks: (leftX: Float, leftY: Float, rightX: Float, rightY: Float)) -> String {
        String(format: "L %+.3f %+.3f   R %+.3f %+.3f", sticks.leftX, sticks.leftY, sticks.rightX, sticks.rightY)
    }
}
