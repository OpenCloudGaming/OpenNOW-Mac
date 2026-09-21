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
        case .takeScreenshot:
            takeNativeScreenshot()
        case .toggleAntiAFK:
            toggleNativeAntiAFKMouseMovement()
        case .togglePointerCapture:
            toggleNativePointerLock()
        default:
            handleNativeSessionCommand(command)
        }
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
