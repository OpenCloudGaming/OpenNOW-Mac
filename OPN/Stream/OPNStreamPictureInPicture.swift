//  Picture-in-Picture, as a mode of the dedicated stream window.
//
//  Windowed only, by decision: `.floating` and `.canJoinAllSpaces`, never `.fullScreenAuxiliary`, so
//  the small window floats over ordinary windows and follows the user between Spaces and displays
//  without floating over full-screen apps.
//
//  The sharp edge is the borderless carrier child window. `NativeStreamView` creates one - a
//  borderless, clear carrier for the vendored NVST Metal view - and attaches it as a child of the
//  stream window. AppKit rewrites the child's `collectionBehavior` to `.ignoresCycle` when it is
//  attached, which drops `.canJoinAllSpaces`: a carrier left as AppKit configured it is pinned to the
//  Space it was created on while its parent floats across every Space, and the visible picture
//  (which is a descendant of the *parent*) would be the only thing that moved. Live-measured on
//  macOS 27.0 - parent `canJoinAllSpaces`, carrier `ignoresCycle` - so the parent's behavior is
//  re-applied to every child window on the way in and on the way out.
//

import AppKit

@MainActor
enum OPNStreamPictureInPicture {
    /// The box a PiP picture fits inside, before the stream's own aspect ratio decides the height.
    /// 320pt is small enough to sit out of the way and still legible.
    static let box = CGSize(width: 320, height: 320)
    static let margin: CGFloat = 20

    /// The aspect-preserving content size of the PiP picture, from the same pure geometry the
    /// windowed stage fits its picture with - `StreamStageLayout.contentSize` delegates to the same
    /// function. The box is asked to fit the ratio directly because there is no titlebar strip to
    /// take off it: that is exactly what a zero inset means to the windowed stage.
    static func contentSize(aspectRatio: CGFloat) -> CGSize {
        OPNStreamStageGeometry.aspectFitted(viewport: box, aspectRatio: aspectRatio) ?? box
    }

    /// Which change the PiP control asks for, from the window's state alone. Pure: the sequencing
    /// rule - leave full screen first, then enter PiP - is the part worth asserting, and it does not
    /// need a window server to be wrong.
    enum Request: Equatable {
        case enter
        case leave
        case leaveFullScreenThenEnter
    }

    static func request(isPictureInPicture: Bool, isFullScreen: Bool, isFullScreenTransitioning: Bool) -> Request {
        if isPictureInPicture { return .leave }
        // A transition already in flight refuses a second style-mask change, so it sequences the same
        // way a settled full-screen state does.
        if isFullScreen || isFullScreenTransitioning { return .leaveFullScreenThenEnter }
        return .enter
    }

    /// Bottom-trailing corner of the screen's visible frame, so the small window clears the Dock
    /// and the menu bar.
    static func frame(contentSize: CGSize, in screen: NSScreen?) -> NSRect {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: contentSize.width + margin * 2, height: contentSize.height + margin * 2)
        return frame(contentSize: contentSize, visibleFrame: visibleFrame)
    }

    /// The placement arithmetic, with the screen taken out of it so it can be asserted directly.
    static func frame(contentSize: CGSize, visibleFrame: NSRect) -> NSRect {
        let origin = NSPoint(
            x: max(visibleFrame.minX, visibleFrame.maxX - contentSize.width - margin),
            // Both clamps matter: a visible frame narrower than the margin pair, or shorter than the
            // picture, must still leave the small window on screen rather than off its floor.
            y: max(visibleFrame.minY, min(visibleFrame.minY + margin, visibleFrame.maxY - contentSize.height - margin))
        )
        return NSRect(origin: origin, size: contentSize)
    }

    static func enter(_ window: OPNStreamWindow, aspectRatio: CGFloat) {
        guard !window.isPictureInPicture else { return }
        window.windowedState = OPNStreamWindow.WindowedState(
            level: window.level,
            collectionBehavior: window.collectionBehavior,
            frame: window.frame,
            isMiniaturized: window.isMiniaturized
        )
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.isPictureInPicture = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces]
        setAllSpacesMembership(onChildWindowsOf: window, isMember: true)
        OPNStreamWindowChrome.apply(to: window, isPictureInPicture: true)
        window.setFrame(frame(contentSize: contentSize(aspectRatio: aspectRatio), in: window.screen), display: true)
    }

    static func exit(_ window: OPNStreamWindow) {
        guard window.isPictureInPicture else { return }
        window.isPictureInPicture = false
        OPNStreamWindowChrome.apply(to: window, isPictureInPicture: false)
        guard let state = window.windowedState else {
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
            setAllSpacesMembership(onChildWindowsOf: window, isMember: false)
            return
        }
        window.windowedState = nil
        window.level = state.level
        window.collectionBehavior = state.collectionBehavior
        setAllSpacesMembership(onChildWindowsOf: window, isMember: false)
        window.setFrame(state.frame, display: true)
        if state.isMiniaturized { window.miniaturize(nil) }
    }

    /// The carrier child windows are not children in the view hierarchy, so nothing else re-derives
    /// their Space membership when the parent's changes.
    ///
    /// Only the one flag is touched, in both directions. AppKit's `.ignoresCycle` on a child stays:
    /// copying the parent's whole `collectionBehavior` onto a carrier would hand it
    /// `.fullScreenPrimary`, which is not something a window that exists to carry a Metal view should
    /// ever be offered.
    static func setAllSpacesMembership(onChildWindowsOf window: NSWindow, isMember: Bool) {
        for child in window.childWindows ?? [] {
            if isMember {
                child.collectionBehavior.insert(.canJoinAllSpaces)
            } else {
                child.collectionBehavior.remove(.canJoinAllSpaces)
            }
        }
    }
}

@MainActor
enum OPNStreamWindowChrome {
    /// PiP drops the traffic lights and makes the whole window draggable, so the small picture is
    /// nothing but picture. The style mask itself is never mutated: this repo has already been
    /// burned by mutating `styleMask`/`collectionBehavior` on a window that is already on screen
    /// (`View/RemoteCoOp/RemoteCoOpGuestView.swift:57-66`), and hiding the standard buttons gives
    /// the same full-bleed result through a supported path.
    static func apply(to window: NSWindow, isPictureInPicture: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = isPictureInPicture
        }
        window.isMovableByWindowBackground = isPictureInPicture
    }
}
