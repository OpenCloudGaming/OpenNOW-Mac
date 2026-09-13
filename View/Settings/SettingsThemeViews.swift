import SwiftUI

struct ThemeSettingsPage: View {
    let uiScale: CGFloat
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) private var uiScaleStorage = OpenNOWInterfacePreferences.defaultUIScale
    @AppStorage(OpenNOWHomeLayout.modeKey) private var homeLayoutRawValue = OpenNOWHomeLayout.Mode.classic.rawValue
    @AppStorage(OpenNOWThemePreferences.tileDensityKey) private var tileDensityRawValue = OpenNOWThemePreferences.TileDensity.comfortable.rawValue
    @AppStorage(OpenNOWThemePreferences.tileTitleVisibilityKey) private var tileTitleVisibilityRawValue = OpenNOWThemePreferences.TileTitleVisibility.onHover.rawValue
    @AppStorage(OpenNOWThemePreferences.isMotionReducedKey) private var isMotionReduced = false
    @AppStorage(OpenNOWThemePreferences.accentColorKey) private var accentColorRawValue = OpenNOWThemePreferences.AccentColor.cloudGreen.rawValue
    @AppStorage(OpenNOWThemePreferences.appearanceKey) private var appearanceRawValue = OpenNOWThemePreferences.Appearance.dark.rawValue

    private var selectedAppearanceIndex: Int {
        let appearance = OpenNOWThemePreferences.Appearance(rawValue: appearanceRawValue) ?? .dark
        return OpenNOWThemePreferences.Appearance.allCases.firstIndex(of: appearance) ?? 0
    }

    private var selectedHomeLayoutIndex: Int {
        let mode = OpenNOWHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic
        return OpenNOWHomeLayout.Mode.allCases.firstIndex(of: mode) ?? 0
    }

    private var selectedTileDensityIndex: Int {
        let density = OpenNOWThemePreferences.TileDensity(rawValue: tileDensityRawValue) ?? .comfortable
        return OpenNOWThemePreferences.TileDensity.allCases.firstIndex(of: density) ?? 0
    }

    private var selectedTileTitleVisibilityIndex: Int {
        let visibility = OpenNOWThemePreferences.TileTitleVisibility(rawValue: tileTitleVisibilityRawValue) ?? .onHover
        return OpenNOWThemePreferences.TileTitleVisibility.allCases.firstIndex(of: visibility) ?? 0
    }

    private var selectedAccentColorIndex: Int {
        let preset = OpenNOWThemePreferences.AccentColor(rawValue: accentColorRawValue) ?? .cloudGreen
        return OpenNOWThemePreferences.AccentColor.allCases.firstIndex(of: preset) ?? 0
    }

    private var accentColorSwatches: [Color] {
        OpenNOWThemePreferences.AccentColor.allCases.map {
            let components = $0.components(isDark: !OpenNOWDesign.isLightAppearance)
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
    ]

    var body: some View {
        SettingsStack(spacing: 16 * uiScale) {
            SettingsCard(title: "Appearance", uiScale: uiScale) {
                SettingsOptionRow(title: "Appearance", subtitle: "Dark, light, or follow the macOS setting. The in-stream HUD and the sign-in screen stay dark either way.", options: OpenNOWThemePreferences.Appearance.allCases.map(\.label), selectedIndex: selectedAppearanceIndex, isNew: OpenNOWNewSettings.isNew(.appearance), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.appearance)
                    appearanceRawValue = OpenNOWThemePreferences.Appearance.allCases[index].rawValue
                }
            }
            .settingsSection("appearance")

            SettingsCard(title: "Interface", uiScale: uiScale) {
                SettingsSliderRow(title: "Interface Scale", valueText: "\(Int((uiScaleStorage * 100).rounded()))%", value: uiScaleStorage, range: OpenNOWInterfacePreferences.uiScaleRange, step: 0.05, uiScale: uiScale) { scale in
                    uiScaleStorage = scale
                }
                SettingsDivider(uiScale: uiScale)
                Text("Scales the catalog, settings, and in-stream HUD. Increase it on high-resolution displays (for example 5K) when the interface feels too small.")
                    .font(.settingsFont(size: 12 * uiScale, weight: .medium))
                    .foregroundStyle(OpenNOWDesign.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsSection("interface")

            SettingsCard(title: "Accent Colour", uiScale: uiScale) {
                SettingsOptionRow(title: "Accent Colour", subtitle: "The highlight colour used across buttons, selection, and focus throughout the app.", options: OpenNOWThemePreferences.AccentColor.allCases.map(\.label), selectedIndex: selectedAccentColorIndex, swatchColors: accentColorSwatches, isNew: OpenNOWNewSettings.isNew(.accentColor), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.accentColor)
                    accentColorRawValue = OpenNOWThemePreferences.AccentColor.allCases[index].rawValue
                }
            }
            .settingsSection("accent")

            SettingsCard(title: "Home Layout", uiScale: uiScale) {
                SettingsOptionRow(title: "Home Layout", subtitle: "How the keyboard-and-mouse home page is laid out. Classic keeps today's featured banner and wide landscape tiles. Poster switches to rows of tall, portrait box-art tiles. Controller mode is unaffected.", options: OpenNOWHomeLayout.Mode.allCases.map(\.label), selectedIndex: selectedHomeLayoutIndex, isNew: OpenNOWNewSettings.isNew(.homeLayout), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.homeLayout)
                    homeLayoutRawValue = OpenNOWHomeLayout.Mode.allCases[index].rawValue
                }
            }
            .settingsSection("home-layout")

            SettingsCard(title: "Tiles", uiScale: uiScale) {
                SettingsOptionRow(title: "Tile Density", subtitle: "How much room a game tile takes. Compact fits more games on screen without shrinking the interface around them; Large is easier to read across a room.", options: OpenNOWThemePreferences.TileDensity.allCases.map(\.label), selectedIndex: selectedTileDensityIndex, isNew: OpenNOWNewSettings.isNew(.tileDensity), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.tileDensity)
                    tileDensityRawValue = OpenNOWThemePreferences.TileDensity.allCases[index].rawValue
                }
                SettingsDivider(uiScale: uiScale)
                SettingsOptionRow(title: "Tile Titles", subtitle: "When a game's name is drawn over its artwork. On Hover shows it as you point at a tile, Always keeps it there, and Never leaves the art to speak for itself.", options: OpenNOWThemePreferences.TileTitleVisibility.allCases.map(\.label), selectedIndex: selectedTileTitleVisibilityIndex, isNew: OpenNOWNewSettings.isNew(.tileTitles), uiScale: uiScale) { index in
                    OpenNOWNewSettings.acknowledge(.tileTitles)
                    tileTitleVisibilityRawValue = OpenNOWThemePreferences.TileTitleVisibility.allCases[index].rawValue
                }
            }
            .settingsSection("tiles")

            SettingsCard(title: "Motion", uiScale: uiScale) {
                SettingsToggleRow(title: "Reduce Motion", subtitle: "Hold the interface still: no hover growth, no sliding panels, no ambient animation. Turns itself on whenever macOS Reduce Motion is on.", isOn: isMotionReduced, isNew: OpenNOWNewSettings.isNew(.reduceMotion), uiScale: uiScale) { newValue in
                    OpenNOWNewSettings.acknowledge(.reduceMotion)
                    isMotionReduced = newValue
                }
            }
            .settingsSection("motion")
        }
    }
}
