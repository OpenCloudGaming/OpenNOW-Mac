//
//  SettingsSystemViews.swift
//  MacForceNow
//

import AppKit
import CryptoKit
import SwiftUI

struct SystemSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Readiness", uiScale: uiScale) {
                HStack(alignment: .top, spacing: 18 * uiScale) {
                    VStack(alignment: .leading, spacing: 10 * uiScale) {
                        Text(systemSummaryTitle)
                            .font(.settingsNvidia(size: 22 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text(systemSummaryDetail)
                            .font(.settingsNvidia(size: 13 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8 * uiScale) {
                            AboutStatusPill(title: "Display", value: displaySummary, uiScale: uiScale)
                            AboutStatusPill(title: "Decode", value: preferredDecoder, uiScale: uiScale)
                            AboutStatusPill(title: "Route", value: route.summary, uiScale: uiScale)
                        }
                    }
                    Spacer(minLength: 0)
                    SystemHealthBadge(title: systemHealthTitle, subtitle: systemHealthSubtitle, positive: systemHealthPositive, uiScale: uiScale)
                }
            }

            SettingsCard(title: "Display", uiScale: uiScale) {
                SettingsFlowLayout(spacing: 10 * uiScale) {
                    SettingsStatisticTile(label: "Resolution", value: displaySummary, emphasized: true, uiScale: uiScale)
                    SettingsStatisticTile(label: "Refresh", value: refreshRateText, uiScale: uiScale)
                    SettingsStatisticTile(label: "DPI", value: dpiText, uiScale: uiScale)
                    SettingsStatisticTile(label: "HDR", value: viewModel.streamCapabilities.hdrDisplaySupported ? "Ready" : "Unavailable", uiScale: uiScale)
                }
            }

            SettingsCard(title: "Video Decode", uiScale: uiScale) {
                VStack(spacing: 10 * uiScale) {
                    SystemCapabilityRow(title: "H.264", subtitle: "Baseline stream compatibility", value: viewModel.streamCapabilities.h264HardwareDecodeSupported ? "Hardware" : "Software", positive: viewModel.streamCapabilities.h264HardwareDecodeSupported, uiScale: uiScale)
                    SystemCapabilityRow(title: "HEVC", subtitle: "Efficient high-quality streaming", value: viewModel.streamCapabilities.h265HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.h265HardwareDecodeSupported, uiScale: uiScale)
                    SystemCapabilityRow(title: "AV1", subtitle: "Next-generation low-bitrate streaming", value: viewModel.streamCapabilities.av1HardwareDecodeSupported ? "Supported" : "Unavailable", positive: viewModel.streamCapabilities.av1HardwareDecodeSupported, uiScale: uiScale)
                }
            }

            SettingsCard(title: "Device & Route", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 12 * uiScale) {
                    VStack(alignment: .leading, spacing: 4 * uiScale) {
                        Text("Identifiers and endpoint paths are masked by default.")
                            .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Reveal only when collecting support information locally.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    SettingsRevealButton(revealed: revealSensitive, uiScale: uiScale) { revealSensitive.toggle() }
                }
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Device ID", value: displayedDeviceId, copyValue: viewModel.session.deviceId, copiedKey: $copiedKey, copyDisabled: viewModel.session.deviceId.isEmpty, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                AboutDetailRow(label: "Current Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey, uiScale: uiScale)
            }
        }
    }

    private var displaySummary: String {
        guard viewModel.streamCapabilities.maxDisplayWidth > 0, viewModel.streamCapabilities.maxDisplayHeight > 0 else { return "Unknown" }
        return "\(viewModel.streamCapabilities.maxDisplayWidth) x \(viewModel.streamCapabilities.maxDisplayHeight)"
    }

    private var refreshRateText: String {
        viewModel.streamCapabilities.maxDisplayRefreshRate > 0 ? "\(viewModel.streamCapabilities.maxDisplayRefreshRate) Hz" : "Unknown"
    }

    private var dpiText: String {
        viewModel.streamCapabilities.displayDpi > 0 ? "\(viewModel.streamCapabilities.displayDpi)" : "Unknown"
    }

    private var preferredDecoder: String {
        if viewModel.streamCapabilities.av1HardwareDecodeSupported { return "AV1" }
        if viewModel.streamCapabilities.h265HardwareDecodeSupported { return "HEVC" }
        if viewModel.streamCapabilities.h264HardwareDecodeSupported { return "H.264" }
        return "Software"
    }

    private var hardwareDecodeCount: Int {
        [viewModel.streamCapabilities.h264HardwareDecodeSupported, viewModel.streamCapabilities.h265HardwareDecodeSupported, viewModel.streamCapabilities.av1HardwareDecodeSupported].filter { $0 }.count
    }

    private var systemHealthPositive: Bool {
        viewModel.streamCapabilities.h264HardwareDecodeSupported && displaySummary != "Unknown"
    }

    private var systemHealthTitle: String {
        systemHealthPositive ? "READY" : "LIMITED"
    }

    private var systemHealthSubtitle: String {
        systemHealthPositive ? "Hardware path available" : "Review decoder support"
    }

    private var systemSummaryTitle: String {
        systemHealthPositive ? "Streaming hardware looks ready" : "Streaming support is partially available"
    }

    private var systemSummaryDetail: String {
        "Detected \(displaySummary) at \(refreshRateText), \(hardwareDecodeCount) hardware decoder\(hardwareDecodeCount == 1 ? "" : "s"), and \(viewModel.streamCapabilities.hdrDisplaySupported ? "HDR-capable" : "SDR") presentation."
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: revealSensitive)
    }

    private var displayedDeviceId: String {
        revealSensitive ? viewModel.session.deviceId : SettingsFormat.maskedIdentifier(viewModel.session.deviceId)
    }
}

struct SystemHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * uiScale) {
            Text(title)
                .font(.settingsNvidia(size: 12 * uiScale, weight: .bold))
                .foregroundStyle(positive ? .black : .white.opacity(0.88))
                .tracking(1.1)
            Text(subtitle)
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(positive ? .black.opacity(0.74) : .white.opacity(0.54))
                .lineLimit(2)
        }
        .padding(.horizontal, 14 * uiScale)
        .frame(width: 172 * uiScale, height: 64 * uiScale, alignment: .leading)
        .background(positive ? Color.openNowGreen : Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(positive ? Color.openNowGreen : Color.white.opacity(0.13), lineWidth: 1) }
    }
}

struct SystemCapabilityRow: View {
    let title: String
    let subtitle: String
    let value: String
    let positive: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 12 * uiScale) {
            Rectangle()
                .fill(positive ? Color.openNowGreen : Color.white.opacity(0.22))
                .frame(width: 4 * uiScale, height: 42 * uiScale)
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text(title)
                    .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 0)
            Text(value.uppercased())
                .font(.settingsNvidia(size: 11 * uiScale, weight: .bold))
                .foregroundStyle(positive ? Color.openNowGreen : .white.opacity(0.56))
                .tracking(0.8)
                .padding(.horizontal, 10 * uiScale)
                .frame(height: 28 * uiScale)
                .background(Color.white.opacity(positive ? 0.07 : 0.04))
                .overlay { Rectangle().stroke(positive ? Color.openNowGreen.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .padding(12 * uiScale)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}
