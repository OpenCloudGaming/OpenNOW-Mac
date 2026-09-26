//  The Picture-in-Picture control strip.
//
//  PiP suppresses the whole HUD - the dock is 268pt wide at its narrowest and the window is 320pt,
//  so it would cover nearly all of the picture - and this replaces it: two actions, on the picture,
//  in the smallest form the design system has. Restore is the way back to the windowed stream;
//  End Session is the same call the in-stream quit menu's third button makes, so a menu bar action
//  and this strip tear down identically.
//
//  The strip is not a bar. It sizes to its two buttons and sits in the bottom-trailing corner
//  rather than spanning the window, and it shows itself only while the pointer is moving over the
//  picture and fades back out after a few idle seconds - the same bargain the Remote Co-Op guest
//  window makes for the controls over its video. It stays visible until the first pointer movement
//  is seen, so a window that never reports one leaves Restore reachable rather than stranding the
//  user in a picture with no way back.
//
//  Everything here scales with the dock's `opnInterfaceScale(uiScale)`, which the surrounding
//  overlay already applies.
//

import AppKit
import SwiftUI

struct NativeNVSTPictureInPictureControls: View {
    @ObservedObject var model: NativeNVSTHostViewModel
    /// Visible until the pointer has been seen and then gone quiet. Starting hidden would make the
    /// whole mode depend on tracking the window server may not deliver.
    @State private var isVisible = true
    @State private var hideTask: Task<Void, Never>?
    static let idleSeconds: UInt64 = 3

    var body: some View {
        HStack(spacing: 6) {
            StreamQuitMenuButton(
                title: "Restore",
                isPrimary: true,
                isFocused: false,
                isDisabled: model.isEnding,
                action: model.togglePictureInPicture
            )
            .frame(width: 104)
            StreamQuitMenuButton(
                title: "End Session",
                isPrimary: false,
                isFocused: false,
                isDisabled: model.isEnding,
                action: model.endFromStreamControls
            )
            .frame(width: 104)
        }
        .padding(6)
        .background(StreamHUDTheme.panel.opacity(0.82))
        .overlay {
            Rectangle()
                .stroke(StreamHUDTheme.divider, lineWidth: 1)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(6)
        .background(
            PictureInPicturePointerTracker(onPointerActivity: reveal)
                .allowsHitTesting(false)
        )
        .onDisappear { hideTask?.cancel() }
    }

    /// Shown again on any movement, then hidden once the pointer has been still for long enough.
    /// Cancelling first is what keeps a burst of movement from accumulating timers.
    private func reveal() {
        hideTask?.cancel()
        if !isVisible { isVisible = true }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.idleSeconds))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

/// A click-transparent pointer reporter for the PiP window. The strip has to notice the pointer
/// anywhere over the picture, not only over its own two buttons, and it must never take a click from
/// the game. `hitTest` answers `nil`, and tracking areas are delivered by the window independently
/// of hit testing, so the picture keeps every event it had before this view existed.
private struct PictureInPicturePointerTracker: NSViewRepresentable {
    let onPointerActivity: () -> Void

    func makeNSView(context: Context) -> PictureInPicturePointerTrackingView {
        let view = PictureInPicturePointerTrackingView()
        view.onPointerActivity = onPointerActivity
        return view
    }

    func updateNSView(_ nsView: PictureInPicturePointerTrackingView, context: Context) {
        nsView.onPointerActivity = onPointerActivity
    }
}

private final class PictureInPicturePointerTrackingView: NSView {
    var onPointerActivity: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    /// Never the hit-test result, so a click goes to the game exactly as it did before.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`: the mode deliberately never activates the app, so an area that only
        // tracked a key window would never fire for the window the user is pointing at.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onPointerActivity?() }
    override func mouseMoved(with event: NSEvent) { onPointerActivity?() }
}

extension NativeNVSTMediaStreamSurface {
    var nativePictureInPictureControls: some View {
        NativeNVSTPictureInPictureControls(model: model)
    }
}
