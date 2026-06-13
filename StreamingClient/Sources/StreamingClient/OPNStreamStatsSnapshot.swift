import Foundation

@objc(OPNStreamStatsSnapshot)
public final class OPNStreamStatsSnapshot: NSObject {
    @objc public let available: Bool
    @objc public let latencyMs: Double
    @objc public let jitterMs: Double
    @objc public let inboundBitrateMbps: Double
    @objc public let packetLossPercent: Double
    @objc public let decodeTimeMs: Double
    @objc public let renderFps: Double
    @objc public let framesReceived: UInt64
    @objc public let framesDropped: UInt64
    @objc public let packetsLost: Int64
    @objc public let fps: Int
    @objc public let resolution: String
    @objc public let codec: String
    @objc public let videoEnhancementActiveTier: String
    @objc public let videoEnhancementConfiguredTier: String
    @objc public let videoEnhancementSourceResolution: String
    @objc public let videoEnhancementDrawableResolution: String
    @objc public let videoEnhancementFallbackReason: String
    @objc public let videoEnhancementDiagnostics: String
    @objc public let videoEnhancementFrameTimeMs: Double
    @objc public let videoEnhancementDroppedFrames: UInt64

    @objc public init(available: Bool,
                      latencyMs: Double,
                      jitterMs: Double,
                      inboundBitrateMbps: Double,
                      packetLossPercent: Double,
                      decodeTimeMs: Double,
                      renderFps: Double,
                      framesReceived: UInt64,
                      framesDropped: UInt64,
                      packetsLost: Int64,
                      fps: Int,
                      resolution: String,
                      codec: String,
                      videoEnhancementActiveTier: String,
                      videoEnhancementConfiguredTier: String,
                      videoEnhancementSourceResolution: String,
                      videoEnhancementDrawableResolution: String,
                      videoEnhancementFallbackReason: String,
                      videoEnhancementDiagnostics: String,
                      videoEnhancementFrameTimeMs: Double,
                      videoEnhancementDroppedFrames: UInt64) {
        self.available = available
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.inboundBitrateMbps = inboundBitrateMbps
        self.packetLossPercent = packetLossPercent
        self.decodeTimeMs = decodeTimeMs
        self.renderFps = renderFps
        self.framesReceived = framesReceived
        self.framesDropped = framesDropped
        self.packetsLost = packetsLost
        self.fps = fps
        self.resolution = resolution
        self.codec = codec
        self.videoEnhancementActiveTier = videoEnhancementActiveTier
        self.videoEnhancementConfiguredTier = videoEnhancementConfiguredTier
        self.videoEnhancementSourceResolution = videoEnhancementSourceResolution
        self.videoEnhancementDrawableResolution = videoEnhancementDrawableResolution
        self.videoEnhancementFallbackReason = videoEnhancementFallbackReason
        self.videoEnhancementDiagnostics = videoEnhancementDiagnostics
        self.videoEnhancementFrameTimeMs = videoEnhancementFrameTimeMs
        self.videoEnhancementDroppedFrames = videoEnhancementDroppedFrames
        super.init()
    }
}

extension OPNStreamStatsSnapshot: @unchecked Sendable {}
