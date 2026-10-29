//  How one stream window is laid out on the desktop, as state the window and its content share.
//
//  Borderless and tiled windows both give up the aspect lock and the titlebar strip: the picture
//  letterboxes inside whatever frame the window was given instead of the frame following the
//  picture. The window owns this, the stream's root view reads it, and the presenter writes it.

import Foundation
import Observation

@MainActor
@Observable
final class OPNStreamWindowLayoutState {
    /// The window covers a frame edge to edge with its chrome hidden.
    var isBorderless = false
    /// The presenter owns this window's frame. Cleared the moment the reader moves or resizes it.
    var isAutoTiled = false

    /// The reader placed this window themselves, so the layout leaves it where it is.
    var isManuallyPlaced = false

    var releasesAspectLock: Bool { isBorderless || isAutoTiled }

    /// A window the layout owns never enters native full screen by itself, and the session-ready
    /// full-screen request leaves it alone.
    var suppressesNativeFullScreen: Bool { isBorderless || isAutoTiled }

    /// Placements are remembered only for a window the reader placed.
    var persistsFrame: Bool { !isBorderless && !isAutoTiled }
}
