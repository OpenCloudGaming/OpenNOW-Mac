import Foundation
import Testing
@testable import OpenNOW

/// The recording mode is a single choice — Off, Instant Replay or Manual — as Steam's own Game
/// Recording modes are, so a session can never be buffering and manual-only at once.
@Suite struct StreamRecordingModeTests {
    private let modeKey = "OpenNOW.Stream.RecordingMode"
    private let legacyReplayKey = "OpenNOW.Stream.RecordingReplayBufferEnabled"

    @Test func theModesAreOffInstantReplayAndManual() {
        #expect(OPNRecordingMode.allCases.map(\.label) == ["Off", "Instant Replay", "Manual"])
        #expect(OPNRecordingMode.allCases.map(\.rawValue) == ["off", "replay", "manual"])
    }

    @Test func aStoredModeSurvivesThePreferenceDictionary() {
        #expect(OPNStreamPreferences.storedRecordingMode([modeKey: "manual"]) == .manual)
        #expect(OPNStreamPreferences.storedRecordingMode([modeKey: "replay"]) == .instantReplay)
        #expect(OPNStreamPreferences.storedRecordingMode([modeKey: "off"]) == .off)
    }

    @Test func anUnreadableModeFallsBackToOff() {
        #expect(OPNStreamPreferences.storedRecordingMode([modeKey: "not-a-mode", legacyReplayKey: false]) == .off)
    }

    @Test func theFirstInstantReplayToggleMigratesToTheMode() {
        let previous = UserDefaults.standard.object(forKey: legacyReplayKey)
        defer { restoreLegacyReplayKey(previous) }
        // An empty stored mode is what the migration path sees: the mode key exists but holds
        // nothing this build wrote.
        let migrated = OPNStreamPreferences.storedRecordingMode([modeKey: "", legacyReplayKey: true])
        #expect(migrated == .instantReplay)
    }

    private func restoreLegacyReplayKey(_ previous: Any?) {
        guard let previous else {
            UserDefaults.standard.removeObject(forKey: legacyReplayKey)
            return
        }
        UserDefaults.standard.set(previous, forKey: legacyReplayKey)
    }

    /// The transports and the HUD gate on this rather than on the raw mode, so a manual profile can
    /// never start a rolling window by accident.
    @Test func onlyInstantReplayEnablesTheRollingWindow() {
        var settings = StreamRuntimeSettings()
        #expect(!settings.isInstantReplayEnabled)
        settings.recordingMode = .manual
        #expect(!settings.isInstantReplayEnabled)
        settings.recordingMode = .instantReplay
        #expect(settings.isInstantReplayEnabled)
    }

    @Test func theRuntimeSettingsReadTheModeFromTheStreamDictionary() {
        var settings = StreamRuntimeSettings(json: #"{"recordingMode":"manual"}"#)
        #expect(settings.recordingMode == .manual)
        settings = StreamRuntimeSettings(json: #"{"recordingMode":"replay"}"#)
        #expect(settings.isInstantReplayEnabled)
        settings = StreamRuntimeSettings(json: #"{}"#)
        #expect(settings.recordingMode == .off)
    }
}
