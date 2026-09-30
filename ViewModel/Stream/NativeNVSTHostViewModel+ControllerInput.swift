import Foundation

struct ControllerInputHUDState: Equatable {
    var backend = ControllerInputBackendPreference.load()
    var rows: [ControllerInputStatusRow] = []
}

struct ControllerInputStatusRow: Identifiable, Equatable {
    let id: Int
    let label: String
    let name: String
    let source: ControllerInputSource
    let output: String?
}

@MainActor
extension NativeNVSTHostViewModel {
    func toggleControllerInputBackend() {
        let next: ControllerInputBackend = controllerInput.backend == .appleFramework ? .gamepadAPI : .appleFramework
        controllerInput.backend = next
        ControllerInputBackendPreference.save(next)
        GamepadHIDMonitor.shared.refreshActivation()
        refreshControllerInputStatus()
        OPNStreamTelemetry.capture("nvst.ui.controller.backend", level: .info, message: "Controller input backend changed.",
                                   attributes: ["applicationID": configuration.applicationID, "backend": next.rawValue])
    }

    /// Keeps the HUD's controller rows live *while they are on screen*.
    ///
    /// The rows exist only in the open HUD, and the Controller API toggle refreshes them directly,
    /// so there is nothing to poll with the HUD down — this used to wake the main actor 10×/s for
    /// the whole of every stream to refresh a list nobody was looking at.
    func pollControllerInputStatus() async {
        while !Task.isCancelled {
            if unifiedHUDVisible {
                refreshControllerInputStatus()
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func refreshControllerInputStatus() {
        let backend = ControllerInputBackendPreference.load()
        if backend != controllerInput.backend { controllerInput.backend = backend }
        guard let nativeView else {
            if !controllerInput.rows.isEmpty { controllerInput.rows = [] }
            return
        }
        let states = nativeView.latestGamepadStates
        let rows = nativeView.controllerInputPaths().map { path in
            // The source travels on the state the wire will actually send, so the label and the
            // stick values below cannot describe a different deadzone from the one applied.
            let state = states[path.playerIndex]
            let source = state?.inputSource ?? path.source
            return ControllerInputStatusRow(id: path.playerIndex,
                                            label: "P\(path.playerIndex + 1)",
                                            name: path.name,
                                            source: source,
                                            output: state.map { Self.stickOutputText(NvstBifrostFreeTransport.wireSticks($0, source: source)) })
        }
        if rows != controllerInput.rows { controllerInput.rows = rows }
    }

    nonisolated static func stickOutputText(_ sticks: (leftX: Float, leftY: Float, rightX: Float, rightY: Float)) -> String {
        String(format: "L %+.3f %+.3f   R %+.3f %+.3f", sticks.leftX, sticks.leftY, sticks.rightX, sticks.rightY)
    }
}
