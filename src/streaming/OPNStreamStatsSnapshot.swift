import Foundation

@objc(OPNStreamStatsSnapshot)
final class OPNStreamStatsSnapshot: NSObject {
    @objc let available: Bool
    @objc let latencyMs: Double
    @objc let jitterMs: Double
    @objc let inboundBitrateMbps: Double
    @objc let packetLossPercent: Double
    @objc let decodeTimeMs: Double
    @objc let renderFps: Double
    @objc let framesReceived: UInt64
    @objc let framesDropped: UInt64
    @objc let packetsLost: Int64
    @objc let fps: Int
    @objc let resolution: String
    @objc let codec: String
    @objc let videoEnhancementActiveTier: String
    @objc let videoEnhancementConfiguredTier: String
    @objc let videoEnhancementSourceResolution: String
    @objc let videoEnhancementDrawableResolution: String
    @objc let videoEnhancementFallbackReason: String
    @objc let videoEnhancementDiagnostics: String
    @objc let videoEnhancementFrameTimeMs: Double
    @objc let videoEnhancementDroppedFrames: UInt64

    @objc init(available: Bool,
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
