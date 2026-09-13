import Testing
@testable import OpenNOW

@Test func defaultAccentColorIsCloudGreen() {
    #expect(OpenNOWThemePreferences.AccentColor(rawValue: "cloudGreen") == .cloudGreen)
}

/// Cloud Green ships today as `Color(red: 0.46, green: 0.90, blue: 0.10)`; the preset must equal
/// that exactly so switching to it is a no-op for every existing reader.
@Test func cloudGreenComponentsMatchTodaysShippingColour() {
    let components = OpenNOWThemePreferences.AccentColor.cloudGreen.components
    #expect(components.red == 0.46)
    #expect(components.green == 0.90)
    #expect(components.blue == 0.10)
}

@Test func anUnknownStoredAccentValueFallsBackToCloudGreen() {
    #expect(OpenNOWThemePreferences.AccentColor(rawValue: "jellyfish") ?? .cloudGreen == .cloudGreen)
    #expect(OpenNOWThemePreferences.AccentColor(rawValue: "") ?? .cloudGreen == .cloudGreen)
}

/// The Settings picker maps `allCases` by index and the raw values are what a stored preference
/// survives a rename by, so both the order and the raw values are a storage/UI contract.
@Test func everyAccentPresetNamesItselfAndTheRawValuesAreStable() {
    let labels = OpenNOWThemePreferences.AccentColor.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OpenNOWThemePreferences.AccentColor.allCases == [.cloudGreen, .sky, .violet, .magenta, .amber, .coral])
    #expect(OpenNOWThemePreferences.AccentColor.allCases.map(\.rawValue) == ["cloudGreen", "sky", "violet", "magenta", "amber", "coral"])
}

@Test func theAccentColorIsStoredInTheInterfaceNamespace() {
    #expect(OpenNOWThemePreferences.accentColorKey == "OpenNOW.Interface.Accent")
    #expect(OpenNOWThemePreferences.accentColorKey.hasPrefix("OpenNOW.Interface."))
}

@Test func blackTextReadsPureBlackOnPureWhite() {
    #expect(OpenNOWThemePreferences.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
    #expect(OpenNOWThemePreferences.relativeLuminance(red: 1, green: 1, blue: 1) == 1)
}

@Test func everyAccentPresetClearsTheLuminanceFloorBlackTextNeeds() {
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        let components = preset.components
        let luminance = OpenNOWThemePreferences.relativeLuminance(red: components.red, green: components.green, blue: components.blue)
        #expect(luminance >= OpenNOWThemePreferences.minimumAccentLuminance)
    }
}

/// A preset chosen to glow on near-black glares on near-white, so each carries a deeper twin. Both
/// halves are a contract: the dark half is what ships today, the light half has to be readable.
@Test func everyAccentPresetCarriesADeeperTwinForLightPages() {
    let page = OpenNOWThemePreferences.lightPaletteTokens.surfaceApp
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        let dark = preset.components
        let light = preset.lightComponents
        let darkLuminance = OpenNOWThemePreferences.relativeLuminance(red: dark.red, green: dark.green, blue: dark.blue)
        let lightLuminance = OpenNOWThemePreferences.relativeLuminance(red: light.red, green: light.green, blue: light.blue)
        #expect(lightLuminance < darkLuminance, "\(preset.label)'s light twin is not deeper than its dark value")

        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: light.red, green: light.green, blue: light.blue,
            againstRed: page.red, againstGreen: page.green, againstBlue: page.blue
        )
        #expect(ratio >= OpenNOWThemePreferences.minimumTextContrastRatio, "\(preset.label) is unreadable on a light page")
    }
}

/// Whatever is written on an accent fill has to be readable on it: black over the bright value,
/// white over the deep one.
@Test func whateverIsWrittenOnAnAccentFillStaysReadable() {
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        let dark = preset.components
        let onDark = OpenNOWThemePreferences.contrastRatio(
            red: 0, green: 0, blue: 0,
            againstRed: dark.red, againstGreen: dark.green, againstBlue: dark.blue
        )
        #expect(onDark >= OpenNOWThemePreferences.minimumTextContrastRatio, "black is unreadable on \(preset.label)")

        let light = preset.lightComponents
        let onLight = OpenNOWThemePreferences.contrastRatio(
            red: 1, green: 1, blue: 1,
            againstRed: light.red, againstGreen: light.green, againstBlue: light.blue
        )
        #expect(onLight >= OpenNOWThemePreferences.minimumTextContrastRatio, "white is unreadable on \(preset.label)'s light twin")
    }
}

@Test func theComponentsForAnAppearanceAreTheHalvesThemselves() {
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        #expect(preset.components(isDark: true) == preset.components)
        #expect(preset.components(isDark: false) == preset.lightComponents)
    }
}
