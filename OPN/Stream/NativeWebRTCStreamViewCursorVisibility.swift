//  Which pointer the player sees over the video: the Mac's own, or the one the stream is drawing.
//
//  The seat can composite its cursor into the encoded frames while macOS draws another on top of
//  the window, and the player sees two. The decision is a cursor rect rather than `NSCursor.hide()`
//  because the hide count is process-wide: pointer lock owns it, and a second owner would have to
//  balance against the first through focus changes, warps and teardown. A cursor rect has no count,
//  is scoped to the key window, and stops applying the moment the pointer moves onto an overlay.

import AppKit

extension NativeWebRTCStreamView {
    /// A 1x1 fully transparent image: the cursor is still tracked and still clicks, it just draws
    /// nothing.
    static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Whether the Mac's pointer should be invisible over the picture right now.
    ///
    /// Everything ahead of the policy switch is a state where a hidden pointer would be a pointer
    /// the player cannot get back, so none of them is negotiable: pointer lock already owns
    /// `NSCursor.hide()` and there is nothing on screen to hide; relative mode has no on-screen
    /// pointer to speak of; with remote input off or a local overlay up, the pointer is being used
    /// on this side of the link; while the Steam guide chord drives the real macOS cursor, hiding
    /// it would leave that feature with nothing to aim; and a cursor rect only applies to the key
    /// window of the active app anyway, so claiming otherwise would only desynchronise the flag
    /// from what AppKit is actually drawing.
    ///
    /// Deliberately not an input: `isAbsoluteCursorConfined`. Confinement is armed by a click and
    /// only when Direct Mouse Input is on, so in absolute mode the pointer routinely sits over the
    /// picture with no confinement at all; keying on it would show the arrow through most of a
    /// session. Leaving the picture is handled by the rect covering `videoContentFrame()` instead.
    ///
    /// In `auto` the pointer is hidden while the seat is still compositing one of its own — which
    /// is the startup state, capture on until the client turns it off — or while the game has
    /// hidden its pointer, where an arrow would be floating over a mouselook. It is *not* keyed on
    /// an unknown seat visibility: capture also stops on a bitmap-only notification and on the
    /// watchdog's deadline for a seat that publishes nothing, and in both of those the seat's
    /// visibility never arrives. Hiding on `nil` there left the session with no pointer at all.
    static func hidesLocalCursorOverVideo(policy: OPNCursorPolicy,
                                          mode: NativeStreamMouseInputMode,
                                          isPointerLocked: Bool,
                                          remoteInputEnabled: Bool,
                                          localOverlayCapturesInput: Bool,
                                          localCursorInjectionActive: Bool,
                                          seatCompositesCursor: Bool,
                                          remoteCursorWantsPointer: Bool?,
                                          isApplicationActive: Bool,
                                          isWindowKey: Bool) -> Bool {
        guard !isPointerLocked, mode == .absolute, remoteInputEnabled, !localOverlayCapturesInput,
              !localCursorInjectionActive, isApplicationActive, isWindowKey else { return false }
        switch policy {
        case .local: return false
        case .stream: return true
        case .auto: return seatCompositesCursor || remoteCursorWantsPointer == false
        }
    }

    func applyLocalCursorPolicy() {
        let hides = Self.hidesLocalCursorOverVideo(
            policy: cursorPolicy,
            mode: mouseInputMode,
            isPointerLocked: isPointerLocked,
            remoteInputEnabled: remoteInputEnabled,
            localOverlayCapturesInput: localOverlayCapturesInput,
            localCursorInjectionActive: localCursorInjectionActive,
            seatCompositesCursor: seatCompositesCursor,
            remoteCursorWantsPointer: remoteCursorWantsPointer,
            isApplicationActive: NSApplication.shared.isActive,
            isWindowKey: window?.isKeyWindow == true
        )
        guard hides != hidesLocalCursorOverVideo else { return }
        hidesLocalCursorOverVideo = hides
        window?.invalidateCursorRects(for: self)
    }

    /// The rect covers the picture, not the whole view: over the pillarbox bars there is nothing
    /// for the stream's cursor to be drawn on, so the arrow stays.
    public override func resetCursorRects() {
        super.resetCursorRects()
        guard hidesLocalCursorOverVideo else { return }
        let content = videoContentFrame()
        guard content.width > 0, content.height > 0 else { return }
        addCursorRect(content, cursor: Self.invisibleCursor)
    }
}
