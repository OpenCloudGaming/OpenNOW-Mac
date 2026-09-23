import Foundation

/// What a transport can say about the session that just ran, for the post-session summary.
/// Called before disconnecting: a disconnected transport has nothing left to measure.
public protocol StreamInsightsReporting: Sendable {
    func streamInsightsMetadata() async -> [String: String]
}

extension NativeWebRTCTransport: StreamInsightsReporting {
    public func streamInsightsMetadata() async -> [String: String] {
        let stats = latestStatsSnapshot()
        guard stats.available else { return [:] }
        var metadata: [String: String] = [:]
        metadata[StreamInsightsKey.transport] = "webrtc"
        if stats.latencyMs > 0 { metadata[StreamInsightsKey.latencyMs] = String(Int(stats.latencyMs.rounded())) }
        if stats.inboundBitrateMbps > 0 { metadata[StreamInsightsKey.bitrateMbps] = String(format: "%.1f", stats.inboundBitrateMbps) }
        if stats.packetLossPercent > 0 { metadata[StreamInsightsKey.packetLossPercent] = String(format: "%.2f", stats.packetLossPercent) }
        if stats.decodeTimeMs > 0 { metadata[StreamInsightsKey.decodeMs] = String(format: "%.1f", stats.decodeTimeMs) }
        if stats.framesDropped > 0 { metadata[StreamInsightsKey.droppedFrames] = String(stats.framesDropped) }
        if !stats.resolution.isEmpty { metadata[StreamInsightsKey.resolution] = stats.resolution }
        if !stats.codec.isEmpty { metadata[StreamInsightsKey.codec] = stats.codec }
        if stats.fps > 0 { metadata[StreamInsightsKey.frameRate] = String(stats.fps) }
        return metadata
    }
}

extension NvstBifrostFreeTransport: StreamInsightsReporting {
    public func streamInsightsMetadata() async -> [String: String] {
        guard let snapshot = await performanceSnapshot() else { return [:] }
        var metadata: [String: String] = [:]
        metadata[StreamInsightsKey.transport] = "nvst"
        if snapshot.latencyMilliseconds >= 0 { metadata[StreamInsightsKey.latencyMs] = String(Int(snapshot.latencyMilliseconds.rounded())) }
        if snapshot.bitrateMegabitsPerSecond > 0 { metadata[StreamInsightsKey.bitrateMbps] = String(format: "%.1f", snapshot.bitrateMegabitsPerSecond) }
        if snapshot.packetLossPercent > 0 { metadata[StreamInsightsKey.packetLossPercent] = String(format: "%.2f", snapshot.packetLossPercent) }
        if snapshot.decodeMilliseconds > 0 { metadata[StreamInsightsKey.decodeMs] = String(format: "%.1f", snapshot.decodeMilliseconds) }
        if snapshot.frameLoss > 0 { metadata[StreamInsightsKey.droppedFrames] = String(snapshot.frameLoss) }
        let decoderErrors = decoder?.failedFrameCount ?? 0
        if decoderErrors > 0 { metadata[StreamInsightsKey.decoderErrors] = String(decoderErrors) }
        let recoveries = receiver?.stats.recoveries ?? 0
        if recoveries > 0 { metadata[StreamInsightsKey.recoveries] = String(recoveries) }
        if !snapshot.resolution.isEmpty { metadata[StreamInsightsKey.resolution] = snapshot.resolution }
        if !snapshot.codec.isEmpty { metadata[StreamInsightsKey.codec] = snapshot.codec }
        if snapshot.negotiatedFramesPerSecond > 0 { metadata[StreamInsightsKey.frameRate] = String(Int(snapshot.negotiatedFramesPerSecond.rounded())) }
        return metadata
    }
}
