import Foundation
@preconcurrency import WebRTC

@_silgen_name("OPNLibWebRTCStatsOwnerHandleStatsReport")
private func OPNLibWebRTCStatsOwnerHandleStatsReport(_ owner: UnsafeMutableRawPointer?, _ stats: NSDictionary)

@objc(OPNLibWebRTCStats)
final class OPNLibWebRTCStats: NSObject, @unchecked Sendable {
    private let owner: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var requestInFlight = false
    private var lastRequestMs: UInt64 = 0
    private weak var sessionImpl: OPNLibWebRTCSessionImpl?

    @objc(initWithOwner:)
    init(owner: UnsafeMutableRawPointer?) {
        self.owner = owner
        super.init()
    }

    @objc(requestStatsWithSessionImpl:queue:)
    func requestStats(sessionImpl: OPNLibWebRTCSessionImpl?, queue: DispatchQueue) {
        guard Self.envFlagEnabled("OPN_ENABLE_WEBRTC_STATS", defaultValue: true) else { return }
        guard let peerConnection = sessionImpl?.peerConnection else { return }
        let now = Self.monotonicMs()
        guard lastRequestMs == 0 || now - lastRequestMs >= 900 else { return }
        guard !requestInFlight else { return }
        lastRequestMs = now
        requestInFlight = true
        peerConnection.statistics { [weak self] report in
            queue.async { [weak self] in
                guard let self else { return }
                self.requestInFlight = false
                guard let parsed = Self.parse(report) else {
                    OPNLibWebRTCStatsOwnerHandleStatsReport(self.owner, ["available": false])
                    return
                }
                OPNLibWebRTCStatsOwnerHandleStatsReport(self.owner, parsed as NSDictionary)
            }
        }
    }

    @objc(startPollingWithSessionImpl:queue:)
    func startPolling(sessionImpl: OPNLibWebRTCSessionImpl?, queue: DispatchQueue) {
        guard timer == nil else { return }
        self.sessionImpl = sessionImpl
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.requestStats(sessionImpl: self.sessionImpl, queue: queue)
        }
        self.timer = timer
        timer.resume()
        NSLog("[LibWebRTC] stats polling started")
    }

    @objc func stopPolling() {
        timer?.cancel()
        timer = nil
        requestInFlight = false
    }

    @objc(applyRuntimeBitrateLimitMbps:reason:sessionImpl:)
    func applyRuntimeBitrateLimit(mbps: Int, reason: String, sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard let peerConnection = sessionImpl?.peerConnection else { return }
        let clampedMbps = min(max(mbps, 1), 250)
        let maxBitrateBps = NSNumber(value: clampedMbps * 1_000_000)
        let currentBitrateBps = NSNumber(value: max(1, clampedMbps * 7 / 10) * 1_000_000)
        let minBitrateBps = NSNumber(value: max(1, clampedMbps * 35 / 100) * 1_000_000)
        let applied = peerConnection.setBweMinBitrateBps(minBitrateBps, currentBitrateBps: currentBitrateBps, maxBitrateBps: maxBitrateBps)
        NSLog("[LibWebRTC] Runtime bitrate limit %d Mbps applied=%d reason=%@", clampedMbps, applied ? 1 : 0, reason)
    }

    private static func parse(_ report: RTCStatisticsReport?) -> [String: Any]? {
        guard let report else { return nil }
        var codecs: [String: String] = [:]
        var parsed: [String: Any] = [
            "available": false,
            "latencyMs": -1.0,
            "jitterMs": -1.0,
            "inboundBitrateMbps": -1.0,
            "packetLossPercent": -1.0,
            "decodeTimeMs": -1.0,
            "renderFps": -1.0,
            "bytesReceived": UInt64(0),
            "packetsReceived": UInt64(0),
            "packetsLost": Int64(0),
            "framesReceived": UInt64(0),
            "framesDecoded": UInt64(0),
            "framesDropped": UInt64(0),
            "timestampMs": monotonicMs(),
            "videoDecoder": "libwebrtc",
            "videoSink": "OPNMetalVideoView",
            "videoPipelineMode": "libwebrtc Metal display",
        ]
        var inboundCodecId = ""
        var selectedVideoScore: UInt64 = 0

        for stat in report.statistics.values {
            if stat.type == "codec" {
                if let mimeType = string(stat.values["mimeType"]), !mimeType.isEmpty { codecs[stat.id] = mimeType }
                continue
            }
            if stat.type == "candidate-pair" {
                let nominated = number(stat.values["nominated"])
                let state = string(stat.values["state"])
                let rtt = number(stat.values["currentRoundTripTime"]) ?? number(stat.values["roundTripTime"])
                if (nominated == nil || nominated?.boolValue == true), (state == nil || state == "succeeded"), let rtt {
                    parsed["latencyMs"] = rtt.doubleValue * 1_000
                    parsed["available"] = true
                }
                continue
            }
            guard stat.type == "inbound-rtp", isVideo(stat) else { continue }
            let jitter = number(stat.values["jitter"])
            let packetsReceived = number(stat.values["packetsReceived"])
            let packetsLost = number(stat.values["packetsLost"])
            let bytesReceived = number(stat.values["bytesReceived"])
            let framesReceived = number(stat.values["framesReceived"])
            let framesDecoded = number(stat.values["framesDecoded"])
            let framesDropped = number(stat.values["framesDropped"])
            let framesPerSecond = number(stat.values["framesPerSecond"])
            let frameWidth = number(stat.values["frameWidth"]) ?? number(stat.values["width"])
            let frameHeight = number(stat.values["frameHeight"]) ?? number(stat.values["height"])
            let totalDecodeTime = number(stat.values["totalDecodeTime"])
            let codecId = string(stat.values["codecId"])

            var videoScore = bytesReceived?.uint64Value ?? 0
            if videoScore == 0 { videoScore = framesDecoded?.uint64Value ?? 0 }
            if videoScore == 0 { videoScore = framesReceived?.uint64Value ?? 0 }
            if videoScore < selectedVideoScore {
                parsed["available"] = true
                continue
            }
            selectedVideoScore = videoScore
            let selectedFramesDecoded = framesDecoded?.uint64Value ?? 0

            if let jitter { parsed["jitterMs"] = jitter.doubleValue * 1_000 }
            if let packetsReceived { parsed["packetsReceived"] = packetsReceived.uint64Value }
            if let packetsLost { parsed["packetsLost"] = packetsLost.int64Value }
            if let bytesReceived { parsed["bytesReceived"] = bytesReceived.uint64Value }
            if let framesReceived { parsed["framesReceived"] = framesReceived.uint64Value }
            if framesDecoded != nil { parsed["framesDecoded"] = selectedFramesDecoded }
            if let framesDropped { parsed["framesDropped"] = framesDropped.uint64Value }
            if let frameWidth, let frameHeight, frameWidth.intValue > 0, frameHeight.intValue > 0 {
                parsed["resolution"] = "\(frameWidth.intValue)x\(frameHeight.intValue)"
            }
            if let framesPerSecond, framesPerSecond.doubleValue > 0 { parsed["renderFps"] = framesPerSecond.doubleValue }
            if let totalDecodeTime, totalDecodeTime.doubleValue > 0, selectedFramesDecoded > 0 {
                parsed["decodeTimeMs"] = (totalDecodeTime.doubleValue * 1_000) / Double(selectedFramesDecoded)
            }
            if let codecId, !codecId.isEmpty { inboundCodecId = codecId }
            parsed["available"] = true
        }

        if !inboundCodecId.isEmpty {
            parsed["codec"] = normalizeCodecName(codecs[inboundCodecId] ?? inboundCodecId)
        }
        return parsed
    }

    private static func isVideo(_ stat: RTCStatistics) -> Bool {
        let values = stat.values
        if string(values["mediaType"]) == "video" || string(values["kind"]) == "video" || string(values["trackKind"]) == "video" { return true }
        return number(values["framesDecoded"]) != nil || number(values["framesReceived"]) != nil
    }

    private static func number(_ value: NSObject?) -> NSNumber? { value as? NSNumber }

    private static func string(_ value: NSObject?) -> String? { value as? String }

    private static func normalizeCodecName(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("h265") || lower.contains("hevc") { return "h265" }
        if lower.contains("h264") || lower.contains("avc") { return "h264" }
        if lower.contains("av1") { return "av1" }
        if lower.contains("vp9") { return "vp9" }
        if lower.contains("vp8") { return "vp8" }
        return lower.replacingOccurrences(of: "video/", with: "")
    }

    private static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private static func envFlagEnabled(_ name: String, defaultValue: Bool) -> Bool {
        guard let rawValue = getenv(name), rawValue.pointee != 0 else { return defaultValue }
        let normalized = String(cString: rawValue).lowercased()
        return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off")
    }
}
