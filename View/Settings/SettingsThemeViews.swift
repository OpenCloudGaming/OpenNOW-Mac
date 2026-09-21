import SwiftUI

struct ThemeSettingsPage: View {
    let viewModel: CatalogViewModel
    let uiScale: CGFloat
    @AppStorage(OPNInterfacePreferences.uiScaleKey) private var uiScaleStorage = OPNInterfacePreferences.defaultUIScale
    @AppStorage(OPNHomeLayout.modeKey) private var homeLayoutRawValue = OPNHomeLayout.Mode.classic.rawValue
    @AppStorage(OPNThemePreferences.tileDensityKey) private var tileDensityRawValue = OPNThemePreferences.TileDensity.comfortable.rawValue
    @AppStorage(OPNThemePreferences.tileTitleVisibilityKey) private var tileTitleVisibilityRawValue = OPNThemePreferences.TileTitleVisibility.onHover.rawValue
    @AppStorage(OPNThemePreferences.isMotionReducedKey) private var isMotionReduced = false
    @AppStorage(OPNThemePreferences.accentColorKey) private var accentColorRawValue = OPNThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OPNThemePreferences.appearanceKey) private var appearanceRawValue = OPNThemePreferences.Appearance.dark.rawValue

    private var selectedAppearanceIndex: Int {
        let appearance = OPNThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark
        return OPNThemePreferences.Appearance.allCases.firstIndex(of: appearance) ?? 0
    }

    private var selectedHomeLayoutIndex: Int {
        let mode = OPNHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic
        return OPNHomeLayout.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    private var selectedTileDensityIndex: Int {
        let density = OPNThemePreferences.TileDensity(rawValue: tileDensityRawValue) ?? .comfortable
        return OPNThemePreferences.TileDensity.allCases.firstIndex(of: density) ?? 0
    }

    private var selectedTileTitleVisibilityIndex: Int {
        let visibility = OPNThemePreferences.TileTitleVisibility(rawValue: tileTitleVisibilityRawValue) ?? .onHover
        return OPNThemePreferences.TileTitleVisibility.allCases.firstIndex(of: visibility) ?? 0
    }

    private var selectedAccentColorIndex: Int {
        let preset = OPNThemePreferences.AccentColor(rawValue: accentColorRawValue) ?? .cloudGreen
        return OPNThemePreferences.AccentColor.allCases.firstIndex(of: preset) ?? 0
    }

    private var accentColorSwatches: [Color] {
        OPNThemePreferences.AccentColor.allCases.map {
            let components = $0.components(isDark: !OPNDesign.isLightAppearance)
            return Color(.sRGB, red: components.red, green: components.green, blue: components.blue)
        }
    }

    static let sections: [SettingsSection] = [
        SettingsSection("appearance", "Appearance"),
        SettingsSection("interface", "Interface"),
        SettingsSection("accent", "Accent Colour"),
        SettingsSection("home-layout", "Home Layout"),
        SettingsSection("tiles", "Tiles"),
        SettingsSection("motion", "Motion"),
        SettingsSection("home-categories", "Home Categories"),
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Appearance", uiScale: uiScale) {
                SettingsOptionRow(title: "Appearance", subtitle: "Dark, light, or follow the macOS setting. The in-stream HUD and the sign-in screen stay dark either way.", options: OPNThemePreferences.Appearance.allCases.map(\.label), selectedIndex: selectedAppearanceIndex, isNew: OPNNewSettings.isNew(.appearance), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.appearance)
                    appearanceRawValue = OPNThemePreferences.Appearance.allCases[index].rawValue
                }
            }
            .settingsSection("appearance")

            SettingsCard(title: "Interface", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: OPNInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsSection("interface")

            SettingsCard(title: "Accent Colour", uiScale: uiScale) {
                SettingsOptionRow(title: "Accent Colour", subtitle: "The highlight colour used across buttons, selection, and focus throughout the app.", options: OPNThemePreferences.AccentColor.allCases.map(\.label), selectedIndex: selectedAccentColorIndex, swatchColors: accentColorSwatches, isNew: OPNNewSettings.isNew(.accentColor), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.accentColor)
                    accentColorRawValue = OPNThemePreferences.AccentColor.allCases[index].rawValue
                }
            }
            .settingsSection("accent")

            SettingsCard(title: "Home Layout", uiScale: uiScale) {
                SettingsOptionRow(title: "Home Layout", subtitle: "How the keyboard-and-mouse home page is laid out. Classic keeps today's featured banner and wide landscape tiles. Poster switches to rows of tall, portrait box-art tiles. Controller mode is unaffected.", options: OPNHomeLayout.Mode.allCases.map(\.label), selectedIndex: selectedHomeLayoutIndex, isNew: OPNNewSettings.isNew(.homeLayout), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.homeLayout)
                    homeLayoutRawValue = OPNHomeLayout.Mode.allCases[index].rawValue
                }
            }
            .settingsSection("home-layout")

            SettingsCard(title: "Tiles", uiScale: uiScale) {
                SettingsOptionRow(title: "Tile Density", subtitle: "How much room a game tile takes. Compact fits more games on screen without shrinking the interface around them; Large is easier to read across a room.", options: OPNThemePreferences.TileDensity.allCases.map(\.label), selectedIndex: selectedTileDensityIndex, isNew: OPNNewSettings.isNew(.tileDensity), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.tileDensity)
                    tileDensityRawValue = OPNThemePreferences.TileDensity.allCases[index].rawValue
                }
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Tile Titles", subtitle: "When a game's name is drawn over its artwork. On Hover shows it as you point at a tile, Always keeps it there, and Never leaves the art to speak for itself.", options: OPNThemePreferences.TileTitleVisibility.allCases.map(\.label), selectedIndex: selectedTileTitleVisibilityIndex, isNew: OPNNewSettings.isNew(.tileTitles), uiScale: uiScale) { index in
                    OPNNewSettings.acknowledge(.tileTitles)
                    tileTitleVisibilityRawValue = OPNThemePreferences.TileTitleVisibility.allCases[index].rawValue
                }
            }
            .settingsSection("tiles")

            SettingsCard(title: "Motion", uiScale: uiScale) {
                SettingsToggleRow(title: "Reduce Motion", subtitle: "Hold the interface still: no hover growth, no sliding panels, no ambient animation. Turns itself on whenever macOS Reduce Motion is on.", isOn: isMotionReduced, isNew: OPNNewSettings.isNew(.reduceMotion), uiScale: uiScale) { newValue in
                    OPNNewSettings.acknowledge(.reduceMotion)
                    isMotionReduced = newValue
                }
            }
            .settingsSection("motion")

            HomeCategorySettingsCard(viewModel: viewModel, uiScale: uiScale)
                .settingsSection("home-categories")
        }
    }
}
