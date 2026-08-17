import Foundation

enum StreamSidebarFeature: String, CaseIterable, Hashable, Sendable {
    case microphone
    case recording
    case antiAFK
    case floatingStats
    case networkHealth
    case sessionLimit
    case remoteCoOp
    case videoEnhancement
}

struct StreamSidebarCapabilities: Equatable, Sendable {
    let availableFeatures: Set<StreamSidebarFeature>

    static let webRTC = StreamSidebarCapabilities(availableFeatures: Set(StreamSidebarFeature.allCases))
    static let nativeNVST = StreamSidebarCapabilities(availableFeatures: [
        .microphone,
        .antiAFK,
        .floatingStats,
        .networkHealth,
        .sessionLimit,
    ])

    var visibleFeatures: [StreamSidebarFeature] {
        StreamSidebarFeature.allCases
    }

    func supports(_ feature: StreamSidebarFeature) -> Bool {
        availableFeatures.contains(feature)
    }
}
