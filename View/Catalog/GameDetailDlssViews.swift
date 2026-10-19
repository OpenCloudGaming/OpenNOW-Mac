//  DLSS compatibility on the full game info page: what NVIDIA's own list says about this game, kept
//  strictly apart from what the membership includes and from what any override actually does.

import AppKit
import SwiftUI

struct DlssCompatibilitySection: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var isSystemReduceMotionEnabled
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isReduceMotionPreferenceEnabled = false

    private var isMotionReduced: Bool {
        OPNDesign.Motion.isMotionReduced(system: isSystemReduceMotionEnabled, preference: isReduceMotionPreferenceEnabled)
    }

    private var presentation: DlssCompatibilityPresentation { viewModel.dlssCompatibility }
    private var membership: DlssMembershipState { viewModel.dlssMembershipState }

    var body: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.medium(scale: uiScale)) {
            heading
            statusRow
            featureTable
            if presentation.gameSupport != nil {
                accessBlock
            }
            freshnessFooter
            sourceFooter
            configureAction
        }
    }

    // MARK: - Heading

    private var heading: some View {
        HStack(spacing: 8 * uiScale) {
            Text(DlssBetaScope.sectionTitle.uppercased())
                .catalogFont(size: 11, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(OPNDesign.Text.tertiary)
            OPNBetaTag(uiScale: uiScale * 0.85, compact: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DlssBetaScope.sectionHeadingAccessibilityLabel)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        if !presentation.statusText.isEmpty {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
                HStack(spacing: 8 * uiScale) {
                    DlssStatusGlyph(
                        glyph: presentation.statusGlyph,
                        isWaiting: viewModel.isDlssCompatibilityWaiting,
                        isMotionReduced: isMotionReduced,
                        uiScale: uiScale
                    )
                    Text(presentation.statusText)
                        .catalogFont(size: 14, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !presentation.statusSupportingText.isEmpty {
                    Text(presentation.statusSupportingText)
                        .catalogFont(size: 12, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.statusText)
            .accessibilityValue(presentation.statusSupportingText)
        }
    }

    // MARK: - Compatibility

    @ViewBuilder
    private var featureTable: some View {
        if let gameSupport = presentation.gameSupport {
            VStack(alignment: .leading, spacing: OPNDesign.Spacing.small(scale: uiScale)) {
                ForEach(gameSupport.featureRows, id: \.feature.id) { row in
                    DlssCompatibilityFeatureRow(feature: row.feature, support: row.support, uiScale: uiScale)
                }
                if let multiFrameGeneration = gameSupport.multiFrameGeneration {
                    multiFrameGenerationRow(multiFrameGeneration)
                }
            }
        }
    }

    private func multiFrameGenerationRow(_ value: DlssMultiFrameGeneration) -> some View {
        DlssCompatibilityFeatureRow(
            feature: .frameGeneration,
            support: .override,
            uiScale: uiScale,
            overrideTitle: "Multi Frame Generation",
            overrideDetail: "NVIDIA lists up to \(value.maxMultiplier)× generated frames per rendered frame.",
            accountLimitText: DlssAccessCopy.multiplierAccessText(for: membership)
        )
    }

    // MARK: - Access

    private var accessBlock: some View {
        VStack(alignment: .leading, spacing: OPNDesign.Spacing.xSmall(scale: uiScale)) {
            HStack(spacing: 8 * uiScale) {
                Text("YOUR ACCESS")
                    .catalogFont(size: 10, weight: .bold)
                    .tracking(1)
                    .foregroundStyle(OPNDesign.Text.muted)
                SettingsHelpIcon(
                    title: "Your access",
                    help: "Overrides need an eligible membership and a cloud rig that supports them. What a game supports and what your membership includes are separate.",
                    uiScale: uiScale
                )
                Spacer(minLength: 0)
            }
            ForEach(DlssCompatibilityFeature.overridableFeatures) { feature in
                HStack(alignment: .firstTextBaseline, spacing: 10 * uiScale) {
                    Text(feature.title)
                        .catalogFont(size: 12, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .frame(width: 140 * uiScale, alignment: .leading)
                    Text(DlssAccessCopy.accessText(for: feature, membership: membership))
                        .catalogFont(size: 12, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Freshness

    @ViewBuilder
    private var freshnessFooter: some View {
        if !presentation.freshnessText.isEmpty {
            VStack(alignment: .leading, spacing: 4 * uiScale) {
                HStack(spacing: 7 * uiScale) {
                    DlssStatusGlyph(
                        glyph: presentation.freshnessGlyph,
                        isWaiting: viewModel.isDlssCompatibilityWaiting,
                        isMotionReduced: isMotionReduced,
                        uiScale: uiScale * 0.85
                    )
                    Text(presentation.freshnessText)
                        .catalogFont(size: 11, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                    if !presentation.freshnessHelpText.isEmpty {
                        SettingsHelpIcon(title: "Compatibility information", help: presentation.freshnessHelpText, uiScale: uiScale)
                    }
                    Spacer(minLength: 0)
                }
                if !presentation.freshnessSupportingText.isEmpty {
                    Text(presentation.freshnessSupportingText)
                        .catalogFont(size: 11, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceFooter: some View {
        Text(presentation.sourceFooter)
            .catalogFont(size: 11, weight: .medium)
            .foregroundStyle(OPNDesign.Text.muted)
    }

    private var configureAction: some View {
        VStack(alignment: .leading, spacing: 6 * uiScale) {
            Button {
                viewModel.configureGlobalDlssOverrides()
            } label: {
                Text("Configure global DLSS overrides…")
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                    .padding(.horizontal, 13 * uiScale)
                    .frame(height: 34 * uiScale)
                    .background(OPNCornerShape(role: .control, scale: uiScale).fill(OPNDesign.accent.opacity(0.14)))
                    .overlay { OPNCornerShape(role: .control, scale: uiScale).strokeBorder(OPNDesign.accent.opacity(0.34), lineWidth: 1) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure global DLSS overrides")
            Text("Changes affect all supported games.")
                .catalogFont(size: 11, weight: .medium)
                .foregroundStyle(OPNDesign.Text.muted)
        }
    }
}

/// One glyph for every compatibility state. Reduce Motion, and a bounded wait that has already ended,
/// both fall back to a static neutral indicator.
struct DlssStatusGlyph: View {
    let glyph: DlssCompatibilityGlyph
    let isWaiting: Bool
    let isMotionReduced: Bool
    let uiScale: CGFloat

    var body: some View {
        switch glyph {
        case .none: EmptyView()
        case .progress: progressGlyph
        case .clock: clockGlyph
        case .warning: warningGlyph
        case .question: neutralGlyph("questionmark.circle")
        case .info: neutralGlyph("info.circle")
        }
    }

    @ViewBuilder
    private var progressGlyph: some View {
        if isMotionReduced || !isWaiting {
            clockGlyph
        }
        if !isMotionReduced, isWaiting {
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
                .accessibilityHidden(true)
        }
    }

    private var clockGlyph: some View {
        Image(systemName: "clock")
            .catalogFont(size: 12 * uiScale, weight: .bold)
            .foregroundStyle(OPNDesign.Text.tertiary)
    }

    private var warningGlyph: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .catalogFont(size: 12 * uiScale, weight: .bold)
            .foregroundStyle(OPNDesign.Semantic.warning)
    }

    private func neutralGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .catalogFont(size: 12 * uiScale, weight: .bold)
            .foregroundStyle(OPNDesign.Text.secondary)
    }
}

/// One compatibility row: the feature name stays visible even when NVIDIA reports nothing for it, and
/// the treatment is text plus an icon rather than colour alone.
struct DlssCompatibilityFeatureRow: View {
    let feature: DlssCompatibilityFeature
    let support: DlssSupport?
    let uiScale: CGFloat
    var overrideTitle: String?
    var overrideDetail: String?
    var accountLimitText: String?

    private var title: String { overrideTitle ?? feature.title }

    private var supportDescription: String {
        if let overrideDetail { return overrideDetail }
        guard let support else { return "NVIDIA's list does not report support for this feature. This does not mean it is unsupported." }
        return support.helpText
    }

    private var reportedValueLabel: String { support?.label ?? "Not reported" }

    private var iconName: String {
        switch support {
        case .native: "gamecontroller"
        case .override: "slider.horizontal.3"
        case nil: "minus.circle"
        }
    }

    private var isReported: Bool { support != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10 * uiScale) {
            Image(systemName: iconName)
                .catalogFont(size: 13, weight: .bold)
                .foregroundStyle(isReported ? OPNDesign.Text.primary : OPNDesign.Text.muted)
                .frame(width: 20 * uiScale, alignment: .leading)
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                Text(title)
                    .catalogFont(size: 13, weight: .bold)
                    .foregroundStyle(isReported ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
                Text(reportedValueLabel)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(isReported ? OPNDesign.Text.secondary : OPNDesign.Text.tertiary)
                Text(supportDescription)
                    .catalogFont(size: 11.5, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accountLimitText {
                    Text(accountLimitText)
                        .catalogFont(size: 11.5, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The compact chip the detail panel wears. It says information is available, never that an override
/// is on, and it stays put - with a warning - while a saved copy is being refreshed or failed.
struct DlssCompactCompatibilityChip: View {
    let chip: DlssCompatibilityPresentation.CompactChip
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 5 * uiScale) {
            if chip.isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .catalogFont(size: 9, weight: .bold)
            }
            Text(chip.label)
                .catalogFont(size: 12, weight: .bold)
        }
        .foregroundStyle(OPNDesign.Text.primary)
        .padding(.horizontal, 9 * uiScale)
        .frame(height: 23 * uiScale)
        .background(OPNCornerShape(role: .control, scale: uiScale).fill(Color.black.opacity(0.18)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chip.accessibilityLabel)
    }
}
