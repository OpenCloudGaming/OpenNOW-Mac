import SwiftUI

/// The cloud-side DLSS override card under Settings -> Video. DLSS runs on the cloud rig, so it sits
/// with the picture settings but is not one of them, and it stays outside the Advanced disclosure.
struct CloudDlssOverridesCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    @State private var isModelPickersVisible = false

    private var settingsState: DlssSettingsState { viewModel.dlssSettingsState }

    var body: some View {
        SettingsCard(
            title: DlssBetaScope.cardTitle,
            badge: .beta,
            headingAccessibilityLabel: DlssBetaScope.cardHeadingAccessibilityLabel,
            uiScale: uiScale
        ) {
            statusRow
            SettingsDivider(uiScale: uiScale)
            resetRow
            SettingsDivider(uiScale: uiScale)
            superResolutionSection
            SettingsDivider(uiScale: uiScale)
            frameGenerationSection
            SettingsDivider(uiScale: uiScale)
            rayReconstructionSection
            SettingsDivider(uiScale: uiScale)
            advancedModelsSection
            if settingsState.isSummaryVisible {
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: DlssAccessCopy.summaryHeading, value: settingsState.summaryText, uiScale: uiScale)
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                statusLine
                if !settingsState.upsellFeatureLabels.isEmpty {
                    Text(DlssAccessCopy.notIncludedList(settingsState.upsellFeatureLabels))
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settingsState.isNextSessionOnlyNoteVisible {
                    Text(DlssAccessCopy.nextSessionOnly)
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8 * uiScale)
            SettingsHelpIcon(title: DlssBetaScope.cardTitle, help: DlssAccessCopy.betaHelp, uiScale: uiScale)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: some View {
        Text(settingsState.statusText)
            .font(.settingsFont(size: 12 * uiScale, weight: .medium))
            .foregroundStyle(OPNDesign.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var resetRow: some View {
        HStack(alignment: .center, spacing: 16 * uiScale) {
            SettingsRowTitle(
                title: "Reset",
                isNew: false,
                help: "Returns every DLSS override to the game's own setting. The next session asks for nothing.",
                uiScale: uiScale
            )
            Spacer(minLength: 12 * uiScale)
            SettingsActionButton(title: DlssAccessCopy.resetAction, minimumWidth: 160 * uiScale, uiScale: uiScale) {
                viewModel.resetDlssOverrides()
            }
            .disabled(settingsState.overrides.isUsingGameSettings)
        }
    }

    // MARK: - Features

    private var superResolutionSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            featureHeading(
                title: "Super Resolution",
                help: "Sets the resolution the game renders at before DLSS upscales it. Custom renders at a share of the stream resolution you pick.",
                isIncluded: settingsState.isSuperResolutionEnabled
            )
            SettingsOptionRow(
                title: "Super Resolution",
                subtitle: "Renders at a share of the stream resolution and upscales with AI.",
                options: DlssSuperResolutionMode.allCases.map(\.label),
                selectedIndex: DlssSuperResolutionMode.allCases.firstIndex(of: settingsState.overrides.superResolution) ?? 0,
                enabled: DlssSuperResolutionMode.allCases.map { _ in settingsState.isSuperResolutionEnabled },
                uiScale: uiScale
            ) { index in
                viewModel.setDlssSuperResolutionMode(DlssSuperResolutionMode.allCases[index])
            }
            if isCustomSuperResolutionScaleVisible {
                customScaleSlider
            }
        }
    }

    private var isCustomSuperResolutionScaleVisible: Bool {
        settingsState.isSuperResolutionEnabled && settingsState.overrides.superResolution == .custom
    }

    private var customScaleSlider: some View {
        let range = DlssOverrides.customScaleRange
        return SettingsSliderRow(
            title: "Input Resolution",
            valueText: "\(settingsState.overrides.normalized().superResolutionScale)%",
            value: Double(settingsState.overrides.normalized().superResolutionScale),
            range: Double(range.lowerBound)...Double(range.upperBound),
            help: "Share of the stream resolution the game renders before upscaling.",
            uiScale: uiScale
        ) { value in
            viewModel.setDlssSuperResolutionScale(Int(value.rounded()))
        }
    }

    private var frameGenerationSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            featureHeading(
                title: "Frame Generation",
                help: "Dynamic adds generated frames only when they are needed to reach your frame rate. The multiplier is how many the cloud rig may insert per rendered frame.",
                isIncluded: settingsState.isFrameGenerationEnabled
            )
            SettingsOptionRow(
                title: "Frame Generation",
                subtitle: "Dynamic follows the frame rate you asked for; In-game leaves the choice to the game.",
                options: DlssFrameGenerationMode.allCases.map(\.label),
                selectedIndex: DlssFrameGenerationMode.allCases.firstIndex(of: settingsState.overrides.frameGeneration) ?? 0,
                enabled: [settingsState.isFrameGenerationEnabled, settingsState.isDynamicFrameGenerationEnabled],
                uiScale: uiScale
            ) { index in
                viewModel.setDlssFrameGenerationMode(DlssFrameGenerationMode.allCases[index])
            }
            if isFrameMultiplierVisible {
                frameMultiplierRow
            }
        }
    }

    private var isFrameMultiplierVisible: Bool {
        settingsState.isFrameGenerationEnabled && settingsState.overrides.frameGeneration == .dynamic
    }

    private var frameMultiplierRow: some View {
        SettingsOptionRow(
            title: "Frame Multiplier",
            subtitle: "Generated frames per rendered frame, at most. Multipliers your membership does not include are unavailable.",
            options: DlssOverrides.frameGenerationMultipliers.map { "Up to \($0)×" },
            selectedIndex: DlssOverrides.frameGenerationMultipliers.firstIndex(of: settingsState.overrides.normalized().frameGenerationMultiplier) ?? 0,
            enabled: DlssOverrides.frameGenerationMultipliers.map { settingsState.allowedMultipliers.contains($0) },
            uiScale: uiScale
        ) { index in
            viewModel.setDlssFrameGenerationMultiplier(DlssOverrides.frameGenerationMultipliers[index])
        }
    }

    private var rayReconstructionSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            featureHeading(
                title: "Ray Reconstruction",
                help: "Replaces the game's ray-traced denoisers. Only ray-traced games use it.",
                isIncluded: settingsState.isRayReconstructionEnabled
            )
            SettingsOptionRow(
                title: "Ray Reconstruction",
                subtitle: "Which DLSS model the cloud rig uses for ray reconstruction.",
                options: DlssModelPreset.labels(for: DlssModelPreset.rayReconstructionModels),
                selectedIndex: DlssModelPreset.rayReconstructionModels.firstIndex(of: settingsState.overrides.normalized().rayReconstructionModel) ?? 0,
                enabled: DlssModelPreset.rayReconstructionModels.map { _ in settingsState.isRayReconstructionEnabled },
                uiScale: uiScale
            ) { index in
                viewModel.setDlssRayReconstructionModel(DlssModelPreset.rayReconstructionModels[index])
            }
        }
    }

    private var advancedModelsSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            HStack(alignment: .center, spacing: 16 * uiScale) {
                SettingsRowTitle(
                    title: "Advanced models",
                    isNew: false,
                    help: "NVIDIA's model presets. Recommended lets NVIDIA pick the model per game; Custom exposes one picker per feature.",
                    uiScale: uiScale
                )
                Spacer(minLength: 12 * uiScale)
                SettingsActionButton(
                    title: isModelPickersVisible ? "HIDE" : "SHOW",
                    tone: .secondary,
                    minimumWidth: 84 * uiScale,
                    uiScale: uiScale
                ) {
                    isModelPickersVisible.toggle()
                }
                .disabled(!isAnyModelPickerAvailable)
            }
            modelPresetRow
            if isModelPickersVisible, settingsState.isSuperResolutionEnabled {
                superResolutionModelRow
            }
            if isModelPickersVisible, settingsState.isFrameGenerationEnabled {
                frameGenerationModelRow
            }
        }
    }

    private var isAnyModelPickerAvailable: Bool {
        settingsState.isSuperResolutionEnabled || settingsState.isFrameGenerationEnabled || settingsState.isRayReconstructionEnabled
    }

    private var modelPresetRow: some View {
        SettingsOptionRow(
            title: "Model Preset",
            subtitle: "Applies to every feature your membership includes.",
            options: DlssModelPreset.Choice.allCases.map(\.label),
            selectedIndex: DlssModelPreset.Choice.allCases.firstIndex(of: viewModel.dlssModelPreset) ?? 0,
            enabled: DlssModelPreset.Choice.allCases.map { _ in isAnyModelPickerAvailable },
            uiScale: uiScale
        ) { index in
            viewModel.setDlssModelPreset(DlssModelPreset.Choice.allCases[index])
        }
    }

    private var superResolutionModelRow: some View {
        SettingsOptionRow(
            title: "Super Resolution Model",
            subtitle: "Presets A-F and J-M, or let NVIDIA pick per game.",
            options: DlssModelPreset.labels(for: DlssModelPreset.superResolutionModels),
            selectedIndex: DlssModelPreset.superResolutionModels.firstIndex(of: settingsState.overrides.normalized().superResolutionModel) ?? 0,
            uiScale: uiScale
        ) { index in
            viewModel.setDlssSuperResolutionModel(DlssModelPreset.superResolutionModels[index])
        }
    }

    private var frameGenerationModelRow: some View {
        SettingsOptionRow(
            title: "Frame Generation Model",
            subtitle: "Used when Frame Generation is Dynamic.",
            options: DlssModelPreset.labels(for: DlssModelPreset.frameGenerationModels),
            selectedIndex: DlssModelPreset.frameGenerationModels.firstIndex(of: settingsState.overrides.normalized().frameGenerationModel) ?? 0,
            uiScale: uiScale
        ) { index in
            viewModel.setDlssFrameGenerationModel(DlssModelPreset.frameGenerationModels[index])
        }
    }

    /// A feature's heading, with the reason beside it when the membership does not include it.
    private func featureHeading(title: String, help: String, isIncluded: Bool) -> some View {
        HStack(alignment: .center, spacing: 8 * uiScale) {
            SettingsRowTitle(title: title, isNew: false, help: help, uiScale: uiScale)
            if !isIncluded {
                Text(DlssAccessCopy.missing)
                    .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
            Spacer(minLength: 0)
        }
    }
}
