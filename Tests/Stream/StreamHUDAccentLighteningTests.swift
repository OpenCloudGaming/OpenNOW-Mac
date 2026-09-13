import Testing
@testable import OpenNOW

/// The HUD's `accentSoft` is a lightened form of whatever accent the reader picked, derived by
/// `OpenNOWDesign.lightenedAccentComponents`. These check the maths, not `Color` itself.
private let accentSoftTolerance = 0.03

@Test func lighteningCloudGreenReproducesTodaysShippingAccentSoft() {
    let components = OpenNOWThemePreferences.AccentColor.cloudGreen.components
    let lightened = OpenNOWDesign.lightenedAccentComponents(red: components.red, green: components.green, blue: components.blue)

    #expect(abs(lightened.red - 0.67) < accentSoftTolerance)
    #expect(abs(lightened.green - 1.0) < accentSoftTolerance)
    #expect(abs(lightened.blue - 0.36) < accentSoftTolerance)
}

@Test func everyAccentPresetLightensToAValueInRangeAndBrighterThanItsSource() {
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        let components = preset.components
        let lightened = OpenNOWDesign.lightenedAccentComponents(red: components.red, green: components.green, blue: components.blue)

        #expect((0...1).contains(lightened.red))
        #expect((0...1).contains(lightened.green))
        #expect((0...1).contains(lightened.blue))

        let sourceLuminance = OpenNOWThemePreferences.relativeLuminance(red: components.red, green: components.green, blue: components.blue)
        let lightenedLuminance = OpenNOWThemePreferences.relativeLuminance(red: lightened.red, green: lightened.green, blue: lightened.blue)
        #expect(lightenedLuminance > sourceLuminance)
    }
}
