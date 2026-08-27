//
//  SettingsStreamingViews.swift
//  OpenNOW
//

import AppKit
import CryptoKit
import SwiftUI

struct ServerLocationSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    private let regionColumns = [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 10)]

    var body: some View {
        let selectedOption = viewModel.settingsRegionOptions.first { $0.url == viewModel.selectedSettingsRegionUrl }
        SettingsCard(title: "Server Location", uiScale: uiScale) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5 * uiScale) {
                    Text("Cloudmatch Region")
                        .font(.settingsNvidia(size: 15 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Automatic chooses the best measured OpenNOW route.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 12 * uiScale)
                SettingsStatusPill(title: "ACTIVE", value: selectedRegionTitle(selectedOption), positive: true, uiScale: uiScale)
                SettingsActionButton(title: viewModel.isRefreshingSettingsRegions ? "PINGING" : "REFRESH", minimumWidth: 104 * uiScale, uiScale: uiScale) { viewModel.refreshSettingsRegions() }
                    .disabled(viewModel.isRefreshingSettingsRegions)
            }
            SettingsDivider(uiScale: uiScale)
            if !viewModel.unavailableSettingsRegionUrl.isEmpty {
                UnavailableRegionPrompt(regionUrl: viewModel.unavailableSettingsRegionUrl, keepAction: viewModel.keepUnavailableSettingsRegion, automaticAction: viewModel.switchUnavailableSettingsRegionToAutomatic, uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
            }
            LazyVGrid(columns: regionColumns, alignment: .leading, spacing: 10 * uiScale) {
                ForEach(viewModel.settingsRegionOptions, id: \.url) { option in
                    SettingsRegionRow(option: option, selected: option.url == viewModel.selectedSettingsRegionUrl, uiScale: uiScale) {
                        viewModel.selectSettingsRegion(option.url)
                    }
                }
            }
        }
    }

    private func selectedRegionTitle(_ option: OPNStreamRegionOption?) -> String {
        guard let option else { return "Automatic" }
        return SettingsRegionName.shortName(for: option)
    }
}

struct UnavailableRegionPrompt: View {
    let regionUrl: String
    let keepAction: () -> Void
    let automaticAction: () -> Void
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * uiScale) {
            HStack(alignment: .top, spacing: 10 * uiScale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.nvidiaSans(size: 15 * uiScale, weight: .bold))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text("Selected Region Unavailable")
                        .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("CloudMatch no longer advertises the selected route. Keep it for one more launch attempt, or switch to Automatic.")
                        .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(regionUrl)
                        .font(.system(size: 11 * uiScale, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12 * uiScale)
            }
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "KEEP", tone: .secondary, minimumWidth: 82 * uiScale, uiScale: uiScale, action: keepAction)
                SettingsActionButton(title: "AUTOMATIC", minimumWidth: 112 * uiScale, uiScale: uiScale, action: automaticAction)
            }
        }
        .padding(14 * uiScale)
        .background(Color.orange.opacity(0.08))
        .overlay { Rectangle().stroke(Color.orange.opacity(0.22), lineWidth: 1) }
    }
}

struct ResolutionUpscalingSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "MetalFX Upscaling", uiScale: uiScale) {
                SettingsToggleRow(title: "MetalFX Upscaling", subtitle: "Optimized for Apple Silicon. Falls back automatically when MetalFX is unavailable.", isOn: viewModel.streamProfile.upscalingMode == 3, uiScale: uiScale) { enabled in viewModel.setUpscalingModeIndex(enabled ? 1 : 0) }
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: "Target", value: "Display", uiScale: uiScale)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Clarity", valueText: "\(viewModel.streamProfile.upscalingSharpness)", value: Double(viewModel.streamProfile.upscalingSharpness), range: 0...15, uiScale: uiScale, action: viewModel.setUpscalingSharpness)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Noise Reduction", valueText: "\(viewModel.streamProfile.upscalingDenoise)", value: Double(viewModel.streamProfile.upscalingDenoise), range: 0...20, uiScale: uiScale, action: viewModel.setUpscalingDenoise)
            }

            SettingsCard(title: "Pillarbox", uiScale: uiScale) {
                SettingsOptionRow(title: "Pillarbox Fill", subtitle: "Repaints the black bars GeForce NOW bakes into 16:9-only titles on wider displays.", options: OPNPillarboxFillMode.pickerCases.map(\.label), selectedIndex: OPNPillarboxFillMode.pickerCases.firstIndex(of: viewModel.streamProfile.pillarboxFillMode) ?? 0, uiScale: uiScale, action: { index in viewModel.setPillarboxFillModeIndex(OPNPillarboxFillMode.pickerCases[index].rawValue) })
                if viewModel.streamProfile.pillarboxFillMode.usesDim {
                    SettingsDivider(uiScale: uiScale)
                    SettingsSliderRow(title: "Edge Dimming", valueText: "\(viewModel.streamProfile.pillarboxFillDim)%", value: Double(viewModel.streamProfile.pillarboxFillDim), range: 0...100, uiScale: uiScale, action: viewModel.setPillarboxFillDim)
                }
            }

            SettingsCard(title: "Image Enhancement", uiScale: uiScale) {
                SettingsOptionRow(title: "Prefilter Mode", subtitle: "Applies GFN-style prefiltering before presentation.", options: OPNStreamPreferences.prefilterModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.prefilterModeIndex, uiScale: uiScale, action: viewModel.setPrefilterModeIndex)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Prefilter Sharpness", valueText: "\(viewModel.streamProfile.prefilterSharpness)", value: Double(viewModel.streamProfile.prefilterSharpness), range: 0...10, uiScale: uiScale, action: viewModel.setPrefilterSharpness)
                SettingsDivider(uiScale: uiScale)
                SettingsSliderRow(title: "Prefilter Denoise", valueText: "\(viewModel.streamProfile.prefilterDenoise)", value: Double(viewModel.streamProfile.prefilterDenoise), range: 0...10, uiScale: uiScale, action: viewModel.setPrefilterDenoise)
            }
        }
    }
}
