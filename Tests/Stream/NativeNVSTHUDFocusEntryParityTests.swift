import Foundation
import Testing
@testable import OpenNOW

/// The HUD's tile arrays and pad-focus list are hand-maintained in parallel: a tile with no matching
/// entry is unreachable from a controller. Each panel's group is checked against its own tile array.
/// These tests never write to `UserDefaults`, so they stay parallel-safe.
@MainActor
struct NativeNVSTHUDFocusEntryParityTests {
    private func focusIDs(in group: String, on model: NativeNVSTHostViewModel) -> [String] {
        model.hudFocusEntries.filter { $0.group == group }.map(\.id)
    }

    @Test func thePowerButtonIsReachableFromAPad() {
        let (_, model) = makeHUDSurface()
        #expect(model.hudFocusEntries.map(\.id).contains("quit-menu"))
    }

    @Test func fullScreenTileIsReachableFromAPad() {
        let (_, model) = makeHUDSurface()
        #expect(model.hudFocusEntries.map(\.id).contains("full-screen"))
    }

    @Test func tileIDsMatchTheFocusEntries() {
        let (surface, model) = makeHUDSurface()
        #expect(focusIDs(in: "audio", on: model) == surface.nativeHUDAudioTiles.map(\.id))
        #expect(focusIDs(in: "capture", on: model) == surface.nativeHUDCaptureTiles.map(\.id))
        #expect(focusIDs(in: "display", on: model) == surface.nativeHUDDisplayTiles.map(\.id))
        #expect(focusIDs(in: "input", on: model) == surface.nativeHUDInputTiles.map(\.id))
    }

    /// The other half of the contract: a tile the grid dims while its entry stays enabled is a
    /// button a pad can still press.
    @Test func tileDisabledStatesMatchTheFocusEntries() {
        let (surface, model) = makeHUDSurface()
        let disabledByID = Dictionary(uniqueKeysWithValues: model.hudFocusEntries.map { ($0.id, $0.isDisabled) })
        let tiles = surface.nativeHUDAudioTiles + surface.nativeHUDCaptureTiles + surface.nativeHUDDisplayTiles + surface.nativeHUDInputTiles
        for tile in tiles {
            #expect(disabledByID[tile.id] == tile.isDisabled, "\(tile.id) disabled state drifted")
        }
    }

    @Test func noPanelWrapsOntoASecondRow() {
        let (_, model) = makeHUDSurface()
        for group in ["audio", "capture", "display", "input"] {
            #expect(focusIDs(in: group, on: model).count <= 4, "\(group) needs a second row")
        }
    }

    /// The controller config tiles live with the connected hardware, so they only need to be
    /// reachable once a pad is actually there.
    @Test func controllerTilesAppearWithAConnectedPad() {
        let (surface, model) = makeHUDSurface()
        #expect(focusIDs(in: "controllers", on: model).isEmpty)
        model.controllerBatteries = [ControllerBatteryInfo(id: "pad", label: "P1", level: 80, charging: false)]
        #expect(focusIDs(in: "controllers", on: model) == surface.nativeHUDControllerTiles.map(\.id))
    }

    /// The seat's live timer replaces the window recorded at connect, so an extended or shortened
    /// limit no longer drifts from the seat's real deadline.
    @Test func theSeatTimerReplacesTheSessionLimit() throws {
        let (_, model) = makeHUDSurface()
        let update = try #require(StreamSessionLimitUpdate(remainingSeconds: 600))
        model.applyNativeSessionLimitUpdate(update)
        #expect(model.sessionLimit?.durationSeconds == 3600)
        #expect(model.sessionLimit?.remainingSeconds(at: Date()) ?? 0 <= 601)
    }

    @Test func focusEntryIDsAreUnique() {
        let (_, model) = makeHUDSurface()
        let ids = model.hudFocusEntries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// The STATS panel's two selectors are full-width rows, not tiles, so nothing but this contract
    /// keeps them reachable from a pad.
    @Test func statsShapeControlsAreReachableFromAPad() {
        let (_, model) = makeHUDSurface()
        let ids = model.hudFocusEntries.map(\.id)
        #expect(ids.contains("stats-detail"))
        #expect(ids.contains("stats-position"))
    }
}
