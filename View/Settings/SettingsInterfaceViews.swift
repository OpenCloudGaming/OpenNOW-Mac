//
//  SettingsInterfaceViews.swift
//  MacForceNow
//

import AppKit
import CryptoKit
import SwiftUI

struct InterfaceSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(MacForceNowInterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @AppStorage(MacForceNowInterfacePreferences.uiScaleKey) private var uiScaleStorage = MacForceNowInterfacePreferences.defaultUIScale
    @StateObject private var inputRouter = ControllerInputRouter()
    @StateObject private var steamNavigator = GamepadUINavigator()

    private var isAnyControllerConnected: Bool {
        inputRouter.isControllerConnected || steamNavigator.isSteamControllerConnected
    }

    private var activeGlyphs: ControllerInputGlyphSet {
        inputRouter.isControllerConnected ? inputRouter.glyphs : steamNavigator.glyphs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            SettingsCard(title: "Mode", uiScale: uiScale) {
                HStack(alignment: .center, spacing: 18 * uiScale) {
                    Rectangle()
                        .fill(controllerModeEnabled ? Color.openNowGreen : Color.white.opacity(0.18))
                        .frame(width: 4 * uiScale, height: 58 * uiScale)
                    VStack(alignment: .leading, spacing: 6 * uiScale) {
                        Text(controllerModeEnabled ? "Controller mode is active" : "Desktop catalog mode is active")
                            .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Controller mode replaces the catalog with a TV-style interface built for gamepads, while keeping keyboard and pointer fallback available.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12 * uiScale)
                    SettingsStatusPill(title: "INPUT", value: activeGlyphs.deviceName, positive: isAnyControllerConnected, uiScale: uiScale)
                }
                SettingsDivider(uiScale: uiScale)
                SettingsToggleRow(title: "Controller Mode", subtitle: "Use a clean Netflix-style catalog with large focus targets, controller shortcuts, and dynamic input glyphs.", isOn: controllerModeEnabled, uiScale: uiScale) { enabled in
                    controllerModeEnabled = enabled
                }
            }

            SettingsCard(title: "Display", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: MacForceNowInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Controls", uiScale: uiScale) {
                SettingsFlowLayout(spacing: 10 * uiScale) {
                    InterfaceInputLegend(title: "Move", glyphs: [activeGlyphs.left, activeGlyphs.up, activeGlyphs.down, activeGlyphs.right], uiScale: uiScale)
                    InterfaceInputLegend(title: "Select", glyphs: [activeGlyphs.confirm], uiScale: uiScale)
                    InterfaceInputLegend(title: "Back", glyphs: [activeGlyphs.back], uiScale: uiScale)
                    InterfaceInputLegend(title: "Search", glyphs: [activeGlyphs.search], uiScale: uiScale)
                    InterfaceInputLegend(title: "Actions", glyphs: [activeGlyphs.actions], uiScale: uiScale)
                    InterfaceInputLegend(title: "Rail", glyphs: [activeGlyphs.pageLeft, activeGlyphs.pageRight], uiScale: uiScale)
                }
                SettingsDivider(uiScale: uiScale)
                HStack(alignment: .center, spacing: 12 * uiScale) {
                    Image(systemName: isAnyControllerConnected ? "gamecontroller.fill" : "keyboard")
                        .font(.settingsNvidia(size: 18 * uiScale, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .frame(width: 34 * uiScale, height: 34 * uiScale)
                        .background(Color.openNowGreen.opacity(0.12))
                        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.30), lineWidth: 1) }
                    VStack(alignment: .leading, spacing: 4 * uiScale) {
                        Text(isAnyControllerConnected ? "Controller glyphs are live" : "Keyboard fallback is active")
                            .font(.settingsNvidia(size: 14 * uiScale, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(isAnyControllerConnected ? "Hints use symbols exposed by the connected game controller whenever the system provides them." : "Connect a controller to switch hints from keyboard keys to controller button glyphs automatically.")
                            .font(.settingsNvidia(size: 12 * uiScale, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear { steamNavigator.start() }
        .onDisappear { steamNavigator.stop() }
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
        .foregroundStyle(Color.openNowGreen)
        .padding(.horizontal, 8 * uiScale)
        .frame(height: 28 * uiScale)
        .background(Color.openNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.openNowGreen.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}
