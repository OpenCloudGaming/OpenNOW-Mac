import AppKit
import CryptoKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScaleStorage = OpenNOWInterfacePreferences.defaultUIScale
    @AppStorage(OpenNOWSessionReadyAction.modeKey) private var sessionReadyActionRawValue = OpenNOWSessionReadyAction.Mode.notification.rawValue

    private var selectedSessionReadyActionIndex: Int {
        let mode = OpenNOWSessionReadyAction.Mode(rawValue: sessionReadyActionRawValue) ?? .notification
        return OpenNOWSessionReadyAction.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    static let sections: [SettingsSection] = [
        SettingsSection("interface", "Interface"),
        SettingsSection("session-ready", "Session Ready"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Display", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: OpenNOWInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsSection("interface")

            SettingsCard(title: "Session Ready", uiScale: uiScale) {
                SettingsOptionRow(title: "When the Stream Is Ready", subtitle: "While OpenNOW is in the background and a queued or provisioning session becomes ready: post a system notification, or bring OpenNOW to the front automatically.", options: OpenNOWSessionReadyAction.Mode.allCases.map(\.label), selectedIndex: selectedSessionReadyActionIndex, isNew: OpenNOWNewSettings.isNew(.sessionReadyAction), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.sessionReadyAction)
                    let mode = OpenNOWSessionReadyAction.Mode.allCases[index]
                    sessionReadyActionRawValue = mode.rawValue
                    if mode == .notification { OpenNOWSessionReadyAction.prepareAuthorizationIfNeeded() }
                }
            }
            .settingsSection("session-ready")
        }
    }
}

struct InterfaceInputLegend: View {
    let title: String
    let glyphs: [ControllerInputGlyph]
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * uiScale) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            HStack(spacing: 6 * uiScale) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph, uiScale: uiScale)
                }
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(minWidth: 132 * uiScale, minHeight: 70 * uiScale, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsNvidia(size: 13 * uiScale, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsNvidia(size: 10 * uiScale, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(OpenNOWDesign.accent)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 28 * uiScale)
        .background(OpenNOWDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OpenNOWDesign.accent.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}
