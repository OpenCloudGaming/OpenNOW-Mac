import Foundation

struct ControllerInputHUDState: Equatable {
    var backend = ControllerInputBackendPreference.load()
    var rows: [ControllerInputStatusRow] = []
}

struct ControllerInputStatusRow: Identifiable, Equatable {
    let id: Int
    let label: String
    let name: String
    let source: ControllerInputPath.Source
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

    func pollControllerInputStatus() async {
        while !Task.isCancelled {
            if unifiedHUDVisible { refreshControllerInputStatus() }
            try? await Task.sleep(for: .milliseconds(100))
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
            ControllerInputStatusRow(id: path.playerIndex,
                                     label: "P\(path.playerIndex + 1)",
                                     name: path.name,
                                     source: path.source,
                                     output: states[path.playerIndex].map { Self.stickOutputText(NvstBifrostFreeTransport.wireSticks($0, backend: backend)) })
        }
        if rows != controllerInput.rows { controllerInput.rows = rows }
    }

    nonisolated static func stickOutputText(_ sticks: (leftX: Float, leftY: Float, rightX: Float, rightY: Float)) -> String {
        String(format: "L %+.3f %+.3f   R %+.3f %+.3f", sticks.leftX, sticks.leftY, sticks.rightX, sticks.rightY)
    }
}
