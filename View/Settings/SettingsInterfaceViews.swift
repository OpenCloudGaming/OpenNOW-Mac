import AppKit
import CryptoKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OPNSessionReadyAction.modeKey) private var sessionReadyActionRawValue = OPNSessionReadyAction.Mode.notification.rawValue

    private var selectedSessionReadyActionIndex: Int {
        let mode = OPNSessionReadyAction.Mode(rawValue: sessionReadyActionRawValue) ?? .notification
        return OPNSessionReadyAction.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    static let sections: [SettingsSection] = [
        SettingsSection("session-ready", "Session Ready"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Session Ready", uiScale: uiScale) {
                SettingsOptionRow(title: "When the Stream Is Ready", subtitle: "While OpenNOW is in the background and a queued or provisioning session becomes ready: post a system notification, bring OpenNOW to the front automatically, bring it forward and put the stream in full screen, or do nothing.", options: OPNSessionReadyAction.Mode.allCases.map(\.label), selectedIndex: selectedSessionReadyActionIndex, isNew: OPNNewSettings.isNew(.sessionReadyAction), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.sessionReadyAction)
                    let mode = OPNSessionReadyAction.Mode.allCases[index]
                    sessionReadyActionRawValue = mode.rawValue
                    if mode == .notification { OPNSessionReadyAction.prepareAuthorizationIfNeeded() }
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
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(OPNDesign.Text.muted)
            HStack(spacing: 6 * uiScale) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph, uiScale: uiScale)
                }
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 11 * uiScale)
        .frame(minWidth: 132 * uiScale, minHeight: 70 * uiScale, alignment: .leading)
        .background(OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }
}

struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsFont(size: 13 * uiScale, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsFont(size: 10 * uiScale, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(OPNDesign.accentInk)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 28 * uiScale)
        .background(OPNDesign.accent.opacity(0.12))
        .overlay { Rectangle().stroke(OPNDesign.accent.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}
