import Foundation

private enum OPNSessionReportDisplayMode: Int {
    case automatic = 0
    case always = 1
    case importantOnly = 2
    case off = 3
}

private struct OPNSessionReportDisplayDecision {
    var shouldShow = false
    var score = 0
    var reason = ""
}

private struct OPNSessionHealthTimelinePoint {
    let label: String
    let elapsedSeconds: Double
}

private struct OPNSessionHealthEvent {
    let title: String
    let detail: String
    let elapsedSeconds: Double
}

private struct OPNSessionHealthStatsSummary {
    var available = false
    var sampleCount: UInt64 = 0
    var averageLatencyMs = -1.0
    var maximumLatencyMs = -1.0
    var averageJitterMs = -1.0
    var averageBitrateMbps = -1.0
    var maximumPacketLossPercent = -1.0
    var averageRenderFps = -1.0
    var averageDecodeTimeMs = -1.0
    var framesReceived: UInt64 = 0
    var framesDropped: UInt64 = 0
    var packetsLost: Int64 = 0
    var resolution = ""
    var codec = ""
    var videoEnhancementConfiguredTier = ""
    var videoEnhancementActiveTier = ""
    var videoEnhancementFallbackReason = ""
    var videoEnhancementSourceResolution = ""
    var videoEnhancementDrawableResolution = ""
    var videoEnhancementDiagnostics = ""
    var videoEnhancementFrameTimeMs = -1.0
    var videoEnhancementDroppedFrames: UInt64 = 0
    var fps = 0
}

private struct OPNSessionHealthReport {
    var gameTitle = ""
    var appId = ""
    var webRTCBackend = ""
    var region = ""
    var networkType = ""
    var gpuType = ""
    var usedAutomaticRegion = false
    var networkLatencyMs = -1
    var networkJitterMs = -1
    var measuredBandwidthMbps = 0.0
    var networkPacketLossPercent = -1.0
    var requestedBitrateMbps = 0
    var finalBitrateMbps = 0
    var requestedFps = 0
    var finalFps = 0
    var requestedResolution = ""
    var finalResolution = ""
    var requestedCodec = ""
    var finalCodec = ""
    var success = false
    var connected = false
    var recovered = false
    var terminalError = ""
    var durationSeconds = 0.0
    var launchSeconds = -1.0
    var stats = OPNSessionHealthStatsSummary()
    var timeline: [OPNSessionHealthTimelinePoint] = []
    var events: [OPNSessionHealthEvent] = []
}

@objcMembers
@objc(OPNSessionHealthReportBuilder)
final class OPNSessionHealthReportBuilder: NSObject {
    private static let displayModeKey = "OpenNOW.SessionReport.DisplayMode"
    private static let automaticReportDisplayScoreThreshold = 40

    private var report = OPNSessionHealthReport()
    private var startedAtSeconds = 0.0
    private var started = false
    private var latencyTotal = 0.0
    private var latencyCount: UInt64 = 0
    private var jitterTotal = 0.0
    private var jitterCount: UInt64 = 0
    private var bitrateTotal = 0.0
    private var bitrateCount: UInt64 = 0
    private var renderFpsTotal = 0.0
    private var renderFpsCount: UInt64 = 0
    private var decodeTimeTotal = 0.0
    private var decodeTimeCount: UInt64 = 0

    @objc(resetWithGameTitle:appId:backend:now:)
    func reset(gameTitle: String, appId: String, backend: String, now: Double) {
        report = OPNSessionHealthReport()
        startedAtSeconds = now
        started = true
        latencyTotal = 0.0
        latencyCount = 0
        jitterTotal = 0.0
        jitterCount = 0
        bitrateTotal = 0.0
        bitrateCount = 0
        renderFpsTotal = 0.0
        renderFpsCount = 0
        decodeTimeTotal = 0.0
        decodeTimeCount = 0
        report.gameTitle = gameTitle
        report.appId = appId
        report.webRTCBackend = backend
        markPhase("Prepare", now: now)
    }

    @objc(markPhase:now:)
    func markPhase(_ phase: String, now: Double) {
        guard started, !phase.isEmpty else { return }
        if report.timeline.last?.label == phase { return }
        report.timeline.append(OPNSessionHealthTimelinePoint(label: phase, elapsedSeconds: elapsedSinceStart(now)))
    }

    @objc(setRequestedResolution:fps:codec:bitrateMbps:)
    func setRequested(resolution: String, fps: Int, codec: String, bitrateMbps: Int) {
        report.requestedResolution = resolution
        report.requestedFps = fps
        report.requestedCodec = codec
        report.requestedBitrateMbps = bitrateMbps
    }

    @objc(setFinalResolution:fps:codec:bitrateMbps:)
    func setFinal(resolution: String, fps: Int, codec: String, bitrateMbps: Int) {
        report.finalResolution = resolution
        report.finalFps = fps
        report.finalCodec = codec
        report.finalBitrateMbps = bitrateMbps
    }

    @objc(setNetworkStreamingBaseUrl:networkType:latencyMs:measuredBandwidthMbps:packetLossPercent:jitterMs:usedAutomaticRegion:region:)
    func setNetwork(
        streamingBaseUrl: String,
        networkType: String,
        latencyMs: Int,
        measuredBandwidthMbps: Double,
        packetLossPercent: Double,
        jitterMs: Int,
        usedAutomaticRegion: Bool,
        region: String
    ) {
        report.region = region.isEmpty ? streamingBaseUrl : region
        report.networkType = networkType
        report.usedAutomaticRegion = usedAutomaticRegion
        report.networkLatencyMs = latencyMs
        report.networkJitterMs = jitterMs
        report.measuredBandwidthMbps = measuredBandwidthMbps
        report.networkPacketLossPercent = packetLossPercent
    }

    @objc(setSessionZone:gpuType:negotiatedResolution:negotiatedFps:negotiatedCodec:)
    func setSession(zone: String, gpuType: String, negotiatedResolution: String, negotiatedFps: Int, negotiatedCodec: String) {
        if !zone.isEmpty { report.region = zone }
        if !gpuType.isEmpty { report.gpuType = gpuType }
        if !negotiatedResolution.isEmpty { report.finalResolution = negotiatedResolution }
        if negotiatedFps > 0 { report.finalFps = negotiatedFps }
        if !negotiatedCodec.isEmpty { report.finalCodec = negotiatedCodec }
    }

    @objc(markConnected:)
    func markConnected(now: Double) {
        guard started else { return }
        report.connected = true
        report.launchSeconds = elapsedSinceStart(now)
        markPhase("Connected", now: now)
    }

    @objc(recordEventWithTitle:detail:now:)
    func recordEvent(title: String, detail: String, now: Double) {
        guard started, !title.isEmpty else { return }
        if title.contains("recover") || title.contains("Recovery") {
            report.recovered = true
        }
        report.events.append(OPNSessionHealthEvent(title: title, detail: detail, elapsedSeconds: elapsedSinceStart(now)))
    }

    @objc(addStatsSnapshot:)
    func addStatsSnapshot(_ snapshot: OPNStreamStatsSnapshot?) {
        guard let snapshot, snapshot.available else { return }
        report.stats.available = true
        report.stats.sampleCount += 1
        addAverage(snapshot.latencyMs, total: &latencyTotal, count: &latencyCount)
        if snapshot.latencyMs >= 0.0, snapshot.latencyMs.isFinite {
            report.stats.maximumLatencyMs = max(report.stats.maximumLatencyMs, snapshot.latencyMs)
        }
        addAverage(snapshot.jitterMs, total: &jitterTotal, count: &jitterCount)
        addAverage(snapshot.inboundBitrateMbps, total: &bitrateTotal, count: &bitrateCount)
        if snapshot.packetLossPercent >= 0.0, snapshot.packetLossPercent.isFinite {
            report.stats.maximumPacketLossPercent = max(report.stats.maximumPacketLossPercent, snapshot.packetLossPercent)
        }
        addAverage(snapshot.renderFps, total: &renderFpsTotal, count: &renderFpsCount)
        addAverage(snapshot.decodeTimeMs, total: &decodeTimeTotal, count: &decodeTimeCount)
        report.stats.framesReceived = max(report.stats.framesReceived, UInt64(snapshot.framesReceived))
        report.stats.framesDropped = max(report.stats.framesDropped, UInt64(snapshot.framesDropped))
        report.stats.packetsLost = max(report.stats.packetsLost, Int64(snapshot.packetsLost))
        if !snapshot.resolution.isEmpty { report.stats.resolution = snapshot.resolution }
        if !snapshot.codec.isEmpty { report.stats.codec = snapshot.codec }
        if snapshot.fps > 0 { report.stats.fps = snapshot.fps }
        if hasMeaningfulVideoEnhancementStats(snapshot) {
            report.stats.videoEnhancementConfiguredTier = snapshot.videoEnhancementConfiguredTier
            report.stats.videoEnhancementActiveTier = snapshot.videoEnhancementActiveTier
            report.stats.videoEnhancementFallbackReason = snapshot.videoEnhancementFallbackReason
            report.stats.videoEnhancementSourceResolution = snapshot.videoEnhancementSourceResolution
            report.stats.videoEnhancementDrawableResolution = snapshot.videoEnhancementDrawableResolution
            report.stats.videoEnhancementDiagnostics = snapshot.videoEnhancementDiagnostics
            if snapshot.videoEnhancementFrameTimeMs >= 0.0, snapshot.videoEnhancementFrameTimeMs.isFinite {
                report.stats.videoEnhancementFrameTimeMs = snapshot.videoEnhancementFrameTimeMs
            }
            report.stats.videoEnhancementDroppedFrames = max(report.stats.videoEnhancementDroppedFrames, UInt64(snapshot.videoEnhancementDroppedFrames))
        }
    }

    @objc(finalizeWithSuccess:terminalError:now:)
    func finalize(success: Bool, terminalError: String, now: Double) -> OPNSessionReportPayload {
        var finalized = report
        finalized.success = success
        finalized.terminalError = success ? "" : terminalError
        finalized.durationSeconds = started ? elapsedSinceStart(now) : 0.0
        finalized.stats.averageLatencyMs = average(latencyTotal, latencyCount)
        finalized.stats.averageJitterMs = average(jitterTotal, jitterCount)
        finalized.stats.averageBitrateMbps = average(bitrateTotal, bitrateCount)
        finalized.stats.averageRenderFps = average(renderFpsTotal, renderFpsCount)
        finalized.stats.averageDecodeTimeMs = average(decodeTimeTotal, decodeTimeCount)
        if finalized.finalResolution.isEmpty { finalized.finalResolution = finalized.stats.resolution }
        if finalized.finalCodec.isEmpty { finalized.finalCodec = finalized.stats.codec }
        if finalized.finalFps <= 0 { finalized.finalFps = finalized.stats.fps }

        let decision = displayDecision(for: finalized, mode: loadDisplayMode())
        let reportText = markdown(for: finalized)
        let launchText = formatDuration(finalized.launchSeconds)
        return OPNSessionReportPayload(
            gameTitle: finalized.gameTitle.isEmpty ? "Unknown Game" : finalized.gameTitle,
            success: finalized.success,
            launchText: launchText,
            averageLatencyText: formatMetric(finalized.stats.averageLatencyMs, suffix: " ms", digits: 0),
            averageBitrateText: formatMetric(finalized.stats.averageBitrateMbps, suffix: " Mbps", digits: 1),
            droppedFramesText: String(finalized.stats.framesDropped),
            reportText: reportText,
            copyText: reportText,
            shouldShow: decision.shouldShow,
            displayScore: decision.score,
            displayReason: decision.reason
        )
    }

    private func elapsedSinceStart(_ now: Double) -> Double {
        guard startedAtSeconds.isFinite, now.isFinite, now >= startedAtSeconds else { return 0.0 }
        return now - startedAtSeconds
    }

    private func addAverage(_ value: Double, total: inout Double, count: inout UInt64) {
        guard value >= 0.0, value.isFinite else { return }
        total += value
        count += 1
    }

    private func average(_ total: Double, _ count: UInt64) -> Double {
        count > 0 ? total / Double(count) : -1.0
    }

    private func hasMeaningfulVideoEnhancementStats(_ snapshot: OPNStreamStatsSnapshot) -> Bool {
        if snapshot.videoEnhancementConfiguredTier.isEmpty { return false }
        if snapshot.videoEnhancementConfiguredTier == "pending" { return false }
        return snapshot.videoEnhancementConfiguredTier != "Off" || snapshot.videoEnhancementActiveTier != "Native"
    }

    private func hasVideoEnhancementSummary(_ stats: OPNSessionHealthStatsSummary) -> Bool {
        !stats.videoEnhancementConfiguredTier.isEmpty
    }

    private func loadDisplayMode() -> OPNSessionReportDisplayMode {
        OPNSessionReportDisplayMode(rawValue: UserDefaults.standard.integer(forKey: Self.displayModeKey)) ?? .automatic
    }

    private func displayDecision(for report: OPNSessionHealthReport, mode: OPNSessionReportDisplayMode) -> OPNSessionReportDisplayDecision {
        var decision = OPNSessionReportDisplayDecision()
        if mode == .off {
            decision.reason = "Session reports are disabled"
            return decision
        }
        if mode == .always {
            decision.shouldShow = true
            decision.score = 100
            decision.reason = "Session reports are set to always show"
            return decision
        }

        let recoveryEvent = report.recovered || eventMatches(report, "recovery")
        let guardrailEvent = eventMatches(report, "guardrail")
        let networkWarningEvent = eventMatches(report, "network warning") || eventMatches(report, "launch cancelled")
        let inactivityEvent = eventMatches(report, "inactivity timeout")

        addDecisionScore(&decision, points: report.success ? 0 : 100, reason: "The stream ended with an error")
        addDecisionScore(&decision, points: report.connected ? 0 : 90, reason: "The stream did not reach a connected state")
        addDecisionScore(&decision, points: report.terminalError.isEmpty ? 0 : 80, reason: "A terminal stream error was reported")
        addDecisionScore(&decision, points: recoveryEvent ? 45 : 0, reason: "Automatic recovery was used")
        addDecisionScore(&decision, points: networkWarningEvent ? 45 : 0, reason: "A network warning affected launch")
        addDecisionScore(&decision, points: guardrailEvent ? 40 : 0, reason: "A quality guardrail changed stream settings")
        addDecisionScore(&decision, points: inactivityEvent ? 35 : 0, reason: "The session ended due to inactivity")

        if mode == .automatic, report.stats.available {
            addDecisionScore(&decision, points: report.stats.averageLatencyMs >= 115.0 ? 35 : 0, reason: "Average latency was high")
            addDecisionScore(&decision, points: report.stats.maximumLatencyMs >= 160.0 ? 30 : 0, reason: "Peak latency was high")
            addDecisionScore(&decision, points: report.stats.maximumPacketLossPercent >= 1.0 ? 30 : 0, reason: "Packet loss was elevated")
            addDecisionScore(&decision, points: report.stats.framesDropped >= 60 ? 25 : 0, reason: "Many frames were dropped")
            if report.finalBitrateMbps > 0, report.stats.averageBitrateMbps >= 0.0, report.stats.averageBitrateMbps < Double(report.finalBitrateMbps) * 0.55 {
                addDecisionScore(&decision, points: 20, reason: "Average bitrate was far below the target")
            }
            let targetFps = report.finalFps > 0 ? report.finalFps : report.stats.fps
            if targetFps > 0, report.stats.averageRenderFps >= 0.0, report.stats.averageRenderFps < Double(targetFps) * 0.82 {
                addDecisionScore(&decision, points: 25, reason: "Render FPS was below target")
            }
        }

        decision.shouldShow = decision.score >= Self.automaticReportDisplayScoreThreshold
        if decision.reason.isEmpty {
            decision.reason = decision.shouldShow ? "Session report score exceeded threshold" : "Session ended normally with healthy metrics"
        }
        return decision
    }

    private func addDecisionScore(_ decision: inout OPNSessionReportDisplayDecision, points: Int, reason: String) {
        guard points > 0 else { return }
        decision.score += points
        if decision.reason.isEmpty { decision.reason = reason }
    }

    private func eventMatches(_ report: OPNSessionHealthReport, _ needle: String) -> Bool {
        let lowerNeedle = needle.lowercased()
        return report.events.contains { event in
            event.title.lowercased().contains(lowerNeedle) || event.detail.lowercased().contains(lowerNeedle)
        }
    }

    private func markdown(for report: OPNSessionHealthReport) -> String {
        var output = "# OpenNOW Session Report\n\n"
        output += "## Summary\n"
        output += "- Game: \(markdownEscaped(safeText(report.gameTitle, fallback: "Unknown")))\n"
        output += "- Result: \(report.success ? "Ended normally" : "Error")\n"
        output += "- Duration: \(formatDuration(report.durationSeconds))\n"
        output += "- Launch time: \(formatDuration(report.launchSeconds))\n"
        if !report.terminalError.isEmpty { output += "- Error: \(markdownEscaped(report.terminalError))\n" }

        output += "\n## Stream Profile\n"
        output += "- Requested: \(safeText(report.requestedResolution, fallback: "Unknown")) \(report.requestedFps) FPS, \(safeText(report.requestedCodec, fallback: "Unknown")), \(report.requestedBitrateMbps) Mbps\n"
        output += "- Final: \(safeText(report.finalResolution, fallback: "Unknown")) \(report.finalFps) FPS, \(safeText(report.finalCodec, fallback: "Unknown")), \(report.finalBitrateMbps) Mbps\n"
        output += "- WebRTC backend: \(safeText(report.webRTCBackend, fallback: "Unknown"))\n"
        output += "- GPU: \(safeText(report.gpuType, fallback: "Unknown"))\n"

        output += "\n## Network\n"
        output += "- Region: \(markdownEscaped(safeText(report.region, fallback: "Automatic")))\(report.usedAutomaticRegion ? " (automatic)" : "")\n"
        output += "- Type: \(safeText(report.networkType, fallback: "Unknown"))\n"
        output += "- Latency: \(formatIntegerMetric(report.networkLatencyMs, suffix: " ms"))\n"
        output += "- Jitter: \(formatIntegerMetric(report.networkJitterMs, suffix: " ms"))\n"
        output += "- Bandwidth: \(formatMetric(report.measuredBandwidthMbps, suffix: " Mbps", digits: 0))\n"
        output += "- Packet loss: \(formatMetric(report.networkPacketLossPercent, suffix: "%", digits: 1))\n"

        output += "\n## Stream Stats\n"
        if report.stats.available {
            output += "- Samples: \(report.stats.sampleCount)\n"
            output += "- Average latency: \(formatMetric(report.stats.averageLatencyMs, suffix: " ms", digits: 0))\n"
            output += "- Maximum latency: \(formatMetric(report.stats.maximumLatencyMs, suffix: " ms", digits: 0))\n"
            output += "- Average jitter: \(formatMetric(report.stats.averageJitterMs, suffix: " ms", digits: 0))\n"
            output += "- Average bitrate: \(formatMetric(report.stats.averageBitrateMbps, suffix: " Mbps", digits: 1))\n"
            output += "- Maximum packet loss: \(formatMetric(report.stats.maximumPacketLossPercent, suffix: "%", digits: 1))\n"
            output += "- Average render FPS: \(formatMetric(report.stats.averageRenderFps, suffix: " FPS", digits: 0))\n"
            output += "- Average decode time: \(formatMetric(report.stats.averageDecodeTimeMs, suffix: " ms", digits: 1))\n"
            output += "- Frames dropped: \(report.stats.framesDropped) / \(report.stats.framesReceived)\n"
            output += "- Packets lost: \(report.stats.packetsLost)\n"
        } else {
            output += "- No stream stats were available.\n"
        }

        output += "\n## Video Enhancement\n"
        if hasVideoEnhancementSummary(report.stats) {
            output += "- Configured tier: \(markdownEscaped(safeText(report.stats.videoEnhancementConfiguredTier, fallback: "Unknown")))\n"
            output += "- Active tier: \(markdownEscaped(safeText(report.stats.videoEnhancementActiveTier, fallback: "Unknown")))\n"
            output += "- Resolution: \(safeText(report.stats.videoEnhancementSourceResolution, fallback: "Unknown")) -> \(safeText(report.stats.videoEnhancementDrawableResolution, fallback: "Unknown"))\n"
            output += "- Latest frame time: \(formatMetric(report.stats.videoEnhancementFrameTimeMs, suffix: " ms", digits: 1))\n"
            output += "- Enhancement dropped frames: \(report.stats.videoEnhancementDroppedFrames)\n"
            if !report.stats.videoEnhancementFallbackReason.isEmpty { output += "- Fallback reason: \(markdownEscaped(report.stats.videoEnhancementFallbackReason))\n" }
            if !report.stats.videoEnhancementDiagnostics.isEmpty { output += "- Temporal diagnostics: \(markdownEscaped(report.stats.videoEnhancementDiagnostics))\n" }
        } else {
            output += "- No video enhancement diagnostics were available.\n"
        }

        output += "\n## Timeline\n"
        for point in report.timeline {
            output += "- +\(formatDuration(point.elapsedSeconds)): \(markdownEscaped(point.label))\n"
        }

        output += "\n## Events\n"
        if report.events.isEmpty {
            output += "- No notable recovery or quality events.\n"
        } else {
            for event in report.events {
                output += "- +\(formatDuration(event.elapsedSeconds)): \(markdownEscaped(event.title))"
                if !event.detail.isEmpty { output += " - \(markdownEscaped(event.detail))" }
                output += "\n"
            }
        }
        return output
    }

    private func safeText(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback : value
    }

    private func markdownEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0.0 else { return "Unknown" }
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return minutes <= 0 ? "\(remainingSeconds)s" : "\(minutes)m \(remainingSeconds)s"
    }

    private func formatIntegerMetric(_ value: Int, suffix: String) -> String {
        value < 0 ? "Unknown" : "\(value)\(suffix)"
    }

    private func formatMetric(_ value: Double, suffix: String, digits: Int) -> String {
        guard value.isFinite, value >= 0.0 else { return "Unknown" }
        return String(format: digits == 0 ? "%.0f%@" : "%.1f%@", value, suffix)
    }
}
