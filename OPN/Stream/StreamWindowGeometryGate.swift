//  When it is safe to change a window's styleMask, aspect ratio or frame.
//

import AppKit
import Foundation

/// Guards every window-geometry mutation against AppKit's nested run loops, and owns the one
/// supported way to release a window aspect-ratio lock.
///
/// `inLiveResize` covers a user dragging an edge. AppKit also spins nested loops that raise no
/// flag and post no notification: `-[NSWindow setFrame:display:animate:]` runs one inside
/// `-[NSMoveHelper _doAnimation]` and interpolates the frame from a display link, in
/// `_NSMoveTimerRunLoopMode`. Any non-default main run loop mode is therefore treated as "AppKit
/// is busy" and the mutation waits for the default mode to come back — resize, move, zoom, menu
/// tracking, a modal session.
///
/// This gate is not what fixes the titlebar double-click crash. A queued `applyNow()` cannot land
/// inside a zoom animation at all: no main-actor continuation drains in `_NSMoveTimerRunLoopMode`,
/// and mutating the theme frame from inside that loop does not reproduce the trap. That crash was
/// a zeroed aspect ratio; see `releaseAspectRatioLock`.
enum StreamWindowGeometryGate {
    /// One-point increments: fine enough to be indistinguishable from free resizing.
    private static let onePointIncrements = NSSize(width: 1, height: 1)

    @MainActor
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

    /// Releases an aspect-ratio lock without poisoning the window's zoom path.
    ///
    /// Assigning `.zero` to `aspectRatio`/`contentAspectRatio` does not release the lock. AppKit
    /// keeps the zeroed ratio as a live divisor, so `-[NSWindow _zoomToScreen:]` computes a
    /// standard frame whose height is NaN and the next titlebar double-click traps in
    /// `-[NSWindow _adjustNeedsDisplayRegionForNewFrame:]` on its way to `translateX:y:`. The
    /// poisoned window reads back identically to one that was never locked, so nothing downstream
    /// can detect it, and no frame change, style-mask change, content-view swap or reordering
    /// undoes it — only assigning a non-degenerate ratio again masks it.
    ///
    /// Aspect ratio and resize increments are mutually exclusive attributes and setting one
    /// cancels the other, so one-point increments are the supported way to drop the ratio: they
    /// leave the window freely resizable and its zoom target finite, and a later lock cancels
    /// them again in turn.
    @MainActor
    static func releaseAspectRatioLock(_ window: NSWindow) {
        window.contentResizeIncrements = onePointIncrements
        window.resizeIncrements = onePointIncrements
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
