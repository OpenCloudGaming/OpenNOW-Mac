//  The floating stats overlay and the formatters behind it. Its colour thresholds and number
//  formatting are its own, and none of it is reachable from the HUD's controls.
//
//  The panel is a header band, three hero readings, and then the detail rows grouped by what they
//  describe - network, video, timing, audio, session. Fifteen equally weighted rows in one column
//  read as a wall of text: nothing said which number to look at first, and nothing said that
//  "Jitter" and "Present" are not the same kind of measurement. Grouping costs one 9pt label per
//  group and keeps every figure the flat list carried.
//
//  Detail strings are the second reason: A/V's audio-buffer breakdown and Colour's format chain do
//  not fit beside their value, and a single-line row truncated them away. Each row is a
//  `ViewThatFits` that keeps the detail inline while it fits and drops it onto its own trailing
//  line when it does not, so nothing is lost at any width.
//
//  `NativeNVSTStatsPanel` takes formatted strings and colours rather than the live snapshot, so
//  the whole panel renders offscreen from sample values - every threshold colour and every
//  wrapping detail can be looked at without a running session.
//

import SwiftUI

struct NativeNVSTStatsPanel: View {
    /// One of the three headline readings across the top.
    struct Hero: Identifiable {
        let label: String
        let value: String
        let unit: String
        let color: Color
        var id: String { label }
    }

    struct Row: Identifiable {
        let label: String
        let value: String
        var detail: String?
        var color: Color = WebRTCMediaStreamTheme.textPrimary
        var id: String { label }
    }

    struct Group: Identifiable {
        let label: String
        let rows: [Row]
        var id: String { label }
    }

    /// Wide enough that only the longest two details (A/V, Colour) ever take the wrapped layout.
    static let width: CGFloat = 296

    let transport: String
    let heroes: [Hero]
    let groups: [Group]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            heroRow
            // No rule between groups: the hairline that carries each group's label already
            // separates it from the one above, and two lines a few points apart read as a mistake.
            ForEach(groups) { group in
                groupView(group)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .background(WebRTCMediaStreamTheme.panel.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WebRTCMediaStreamTheme.accent)
                .frame(height: 2)
        }
        .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 16, x: 0, y: 8)
    }

    /// The transport used to be a row of its own reading "Native NVST" on every native session.
    /// It is a property of the whole panel, so it sits in the header as a badge instead.
    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("STREAM STATS")
                .font(.streamFont(size: 9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
            Spacer(minLength: 6)
            Text(transport)
                .font(.streamFont(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(WebRTCMediaStreamTheme.accent.opacity(0.14))
                .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.5), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    private var heroRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(heroes.enumerated()), id: \.element.id) { index, hero in
                if index > 0 {
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 1)
                }
                heroBox(hero)
            }
        }
        .frame(height: 54)
    }

    /// The reading, its unit, and a status bar along the bottom edge in the same colour - these
    /// three are the ones read at a glance, mid-game, without stopping to parse a label.
    private func heroBox(_ hero: Hero) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(hero.value)
                    .font(.streamFont(size: 25, weight: .bold))
                    .foregroundStyle(hero.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(hero.unit)
                    .font(.streamFont(size: 10, weight: .bold))
                    .foregroundStyle(hero.color.opacity(0.7))
            }
            Text(hero.label)
                .font(.streamFont(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(hero.color.opacity(0.8))
                .frame(height: 2)
        }
    }

    /// A group label, a hairline carrying it across the panel, and the group's rows.
    private func groupView(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(group.label)
                    .font(.streamFont(size: 9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.rows) { row in
                    rowView(row)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Inline while the detail fits; label and value on one line with the detail beneath, trailing
    /// aligned, when it does not. `ViewThatFits` falls back to its last child when nothing fits,
    /// which is the wrapped layout - so the longest details wrap rather than truncate.
    private func rowView(_ row: Row) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                rowLabel(row.label)
                Spacer(minLength: 10)
                rowValue(row.value, color: row.color)
                if let detail = row.detail { rowDetail(detail) }
            }
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    rowLabel(row.label)
                    Spacer(minLength: 10)
                    rowValue(row.value, color: row.color)
                }
                if let detail = row.detail {
                    rowDetail(detail)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.streamFont(size: 10, weight: .medium))
            .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
            .lineLimit(1)
    }

    private func rowValue(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.streamFont(size: 11, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func rowDetail(_ detail: String) -> some View {
        Text(detail)
            .font(.streamFont(size: 9, weight: .medium))
            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
    }
}

extension NativeNVSTMediaStreamSurface {
    var nativeStatsHUD: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        let streamFramesPerSecond = model.latestNativeStats?.streamFramesPerSecond ?? Double(profile.fps)
        let resolution = nonEmptyNativeStat(model.latestNativeStats?.resolution, fallback: "\(profile.resolution.width)x\(profile.resolution.height)")
        let codec = nonEmptyNativeStat(model.latestNativeStats?.codec, fallback: "--")
        return NativeNVSTStatsPanel(
            transport: "NATIVE NVST",
            heroes: [
                NativeNVSTStatsPanel.Hero(label: "GAME", value: nativeLiveStatsWholeNumber(model.latestNativeStats?.gameFramesPerSecond), unit: "fps", color: nativeGameFPSColor(target: streamFramesPerSecond)),
                NativeNVSTStatsPanel.Hero(label: "STREAM", value: nativeStatsWholeNumber(streamFramesPerSecond), unit: "fps", color: WebRTCMediaStreamTheme.textPrimary),
                NativeNVSTStatsPanel.Hero(label: "LATENCY", value: nativeLiveStatsWholeNumber(model.latestNativeStats?.latencyMilliseconds), unit: "ms", color: nativeLatencyColor),
            ],
            groups: [
                NativeNVSTStatsPanel.Group(label: "NETWORK", rows: [
                    NativeNVSTStatsPanel.Row(label: "Frame Loss", value: nativeStatsCount(model.latestNativeStats?.frameLoss), detail: nativeStatsTotal(model.latestNativeStats?.totalFrameLoss), color: nativeFrameLossColor),
                    // Percent over the last interval, matching what the WebRTC HUD shows; the
                    // running count stays alongside it as the detail.
                    NativeNVSTStatsPanel.Row(label: "Packet Loss", value: nativeStatsPercentage(model.latestNativeStats?.packetLossPercent), detail: nativeStatsTotal(model.latestNativeStats?.totalPacketLoss), color: nativePacketLossColor),
                    NativeNVSTStatsPanel.Row(label: "Bandwidth Used", value: nativeStatsMegabits(model.latestNativeStats?.bitrateMegabitsPerSecond), detail: nativeStatsBandwidthDetail),
                    NativeNVSTStatsPanel.Row(label: "Jitter", value: nativeStatsMilliseconds(model.latestNativeStats?.jitterMilliseconds), detail: "ms"),
                ]),
                NativeNVSTStatsPanel.Group(label: "VIDEO", rows: [
                    NativeNVSTStatsPanel.Row(label: "Resolution", value: resolution),
                    NativeNVSTStatsPanel.Row(label: "Codec", value: codec, detail: nativeStatsDecoderDetail),
                    // Decoded surface -> drawable, so a 10-bit or HDR session can be confirmed
                    // from the HUD rather than from the diagnostic log.
                    NativeNVSTStatsPanel.Row(label: "Colour", value: nativeStatsColourValue, detail: nativeStatsColourDetail, color: nativeStatsColourColor),
                    NativeNVSTStatsPanel.Row(label: "Render", value: nativeStatsRenderValue, detail: nativeStatsRenderDetail),
                ]),
                NativeNVSTStatsPanel.Group(label: "TIMING", rows: [
                    // Client-side decode cost. It used to occupy the MS box, where it read as
                    // network latency and was not one.
                    NativeNVSTStatsPanel.Row(label: "Decode", value: nativeStatsDecodeValue, detail: nativeStatsDecodeDetail, color: nativeDecodeBudgetColor),
                    // Decode-to-glass, the latency a viewer feels from this side, and its jitter.
                    NativeNVSTStatsPanel.Row(label: "Present", value: nativeStatsPresentValue, detail: nativeStatsPresentDetail),
                ]),
                NativeNVSTStatsPanel.Group(label: "AUDIO", rows: [
                    // The channel layout the bundle actually decodes. Surround is the one setting
                    // whose outcome cannot be confirmed by looking at the stream, and the seat,
                    // not the client, has the last word on it.
                    NativeNVSTStatsPanel.Row(label: "Format", value: nativeStatsAudioValue, detail: nativeStatsAudioDetail, color: nativeStatsAudioColor),
                    // Video path (decode + present) against audio's jitter-buffer dwell: an
                    // estimate of which one reaches the viewer later, and by how much.
                    NativeNVSTStatsPanel.Row(label: "A/V", value: nativeStatsAVValue, detail: nativeStatsAVDetail),
                ]),
                NativeNVSTStatsPanel.Group(label: "SESSION", rows: [
                    NativeNVSTStatsPanel.Row(label: "Rig", value: nativeStatsRigName, detail: nativeStatsRigDetail),
                    NativeNVSTStatsPanel.Row(label: "Server Location", value: nonEmptyNativeStat(model.latestNativeStats?.serverLocation, fallback: "--")),
                ]),
            ]
        )
        .padding([.top, .trailing], OpenNOWDesign.Spacing.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    /// The headline number: the slowest 1% of recent frames, not the session mean — a mean under
    /// budget can still hitch on every motion spike, which is exactly what this is meant to catch.
    /// Falls back to the lifetime mean early in a session, before enough frames exist for a p99.
    var nativeStatsDecodeValue: String {
        guard let stats = model.latestNativeStats else { return "--" }
        return nativeStatsMilliseconds(NativeNVSTDecodeBudget.representativeDecodeMilliseconds(for: stats))
    }

    /// `ms of 8.3`: decode time against the negotiated frame interval. Over it and the seat is
    /// already lowering the frame rate to what this Mac reports it can decode. The mean rides
    /// along in parenthesis so the two readings can't be mistaken for each other.
    var nativeStatsDecodeDetail: String {
        guard let fps = model.latestNativeStats?.negotiatedFramesPerSecond,
              let interval = NativeNVSTDecodeBudget.frameIntervalMilliseconds(framesPerSecond: fps) else { return "ms" }
        guard let mean = model.latestNativeStats?.decodeMilliseconds, mean >= 0 else {
            return String(format: "ms of %.1f", interval)
        }
        return String(format: "ms of %.1f (mean %.1f)", interval, mean)
    }

    var nativeDecodeBudgetColor: Color {
        guard let stats = model.latestNativeStats else { return WebRTCMediaStreamTheme.textPrimary }
        switch NativeNVSTDecodeBudget.level(for: stats) {
        case .over: return WebRTCMediaStreamTheme.danger
        case .tight: return WebRTCMediaStreamTheme.warning
        case .comfortable, .unknown: return WebRTCMediaStreamTheme.textPrimary
        }
    }

    private var nativeStatsAudioValue: String {
        model.latestNativeStats?.audioFormatSummary ?? "-"
    }

    private var nativeStatsAudioDetail: String? {
        guard let stats = model.latestNativeStats, stats.audioChannelCount > 0 else { return nil }
        return "Opus"
    }

    /// Amber when the seat answered with fewer channels than the session asked for: the setting did
    /// not take, and nothing else on screen would say so.
    private var nativeStatsAudioColor: Color {
        guard let stats = model.latestNativeStats, stats.audioChannelCount > 0,
              stats.requestedAudioChannelCount > 0,
              stats.requestedAudioChannelCount != stats.audioChannelCount else {
            return WebRTCMediaStreamTheme.textPrimary
        }
        return WebRTCMediaStreamTheme.warning
    }

    /// Video lead/lag estimate: (decode + present) − audio jitter-buffer dwell. Positive means the
    /// picture arrives after the sound. Excludes the audio device's own output latency (~10–20 ms),
    /// which pulls the true figure toward video-leading; an estimate, labelled as one.
    var nativeStatsAVOffsetMilliseconds: Double? {
        guard let stats = model.latestNativeStats, stats.audioJitterBufferMilliseconds >= 0, stats.decodeMilliseconds >= 0,
              let render = model.latestRenderDiagnostics, render.presentLatencyMs >= 0 else { return nil }
        // Audio's path: jitter-buffer dwell, then the output device's latency and IO buffer. Video's:
        // decode, then present-to-glass. Both measured on this Mac; neither includes the seat.
        let audioPath = stats.audioJitterBufferMilliseconds + max(0, stats.audioOutputLatencyMilliseconds)
        return stats.decodeMilliseconds + render.presentLatencyMs - audioPath
    }

    var nativeStatsAVValue: String {
        guard let offset = nativeStatsAVOffsetMilliseconds else { return "--" }
        return String(format: "%@%.0f", offset >= 0 ? "+" : "", offset)
    }

    var nativeStatsAVDetail: String? {
        guard let stats = model.latestNativeStats, stats.audioJitterBufferMilliseconds >= 0 else { return "ms est." }
        let lead = nativeStatsAVOffsetMilliseconds.map { $0 >= 0 ? "video late" : "audio late" } ?? ""
        let device = stats.audioOutputLatencyMilliseconds >= 0 ? String(format: " + device %.0f", stats.audioOutputLatencyMilliseconds) : ""
        return String(format: "ms est. · audio buffer %.0f%@ ms%@", stats.audioJitterBufferMilliseconds, device, lead.isEmpty ? "" : " · " + lead)
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
        // What the seat says the game is outputting, from its 0x010e notification. Next to the
        // drawable so "game says HDR, drawable is SDR" is visible on one line.
        if !model.nativeHdrModeText.isEmpty { detail += " · game \(model.nativeHdrModeText)" }
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
