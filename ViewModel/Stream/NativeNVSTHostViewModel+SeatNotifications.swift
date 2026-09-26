//  The seat's asynchronous notifications, routed to the surfaces that act on them. Split out of the
//  session model's own file, which is already at its body-length budget, exactly as `+HUDSections` was.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// The seat's asynchronous notifications, routed to the surfaces that act on them.
    func attachSeatNotificationHandlers(_ bifrostFree: NvstBifrostFreeTransport, nativeView: NativeStreamView) {
        Task { [weak self, weak nativeView] in
            // Match the local pointer to the game's: the seat stops compositing its own cursor as
            // soon as it starts publishing cursor state, so from then on the only pointer is ours
            // and it has to appear and disappear when the game's does.
            await bifrostFree.setRemoteCursorVisibilityHandler { isVisible in
                nativeView?.setRemoteCursorVisible(isVisible)
            }
            // Whether the seat still draws a pointer of its own is a separate question from where
            // the game's pointer is: it stops compositing on a bitmap-only notification and on the
            // watchdog's deadline, neither of which publishes a visibility. The local cursor policy
            // follows this, so a seat that goes quiet gives the pointer back instead of leaving the
            // session with none.
            await bifrostFree.setRemoteCursorCaptureHandler { isCompositing in
                nativeView?.seatCompositesCursor = isCompositing
            }
            // Rumble: the seat names a pad slot and two motor amplitudes; the gamepad monitor
            // behind the view knows which physical device (GameController pad or Steam
            // Controller) holds that slot.
            await bifrostFree.setHapticEventHandler { events in
                guard let self, !self.didEnd else { return }
                self.nativeHapticEventCount += events.count
                for event in events {
                    nativeView?.playHaptic(NativeNVSTHapticCommand(
                        playerIndex: Int(event.gamepadIndex),
                        lowFrequency: event.leftMotor,
                        highFrequency: event.rightMotor,
                        durationMilliseconds: event.effectiveDurationMilliseconds
                    ))
                }
            }
            await bifrostFree.setHdrModeHandler { notification in
                guard let self, !self.didEnd else { return }
                self.nativeHdrModeText = notification.isHDR ? (notification.mode == .trueHdr ? "true-hdr" : "hdr") : ""
            }
            await bifrostFree.setSessionLimitUpdateHandler { [weak self] update in
                self?.applyNativeSessionLimitUpdate(update)
            }
        }
    }

}
