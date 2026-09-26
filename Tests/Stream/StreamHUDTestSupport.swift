import Foundation
@testable import OpenNOW

/// Restores every persisted HUD preference around a test, so a test that rearranges, hides, folds,
/// or toggles the clock cannot leak into the next one through `UserDefaults`.
func withPreservedHUDSettings(_ body: () -> Void) {
    withExclusivePreferenceDomain {
        let defaults = UserDefaults.standard
        let keys = [
            OPNStreamHUDSettings.collapsedSectionsKey,
            OPNStreamHUDSettings.sectionOrderKey,
            OPNStreamHUDSettings.hiddenSectionsKey,
            OPNStreamHUDSettings.clockVisibleKey,
        ]
        let existing = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in existing {
                guard let value else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                defaults.set(value, forKey: key)
            }
        }
        body()
    }
}

/// Restores the persisted microphone mode around a test, so a mode one test applies cannot leak into
/// the next one through `UserDefaults`. Restored through the same validated setter Settings uses.
func withPreservedMicrophoneMode(_ body: () -> Void) {
    withExclusivePreferenceDomain {
        let previousMode = OPNStreamPreferences.loadProfile().microphoneMode
        defer { OPNStreamPreferences.saveMicrophoneMode(previousMode) }
        body()
    }
}

struct StubNativeNVSTSessionProvider: NativeNVSTSessionProvider {
    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
        throw NativeNVSTError.transportFailed("unused")
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {}
}

/// A surface for the HUD tests, with the model's arrangement reset to the defaults. The reset keeps
/// a test from inheriting a layout another test wrote, and side-steps `@StateObject` handing back a
/// fresh instance on each access. Returns both because tile arrays live on the surface and focus
/// entries on the model.
@MainActor
func makeHUDSurface() -> (surface: NativeNVSTMediaStreamSurface, model: NativeNVSTHostViewModel) {
    let surface = NativeNVSTMediaStreamSurface(
        configuration: StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam"),
        sessionProvider: StubNativeNVSTSessionProvider(),
        preventDisplaySleep: false,
        onProgress: nil,
        onEnd: { _, _, _ in }
    )
    let model = surface.model
    model.hudSectionOrder = OPNStreamHUDSection.allCases
    model.hiddenHUDSections = []
    model.collapsedHUDSections = []
    model.isHUDClockVisible = true
    return (surface, model)
}
