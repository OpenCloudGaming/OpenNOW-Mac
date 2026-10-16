import SwiftUI

/// The cloud-side DLSS override card under Settings -> Video.
///
/// It sits with the picture settings but is not one of them: DLSS runs on the cloud rig and is
/// requested when the next session is created, while everything above it describes what this Mac
/// does with the stream it receives. The card is full width and outside the generic Advanced
/// disclosure for the same reason - it is a separate feature, not a tuning knob of the profile.
struct CloudDlssOverridesCard: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    @State private var areModelPickersVisible = false

    private var state: DlssSettingsState { viewModel.dlssSettingsState }

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
            if state.showsSummary {
                SettingsDivider(uiScale: uiScale)
                SettingsInfoRow(label: DlssSettingsState.summaryHeading, value: state.summaryText, uiScale: uiScale)
            }
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10 * uiScale) {
            VStack(alignment: .leading, spacing: 5 * uiScale) {
                Text(state.statusText)
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.upsellFeatureLabels.isEmpty {
                    Text("Not included: \(state.upsellFeatureLabels.joined(separator: ", ")). A membership with these overrides unlocks them.")
                        .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if state.showsNextSessionOnlyNote {
                    Text(DlssSettingsState.nextSessionOnlyText)
                        .font(.settingsFont(size: 12 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.accentInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8 * uiScale)
            SettingsHelpIcon(title: DlssBetaScope.cardTitle, help: DlssSettingsState.betaHelpText, uiScale: uiScale)
        }
        .accessibilityElement(children: .combine)
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
            SettingsActionButton(title: DlssSettingsState.resetActionTitle, minimumWidth: 160 * uiScale, uiScale: uiScale) {
                viewModel.resetDlssOverrides()
            }
            .disabled(state.overrides.isUsingGameSettings)
        }
    }

    // MARK: - Features

    private var superResolutionSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            featureRow(
                title: "Super Resolution",
                help: "Sets the resolution the game renders at before DLSS upscales it. Custom renders at a share of the stream resolution you pick.",
                isIncluded: state.superResolutionEnabled
            ) {
                SettingsOptionRow(
                    title: "Super Resolution",
                    subtitle: "Renders at a share of the stream resolution and upscales with AI.",
                    options: DlssSuperResolutionMode.allCases.map(\.label),
                    selectedIndex: DlssSuperResolutionMode.allCases.firstIndex(of: state.overrides.superResolution) ?? 0,
                    enabled: DlssSuperResolutionMode.allCases.map { _ in state.superResolutionEnabled },
                    uiScale: uiScale
                ) { index in
                    viewModel.setDlssSuperResolutionMode(DlssSuperResolutionMode.allCases[index])
                }
            }
            if state.superResolutionEnabled, state.overrides.superResolution == .custom {
                SettingsSliderRow(
                    title: "Input Resolution",
                    valueText: "\(state.overrides.normalized().superResolutionScale)%",
                    value: Double(state.overrides.normalized().superResolutionScale),
                    range: Double(DlssOverrides.customScaleRange.lowerBound)...Double(DlssOverrides.customScaleRange.upperBound),
                    help: "Share of the stream resolution the game renders before upscaling.",
                    uiScale: uiScale
                ) { value in
                    viewModel.setDlssSuperResolutionScale(Int(value.rounded()))
                }
            }
        }
    }

    private var frameGenerationSection: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            featureRow(
                title: "Frame Generation",
                help: "Dynamic adds generated frames only when they are needed to reach your frame rate. The multiplier is how many the cloud rig may insert per rendered frame.",
                isIncluded: state.frameGenerationEnabled
            ) {
                SettingsOptionRow(
                    title: "Frame Generation",
                    subtitle: "Dynamic follows the frame rate you asked for; In-game leaves the choice to the game.",
                    options: DlssFrameGenerationMode.allCases.map(\.label),
                    selectedIndex: DlssFrameGenerationMode.allCases.firstIndex(of: state.overrides.frameGeneration) ?? 0,
                    enabled: [state.frameGenerationEnabled, state.dynamicFrameGenerationEnabled],
                    uiScale: uiScale
                ) { index in
                    viewModel.setDlssFrameGenerationMode(DlssFrameGenerationMode.allCases[index])
                }
            }
            if state.frameGenerationEnabled, state.overrides.frameGeneration == .dynamic {
                SettingsOptionRow(
                    title: "Frame Multiplier",
                    subtitle: "Generated frames per rendered frame, at most. Multipliers your membership does not include are unavailable.",
                    options: DlssOverrides.frameGenerationMultipliers.map { "Up to \($0)×" },
                    selectedIndex: DlssOverrides.frameGenerationMultipliers.firstIndex(of: state.overrides.normalized().frameGenerationMultiplier) ?? 0,
                    enabled: DlssOverrides.frameGenerationMultipliers.map { state.allowedMultipliers.contains($0) },
                    uiScale: uiScale
                ) { index in
                    viewModel.setDlssFrameGenerationMultiplier(DlssOverrides.frameGenerationMultipliers[index])
                }
            }
        }
    }

    private var rayReconstructionSection: some View {
        featureRow(
            title: "Ray Reconstruction",
            help: "Replaces the game's ray-traced denoisers. Only ray-traced games use it.",
            isIncluded: state.rayReconstructionEnabled
        ) {
            SettingsOptionRow(
                title: "Ray Reconstruction",
                subtitle: "Which DLSS model the cloud rig uses for ray reconstruction.",
                options: DlssModelPreset.options(DlssModelPreset.rayReconstructionModels).map(\.label),
                selectedIndex: DlssModelPreset.rayReconstructionModels.firstIndex(of: state.overrides.normalized().rayReconstructionModel) ?? 0,
                enabled: DlssModelPreset.rayReconstructionModels.map { _ in state.rayReconstructionEnabled },
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
                    title: areModelPickersVisible ? "HIDE" : "SHOW",
                    tone: .secondary,
                    minimumWidth: 84 * uiScale,
                    uiScale: uiScale
                ) {
                    areModelPickersVisible.toggle()
                }
                .disabled(!state.superResolutionEnabled && !state.frameGenerationEnabled && !state.rayReconstructionEnabled)
            }
            SettingsOptionRow(
                title: "Model Preset",
                subtitle: "Applies to every feature your membership includes.",
                options: DlssModelPreset.Choice.allCases.map(\.label),
                selectedIndex: DlssModelPreset.Choice.allCases.firstIndex(of: viewModel.dlssModelPreset) ?? 0,
                enabled: DlssModelPreset.Choice.allCases.map { _ in
                    state.superResolutionEnabled || state.frameGenerationEnabled || state.rayReconstructionEnabled
                },
                uiScale: uiScale
            ) { index in
                viewModel.setDlssModelPreset(DlssModelPreset.Choice.allCases[index])
            }
            if areModelPickersVisible, state.superResolutionEnabled {
                SettingsOptionRow(
                    title: "Super Resolution Model",
                    subtitle: "Presets A-F and J-M, or let NVIDIA pick per game.",
                    options: DlssModelPreset.options(DlssModelPreset.superResolutionModels).map(\.label),
                    selectedIndex: DlssModelPreset.superResolutionModels.firstIndex(of: state.overrides.normalized().superResolutionModel) ?? 0,
                    uiScale: uiScale
                ) { index in
                    viewModel.setDlssSuperResolutionModel(DlssModelPreset.superResolutionModels[index])
                }
            }
            if areModelPickersVisible, state.frameGenerationEnabled {
                SettingsOptionRow(
                    title: "Frame Generation Model",
                    subtitle: "Used when Frame Generation is Dynamic.",
                    options: DlssModelPreset.options(DlssModelPreset.frameGenerationModels).map(\.label),
                    selectedIndex: DlssModelPreset.frameGenerationModels.firstIndex(of: state.overrides.normalized().frameGenerationModel) ?? 0,
                    uiScale: uiScale
                ) { index in
                    viewModel.setDlssFrameGenerationModel(DlssModelPreset.frameGenerationModels[index])
                }
            }
        }
    }

    // MARK: - Rows

    /// A feature's heading plus its controls, and - when the membership does not include it - the
    /// reason right beside the control rather than only in the card's help.
    private func featureRow<Content: View>(
        title: String,
        help: String,
        isIncluded: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            HStack(alignment: .center, spacing: 8 * uiScale) {
                SettingsRowTitle(title: title, isNew: false, help: help, uiScale: uiScale)
                if !isIncluded {
                    Text(DlssSettingsState.missingAccessText)
                        .font(.settingsFont(size: 11 * uiScale, weight: .bold))
                        .foregroundStyle(OPNDesign.Text.muted)
                }
                Spacer(minLength: 0)
            }
            content()
        }
    }
}
