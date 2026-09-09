//  The native NVST surface's own HUD: the unified sidebar dock and its top-level status row.
//

import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeUnifiedHUD: some View {
        StreamUnifiedSidebar(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, closeAction: { model.setUnifiedHUDVisible(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                nativeHUDStatusPanel
                nativeHUDControlsPanel
                nativeHUDInputPanel
                nativeHUDControllersPanel
                nativeHUDNetworkPanel
                if model.sidebarCapabilities.visibleFeatures.contains(.remoteCoOp), model.remoteCoOpPreferences.isEnabled {
                    nativeHUDRemoteCoOpPanel
                }
                nativeHUDVideoPanel
            }
        }
    }

    var nativeHUDStatusPanel: some View {
        StreamHUDWrappingRow(minimumItemWidth: 84) {
            StreamHUDMetricCard(title: "Mic", value: nativeMicrophoneStatusText, isPositive: model.microphoneEnabled && model.microphoneAvailable)
            StreamHUDMetricCard(title: "Rec", value: model.recordingStatusText, isPositive: model.recordingCanStop)
            StreamHUDMetricCard(title: "AFK", value: model.antiAFKMouseMovementEnabled ? "On" : "Off", isPositive: model.antiAFKMouseMovementEnabled)
            if model.sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StreamHUDMetricCard(title: "Session", value: nativeSessionLimitText(at: context.date), isPositive: nativeSessionLimitIsHealthy(at: context.date))
                }
            }
            if model.remoteCoOpPreferences.isEnabled {
                StreamHUDMetricCard(title: "Co-Op", value: model.remoteCoOpSummaryText, isPositive: model.remoteCoOpSnapshot.connectedParticipantCount > 0)
            }
        }
    }

    /// Shared `label: value` row used by the Co-Op and Stream Info panels.
    func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamFont(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamFont(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
