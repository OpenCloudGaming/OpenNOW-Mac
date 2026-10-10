import Combine
import Foundation
import SwiftUI

/// The unified HUD's NETWORK panel. Its own view so the one-second stats tick re-evaluates this
/// body, not the surface's.
struct NativeNVSTNetworkHUDPanel: View {
    let stats: NativeNVSTStreamStatsModel
    let isCollapsed: Bool
    let isFocused: Bool
    let onToggle: () -> Void

    var body: some View {
        StreamHUDSection(
            label: OPNStreamHUDSection.network.title,
            spacing: 8,
            isCollapsed: isCollapsed,
            isFocused: isFocused,
            reorderPayload: OPNStreamHUDSection.network.rawValue,
            onToggle: onToggle
        ) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                StreamHUDMetricCard(title: "Health", value: healthText, isPositive: isHealthGood)
                StreamHUDMetricCard(title: "Latency", value: latencyText, isPositive: (stats.latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                StreamHUDMetricCard(title: "Loss", value: packetLossText, isPositive: (stats.latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !warningText.isEmpty {
                Text(warningText)
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(StreamHUDTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var healthText: String {
        guard stats.latestNativeStats?.available == true else { return "Waiting" }
        if (stats.latestNativeStats?.packetLoss ?? 0) > 0 || (stats.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (stats.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (stats.latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (stats.latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    private var isHealthGood: Bool {
        healthText == "Good"
    }

    private var latencyText: String {
        guard stats.latestNativeStats?.available == true, let latency = stats.latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    private var packetLossText: String {
        guard stats.latestNativeStats?.available == true, let packetLoss = stats.latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    private var warningText: String {
        guard stats.latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (stats.latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (stats.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (stats.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        // Bitrate alone says nothing on NVST: the seat skips unchanged frames, so menus and pauses
        // read as a few hundred kilobits with the link perfectly healthy. The model raises this
        // only when low bitrate and a falling frame rate have persisted together.
        if let snapshot = stats.latestNativeStats, let decodeWarning = NativeNVSTDecodeBudget.warning(for: snapshot) { return decodeWarning }
        if stats.isNativeBitrateStarved { return "Inbound bitrate is low and frames are arriving late; the link may be starved." }
        if stats.latestNativeStats?.decoderIsHardware == false { return "Video is decoding in software; this colour format has no hardware decoder here." }
        return ""
    }
}

extension NativeNVSTMediaStreamSurface {
    var nativeHUDNetworkPanel: some View {
        NativeNVSTNetworkHUDPanel(
            stats: model.stats,
            isCollapsed: model.isHUDSectionCollapsed(.network),
            isFocused: model.isHUDSectionHeaderFocused(.network),
            onToggle: { model.toggleHUDSection(.network) }
        )
    }
}
