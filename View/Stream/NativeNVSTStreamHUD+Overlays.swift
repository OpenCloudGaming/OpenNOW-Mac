import Combine
import Foundation
import SwiftUI

extension NativeNVSTMediaStreamSurface {
    var nativeNetworkRecoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(WebRTCMediaStreamTheme.accent)
                Text("CONNECTION INTERRUPTED")
                    .font(.streamFont(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text("Waiting for a usable network path. OpenNOW will resume the same GeForce NOW session automatically.")
                    .font(.streamFont(size: 12, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("End Stream", action: model.endFromStreamControls)
                    .buttonStyle(.bordered)
            }
            .padding(30)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.96))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.4), lineWidth: 1))
        }
    }

    var nativeTransientStreamMessageOverlay: some View {
        Text(model.transientStreamMessage)
            .font(.streamFont(size: 12, weight: .bold))
            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.86))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
            .allowsHitTesting(false)
    }

    var nativeStreamControlsOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PAUSED")
                        .font(.streamFont(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.streamFont(size: 20, weight: .bold))
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
                        .font(.streamFont(size: 12, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StreamQuitMenuButton(
                            title: "Resume",
                            isPrimary: true,
                            isFocused: model.streamControlsFocusIndex == 0,
                            isDisabled: model.isEnding,
                            action: model.dismissStreamControls
                        )
                        .keyboardShortcut(.cancelAction)
                        StreamQuitMenuButton(
                            title: "Pause Stream",
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 1,
                            isDisabled: model.isEnding,
                            action: model.pauseFromStreamControls
                        )
                        StreamQuitMenuButton(
                            title: model.isEnding ? "Quitting..." : (model.pendingApplicationQuitCompletion == nil ? "End Stream" : "Quit OpenNOW"),
                            isPrimary: false,
                            isFocused: model.streamControlsFocusIndex == 2,
                            isDisabled: model.isEnding,
                            action: model.endFromStreamControls
                        )
                    }
                    Text("\(WebRTCMediaStreamCommand.shortcutGuide)   Esc Resume")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
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
