import SwiftUI

struct ControllerMappingDiagram: View {
    let family: ControllerFamily
    let snapshot: ControllerInputSnapshot
    let selectedControl: ControllerControl
    let onSelectControl: (ControllerControl) -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { geometry in
            let scale = ControllerDiagramArtwork.fittedScale(in: geometry.size, maximumScale: uiScale)
            if scale > 0 {
                artwork
                    .environment(\.opnUIScale, scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    @ViewBuilder private var artwork: some View {
        switch family {
        case .steam:
            SteamControllerDiagramView(snapshot: snapshot, selectedControl: selectedControl, onSelectControl: onSelectControl)
        case .dualShock4:
            DualShock4DiagramView(snapshot: genericSnapshot)
        case .generic:
            GenericControllerDiagramView(snapshot: genericSnapshot)
        }
    }

    private var genericSnapshot: GenericControllerInputSnapshot {
        var result = GenericControllerInputSnapshot()
        result.buttons = snapshot.buttons
        result.leftTrigger = snapshot.leftTrigger
        result.rightTrigger = snapshot.rightTrigger
        result.leftStickX = snapshot.leftStickX
        result.leftStickY = snapshot.leftStickY
        result.rightStickX = snapshot.rightStickX
        result.rightStickY = snapshot.rightStickY
        result.touchpad = snapshot.touchpad.map {
            ControllerTouchpadState(x: $0.x, y: $0.y, touched: $0.touched, pressed: $0.pressed)
        }
        return result
    }
}
