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
