import Foundation

/// What a transport can say about the session that just ran, for the post-session summary.
/// Called before disconnecting: a disconnected transport has nothing left to measure.
public protocol StreamInsightsReporting: Sendable {
    func streamInsightsMetadata() async -> [String: String]
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
