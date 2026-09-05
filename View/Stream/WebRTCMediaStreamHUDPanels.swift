//  The HUD's stats and video panels, the quit menu, and the formatting the numbers go through.
//  Split out of WebRTCMediaStreamHUD.swift.
//

import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

extension WebRTCMediaStreamSurface {
    var hudStatsPanel: some View {
        hudSection(label: "STATS") {
            VStack(alignment: .leading, spacing: 8) {
                statsRow("Transport", latestStats?.transport.isEmpty == false ? "WebRTC · \(latestStats?.transport ?? "")" : "WebRTC")
                statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
                statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
                statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
                statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
                statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
                statsRow("Decode", formatted(latestStats?.decodeTimeMs, suffix: " ms"))
                statsRow("Drops", String(latestStats?.framesDropped ?? 0))
                statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
                statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
                statsRow("Decoded", latestStats?.videoEnhancementSourceResolution.isEmpty == false ? latestStats?.videoEnhancementSourceResolution ?? "-" : "-")
            }
        }
    }

    var hudVideoPanel: some View {
        hudSection(label: "VIDEO") {
            VStack(alignment: .leading, spacing: 10) {
                StreamHUDSegmentedRow(
                    label: "Upscaling",
                    options: StreamRuntimeSettings.upscalingModes.map { ($0.value, $0.label) },
                    selection: runtimeSettings.upscalingMode,
                    isDisabled: !sidebarCapabilities.supports(.videoEnhancement) || !isStreamReady,
                    onSelect: { updateVideoEnhancement(mode: $0) }
                )
                if runtimeSettings.upscalingMode != 0 {
                    videoStepperRow("Clarity", value: runtimeSettings.upscalingSharpness, range: 0...15) { value in updateVideoEnhancement(sharpness: value) }
                    videoStepperRow("Noise Reduction", value: runtimeSettings.upscalingDenoise, range: 0...20) { value in updateVideoEnhancement(denoise: value) }
                }
                StreamHUDDropdown(
                    label: "Pillarbox Fill",
                    options: OPNPillarboxFillMode.pickerCases.map { ($0.rawValue, $0.label) },
                    selection: runtimeSettings.pillarboxFillMode,
                    isDisabled: !isStreamReady,
                    onSelect: { updateVideoEnhancement(pillarboxFillMode: $0) }
                )
                if OPNPillarboxFillMode.from(runtimeSettings.pillarboxFillMode).usesDim {
                    videoStepperRow("Fill Dim", value: runtimeSettings.pillarboxFillDim, range: 0...100, step: 5) { value in
                        updateVideoEnhancement(pillarboxFillDim: value)
                    }
                }
                settingsRow("Active", liveEnhancementValue(latestStats?.videoEnhancementActiveTier, fallback: runtimeSettings.upscalingMode == 0 ? "Native" : "Pending"))
                settingsRow("Target", runtimeSettings.upscalingMode == 0 ? "Native" : "Display")
                settingsRow("Frame", frameTimeValue(latestStats?.videoEnhancementFrameTimeMs))
                settingsRow("Dropped", String(latestStats?.videoEnhancementDroppedFrames ?? 0))
            }
        }
    }

    func hudMetricCard(title: String, value: String, positive: Bool) -> some View {
        StreamHUDMetricCard(title: title, value: value, positive: positive)
    }

    var launchOverlay: some View {
        StreamLaunchLoadingScreen(
            title: configuration.title,
            stage: StreamLaunchLoadingStage.label(stepIndex: loadingStepIndex),
            artworkURL: configuration.loadingArtworkURL
        ) { EmptyView() }
    }

    var quitMenu: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PAUSED")
                        .font(.streamNvidia(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WebRTCMediaStreamTheme.appBar)
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dismiss this overlay to resume input, pause the session, or quit the stream. Remote input is paused while this menu is open.")
                        .font(.streamNvidia(size: 12, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StreamQuitMenuButton(
                            title: "Resume",
                            isPrimary: true,
                            isFocused: quitMenuFocusIndex == 0,
                            isDisabled: isEndingStream,
                            action: dismissQuitMenu
                        )
                        .keyboardShortcut(.cancelAction)
                        StreamQuitMenuButton(
                            title: "Pause Stream",
                            isPrimary: false,
                            isFocused: quitMenuFocusIndex == 1,
                            isDisabled: isEndingStream,
                            action: pauseFromQuitMenu
                        )
                        StreamQuitMenuButton(
                            title: isEndingStream ? "Quitting..." : "Quit",
                            isPrimary: false,
                            isFocused: quitMenuFocusIndex == 2,
                            isDisabled: isEndingStream,
                            action: quitStreamFromMenu
                        )
                    }
                }
                .padding(18)
            }
            .frame(width: 440)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay {
                Rectangle()
                    .stroke(WebRTCMediaStreamTheme.accent.opacity(0.28), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
        }
    }
}
