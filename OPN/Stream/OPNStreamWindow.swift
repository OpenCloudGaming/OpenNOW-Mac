//  The dedicated stream window: an AppKit-owned `NSWindow` the stream is created in and never
//  leaves.
//
//  Why AppKit owns it rather than a SwiftUI `Window` scene. Two things have to be true at once, and
//  only this arrangement gives both:
//
//  * The session must not be rebuilt while it is on screen. `NativeNVSTMediaStreamSurface` holds it
//    in a `@StateObject`, so it lives exactly as long as that view does - which rules out hosting the
//    stream in the catalog window and moving it afterwards, and is why the stream gets its own
//    window from the moment it is created.
//  * The window must be able to leave full screen reliably, and a stream window is by definition
//    created mid-session. `.fullScreenPrimary` therefore cannot be granted to a window that has
//    already been ordered in, which is what a SwiftUI `Window` scene does
//    (`View/RemoteCoOp/RemoteCoOpGuestView.swift:53-66`). `WindowFitting.installEarlyFitting`
//    solves this for the main window by fitting it before it is shown; an AppKit-owned window can
//    simply configure `collectionBehavior` before its first `orderFront`, which is the condition the
//    main window depends on. Live-verified on macOS 27.0: enter and exit, three for three, by both
//    `toggleFullScreen` and the green traffic-light button.
//
//  The window is titled on purpose. The green button and the close button are both part of the
//  design, and `OPNDockIconController.hasVisibleAppWindow()` counts a window towards the Dock icon
//  precisely when its style mask contains `.titled` - so a titled stream window keeps the Dock
//  arithmetic that the catalog window alone used to carry.
//

import AppKit

final class OPNStreamWindow: NSWindow {
    /// PiP is a mode of this window, not a second window: the one window shrinks, floats and stays
    /// on top.
    ///
    /// It stays an ordinary key window on purpose. A PiP window that refuses key status is a
    /// viewing surface only - and this one has to keep playing: the picture is in the game, and the
    /// mouse and keyboard have to reach it. What PiP must not do is *take* focus, which is why
    /// entering the mode never activates the app or orders the window front; the user clicking it
    /// is what makes it key, exactly as for the windowed stream.
    var isPictureInPicture = false

    /// What PiP entry replaced, so leaving PiP puts the window back exactly where it was.
    var windowedState: WindowedState?

    /// The stream surface's answer to the close button, installed once the surface is up. Returning
    /// `true` keeps the window open - see `OPNStreamWindowCloseGuard` for why the window itself
    /// never decides.
    var closeRequestHandler: (@MainActor () -> Bool)?

    /// The session surface hosting the stream in this window, registered by the surface itself once
    /// it resolves. The close-button decision needs the session's state - whether there is one at
    /// all, and the controls panel it raises - and the surface is the only thing that has it.
    weak var sessionSurface: (any OPNStreamWindowSessionSurface)?

    /// The close guard, held **strongly and by the window**.
    ///
    /// `NSWindow.delegate` is a `weak` property (AppKit's `NSWindow.h`), so a guard that is only
    /// installed and never retained is deallocated as soon as the installing call returns: the
    /// delegate slot goes back to `nil`, nothing answers `windowShouldClose`, and the close button
    /// tears the window - and the session inside it - down with no prompt at all. That is exactly
    /// what shipped once. `OPNMainWindowCloseGuard` keeps its proxy in a `static var` for the same
    /// reason; this window owns its own, which is also what keeps two windows from sharing one.
    var closeGuard: OPNStreamWindowCloseDelegateProxy?

    struct WindowedState {
        let level: NSWindow.Level
        let collectionBehavior: NSWindow.CollectionBehavior
        let frame: NSRect
        let isMiniaturized: Bool
    }
}

/// What a close-button decision needs to know about the session in the window. Deliberately tiny:
/// the window's guard asks two questions and asks for one thing, and everything else the stream
/// surface can do stays out of this seam.
@MainActor
protocol OPNStreamWindowSessionSurface: AnyObject {
    var isConnected: Bool { get }
    var isPictureInPicture: Bool { get }
    /// Raises the stream controls panel. Called with a `nil` completion, which is what keeps the
    /// third button reading "End Stream" rather than "Quit OpenNOW". Deliberately written out
    /// rather than leaning on `showStreamControls`'s default argument: a defaulted parameter does
    /// not satisfy a protocol requirement, so the signature is spelled the same in both places.
    func showStreamControls(completion: StreamSessionQuitDecisionHandler?)
}

@MainActor
enum OPNStreamWindowFactory {
    /// Matched by identifier, the same way the main window is found, so a second window cannot make
    /// the lookup ambiguous.
    static let identifier = "stream"
    static let defaultContentSize = CGSize(width: 1280, height: 720)
    static let minimumContentSize = CGSize(width: 480, height: 270)
    /// Titled on purpose, and it is load-bearing beyond looks: `OPNDockIconController` counts a
    /// window towards the Dock icon exactly when its style mask contains `.titled`, so a titled
    /// stream window keeps the arithmetic the catalog window alone used to carry. Named here rather
    /// than inline so the Dock test can assert it without a window server.
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    /// Set **before** the first `orderFront` - the entire point of owning the window ourselves.
    static let collectionBehavior: NSWindow.CollectionBehavior = [.fullScreenPrimary]

    static func existing() -> OPNStreamWindow? {
        NSApp.windows.compactMap { $0 as? OPNStreamWindow }.first { $0.identifier?.rawValue == identifier }
    }

    /// Every window setting that has to be in place before the window is ever ordered in goes here.
    static func make() -> OPNStreamWindow {
        let window = OPNStreamWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        // Full-bleed picture under a transparent titlebar, the same arrangement the catalog window
        // has, and the reason `StreamStageLayout` still reserves the top strip in windowed mode.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The window's lifetime is the presenter's, never AppKit's: a real close would tear the
        // stream surface down, and the session lives in it.
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumContentSize
        window.setContentSize(defaultContentSize)
        window.collectionBehavior = collectionBehavior
        return window
    }
}
