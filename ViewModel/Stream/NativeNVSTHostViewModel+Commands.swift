//  Routing a `StreamCommand` to a live native NVST session, split from the controls file so the
//  primary switch stays a plain one-action-per-tile table and this one owns the session-level tail.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    func handleNativeCommand(_ command: StreamCommand) {
        switch command {
        case .toggleStatsHUD:
            toggleNativeStatsHUD()
        case .toggleUnifiedHUD:
            guard !streamControlsVisible else { return }
            setUnifiedHUDVisible(!unifiedHUDVisible)
        case .toggleMicrophone:
            toggleNativeMicrophone()
        case .toggleRecording:
            toggleNativeRecording()
        case .saveReplay:
            saveNativeReplayClip()
        case .takeScreenshot:
            takeNativeScreenshot()
        case .toggleAntiAFK:
            toggleNativeAntiAFKMouseMovement()
        case .togglePointerCapture:
            toggleNativePointerLock()
        case .showShortcutsHelp:
            toggleShortcutsHelp()
        default:
            handleNativeSessionCommand(command)
        }
    }

    /// Opens and closes the shortcut list. Remote input is paused while it is up, and restored to
    /// whatever the HUD and quit menu allow on the way out.
    func toggleShortcutsHelp() {
        setShortcutsHelpVisible(!isShortcutsHelpVisible)
    }

    func setShortcutsHelpVisible(_ visible: Bool) {
        guard isConnected, !isEnding, !didEnd, !streamControlsVisible else { return }
        if visible { isHUDCustomizeVisible = false }
        isShortcutsHelpVisible = visible
        nativeView?.remoteInputEnabled = visible ? false : (!unifiedHUDVisible && networkPathAvailable)
        if !visible { hudGamepadTracker.reset() }
        OPNStreamTelemetry.capture("nvst.ui.shortcuts.toggle", level: .info, message: visible ? "Native NVST shortcuts help shown." : "Native NVST shortcuts help hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    /// The command tail that is not a HUD control: the quit/pause pair and the on-screen keyboard.
    func handleNativeSessionCommand(_ command: StreamCommand) {
        switch command {
        case .showQuitMenu:
            if !streamControlsVisible { showStreamControls() }
        case .endSession:
            endFromStreamControls()
        case .pauseSession:
            pauseFromStreamControls()
        case .toggleOnScreenKeyboard:
            toggleOnScreenKeyboard()
        default:
            break
        }
    }
}
