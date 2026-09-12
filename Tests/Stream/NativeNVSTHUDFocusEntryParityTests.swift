import Foundation
import Testing
@testable import OpenNOW

/// The HUD's tile arrays and its pad-focus list are hand-maintained in parallel: a tile with no
/// matching entry is simply unreachable from a controller, and nothing else catches that.
@MainActor
struct NativeNVSTHUDFocusEntryParityTests {
    private struct StubSessionProvider: NativeNVSTSessionProvider {
        func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
            throw NativeNVSTError.transportFailed("unused")
        }

        func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {}
    }

    private func makeSurface() -> NativeNVSTMediaStreamSurface {
        NativeNVSTMediaStreamSurface(
            configuration: StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam"),
            sessionProvider: StubSessionProvider(),
            preventDisplaySleep: false,
            onProgress: nil,
            onEnd: { _, _, _ in }
        )
    }

    @Test func fullScreenTileIsReachableFromAPad() {
        let surface = makeSurface()
        let ids = surface.model.hudFocusEntries.map(\.id)
        #expect(ids.contains("full-screen"))
        #expect(Array(ids.prefix(5)) == ["microphone", "localAudioMute", "recording", "floating-stats", "full-screen"])
    }

    @Test func tileIDsMatchTheFocusEntries() {
        let surface = makeSurface()
        let entries = surface.model.hudFocusEntries
        let controls = entries.filter { $0.group == "controls" }.map(\.id)
        let input = entries.filter { $0.group == "input" }.map(\.id)
        #expect(controls == surface.nativeHUDControlTiles.map(\.id))
        #expect(input == surface.nativeHUDInputTiles.map(\.id))
    }

    /// The other half of the contract: a tile the grid dims while its entry stays enabled is a
    /// button a pad can still press.
    @Test func tileDisabledStatesMatchTheFocusEntries() {
        let surface = makeSurface()
        let entries = surface.model.hudFocusEntries
        let disabledByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.isDisabled) })
        for tile in surface.nativeHUDControlTiles + surface.nativeHUDInputTiles {
            #expect(disabledByID[tile.id] == tile.isDisabled, "\(tile.id) disabled state drifted")
        }
    }

    @Test func controlsStillChunkFourWide() {
        let surface = makeSurface()
        let entries = surface.model.hudFocusEntries
        let rows = StreamHUDFocusEntry.rows(of: entries)
        #expect(rows.prefix(3).map { $0.map { entries[$0].id } } == [
            ["microphone", "localAudioMute", "recording", "floating-stats"],
            ["full-screen"],
            ["pointer", "cursor-policy", "anti-afk", "controller-mapping"],
        ])
    }

    @Test func focusEntryIDsAreUnique() {
        let ids = makeSurface().model.hudFocusEntries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
