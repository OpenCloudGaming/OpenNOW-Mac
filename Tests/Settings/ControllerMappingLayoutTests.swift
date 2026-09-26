import Foundation
import Testing
@testable import OpenNOW

@MainActor
@Suite("Controller mapping layout")
struct ControllerMappingLayoutTests {
    private let steam = ControllerMappingDevice(id: "steam", name: "Steam Controller", family: .steam, hasTouchpad: false)
    private let dualShock = ControllerMappingDevice(id: "ds4", name: "DualShock 4", family: .dualShock4, hasTouchpad: true)
    private let generic = ControllerMappingDevice(id: "generic", name: "Generic", family: .generic, hasTouchpad: false)

    @Test func disconnectedSelectionNeverFallsBackToASpecificFamily() {
        for selection in [ControllerMappingSelection.none, .family(.steam), .family(.dualShock4)] {
            #expect(selection.resolved(devices: []) == .none)
        }
    }

    @Test func openingSelectsTheFirstConnectedControllerFamily() {
        #expect(ControllerMappingSelection.none.resolved(devices: [dualShock]) == .family(.dualShock4))
        #expect(ControllerMappingSelection.none.resolved(devices: [generic]) == .family(.generic))
        #expect(ControllerMappingSelection.none.resolved(devices: [steam]) == .family(.steam))
    }

    @Test func anyFamilyStaysSelectedWhileAnyControllerIsConnected() {
        // A type's default must be preparable without that pad plugged in, so selection binds to
        // the family rather than to a connected device of that family.
        let selection = ControllerMappingSelection.family(.dualShock4)
        #expect(selection.resolved(devices: [steam, dualShock, generic]) == selection)
        #expect(selection.resolved(devices: [steam, generic]) == selection)
        #expect(selection.resolved(devices: []) == .none)
    }

    @Test(arguments: [CGFloat(1), 1.25, 1.5])
    func diagramFitsRemainingEditorSpace(scale: CGFloat) {
        for viewport in [CGSize(width: 580 * scale, height: 310 * scale), CGSize(width: 340 * scale, height: 500 * scale)] {
            let fitted = ControllerDiagramArtwork.fittedScale(in: viewport, maximumScale: scale)
            let diagram = ControllerDiagramArtwork.diagramSize
            #expect(fitted > 0)
            #expect(fitted <= scale)
            #expect(diagram.width * fitted <= viewport.width + 0.001)
            #expect(diagram.height * fitted <= viewport.height + 0.001)
        }
    }

    @Test func diagramDoesNotUpscaleOrUseCollapsedSpace() {
        #expect(ControllerDiagramArtwork.fittedScale(in: CGSize(width: 2000, height: 2000), maximumScale: 1.25) == 1.25)
        #expect(ControllerDiagramArtwork.fittedScale(in: .zero, maximumScale: 1) == 0)
        #expect(ControllerDiagramArtwork.fittedScale(in: CGSize(width: 500, height: -1), maximumScale: 1) == 0)
    }
}
