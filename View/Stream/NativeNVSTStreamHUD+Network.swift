import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeNetworkHealthText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting" }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 || (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    var nativeNetworkHealthIsGood: Bool {
        nativeNetworkHealthText == "Good"
    }

    var nativeLatencyText: String {
        guard model.latestNativeStats?.available == true, let latency = model.latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    var nativePacketLossText: String {
        guard model.latestNativeStats?.available == true, let packetLoss = model.latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    var nativeNetworkWarningText: String {
        guard model.latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (model.latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (model.latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (model.latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        // Bitrate alone says nothing on NVST: the seat skips unchanged frames, so menus and pauses
        // read as a few hundred kilobits with the link perfectly healthy. The model raises this
        // only when low bitrate and a falling frame rate have persisted together.
        if let stats = model.latestNativeStats, let decodeWarning = NativeNVSTDecodeBudget.warning(for: stats) { return decodeWarning }
        if model.nativeBitrateStarved { return "Inbound bitrate is low and frames are arriving late; the link may be starved." }
        if model.latestNativeStats?.decoderIsHardware == false { return "Video is decoding in software; this colour format has no hardware decoder here." }
        return ""
    }

    var nativeHUDNetworkPanel: some View {
        StreamHUDSection(label: "NETWORK", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                StreamHUDMetricCard(title: "Health", value: nativeNetworkHealthText, isPositive: nativeNetworkHealthIsGood)
                StreamHUDMetricCard(title: "Latency", value: nativeLatencyText, isPositive: (model.latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                StreamHUDMetricCard(title: "Loss", value: nativePacketLossText, isPositive: (model.latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !nativeNetworkWarningText.isEmpty {
                Text(nativeNetworkWarningText)
                    .font(.streamFont(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }
}
