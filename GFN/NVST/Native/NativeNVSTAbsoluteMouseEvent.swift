import Foundation

/// An absolute cursor position for the remote pointer.
///
/// This outlived the vendored input encoder it used to share a file with: the stream view routes
/// absolute-mode cursor moves through it, and the Bifrost-free transport encodes it as the
/// `0x206` absolute-pointer command.
public struct NativeNVSTAbsoluteMouseEvent: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    /// The coordinate space `x` and `y` are measured in — the stream view's content frame, not the
    /// stream resolution. The wire carries it alongside the position.
    public let viewportWidth: Int32
    public let viewportHeight: Int32
    public let timestamp: MediaTimestamp

    public init(x: Int32,
                y: Int32,
                viewportWidth: Int32 = 0,
                viewportHeight: Int32 = 0,
                timestamp: MediaTimestamp) {
        self.x = x
        self.y = y
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.timestamp = timestamp
    }
}
