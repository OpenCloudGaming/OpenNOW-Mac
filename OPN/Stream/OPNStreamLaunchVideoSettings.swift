import Foundation

/// The launch profile's renderer-facing settings, handed over as the Bifrost-free renderer is created.
///
/// They used to be applied only once the session connected, so the first frames ran Balanced with no
/// upscaling whatever the profile said, and the renderer's own log line reported the view's defaults.
public struct OPNStreamLaunchVideoSettings: Equatable, Sendable {
    public let upscalingMode: Int
    public let upscalingSharpness: Int
    public let upscalingDenoise: Int
    public let upscalingTargetHeight: Int
    public let pillarboxFillModeIndex: Int
    public let pillarboxFillDim: Int
    public let presentationMode: Int

    public init(profile: OPNStreamPreferenceProfile) {
        upscalingMode = profile.upscalingMode
        upscalingSharpness = profile.upscalingSharpness
        upscalingDenoise = profile.upscalingDenoise
        upscalingTargetHeight = profile.upscalingTargetHeight
        pillarboxFillModeIndex = profile.pillarboxFillModeIndex
        pillarboxFillDim = profile.pillarboxFillDim
        presentationMode = profile.presentationMode
    }
}
