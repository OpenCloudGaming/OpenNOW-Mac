import Foundation

/// The canonical keys a transport writes into `StreamReport.metadata` for the post-session summary.
/// Written while the session is connected; a transport omits what it cannot measure.
public enum StreamInsightsKey {
    public static let transport = "transport"
    public static let resolution = "streamResolution"
    public static let codec = "streamCodec"
    public static let frameRate = "streamFrameRate"
    public static let latencyMs = "streamLatencyMs"
    public static let bitrateMbps = "streamBitrateMbps"
    public static let decodeMs = "streamDecodeMs"
    public static let packetLossPercent = "streamPacketLossPercent"
    public static let droppedFrames = "streamDroppedFrames"
    public static let decoderErrors = "streamDecoderErrors"
    public static let recoveries = "streamRecoveries"
}

/// What one finished stream measured about itself, gathered for the post-session summary.
/// Built from the `StreamInsightsKey` entries in `StreamReport.metadata`, plus profile fallbacks.
public struct SessionInsights: Equatable, Sendable {
    public let title: String
    public let endedAt: Date
    public let durationSeconds: Double
    public let outcome: Outcome
    public let transportName: String
    public let streamShapeText: String
    public let metrics: [Metric]
    public let guidance: String

    public enum Outcome: Equatable, Sendable {
        case endedNormally
        case endedWithWarnings
        case endedRemotely
        case failed

        public var headline: String {
            switch self {
            case .endedNormally: return "Session complete"
            case .endedWithWarnings: return "Session ended with warnings"
            case .endedRemotely: return "Session ended remotely"
            case .failed: return "Session stopped"
            }
        }
    }

    public struct Metric: Equatable, Sendable, Identifiable {
        public enum Tone: Equatable, Sendable {
            case neutral
            case caution
        }

        public let id: String
        public let label: String
        public let value: String
        public let tone: Tone

        public init(id: String, label: String, value: String, tone: Tone = .neutral) {
            self.id = id
            self.label = label
            self.value = value
            self.tone = tone
        }
    }

    /// Nil unless a stream actually ran: a launch that failed before the first frame, or a session
    /// the reader paused to step away from, has nothing to summarise.
    public init?(report: StreamReport,
                 endedAt: Date = Date(),
                 fallbackResolution: String,
                 fallbackCodec: String,
                 fallbackFrameRate: Int) {
        guard report.durationSeconds > 0, report.reason != .paused else { return nil }

        let metadata = report.metadata
        let decoderErrors = Self.integer(metadata, StreamInsightsKey.decoderErrors) ?? 0
        let droppedFrames = Self.integer(metadata, StreamInsightsKey.droppedFrames) ?? 0
        let recoveries = Self.integer(metadata, StreamInsightsKey.recoveries) ?? 0
        let frameRate = Self.integer(metadata, StreamInsightsKey.frameRate) ?? fallbackFrameRate

        let trimmedTitle = report.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle.isEmpty ? "GeForce NOW" : trimmedTitle
        self.endedAt = endedAt
        self.durationSeconds = report.durationSeconds
        self.transportName = Self.transportName(metadata[StreamInsightsKey.transport])
        self.streamShapeText = Self.streamShapeText(
            resolution: metadata[StreamInsightsKey.resolution] ?? fallbackResolution,
            frameRate: frameRate,
            codec: metadata[StreamInsightsKey.codec] ?? fallbackCodec
        )
        self.outcome = Self.outcome(report: report,
                                    decoderErrors: decoderErrors,
                                    droppedFrames: droppedFrames,
                                    recoveries: recoveries)
        self.metrics = Self.metrics(metadata: metadata, frameRate: frameRate)
        self.guidance = Self.guidance(report: report,
                                      decoderErrors: decoderErrors,
                                      droppedFrames: droppedFrames,
                                      packetLossPercent: Self.number(metadata, StreamInsightsKey.packetLossPercent))
    }

    public var durationText: String {
        Self.durationText(seconds: durationSeconds)
    }

    public static func durationText(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainder = totalSeconds % 60
        guard hours > 0 else {
            return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
        }
        return String(format: "%dh %02dm", hours, minutes)
    }

    static func transportName(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return "WebRTC"
        }
        if raw.hasPrefix("nvst") { return "Native NVST" }
        if raw == "webrtc" { return "WebRTC" }
        return raw.uppercased()
    }

    static func streamShapeText(resolution: String, frameRate: Int, codec: String) -> String {
        var parts: [String] = []
        let normalizedResolution = resolution
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "x", with: " × ")
        if !normalizedResolution.isEmpty { parts.append(normalizedResolution) }
        if frameRate > 0 { parts.append("\(frameRate) FPS") }
        let normalizedCodec = codec.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedCodec.isEmpty { parts.append(normalizedCodec) }
        return parts.joined(separator: "  ·  ")
    }

    static func outcome(report: StreamReport, decoderErrors: Int, droppedFrames: Int, recoveries: Int) -> Outcome {
        guard report.success, report.reason != .failed else { return .failed }
        if decoderErrors > 0 || droppedFrames > 0 || recoveries > 0 { return .endedWithWarnings }
        if report.reason == .remoteEnded { return .endedRemotely }
        return .endedNormally
    }

    static func metrics(metadata: [String: String], frameRate: Int) -> [Metric] {
        var metrics: [Metric] = []
        if let latency = number(metadata, StreamInsightsKey.latencyMs) {
            metrics.append(Metric(
                id: StreamInsightsKey.latencyMs,
                label: "Latency",
                value: "\(Int(latency.rounded())) ms",
                tone: latency > 60 ? .caution : .neutral
            ))
        }
        if let bitrate = number(metadata, StreamInsightsKey.bitrateMbps) {
            metrics.append(Metric(
                id: StreamInsightsKey.bitrateMbps,
                label: "Bitrate",
                value: String(format: "%.1f Mbps", bitrate)
            ))
        }
        if let decode = number(metadata, StreamInsightsKey.decodeMs), decode > 0 {
            let overBudget = frameRate > 0 && decode > 1000 / Double(frameRate)
            metrics.append(Metric(
                id: StreamInsightsKey.decodeMs,
                label: "Decode",
                value: String(format: "%.1f ms", decode),
                tone: overBudget ? .caution : .neutral
            ))
        }
        if let loss = number(metadata, StreamInsightsKey.packetLossPercent), loss > 0 {
            metrics.append(Metric(
                id: StreamInsightsKey.packetLossPercent,
                label: "Packet loss",
                value: String(format: "%.1f%%", loss),
                tone: loss > 1 ? .caution : .neutral
            ))
        }
        if let dropped = integer(metadata, StreamInsightsKey.droppedFrames), dropped > 0 {
            metrics.append(Metric(
                id: StreamInsightsKey.droppedFrames,
                label: "Dropped frames",
                value: "\(dropped)",
                tone: .caution
            ))
        }
        if let errors = integer(metadata, StreamInsightsKey.decoderErrors), errors > 0 {
            metrics.append(Metric(
                id: StreamInsightsKey.decoderErrors,
                label: "Decoder errors",
                value: "\(errors)",
                tone: .caution
            ))
        }
        if let recoveries = integer(metadata, StreamInsightsKey.recoveries), recoveries > 0 {
            metrics.append(Metric(
                id: StreamInsightsKey.recoveries,
                label: "Recoveries",
                value: "\(recoveries)",
                tone: .caution
            ))
        }
        return metrics
    }

    static func guidance(report: StreamReport, decoderErrors: Int, droppedFrames: Int, packetLossPercent: Double?) -> String {
        guard report.success, report.reason != .failed else {
            let message = report.message.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "The stream stopped before it could run normally." : message
        }
        if decoderErrors > 0 {
            let noun = decoderErrors == 1 ? "frame error" : "frame errors"
            return "The decoder reported \(decoderErrors) \(noun)."
        }
        if droppedFrames > 0 {
            let noun = droppedFrames == 1 ? "frame was" : "frames were"
            return "\(droppedFrames) \(noun) lost before decoding."
        }
        if let packetLossPercent, packetLossPercent > 1 {
            return String(format: "About %.1f%% of packets were lost on the way in.", packetLossPercent)
        }
        return "No decoder errors or lost frames were recorded."
    }

    static func number(_ metadata: [String: String], _ key: String) -> Double? {
        guard let raw = metadata[key], let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    static func integer(_ metadata: [String: String], _ key: String) -> Int? {
        guard let raw = metadata[key], let value = Int(raw) else { return nil }
        return value
    }
}
