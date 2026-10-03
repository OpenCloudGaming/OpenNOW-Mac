//  The composed microphone gate: mode, push-to-talk key-held state and the user's mute override,
//  resolved through one authoritative decision. Split from `+Controls` to stay under its budget.
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// The HUD's microphone icon. It flips the mute override in every mode and never changes the
    /// mode itself; push-to-talk composes that override with its held key.
    func toggleNativeMicrophone() {
        toggleNativeMicrophoneMuteOverride()
    }

    /// The independent mute override, separate from the push-to-talk key and from the state the
    /// transport was last told.
    func toggleNativeMicrophoneMuteOverride() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage(microphoneUnavailableReason ?? "Microphone is disabled in Settings.")
            return
        }
        isMicrophoneMuteOverrideActive.toggle()
        reconcileNativeMicrophoneGate(source: "mute-override")
        showNativeTransientStreamMessage(isMicrophoneMuteOverrideActive ? "Microphone Muted" : "Microphone Unmuted")
        OPNStreamTelemetry.capture("nvst.ui.microphone.mute", level: .info, message: isMicrophoneMuteOverrideActive ? "Native NVST microphone muted by the user." : "Native NVST microphone unmuted by the user.", attributes: ["applicationID": configuration.applicationID, "muted": String(isMicrophoneMuteOverrideActive), "mode": microphoneMode])
    }

    /// The one authoritative capture decision, subject to microphone availability and session
    /// readiness. Every event lands here, so a late key event cannot bypass the override.
    var nativeMicrophoneCaptureRequested: Bool {
        guard microphoneAvailable, isConnected, !isEnding, !didEnd else { return false }
        switch microphoneMode {
        case "push-to-talk": return isPushToTalkKeyHeld && !isMicrophoneMuteOverrideActive
        case "voice-activity": return !isMicrophoneMuteOverrideActive
        default: return false
        }
    }

    func reconcileNativeMicrophoneGate(source: String) {
        requestNativeMicrophoneEnabled(nativeMicrophoneCaptureRequested, source: source)
    }

    /// The chord's own state. It never sets capture directly, which is what keeps the override
    /// authoritative over a held key.
    func handleNativePushToTalkKey(isHeld: Bool) {
        guard microphoneMode == "push-to-talk" else {
            isPushToTalkKeyHeld = false
            return
        }
        isPushToTalkKeyHeld = isHeld
        reconcileNativeMicrophoneGate(source: "push-to-talk")
    }
}
