//  The floating stats overlay and the formatters behind it.
//
//  Split from `NativeNVSTStreamHUD.swift` on the seam that was already there: this is a diagnostic
//  surface with its own colour thresholds and number formatting, and none of it is reachable from
//  the HUD's controls.
//

import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeStatsHUD: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        let streamFramesPerSecond = model.latestNativeStats?.streamFramesPerSecond ?? Double(profile.fps)
        let resolution = nonEmptyNativeStat(model.latestNativeStats?.resolution, fallback: "\(profile.resolution.width)x\(profile.resolution.height)")
        let codec = nonEmptyNativeStat(model.latestNativeStats?.codec, fallback: "--")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(model.latestNativeStats?.gameFramesPerSecond), label: "GAME FPS", color: nativeGameFPSColor(target: streamFramesPerSecond))
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeStatsWholeNumber(streamFramesPerSecond), label: "STREAM FPS", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(model.latestNativeStats?.latencyMilliseconds), label: "MS", color: nativeLatencyColor)
            }
            .frame(height: 48)

            nativeStatsHorizontalDivider

            VStack(alignment: .leading, spacing: 5) {
                nativeStatsStandardRow(label: "Frame Loss", value: nativeStatsCount(model.latestNativeStats?.frameLoss), detail: nativeStatsTotal(model.latestNativeStats?.totalFrameLoss), color: nativeFrameLossColor)
                // Percent over the last interval, matching what the WebRTC HUD shows; the running
                // count stays alongside it as the detail.
                nativeStatsStandardRow(label: "Packet Loss", value: nativeStatsPercentage(model.latestNativeStats?.packetLossPercent), detail: nativeStatsTotal(model.latestNativeStats?.totalPacketLoss), color: nativePacketLossColor)
                nativeStatsStandardRow(label: "Bandwidth Used", value: nativeStatsMegabits(model.latestNativeStats?.bitrateMegabitsPerSecond), detail: nativeStatsBandwidthDetail, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Jitter", value: nativeStatsMilliseconds(model.latestNativeStats?.jitterMilliseconds), detail: "ms", color: WebRTCMediaStreamTheme.textPrimary)
                // Client-side decode cost. It used to occupy the MS box, where it read as network
                // latency and was not one.
                nativeStatsStandardRow(label: "Decode", value: nativeStatsMilliseconds(model.latestNativeStats?.decodeMilliseconds), detail: nativeStatsDecodeDetail, color: nativeDecodeBudgetColor)
                nativeStatsStandardRow(label: "Transport", value: "Native NVST", detail: nil, color: OpenNOWDesign.accent)
                nativeStatsStandardRow(label: "Resolution", value: resolution, detail: nativeStatsResolutionDetail, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Codec", value: codec, detail: nativeStatsDecoderDetail, color: WebRTCMediaStreamTheme.textPrimary)
                // Decoded surface -> drawable, so a 10-bit or HDR session can be confirmed from
                // the HUD rather than from the diagnostic log.
                nativeStatsStandardRow(label: "Colour", value: nativeStatsColourValue, detail: nativeStatsColourDetail, color: nativeStatsColourColor)
                nativeStatsStandardRow(label: "Render", value: nativeStatsRenderValue, detail: nativeStatsRenderDetail, color: WebRTCMediaStreamTheme.textPrimary)
                // Decode-to-glass, the latency a viewer feels from this side, and its jitter.
                nativeStatsStandardRow(label: "Present", value: nativeStatsPresentValue, detail: nativeStatsPresentDetail, color: WebRTCMediaStreamTheme.textPrimary)
                // Video path (decode + present) against audio's jitter-buffer dwell: an estimate of
                // which one reaches the viewer later, and by how much.
                nativeStatsStandardRow(label: "A/V", value: nativeStatsAVValue, detail: nativeStatsAVDetail, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Rig", value: nativeStatsRigName, detail: nativeStatsRigDetail, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Server Location", value: nonEmptyNativeStat(model.latestNativeStats?.serverLocation, fallback: "--"), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 264, alignment: .topLeading)
        .background(Color.black.opacity(0.90))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WebRTCMediaStreamTheme.accent)
                .frame(height: 2)
        }
        .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 16, x: 0, y: 8)
        .padding([.top, .trailing], OpenNOWDesign.Spacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    func nativeStatsCompactBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.streamNvidia(size: 22, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Text(label)
                .font(.streamNvidia(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
    }

    var nativeStatsVerticalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    var nativeStatsHorizontalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 1)
    }

    func nativeStatsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.streamNvidia(size: 10, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Why the resolution is what it is: `16:9 title` once the launch dropped the bars, or
    /// `16:9 title · 16:9 next launch` when this session found them and the next one will.
    var nativeStatsResolutionDetail: String? {
        if model.resolutionOverriddenForSixteenNine { return "16:9 title" }
        if model.sixteenNineTitleDetected { return "16:9 title · 16:9 next launch" }
        return nil
    }

    /// `ms of 8.3`: decode time against the negotiated frame interval. Over it and the seat is
    /// already lowering the frame rate to what this Mac reports it can decode.
    var nativeStatsDecodeDetail: String {
        guard let fps = model.latestNativeStats?.negotiatedFramesPerSecond,
              let interval = NativeNVSTDecodeBudget.frameIntervalMilliseconds(framesPerSecond: fps) else { return "ms" }
        return String(format: "ms of %.1f", interval)
    }

    var nativeDecodeBudgetColor: Color {
        guard let stats = model.latestNativeStats else { return WebRTCMediaStreamTheme.textPrimary }
        switch NativeNVSTDecodeBudget.level(for: stats) {
        case .over: return WebRTCMediaStreamTheme.danger
        case .tight: return WebRTCMediaStreamTheme.warning
        case .comfortable, .unknown: return WebRTCMediaStreamTheme.textPrimary
        }
    }

    /// Video lead/lag estimate: (decode + present) − audio jitter-buffer dwell. Positive means the
    /// picture arrives after the sound. Excludes the audio device's own output latency (~10–20 ms),
    /// which pulls the true figure toward video-leading; an estimate, labelled as one.
    var nativeStatsAVOffsetMilliseconds: Double? {
        guard let stats = model.latestNativeStats, stats.audioJitterBufferMilliseconds >= 0, stats.decodeMilliseconds >= 0,
              let render = model.latestRenderDiagnostics, render.presentLatencyMs >= 0 else { return nil }
        return stats.decodeMilliseconds + render.presentLatencyMs - stats.audioJitterBufferMilliseconds
    }

    var nativeStatsAVValue: String {
        guard let offset = nativeStatsAVOffsetMilliseconds else { return "--" }
        return String(format: "%@%.0f", offset >= 0 ? "+" : "", offset)
    }

    var nativeStatsAVDetail: String? {
        guard let stats = model.latestNativeStats, stats.audioJitterBufferMilliseconds >= 0 else { return "ms est." }
        let lead = nativeStatsAVOffsetMilliseconds.map { $0 >= 0 ? "video late" : "audio late" } ?? ""
        return String(format: "ms est. · audio buffer %.0f ms%@", stats.audioJitterBufferMilliseconds, lead.isEmpty ? "" : " · " + lead)
    }

    /// Mean decode-to-glass latency over the last second.
    var nativeStatsPresentValue: String {
        guard let render = model.latestRenderDiagnostics, render.presentLatencyMs >= 0 else { return "--" }
        return String(format: "%.1f", render.presentLatencyMs)
    }

    /// `ms · max 14.2 · jitter 0.8`.
    var nativeStatsPresentDetail: String? {
        guard let render = model.latestRenderDiagnostics, render.presentLatencyMs >= 0 else { return "ms" }
        var detail = String(format: "ms · max %.1f", render.presentLatencyMaxMs)
        if render.presentJitterMs >= 0 { detail += String(format: " · jitter %.2f", render.presentJitterMs) }
        return detail
    }

    /// The seat's GPU as the official client names it (`GeForce RTX 5080`, `Basic Rig`), via the
    /// service's own `gpuNameMap`; the raw identifier (`5080h / B40`) as the detail.
    var nativeStatsRigName: String {
        model.nativeRigName.isEmpty ? "--" : model.nativeRigName
    }

    var nativeStatsRigDetail: String? {
        guard !model.nativeRigRawName.isEmpty, model.nativeRigRawName != model.nativeRigName else { return nil }
        return model.nativeRigRawName
    }

    /// `Mbps of 100`: the used rate against the configured ceiling, so a low reading can be judged
    /// against what was asked for rather than against an absolute threshold.
    var nativeStatsBandwidthDetail: String {
        guard let target = model.latestNativeStats?.targetBitrateMegabitsPerSecond, target > 0 else { return "Mbps" }
        return String(format: "Mbps of %.0f", target)
    }

    /// "hw" / "sw" beside the codec, from the decoder's own report.
    var nativeStatsDecoderDetail: String? {
        guard let stats = model.latestNativeStats, stats.available else { return nil }
        return stats.decoderIsHardware ? "hw" : "software"
    }

    /// The bitstream's declared depth and chroma layout, e.g. `10-bit 4:2:0`.
    var nativeStatsColourValue: String {
        nonEmptyNativeStat(model.latestNativeStats?.bitstreamFormat, fallback: "--")
    }

    /// `xf20 -> bgr10a2 HDR`: the decoded surface, the drawable, and whether EDR is on.
    var nativeStatsColourDetail: String? {
        guard let stats = model.latestNativeStats, stats.available, !stats.decoderOutputFormat.isEmpty else { return nil }
        var detail = stats.decoderOutputFormat
        if let render = model.latestRenderDiagnostics, !render.outputFormat.isEmpty {
            detail += " → " + render.outputFormat
            if render.isHDR { detail += " HDR" }
        }
        return detail
    }

    var nativeStatsColourColor: Color {
        guard let render = model.latestRenderDiagnostics else { return WebRTCMediaStreamTheme.textPrimary }
        return render.isHDR || render.outputFormat == "bgr10a2" ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.textPrimary
    }

    /// The active render tier and how many frames the display loop skipped.
    var nativeStatsRenderValue: String {
        guard let render = model.latestRenderDiagnostics, !render.activeTier.isEmpty else { return "--" }
        return render.activeTier
    }

    var nativeStatsRenderDetail: String? {
        guard let render = model.latestRenderDiagnostics, render.framesReceived > 0 else { return nil }
        let skipped = render.framesReceived > render.framesDrawn ? render.framesReceived - render.framesDrawn : 0
        return render.presentationMode.isEmpty ? "skipped \(skipped)" : "skipped \(skipped) · \(render.presentationMode)"
    }

    func nativeGameFPSColor(target: Double) -> Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available, latestNativeStats.gameFramesPerSecond >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.gameFramesPerSecond >= max(1, target * 0.9) ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    var nativeLatencyColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available, latestNativeStats.latencyMilliseconds >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        if latestNativeStats.latencyMilliseconds >= 120 { return WebRTCMediaStreamTheme.danger }
        if latestNativeStats.latencyMilliseconds >= 90 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    var nativeFrameLossColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.frameLoss == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    var nativePacketLossColor: Color {
        guard let latestNativeStats = model.latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.packetLossPercent <= 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    func nativeStatsWholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    func nativeLiveStatsWholeNumber(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true else { return "--" }
        return nativeStatsWholeNumber(value)
    }

    func nativeStatsCount(_ value: UInt64?) -> String {
        guard model.latestNativeStats?.available == true, let value else { return "--" }
        return String(value)
    }

    func nativeStatsTotal(_ value: UInt64?) -> String {
        guard model.latestNativeStats?.available == true, let value else { return "(-- Total)" }
        return "(\(value) Total)"
    }

    func nativeStatsPercentage(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f%%", value)
    }

    /// Sub-millisecond values are the normal case for decode, so one decimal rather than none.
    func nativeStatsMilliseconds(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    func nativeStatsMegabits(_ value: Double?) -> String {
        guard model.latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    func nonEmptyNativeStat(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }
}
