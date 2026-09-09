import AppKit
import Testing
@testable import OpenNOW

/// `seatCompositesCursor` defaults to false — the state a session spends nearly all of its time
/// in, capture switched off by the first notification — so the startup case names itself.
@MainActor private func hidesLocalCursor(policy: OPNCursorPolicy,
                                         seatWantsPointer: Bool?,
                                         seatCompositesCursor: Bool = false,
                                         mode: NativeStreamMouseInputMode = .absolute,
                                         isPointerLocked: Bool = false,
                                         remoteInputEnabled: Bool = true,
                                         localOverlayCapturesInput: Bool = false,
                                         localCursorInjectionActive: Bool = false,
                                         isApplicationActive: Bool = true,
                                         isWindowKey: Bool = true) -> Bool {
    NativeWebRTCStreamView.hidesLocalCursorOverVideo(
        policy: policy,
        mode: mode,
        isPointerLocked: isPointerLocked,
        remoteInputEnabled: remoteInputEnabled,
        localOverlayCapturesInput: localOverlayCapturesInput,
        localCursorInjectionActive: localCursorInjectionActive,
        seatCompositesCursor: seatCompositesCursor,
        remoteCursorWantsPointer: seatWantsPointer,
        isApplicationActive: isApplicationActive,
        isWindowKey: isWindowKey
    )
}

@Test @MainActor func localCursorPolicyResolvesEverySeatCursorState() {
    // Auto hides only while something else is drawing a pointer: the seat's composited one, which
    // is the startup state until the client switches capture off, or a game that has hidden its
    // own. Every other combination leaves the local pointer where the player can find it.
    #expect(hidesLocalCursor(policy: .auto, seatWantsPointer: nil, seatCompositesCursor: true))
    #expect(hidesLocalCursor(policy: .auto, seatWantsPointer: true, seatCompositesCursor: true))
    #expect(hidesLocalCursor(policy: .auto, seatWantsPointer: false, seatCompositesCursor: true))
    #expect(hidesLocalCursor(policy: .auto, seatWantsPointer: false))
    #expect(!hidesLocalCursor(policy: .auto, seatWantsPointer: true))
    // The seat stopped compositing and never published a visibility — the watchdog's deadline on a
    // silent seat, or a bitmap-only push. Hiding here was a session with no pointer at all.
    #expect(!hidesLocalCursor(policy: .auto, seatWantsPointer: nil))

    for compositing in [true, false] {
        #expect(!hidesLocalCursor(policy: .local, seatWantsPointer: nil, seatCompositesCursor: compositing))
        #expect(!hidesLocalCursor(policy: .local, seatWantsPointer: false, seatCompositesCursor: compositing))
        #expect(!hidesLocalCursor(policy: .local, seatWantsPointer: true, seatCompositesCursor: compositing))

        #expect(hidesLocalCursor(policy: .stream, seatWantsPointer: nil, seatCompositesCursor: compositing))
        #expect(hidesLocalCursor(policy: .stream, seatWantsPointer: false, seatCompositesCursor: compositing))
        #expect(hidesLocalCursor(policy: .stream, seatWantsPointer: true, seatCompositesCursor: compositing))
    }
}

@Test @MainActor func localCursorPolicyKeepsThePointerWhereverItIsStillNeeded() {
    for policy in OPNCursorPolicy.allCases {
        for seatWantsPointer in [nil, true, false] as [Bool?] {
            let seatCompositesCursor = seatWantsPointer == nil
            // Pointer lock owns NSCursor.hide() and has already taken the pointer away.
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, isPointerLocked: true))
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, mode: .relative))
            // Input is being used on this side of the link: the HUD, the on-screen keyboard, a
            // stream that is not connected yet.
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, remoteInputEnabled: false))
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, localOverlayCapturesInput: true))
            // The Steam guide chord is driving the real pointer so the player can click their way
            // back into the app; an invisible one has nothing to aim.
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, localCursorInjectionActive: true))
            // Cursor rects only apply to the key window of the active app.
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, isApplicationActive: false))
            #expect(!hidesLocalCursor(policy: policy, seatWantsPointer: seatWantsPointer, seatCompositesCursor: seatCompositesCursor, isWindowKey: false))
        }
    }
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
@MainActor func manualPointerCaptureSurvivesSeatCursorNotifications() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.cursorAssociationHandler = { _ in .success }
    view.hidesCursorWhilePointerLocked = false
    view.mouseInputMode = .absolute
    window.contentView = view
    defer { view.setPointerLocked(false) }

    view.setManualPointerCapture(true)

    #expect(view.isPointerLocked)
    #expect(view.manualPointerCaptureOverride)

    // The games this override exists for never hide their cursor, so the seat keeps publishing a
    // visible one. Before the override, each of these threw the player's capture away mid-game.
    view.setRemoteCursorVisible(true)

    #expect(view.isPointerLocked)
    #expect(view.remoteCursorWantsPointer == true)

    view.setRemoteCursorVisible(false)

    #expect(view.isPointerLocked)
    #expect(view.mouseInputMode == .absolute)

    view.setManualPointerCapture(false)

    #expect(!view.isPointerLocked)
    #expect(!view.manualPointerCaptureOverride)

    // Released by hand, the seat is back in charge.
    view.setRemoteCursorVisible(false)

    #expect(view.mouseInputMode == .relative)
}

@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
@MainActor func manualPointerCaptureOverrideEndsWithTheSession() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.cursorAssociationHandler = { _ in .success }
    view.hidesCursorWhilePointerLocked = false
    view.mouseInputMode = .absolute
    window.contentView = view
    defer { view.setPointerLocked(false) }

    view.setManualPointerCapture(true)
    // Teardown and in-place reconnect both drop remote input, which releases the pointer.
    view.remoteInputEnabled = false

    #expect(!view.isPointerLocked)
    #expect(!view.manualPointerCaptureOverride)
}

@Test @MainActor func manualPointerCaptureOverrideNeedsALockThatTookHold() {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.mouseInputMode = .absolute

    // No window: `enablePointerLock` gives up. An override with no lock behind it would silence
    // every seat cursor notification for the rest of the session.
    view.setManualPointerCapture(true)

    #expect(!view.isPointerLocked)
    #expect(!view.manualPointerCaptureOverride)

    view.setRemoteCursorVisible(false)

    #expect(view.mouseInputMode == .relative)
}

/// A capture held by hand swallows the seat's mode changes for as long as it lasts, so releasing it
/// can land in `.relative` with no lock behind it — the state where `routeInputEvent` drops every
/// mouse event and the mouse is dead until the seat next changes its mind.
@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
@MainActor func releasingAManualCaptureReplaysTheSeatsPointerRequest() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.cursorAssociationHandler = { _ in .success }
    view.hidesCursorWhilePointerLocked = false
    view.mouseInputMode = .absolute
    window.contentView = view
    defer { view.setPointerLocked(false) }

    // The game is in mouselook, so the client followed it into relative mode.
    view.setRemoteCursorVisible(false)

    #expect(view.mouseInputMode == .relative)
    #expect(view.isPointerLocked)

    // The player hands the pointer back and takes it again by hand: from here the override swallows
    // whatever the seat says.
    view.setManualPointerCapture(false)
    view.setManualPointerCapture(true)
    view.setRemoteCursorVisible(true)

    #expect(view.mouseInputMode == .relative)
    #expect(view.isPointerLocked)

    view.setManualPointerCapture(false)

    #expect(!view.isPointerLocked)
    #expect(view.mouseInputMode == .absolute)
}

/// The mouselook direction is deliberately not replayed: following the seat back into a lock here
/// would retake the pointer the player just asked to get back.
@Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
@MainActor func releasingAManualCaptureDoesNotFollowTheSeatBackIntoMouselook() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.cursorAssociationHandler = { _ in .success }
    view.hidesCursorWhilePointerLocked = false
    view.mouseInputMode = .absolute
    window.contentView = view
    defer { view.setPointerLocked(false) }

    view.setManualPointerCapture(true)
    view.setRemoteCursorVisible(false)
    view.setManualPointerCapture(false)

    #expect(!view.isPointerLocked)
    #expect(view.mouseInputMode == .absolute)
}

/// The transport reports the seat's capture separately from its cursor visibility, and the local
/// pointer follows the capture: a seat that stops compositing without ever publishing a visibility
/// used to leave the session with no pointer at all.
@Test @MainActor func theLocalPointerComesBackWhenTheSeatStopsCompositing() {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.cursorPolicy = .auto
    view.mouseInputMode = .absolute

    #expect(view.seatCompositesCursor)
    #expect(view.remoteCursorWantsPointer == nil)

    view.seatCompositesCursor = false

    #expect(!view.seatCompositesCursor)
    #expect(view.remoteCursorWantsPointer == nil)
    #expect(!NativeWebRTCStreamView.hidesLocalCursorOverVideo(
        policy: view.cursorPolicy,
        mode: view.mouseInputMode,
        isPointerLocked: view.isPointerLocked,
        remoteInputEnabled: view.remoteInputEnabled,
        localOverlayCapturesInput: view.localOverlayCapturesInput,
        localCursorInjectionActive: view.localCursorInjectionActive,
        seatCompositesCursor: view.seatCompositesCursor,
        remoteCursorWantsPointer: view.remoteCursorWantsPointer,
        isApplicationActive: true,
        isWindowKey: true))
}
