//  The composed microphone gate: mode, push-to-talk key-held state and the user's mute override,
//  resolved through one authoritative decision. Split from `+Controls` to stay under its budget.
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// The HUD's microphone icon. In every mode it flips the user's mute override; the mode itself
    /// decides whether that override is composed with a held key. It never changes the mode.
    func toggleNativeMicrophone() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage(microphoneUnavailableReason ?? "Microphone is disabled in Settings.")
            return
        }
        toggleNativeMicrophoneMuteOverride()
    }

    /// The independent mute override. Separate from the push-to-talk key, which still owns the
    /// held-to-talk gate, and separate from the actual transmission state, which is what the
    /// transport was last told.
    func toggleNativeMicrophoneMuteOverride() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage(microphoneUnavailableReason ?? "Microphone is disabled in Settings.")
            return
        }
        microphoneMuteOverride.toggle()
        reconcileNativeMicrophoneGate(source: "mute-override")
        showNativeTransientStreamMessage(microphoneMuteOverride ? "Microphone Muted" : "Microphone Unmuted")
        OPNStreamTelemetry.capture("nvst.ui.microphone.mute", level: .info, message: microphoneMuteOverride ? "Native NVST microphone muted by the user." : "Native NVST microphone unmuted by the user.", attributes: ["applicationID": configuration.applicationID, "muted": String(microphoneMuteOverride), "mode": microphoneMode])
    }

    /// The one authoritative capture decision. Transmission needs the mode's own gate open *and* the
    /// override inactive, subject to microphone availability and session readiness. Every event —
    /// key press, key release, icon click, mode change, recovery — lands here rather than opening
    /// capture directly, so a queued or late key event can never bypass the override.
    var nativeMicrophoneCaptureRequested: Bool {
        guard microphoneAvailable, isConnected, !isEnding, !didEnd else { return false }
        switch microphoneMode {
        case "push-to-talk": return microphoneKeyHeld && !microphoneMuteOverride
        case "voice-activity": return !microphoneMuteOverride
        default: return false
        }
    }

    func reconcileNativeMicrophoneGate(source: String) {
        requestNativeMicrophoneEnabled(nativeMicrophoneCaptureRequested, source: source)
    }

    /// The push-to-talk chord's own state. It updates the held-key flag and reconciles the composed
    /// gate; it never sets capture directly, which is what keeps the override authoritative.
    func handleNativePushToTalkKey(isHeld: Bool) {
        guard microphoneMode == "push-to-talk" else {
            // A late release from a chord that has since been reconfigured: record the state, but
            // never let it open capture in a mode that is no longer push-to-talk.
            microphoneKeyHeld = false
            return
        }
        microphoneKeyHeld = isHeld
        reconcileNativeMicrophoneGate(source: "push-to-talk")
    }
}
