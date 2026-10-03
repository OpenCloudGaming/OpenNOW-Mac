import Foundation
import Testing
@testable import OpenNOW

/// The composed microphone gate: mode, push-to-talk key state and the user's mute override, resolved
/// through one authoritative decision. The transport call itself needs a live session, so what is
/// asserted here is the decision every event reconciles.
@MainActor
struct NativeNVSTMicrophoneMuteOverrideTests {
    /// A connected session whose seat carries a microphone, in `mode`, with no override and no key
    /// held. Everything else is the model's own default.
    private func model(mode: String, volumePercent: Int = 100) -> NativeNVSTHostViewModel {
        let (_, model) = makeHUDSurface()
        model.isConnected = true
        model.isEnding = false
        model.didEnd = false
        model.isMicrophoneSectionNegotiated = true
        model.microphoneMode = mode
        model.microphoneAvailable = mode != "disabled"
        model.microphoneMuteOverride = false
        model.microphoneKeyHeld = false
        model.microphoneVolumePercent = volumePercent
        return model
    }

    // MARK: - The four push-to-talk combinations

    @Test func releasedAndUnmutedIsClosed() {
        let model = model(mode: "push-to-talk")
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    @Test func heldAndUnmutedIsOpen() {
        let model = model(mode: "push-to-talk")
        model.microphoneKeyHeld = true
        #expect(model.nativeMicrophoneCaptureRequested)
    }

    @Test func releasedAndMutedIsClosed() {
        let model = model(mode: "push-to-talk")
        model.microphoneMuteOverride = true
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// The override outranks the key: this is the combination the standalone mute tile could not
    /// express, and the one a late key event must never reopen.
    @Test func heldAndMutedIsClosed() {
        let model = model(mode: "push-to-talk")
        model.microphoneKeyHeld = true
        model.microphoneMuteOverride = true
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    // MARK: - Transitions

    /// Muting while the key is held stops transmission without the key being released.
    @Test func mutingWhileHeldClosesTheGate() {
        let model = model(mode: "push-to-talk")
        model.microphoneKeyHeld = true
        #expect(model.nativeMicrophoneCaptureRequested)
        model.microphoneMuteOverride = true
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// A release and repress while the override is active stays closed: a queued or late key event
    /// cannot bypass it.
    @Test func aRepressWhileMutedStaysClosed() {
        let model = model(mode: "push-to-talk")
        model.microphoneMuteOverride = true
        model.handleNativePushToTalkKey(isHeld: true)
        #expect(!model.nativeMicrophoneCaptureRequested)
        model.handleNativePushToTalkKey(isHeld: false)
        #expect(!model.nativeMicrophoneCaptureRequested)
        model.handleNativePushToTalkKey(isHeld: true)
        #expect(!model.nativeMicrophoneCaptureRequested)
        #expect(model.microphoneKeyHeld, "the key state is still tracked; only the gate refuses")
    }

    @Test func unmutingWhileHeldResumesTransmission() {
        let model = model(mode: "push-to-talk")
        model.microphoneKeyHeld = true
        model.microphoneMuteOverride = true
        #expect(!model.nativeMicrophoneCaptureRequested)
        model.microphoneMuteOverride = false
        #expect(model.nativeMicrophoneCaptureRequested)
    }

    @Test func unmutingAfterReleaseDoesNotStartTransmission() {
        let model = model(mode: "push-to-talk")
        model.microphoneMuteOverride = true
        model.microphoneKeyHeld = false
        model.microphoneMuteOverride = false
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// A mode change drops the held-key state rather than carrying a press into a mode that did not
    /// receive it. Open Mic is unmuted, so the gate opens on the mode alone.
    @Test func aModeChangeClearsAHeldKey() {
        withPreservedMicrophoneMode {
            let model = model(mode: "push-to-talk")
            model.microphoneKeyHeld = true
            model.applyMicrophoneMode("voice-activity")
            #expect(!model.microphoneKeyHeld)
            #expect(model.nativeMicrophoneCaptureRequested, "Open Mic transmits without a held key")
        }
    }

    /// A late release from a chord that no longer belongs to the current mode is recorded as
    /// released and never opens capture.
    @Test func aLateKeyEventInAnotherModeNeverOpensCapture() {
        let model = model(mode: "voice-activity")
        model.microphoneMuteOverride = true
        model.handleNativePushToTalkKey(isHeld: true)
        #expect(!model.microphoneKeyHeld)
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// Disabled mode stays disabled: neither a held key nor an override can open it.
    @Test func disabledModeNeverCaptures() {
        let model = model(mode: "disabled")
        model.microphoneKeyHeld = true
        model.microphoneMuteOverride = false
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// An unavailable microphone closes the gate whatever the mode and key say.
    @Test func anUnavailableMicrophoneClosesTheGate() {
        let model = model(mode: "voice-activity")
        model.microphoneAvailable = false
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    /// A session that is no longer connected cannot transmit.
    @Test func aDisconnectedSessionClosesTheGate() {
        let model = model(mode: "voice-activity")
        model.isConnected = false
        #expect(!model.nativeMicrophoneCaptureRequested)
    }

    // MARK: - Open Mic and the icon

    @Test func openMicMutesAndUnmutesNormally() {
        let model = model(mode: "voice-activity")
        #expect(model.nativeMicrophoneCaptureRequested)
        model.toggleNativeMicrophone()
        #expect(model.microphoneMuteOverride)
        #expect(!model.nativeMicrophoneCaptureRequested)
        model.toggleNativeMicrophone()
        #expect(!model.microphoneMuteOverride)
        #expect(model.nativeMicrophoneCaptureRequested)
    }

    /// The icon in push-to-talk mode toggles the override rather than refusing the click the way the
    /// old tile did.
    @Test func pushToTalkIconTogglesTheOverrideAndNotTheMode() {
        let model = model(mode: "push-to-talk")
        model.toggleNativeMicrophone()
        #expect(model.microphoneMuteOverride)
        #expect(model.microphoneMode == "push-to-talk", "clicking the icon never changes the mode")
        model.toggleNativeMicrophone()
        #expect(!model.microphoneMuteOverride)
        #expect(model.microphoneMode == "push-to-talk")
    }

    /// The override-muted icon wins over a held key, and over an available microphone.
    @Test func anOverrideAlwaysReadsMuted() {
        let model = model(mode: "push-to-talk")
        #expect(!model.isNativeMicrophoneMuted)
        model.microphoneKeyHeld = true
        #expect(!model.isNativeMicrophoneMuted)
        model.microphoneMuteOverride = true
        #expect(model.isNativeMicrophoneMuted, "a held key must not outrank the override")
        model.microphoneKeyHeld = false
        #expect(model.isNativeMicrophoneMuted)
    }

    @Test func aDisabledMicrophoneReadsMuted() {
        let model = model(mode: "disabled")
        #expect(model.isNativeMicrophoneMuted)
    }

    /// Toggling the override leaves the user's gain and the mode alone.
    @Test func theOverrideNeverTouchesTheVolumeOrTheMode() {
        let model = model(mode: "voice-activity", volumePercent: 70)
        model.toggleNativeMicrophone()
        #expect(model.microphoneVolumePercent == 70)
        #expect(model.microphoneMode == "voice-activity")
        model.toggleNativeMicrophone()
        #expect(model.microphoneVolumePercent == 70)
    }

    /// Moving the microphone slider while muted changes the level and never unmutes.
    @Test func movingTheVolumeWhileMutedDoesNotUnmute() {
        withExclusivePreferenceDomain {
            let model = model(mode: "voice-activity")
            model.microphoneMuteOverride = true
            model.updateNativeMicrophoneVolume(percent: 40)
            #expect(model.microphoneVolumePercent == 40)
            #expect(model.microphoneMuteOverride)
        }
    }

    // MARK: - Status text

    /// The status line has to distinguish "available" from "transmitting", and never claim a
    /// transmission the override is blocking.
    @Test func theStatusTextPrefersTheOverride() {
        let (_, model) = makeHUDSurface()
        model.isConnected = true
        model.isMicrophoneSectionNegotiated = true
        model.microphoneAvailable = true
        model.microphoneMode = "push-to-talk"
        // The applied gate, which is what the transport was last told: the status line reads it, not
        // the key state.
        model.microphoneEnabled = true
        #expect(model.microphoneStatusText == "PTT Active")
        model.microphoneMuteOverride = true
        #expect(model.microphoneStatusText == "Muted")
        model.microphoneAvailable = false
        #expect(model.microphoneStatusText == "Disabled")
    }
}
