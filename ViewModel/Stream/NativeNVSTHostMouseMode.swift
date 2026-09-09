//  What the HUD says about the mouse, and the one cursor decision it can change mid-game.
//
//  Two questions the player asks while a game is misbehaving: which mode is input actually
//  travelling in, and whose pointer am I looking at. The first is a readout the capture tile
//  carries; the second is a real setting, cycled here and written straight through to the live
//  view so the fix lands in the session that needed it.

import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    /// The stored index as the enum the view and the preference both speak.
    var cursorPolicy: OPNCursorPolicy { OPNCursorPolicy.from(cursorPolicyIndex) }

    /// The capture tile's readout.
    ///
    /// Opening the HUD turns remote input off, which drops any pointer lock, so `pointerLocked`
    /// reads false for nearly every sample taken while this is on screen. The mode is the part of
    /// the answer that survives the HUD being up, which is why the tile reports it at all.
    var mouseModeSubtitle: String {
        Self.mouseModeSubtitle(isRelative: mouseInputIsRelative, isPointerLocked: pointerLocked)
    }

    /// Relative without a lock is the normal reading inside the HUD: closing it calls
    /// `restoreInputFocus()`, which re-takes the pointer whenever the selected mode is relative.
    nonisolated static func mouseModeSubtitle(isRelative: Bool, isPointerLocked: Bool) -> String {
        guard isRelative else { return "Absolute · click stream to capture" }
        return isPointerLocked ? "Relative · pointer locked" : "Relative · recaptures on close"
    }

    /// The Cursor tile's readout: which pointer the player sees once the HUD is out of the way.
    var cursorPolicySubtitle: String { Self.cursorPolicySubtitle(for: cursorPolicy) }

    nonisolated static func cursorPolicySubtitle(for policy: OPNCursorPolicy) -> String {
        switch policy {
        case .auto: return "\(policy.label) · follows the stream"
        case .local: return "\(policy.label) · Mac pointer always drawn"
        case .stream: return "\(policy.label) · Mac pointer hidden"
        }
    }

    /// Only `.stream` guarantees the Mac's pointer is never drawn over the picture; `.auto` still
    /// draws it whenever the seat reports a visible cursor of its own, so it keeps the plain arrow.
    var cursorPolicySymbolName: String { cursorPolicy == .stream ? "cursorarrow.slash" : "cursorarrow" }

    nonisolated static func nextCursorPolicy(after policy: OPNCursorPolicy) -> OPNCursorPolicy {
        let cases = OPNCursorPolicy.allCases
        guard let index = cases.firstIndex(of: policy) else { return .auto }
        return cases[(index + 1) % cases.count]
    }

    /// Saved as the global setting and pushed into the running view, because the only reason to
    /// reach this control is a game drawing a second pointer right now.
    func updateCursorPolicy(_ policy: OPNCursorPolicy) {
        cursorPolicyIndex = policy.rawValue
        OPNStreamPreferences.saveCursorPolicyIndex(policy.rawValue)
        nativeView?.cursorPolicy = policy
        WebRTCMediaTelemetry.capture("nvst.ui.cursor.policy", level: .info, message: "Native NVST cursor policy changed.", attributes: ["applicationID": configuration.applicationID, "policy": policy.label])
    }

    /// Auto → Local → Stream → Auto, one step per click or pad activate.
    ///
    /// Unlike the capture tile this deliberately leaves the HUD open: nothing here needs remote
    /// input to be live — `remoteInputEnabled`'s own observer re-applies the cursor rect when the
    /// HUD closes — and staying put is what lets the player read the label while stepping through.
    func cycleCursorPolicy() {
        guard isConnected, !isEnding, !didEnd else { return }
        updateCursorPolicy(Self.nextCursorPolicy(after: cursorPolicy))
    }
}
