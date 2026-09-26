//  Where the stream window and its Picture-in-Picture mode were last left.
//
//  AppKit's own frame autosave is the obvious tool and it is the wrong one here: there is one
//  window with two distinct placements - the windowed stream and the small floating PiP picture -
//  and one autosave name cannot tell them apart. PiP's position would overwrite the windowed one
//  and the next session would open small; the two are therefore stored separately, keyed by mode.
//
//  Only the placement is restored, clamped onto a screen that still exists: a frame saved on a
//  display that has since been unplugged must not open the window off the desktop.

import AppKit

@MainActor
enum OPNStreamWindowFrameStore {
    static let windowedFrameKey = "OpenNOW.Stream.WindowedFrame"
    static let pictureInPictureFrameKey = "OpenNOW.Stream.PictureInPictureFrame"

    static func rememberedFrame(isPictureInPicture: Bool, defaults: UserDefaults = .standard) -> NSRect? {
        guard let string = defaults.string(forKey: key(isPictureInPicture: isPictureInPicture)),
              !string.isEmpty else { return nil }
        let frame = NSRectFromString(string)
        guard isUsable(frame) else { return nil }
        return frame
    }

    static func save(_ frame: NSRect, isPictureInPicture: Bool, defaults: UserDefaults = .standard) {
        guard isUsable(frame) else { return }
        defaults.set(NSStringFromRect(frame), forKey: key(isPictureInPicture: isPictureInPicture))
    }

    static func forget(isPictureInPicture: Bool, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(isPictureInPicture: isPictureInPicture))
    }

    /// Nudges a remembered frame back onto a screen, preferring the one it already overlaps.
    static func onScreen(_ frame: NSRect) -> NSRect {
        onScreen(frame, within: NSScreen.screens.map(\.visibleFrame))
    }

    /// The clamping arithmetic, with the screens taken out of it so it can be asserted directly.
    static func onScreen(_ frame: NSRect, within visibleFrames: [NSRect]) -> NSRect {
        guard let visible = visibleFrames.first(where: { $0.intersects(frame) }) ?? visibleFrames.first else {
            return frame
        }
        return OPNStreamStageGeometry.clamped(frame, within: visible)
    }

    private static func key(isPictureInPicture: Bool) -> String {
        isPictureInPicture ? pictureInPictureFrameKey : windowedFrameKey
    }

    private static func isUsable(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
