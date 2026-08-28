import Foundation

/// The seat's cursor notifications, and what they say about the pointer the game wants drawn.
///
/// The seat can either composite its own cursor into the encoded video (`0x308` mouse cursor
/// capture) or leave the picture clean and tell the client what to draw. Doing both at once is the
/// double-cursor bug: the seat's pointer is baked into the frames while the client's own pointer
/// floats over them. NVIDIA's client enables capture only for startup, then switches to these
/// notifications and turns capture back off — which is only possible if the client understands
/// them, so the parse lives here.
public struct NvstRemoteCursor: Equatable, Sendable {
    /// A predefined system cursor: an id, an optional position, an optional visibility byte.
    public static let systemCursorCode: UInt16 = 0x010f
    /// OpenNOW's client calls `0x0110` a bitmap cursor. Our own inbound command table — built from
    /// captures — calls it `video-stream-progress`, and the two cannot both be right. Treating a
    /// progress message as "cursor visible" would un-hide the pointer during mouselook on every
    /// one, so `0x0110` is deliberately NOT treated as a cursor until a capture settles it. The
    /// visible/hidden decision comes from `0x010f` regardless, which is the only cursor command
    /// the seat was observed sending.
    public static let bitmapCursorCode: UInt16 = 0x0110

    /// Whether the game wants a pointer on screen at all. False means it has hidden the cursor —
    /// mouselook — and the client should hide its own pointer rather than leave one floating.
    public let isVisible: Bool

    public static func from(_ command: NvstControlCommand) -> NvstRemoteCursor? {
        switch command.code {
        case systemCursorCode:
            let payload = command.payload
            guard payload.count >= 4 else { return nil }
            // An explicit visibility byte wins when the seat sends one.
            if payload.count >= 9 {
                return NvstRemoteCursor(isVisible: payload[payload.startIndex + 8] != 0)
            }
            var cursorID: UInt32 = 0
            for offset in (0..<4).reversed() {
                cursorID = (cursorID << 8) | UInt32(payload[payload.startIndex + offset])
            }
            // Predefined cursor 0 is the "no cursor" shape. Only a *system* cursor id of 0 means
            // hidden — a bitmap cursor with id 0 is still a visible image, which is why the two
            // commands are kept apart above.
            return NvstRemoteCursor(isVisible: cursorID != 0)
        default:
            return nil
        }
    }
}
