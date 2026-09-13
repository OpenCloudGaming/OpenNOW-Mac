import Testing
@testable import OpenNOW

@Test func defaultAppearanceIsDark() {
    #expect(OpenNOWThemePreferences.Appearance(rawValue: "dark") == .dark)
}

@Test func anUnknownStoredAppearanceValueFallsBackToDark() {
    #expect(OpenNOWThemePreferences.Appearance(rawValue: "sepia") ?? .dark == .dark)
    #expect(OpenNOWThemePreferences.Appearance(rawValue: "") ?? .dark == .dark)
}

/// The picker maps `allCases` by index and the raw values are what a stored preference survives a
/// rename by, so both the order and the raw values are a storage/UI contract.
@Test func everyAppearanceNamesItselfAndTheRawValuesAreStable() {
    let labels = OpenNOWThemePreferences.Appearance.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OpenNOWThemePreferences.Appearance.allCases == [.system, .dark, .light])
    #expect(OpenNOWThemePreferences.Appearance.allCases.map(\.rawValue) == ["system", "dark", "light"])
}

@Test func theAppearanceIsStoredInTheInterfaceNamespace() {
    #expect(OpenNOWThemePreferences.appearanceKey == "OpenNOW.Interface.Appearance")
    #expect(OpenNOWThemePreferences.appearanceKey.hasPrefix("OpenNOW.Interface."))
}

/// Asserts one opaque surface token's three channels against known 0-255 shipping values.
private func expectSurface(
    _ token: (red: Double, green: Double, blue: Double),
    _ red: Double, _ green: Double, _ blue: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(token.red == red / 255, sourceLocation: sourceLocation)
    #expect(token.green == green / 255, sourceLocation: sourceLocation)
    #expect(token.blue == blue / 255, sourceLocation: sourceLocation)
}

/// Asserts one translucent (text/stroke/scrim) token's colour and opacity against shipping values.
private func expectTranslucent(
    _ token: (red: Double, green: Double, blue: Double, opacity: Double),
    _ red: Double, _ green: Double, _ blue: Double, _ opacity: Double,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(token.red == red, sourceLocation: sourceLocation)
    #expect(token.green == green, sourceLocation: sourceLocation)
    #expect(token.blue == blue, sourceLocation: sourceLocation)
    #expect(token.opacity == opacity, sourceLocation: sourceLocation)
}

/// Regression guard: dark mode must not have shifted a single value when Appearance landed. Every
/// token the dark palette carried before this feature existed is pinned here exactly.
@Test func theDarkPaletteMatchesTodaysShippingValuesExactly() {
    let tokens = OpenNOWThemePreferences.darkPaletteTokens
    expectSurface(tokens.surfaceApp, 25, 25, 25)
    expectSurface(tokens.surfaceAppBar, 45, 45, 45)
    expectSurface(tokens.surfacePanel, 28, 28, 28)
    expectSurface(tokens.surfacePanelRaised, 34, 34, 34)
    expectSurface(tokens.surfaceTileTray, 41, 41, 41)
    expectSurface(tokens.surfaceField, 31, 31, 31)
    expectTranslucent(tokens.surfaceScrim, 0, 0, 0, 0.58)
    expectSurface(tokens.surfaceDeep, 18, 19, 18)
    expectSurface(tokens.surfaceOverlay, 23, 23, 23)
    expectSurface(tokens.surfaceChrome, 57, 57, 59)
    expectTranslucent(tokens.textPrimary, 1, 1, 1, 0.96)
    expectTranslucent(tokens.textSecondary, 1, 1, 1, 0.72)
    expectTranslucent(tokens.textTertiary, 1, 1, 1, 0.52)
    expectTranslucent(tokens.textMuted, 1, 1, 1, 0.38)
    expectTranslucent(tokens.strokeSubtle, 1, 1, 1, 0.10)
    expectTranslucent(tokens.strokeRegular, 1, 1, 1, 0.14)
    expectTranslucent(tokens.strokeStrong, 1, 1, 1, 0.22)
}

@Test func blackOnWhiteIsTheMaximumContrastRatio() {
    let ratio = OpenNOWThemePreferences.contrastRatio(red: 0, green: 0, blue: 0, againstRed: 1, againstGreen: 1, againstBlue: 1)
    #expect(ratio == 21)
}

@Test func contrastRatioIsOrderIndependent() {
    let forward = OpenNOWThemePreferences.contrastRatio(red: 0.2, green: 0.2, blue: 0.2, againstRed: 0.8, againstGreen: 0.8, againstBlue: 0.8)
    let backward = OpenNOWThemePreferences.contrastRatio(red: 0.8, green: 0.8, blue: 0.8, againstRed: 0.2, againstGreen: 0.2, againstBlue: 0.2)
    #expect(forward == backward)
}

/// The blend of a translucent token over an opaque surface, so contrast can be measured on what a
/// reader actually sees rather than on the token's own components.
private func blended(
    foreground: (red: Double, green: Double, blue: Double, opacity: Double),
    background: (red: Double, green: Double, blue: Double)
) -> (red: Double, green: Double, blue: Double) {
    let alpha = foreground.opacity
    return (
        foreground.red * alpha + background.red * (1 - alpha),
        foreground.green * alpha + background.green * (1 - alpha),
        foreground.blue * alpha + background.blue * (1 - alpha)
    )
}

@Test func textPrimaryClearsSevenToOneOnAppInBothPalettes() {
    for tokens in [OpenNOWThemePreferences.darkPaletteTokens, OpenNOWThemePreferences.lightPaletteTokens] {
        let blend = blended(foreground: tokens.textPrimary, background: tokens.surfaceApp)
        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: blend.red, green: blend.green, blue: blend.blue,
            againstRed: tokens.surfaceApp.red, againstGreen: tokens.surfaceApp.green, againstBlue: tokens.surfaceApp.blue
        )
        #expect(ratio >= 7)
    }
}

@Test func textSecondaryClearsFourPointFiveToOneOnAppInBothPalettes() {
    for tokens in [OpenNOWThemePreferences.darkPaletteTokens, OpenNOWThemePreferences.lightPaletteTokens] {
        let blend = blended(foreground: tokens.textSecondary, background: tokens.surfaceApp)
        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: blend.red, green: blend.green, blue: blend.blue,
            againstRed: tokens.surfaceApp.red, againstGreen: tokens.surfaceApp.green, againstBlue: tokens.surfaceApp.blue
        )
        #expect(ratio >= 4.5)
    }
}

@Test func textMutedClearsThreeToOneOnAppInBothPalettes() {
    for tokens in [OpenNOWThemePreferences.darkPaletteTokens, OpenNOWThemePreferences.lightPaletteTokens] {
        let blend = blended(foreground: tokens.textMuted, background: tokens.surfaceApp)
        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: blend.red, green: blend.green, blue: blend.blue,
            againstRed: tokens.surfaceApp.red, againstGreen: tokens.surfaceApp.green, againstBlue: tokens.surfaceApp.blue
        )
        #expect(ratio >= 3)
    }
}

/// "Visible" means the blended stroke reads as a distinct grey from the panel behind it. 1.2 sits
/// just under the dark palette's own shipping ratio (~1.34), so a stroke actually has to separate
/// from its surface to pass rather than the floor being tuned to whatever the values happen to be.
@Test func strokeSubtleIsVisibleAgainstPanelInBothPalettes() {
    for tokens in [OpenNOWThemePreferences.darkPaletteTokens, OpenNOWThemePreferences.lightPaletteTokens] {
        let blend = blended(foreground: tokens.strokeSubtle, background: tokens.surfacePanel)
        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: blend.red, green: blend.green, blue: blend.blue,
            againstRed: tokens.surfacePanel.red, againstGreen: tokens.surfacePanel.green, againstBlue: tokens.surfacePanel.blue
        )
        #expect(ratio >= 1.2)
    }
}

/// Match System resolves against what macOS is set to. The app forces a window appearance for Dark
/// and Light, so reading the scheme back out of the environment would feed the app's own override
/// in as the system answer and leaving Light would resolve straight back to Light.
@MainActor @Test func matchSystemResolvesAgainstTheOperatingSystemNotTheForcedWindow() {
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .light, systemColorScheme: .dark)
    #expect(OpenNOWDesign.isLightAppearance)

    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .system, systemColorScheme: .dark)
    #expect(!OpenNOWDesign.isLightAppearance, "Match System stayed light after leaving the light appearance")

    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
}
