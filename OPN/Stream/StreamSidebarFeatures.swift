import Foundation

enum StreamSidebarFeature: String, CaseIterable, Hashable, Sendable {
    case microphone
    case recording
    case screenshot
    case antiAFK
    case floatingStats
    case networkHealth
    case sessionLimit
    case remoteCoOp
    case videoEnhancement
    /// A property of the window rather than of the transport, and still gated on purpose: this is
    /// how Picture-in-Picture gets turned off if a render path cannot survive the mode change.
    case pictureInPicture
}

struct StreamSidebarCapabilities: Equatable, Sendable {
    let availableFeatures: Set<StreamSidebarFeature>

    static let nativeNVST = StreamSidebarCapabilities(availableFeatures: [
        .microphone,
        .recording,
        .screenshot,
        .antiAFK,
        .floatingStats,
        .networkHealth,
        .sessionLimit,
        .remoteCoOp,
        .videoEnhancement,
        .pictureInPicture,
    ])

    var visibleFeatures: [StreamSidebarFeature] {
        StreamSidebarFeature.allCases
    }

    func supports(_ feature: StreamSidebarFeature) -> Bool {
        availableFeatures.contains(feature)
    }
}
