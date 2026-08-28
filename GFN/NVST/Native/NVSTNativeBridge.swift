import Foundation

/// Result of `prepare()` on a native NVST transport.
///
/// This is all that remains of the old native-bridge module: the vendored NVIDIA libraries and the
/// shim that loaded them have been removed, and the Bifrost-free transport builds this directly —
/// it loads no native library, so `runtimeAvailable` is always true and the artifact lists empty.
public struct NVSTNativeBridgeStatus: Equatable, Sendable {
    public let libraryURL: URL
    public let bundledArtifactURLs: [URL]
    public let resolvedSymbols: [String]
    public let runtimeAvailable: Bool

    public init(libraryURL: URL, bundledArtifactURLs: [URL], resolvedSymbols: [String], runtimeAvailable: Bool) {
        self.libraryURL = libraryURL
        self.bundledArtifactURLs = bundledArtifactURLs
        self.resolvedSymbols = resolvedSymbols
        self.runtimeAvailable = runtimeAvailable
    }
}
