import Foundation

/// The bounding-box fit the native transport uses when a guest's preset is below the source. It was
/// lifted out of the deleted WebRTC relay, where the same geometry decided libwebrtc's pre-scale.
enum RemoteCoOpNativeVideoGeometry {
    /// The largest box no bigger than the limit that keeps the source's aspect ratio, with even
    /// dimensions because I420 subsamples chroma by two. A zero limit means "do not scale".
    static func adaptedSize(sourceWidth: Int, sourceHeight: Int, maximumWidth: Int, maximumHeight: Int) -> (width: Int, height: Int) {
        guard maximumWidth > 0, maximumHeight > 0 else { return (even(sourceWidth), even(sourceHeight)) }
        let scale = min(Double(maximumWidth) / Double(sourceWidth), Double(maximumHeight) / Double(sourceHeight))
        guard scale < 1 else { return (even(sourceWidth), even(sourceHeight)) }
        return (even(Int((Double(sourceWidth) * scale).rounded())), even(Int((Double(sourceHeight) * scale).rounded())))
    }

    private static func even(_ value: Int) -> Int { max(2, value - (value % 2)) }
}
