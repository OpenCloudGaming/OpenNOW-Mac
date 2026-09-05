//  The in-stream HUD: the stats overlay, the unified dock and its panels, and the quit menu.
//

import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

extension WebRTCMediaStreamSurface {
    @ViewBuilder
    var hudChrome: some View {
        if !isStreamReady { launchOverlay }
        if isStreamReady && !quitMenuVisible { microphoneToggleOverlay }
        if statsVisible { statsHUD }
        if unifiedHUDVisible { unifiedHUD }
        if onScreenKeyboardVisible { StreamOnScreenKeyboardOverlay(controller: onScreenKeyboard) }
        if isStreamReady { sessionLimitCountdownOverlay }
        if !transientStreamMessage.isEmpty { transientStreamMessageOverlay }
        if quitMenuVisible { quitMenu }
    }

    var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                statsCompactBox(value: "--", label: "FPS", color: WebRTCMediaStreamTheme.textPrimary)
                statsVerticalDivider
                statsCompactBox(value: wholeNumber(latestStats?.renderFps), label: "FPS", color: fpsColor)
                statsVerticalDivider
                statsCompactBox(value: wholeNumber(latestStats?.latencyMs), label: "MS", color: latencyColor)
            }
            .frame(height: 48)

            statsHorizontalDivider

            VStack(alignment: .leading, spacing: 5) {
                statsStandardRow(label: "Frame Loss", value: String(latestStats?.framesDropped ?? 0), detail: "(0 Total)", color: frameLossColor)
                statsStandardRow(label: "Packet Loss", value: percentage(latestStats?.packetLossPercent), detail: packetLossTotalText, color: packetLossColor)
                statsStandardRow(label: "Bandwidth Used", value: megabits(latestStats?.inboundBitrateMbps), detail: "Mbps", color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Resolution", value: nonEmpty(latestStats?.resolution), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Codec", value: nonEmpty(latestStats?.codec), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Server Location", value: "--", detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 244, alignment: .topLeading)
        .background(Color.black.opacity(0.90))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WebRTCMediaStreamTheme.accent)
                .frame(height: 2)
        }
        .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 16, x: 0, y: 8)
        .padding(.top, 5)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    var unifiedHUD: some View {
        GeometryReader { proxy in
            let dockWidth = WebRTCMediaStreamTheme.dockWidth(for: proxy.size.width)
            VStack(alignment: .leading, spacing: 0) {
                hudDockHeader
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        hudStatusPanel
                        hudControllersPanel
                        hudControlsPanel
                        hudInputPanel
                        hudNetworkPanel
                        hudStatsPanel
                        // Behind the feature toggle, like every other Remote Co-Op surface. The
                        // value is read once on appear rather than from the store on every HUD
                        // frame, which is what the alpha check used to do.
                        if remoteCoOpEnabled { hudRemoteCoOpPanel }
                        hudVideoPanel
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                hudShortcutFooter
            }
            .frame(width: dockWidth, height: proxy.size.height, alignment: .topLeading)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(width: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
    }

    func statsCompactBox(value: String, label: String, color: Color) -> some View {
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

    var statsVerticalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    var statsHorizontalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 1)
    }

    func statsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
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

    var hudDockHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GFN")
                        .font(.streamNvidia(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text("HUD")
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: { setUnifiedHUDVisible(false) }) {
                    Image(systemName: "xmark")
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08))
                        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close stream HUD")
            }

            Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                .font(.streamNvidia(size: 13, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    var hudStatusPanel: some View {
        StreamHUDWrappingRow(minimumItemWidth: 84) {
            hudMetricCard(title: "Mic", value: microphoneStatusText, positive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled")
            hudMetricCard(title: "Rec", value: recordingStatusText, positive: recordingStatus.isRecording)
            hudMetricCard(title: "AFK", value: runtimeSettings.antiAFKMouseMovementEnabled ? "On" : "Off", positive: runtimeSettings.antiAFKMouseMovementEnabled)
            if sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    hudMetricCard(title: "Session", value: sessionLimitHUDText(at: context.date), positive: sessionLimitIsHealthy(at: context.date))
                }
            }
            if remoteCoOpEnabled {
                hudMetricCard(title: "Co-Op", value: "NVST Only", positive: false)
            }
        }
    }

    @ViewBuilder
    var hudControllersPanel: some View {
        if !controllerBatteries.isEmpty {
            StreamHUDSection(label: "CONTROLLERS", spacing: 6) {
                ForEach(controllerBatteries) { battery in
                    StreamHUDControllerRow(label: battery.label, name: battery.name, level: battery.level, charging: battery.charging)
                }
            }
        }
    }

    var sessionLimitCountdownOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let sessionLimit, sessionLimit.remainingSeconds(at: context.date) <= 30 {
                VStack(spacing: 16) {
                    Text("FREE SESSION ENDS IN")
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(sessionLimitCountdownText(at: context.date))
                        .font(.system(size: 74, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("Save progress now. GeForce NOW may close this session when the timer reaches zero.")
                        .font(.streamNvidia(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(WebRTCMediaStreamTheme.accent.opacity(0.42), lineWidth: 1))
                .shadow(color: .black.opacity(0.64), radius: 30, x: 0, y: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    var hudShortcutFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text(Date(), style: .time)
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Date(), style: .time))
            Text("⌘G HUD   ⌘M Mic   ⌘R Rec   ⌘K AFK   ⌘Q Quit")
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    var hudControlsPanel: some View {
        hudSection(label: "CONTROLS", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 42, fixedItemWidth: 42) {
                StreamHUDActionRow(
                    title: microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                    subtitle: microphoneStatusText,
                    systemName: microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled",
                    isDisabled: !sidebarCapabilities.supports(.microphone) || runtimeSettings.microphoneMode == "disabled",
                    isFocused: hudFocusID == "microphone",
                    action: toggleMicrophone
                )
                StreamHUDActionRow(
                    title: recordingCanStop ? "Stop Recording" : "Record",
                    subtitle: recordingStatusText,
                    systemName: "record.circle",
                    isActive: recordingStatus.isRecording,
                    isDisabled: !sidebarCapabilities.supports(.recording) || !isStreamReady || recordingIsBusy,
                    isFocused: hudFocusID == "recording",
                    action: toggleRecording
                )
                StreamHUDActionRow(
                    title: runtimeSettings.antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                    subtitle: runtimeSettings.antiAFKMouseMovementEnabled ? "Active" : "Idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: runtimeSettings.antiAFKMouseMovementEnabled,
                    isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isStreamReady,
                    isFocused: hudFocusID == "anti-afk",
                    action: toggleAntiAFKMouseMovement
                )
                StreamHUDActionRow(
                    title: statsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Detailed overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: statsVisible,
                    isDisabled: false,
                    action: toggleStatsHUD
                )
            }
        }
    }

    var hudInputPanel: some View {
        hudSection(label: "INPUT", spacing: 8) {
            HStack(spacing: 8) {
                StreamHUDActionRow(
                    title: "Paste Clipboard",
                    subtitle: "Send text to stream",
                    systemName: "doc.on.clipboard",
                    isActive: false,
                    isDisabled: !clipboardTextAvailable || !isStreamReady,
                    action: pasteClipboardIntoStream
                )
                StreamHUDActionRow(
                    title: pointerLocked ? "Release Mouse" : "Capture Mouse",
                    subtitle: pointerLocked ? "Pointer locked" : "Click stream also captures",
                    systemName: pointerLocked ? "cursorarrow.slash" : "cursorarrow.click",
                    isActive: pointerLocked,
                    isDisabled: !isStreamReady || !runtimeSettings.directMouseInput,
                    action: togglePointerLockFromHUD
                )
                StreamHUDActionRow(
                    title: "Toggle Full Screen",
                    subtitle: "Window full screen",
                    systemName: "arrow.up.left.and.arrow.down.right",
                    isActive: nativeView?.window?.styleMask.contains(.fullScreen) == true,
                    isDisabled: nativeView?.window == nil,
                    action: toggleFullScreenFromHUD
                )
                StreamHUDActionRow(
                    title: "Controller Mapping",
                    subtitle: "Steam Controller grip binds",
                    systemName: "gamecontroller",
                    isActive: false,
                    isDisabled: false,
                    isFocused: hudFocusID == "controller-mapping",
                    action: openControllerMapping
                )
                StreamHUDActionRow(
                    title: "Quit Menu",
                    subtitle: "End session",
                    systemName: "power",
                    isActive: false,
                    isDisabled: false,
                    isFocused: hudFocusID == "quit",
                    action: { showQuitMenu() }
                )
            }
            settingsRow("Mouse", pointerLocked ? "Captured" : (runtimeSettings.directMouseInput ? "Available" : "Relative input off"))
            settingsRow("Clipboard", clipboardTextAvailable ? "Ready" : "Empty")
        }
    }

    var hudNetworkPanel: some View {
        hudSection(label: "NETWORK", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                hudMetricCard(title: "Health", value: networkHealthText, positive: networkHealthIsGood)
                hudMetricCard(title: "Latency", value: formatted(latestStats?.latencyMs, suffix: " ms"), positive: (latestStats?.latencyMs ?? 0) < 90)
                hudMetricCard(title: "Loss", value: formatted(latestStats?.packetLossPercent, suffix: "%"), positive: (latestStats?.packetLossPercent ?? 0) < 1)
            }
            if !networkWarningText.isEmpty {
                Text(networkWarningText)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    /// Remote Co-Op is not offered on this transport.
    ///
    /// It was, and it did not work: the WebRTC path decodes into libwebrtc's own pipeline and has no
    /// frame tap comparable to the native decoder's, so guest video was assembled from re-rendered
    /// output. That cost a second decode and encode per frame on the host and delivered a stream
    /// guests described as sluggish. The native NVST path hands over the decoder's CVPixelBuffer
    /// directly, which is what makes the relay cheap enough to be worth having.
    ///
    /// Stated rather than hidden: a host who has enabled Remote Co-Op in Settings and finds no way to
    /// invite anyone needs to know it is the transport, not a missing setting.
    var hudRemoteCoOpPanel: some View {
        hudSection(label: "CO-OP", spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not available on this transport")
                    .font(.streamNvidia(size: 14, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                Text("Remote Co-Op needs the Native NVST transport, which is where the host can share decoded frames without paying for them twice. Switch in Settings > Streaming and relaunch.")
                    .font(.streamNvidia(size: 12, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func hudSection<Content: View>(label: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) -> some View {
        StreamHUDSection(label: label, spacing: spacing, content: content)
    }

    var microphoneToggleOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                microphoneToggleButton
            }
        }
        .padding(.trailing, 24)
        .padding(.bottom, 24)
    }

    var microphoneToggleButton: some View {
        Button(action: toggleMicrophone) {
            Image(systemName: microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(microphoneEnabled ? .black.opacity(0.72) : .white.opacity(0.58))
                .frame(width: 28, height: 28)
                .background(microphoneEnabled ? WebRTCMediaStreamTheme.accent.opacity(0.42) : .black.opacity(0.26), in: Circle())
                .overlay(Circle().stroke(.white.opacity(runtimeSettings.microphoneMode == "disabled" ? 0.05 : 0.11), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(runtimeSettings.microphoneMode == "disabled")
        .opacity(runtimeSettings.microphoneMode == "disabled" ? 0.24 : 0.58)
        .accessibilityLabel(microphoneEnabled ? "Mute microphone" : "Unmute microphone")
    }

    var transientStreamMessageOverlay: some View {
        Text(transientStreamMessage)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay(Capsule().stroke(WebRTCMediaStreamTheme.accent.opacity(0.36), lineWidth: 1))
            .shadow(color: .black.opacity(0.36), radius: 18, x: 0, y: 8)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

}
