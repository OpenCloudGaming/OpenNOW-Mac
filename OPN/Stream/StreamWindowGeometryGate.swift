//
//  StreamWindowGeometryGate.swift
//  OpenNOW
//
//  When it is safe to change a window's styleMask, aspect ratio or frame.
//
//  Split out of StreamWindowAspectCoordinator.swift so the catalog window's coordinator answers the
//  question the same way.
//

import AppKit
import Foundation

/// Guards every window-geometry mutation against AppKit's nested run loops.
///
/// `inLiveResize` covers a user dragging an edge, and that was the whole guard until a titlebar
/// double-click crashed the app. Zoom does not go through live resize: it runs
/// `-[NSWindow setFrame:display:animate:]`, which spins its own run loop inside
/// `-[NSMoveHelper _doAnimation]` and interpolates the frame from a display link. Swift's main-actor
/// executor drains in that nested loop, so a queued `applyNow()` lands mid-animation, rebuilds the
/// theme frame under AppKit, and the animation's next `_setFrameCommon:` traps inside
/// `_adjustNeedsDisplayRegionForNewFrame:`.
///
/// Any non-default main run loop mode means AppKit is inside one of those nested loops — resize,
/// move, zoom, menu tracking, a modal session — so the only safe move is to wait for the default
/// mode to come back.
enum StreamWindowGeometryGate {
    static func isLiveResizing(_ window: NSWindow) -> Bool {
        window.inLiveResize || window.contentView?.inLiveResize == true
    }

    @MainActor
    static func isRunningNestedRunLoop() -> Bool {
        isNestedRunLoopMode(CFRunLoopCopyCurrentMode(CFRunLoopGetMain()))
    }

    /// A `nil` mode means the main run loop is not running an iteration at all, which is not a
    /// nested loop and must not block a mutation.
    static func isNestedRunLoopMode(_ mode: CFRunLoopMode?) -> Bool {
        guard let mode else { return false }
        return mode != CFRunLoopMode.defaultMode
    }

    /// True when a geometry change has to wait. Live resize is reported separately by the callers
    /// that already have a `didEndLiveResize` observer to resume from.
    @MainActor
    static func shouldDeferGeometryMutation(for window: NSWindow) -> Bool {
        isLiveResizing(window) || isRunningNestedRunLoop()
    }

    /// Runs `body` once the nested loop ends, and drops it if that never happens.
    ///
    /// A zoom animation has no "did end" notification to observe, so this polls at roughly its own
    /// cadence. Dropping after the cap is deliberate: forcing the mutation through is the crash
    /// this type exists to prevent, and the coordinators re-apply on their next update anyway.
    @MainActor
    static func whenGeometryIsMutable(_ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            var remainingAttempts = 200
            while isRunningNestedRunLoop(), remainingAttempts > 0 {
                remainingAttempts -= 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !isRunningNestedRunLoop() else { return }
            body()
        }
    }
}
