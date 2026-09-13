import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// Every catalog and settings colour constant has to read the palette at render time. Holding one
/// in a `static let` froze it at whichever appearance happened to resolve first, which shipped as
/// black light-mode text on a dark page that never flipped.
@MainActor private func brightness(of color: Color) -> Double {
    let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return Double(resolved.brightnessComponent)
}

@MainActor private func withAppearance(_ appearance: OpenNOWThemePreferences.Appearance, _ body: () -> Void) {
    OpenNOWDesign.applyAppearance(appearance, systemColorScheme: .dark)
    body()
    OpenNOWDesign.applyAppearance(.dark, systemColorScheme: .dark)
}

@MainActor @Test func everySettingsSurfaceFollowsTheChosenAppearance() {
    let darkSurfaces = [SettingsVendorLayout.surface, SettingsVendorLayout.sidebar, SettingsVendorLayout.card, SettingsVendorLayout.cardRaised].map(brightness)
    withAppearance(.light) {
        let lightSurfaces = [SettingsVendorLayout.surface, SettingsVendorLayout.sidebar, SettingsVendorLayout.card, SettingsVendorLayout.cardRaised].map(brightness)
        for (dark, light) in zip(darkSurfaces, lightSurfaces) {
            #expect(light > dark, "a settings surface stayed at its dark value under the light appearance")
        }
    }
}

@MainActor @Test func everyCatalogSurfaceFollowsTheChosenAppearance() {
    let darkSurfaces = [CatalogVendorLayout.appBarBackground, CatalogVendorLayout.mallSurface, CatalogVendorLayout.tileTray].map(brightness)
    withAppearance(.light) {
        let lightSurfaces = [CatalogVendorLayout.appBarBackground, CatalogVendorLayout.mallSurface, CatalogVendorLayout.tileTray].map(brightness)
        for (dark, light) in zip(darkSurfaces, lightSurfaces) {
            #expect(light > dark, "a catalog surface stayed at its dark value under the light appearance")
        }
    }
}

/// Text and surfaces have to flip together. They came apart once already: the text tokens resolved
/// live while the surfaces behind them were frozen, so light mode painted dark text on a dark page.
@MainActor @Test func textAndSurfacesFlipTogetherSoOneNeverPaintsOnTheOther() {
    #expect(brightness(of: OpenNOWDesign.Text.primary) > brightness(of: OpenNOWDesign.Surface.app))
    withAppearance(.light) {
        #expect(brightness(of: OpenNOWDesign.Text.primary) < brightness(of: OpenNOWDesign.Surface.app))
    }
}

@MainActor @Test func aNeutralFillWashesAgainstThePageRatherThanAlwaysWhite() {
    let darkFill = brightness(of: OpenNOWDesign.Fill.neutral(0.5))
    withAppearance(.light) {
        #expect(brightness(of: OpenNOWDesign.Fill.neutral(0.5)) < darkFill)
    }
}

/// The palette is pushed from a root view's `body`, so it runs once per body pass on every root.
/// It has to be cheap to call repeatedly and it has to resolve both halves together.
@MainActor @Test func applyingTheSameThemeTwiceIsANoOpButAChangeIsNot() {
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark) == false)
    #expect(OpenNOWDesign.applyTheme(accent: .magenta, appearance: .dark, systemColorScheme: .dark))
    #expect(OpenNOWDesign.applyTheme(accent: .magenta, appearance: .light, systemColorScheme: .dark))
    #expect(brightness(of: OpenNOWDesign.Surface.app) > 0.5, "the light appearance did not reach the surfaces")
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
}

/// Match System has to follow the OS, which is the only case where the system scheme is consulted.
@MainActor @Test func matchSystemFollowsTheOperatingSystemScheme() {
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .system, systemColorScheme: .light)
    #expect(brightness(of: OpenNOWDesign.Surface.app) > 0.5)
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .system, systemColorScheme: .dark)
    #expect(brightness(of: OpenNOWDesign.Surface.app) < 0.5)
}

/// The shipping accents are bright enough to vanish on a light page, so accent-coloured LABELS go
/// through `accentInk`, which darkens until it clears the text contrast floor.
@MainActor @Test func everyAccentStaysReadableAsTextOnALightPage() {
    let surface = OpenNOWThemePreferences.lightPaletteTokens.surfaceApp
    let surfaceLuminance = OpenNOWThemePreferences.relativeLuminance(red: surface.red, green: surface.green, blue: surface.blue)
    for preset in OpenNOWThemePreferences.AccentColor.allCases {
        let components = preset.components
        let ink = OpenNOWThemePreferences.legibleAccentComponents(
            red: components.red,
            green: components.green,
            blue: components.blue,
            onSurfaceLuminance: surfaceLuminance
        )
        let ratio = OpenNOWThemePreferences.contrastRatio(
            red: ink.red, green: ink.green, blue: ink.blue,
            againstRed: surface.red, againstGreen: surface.green, againstBlue: surface.blue
        )
        #expect(ratio >= OpenNOWThemePreferences.minimumTextContrastRatio, "\(preset.label) is unreadable as text on a light page")
    }
}

/// Dark mode must keep the accent exactly as it ships: the ink treatment is a light-page fix, not a
/// change to the look everyone already has.
@MainActor @Test func theAccentInkIsTheUntouchedAccentOnADarkPage() {
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(brightness(of: OpenNOWDesign.accentInk) == brightness(of: OpenNOWDesign.accent))
    withAppearance(.light) {
        #expect(brightness(of: OpenNOWDesign.accentInk) < brightness(of: OpenNOWDesign.accent))
    }
}

/// A wash is not symmetric: white at 38% over a near-black page is a soft grey, while black at 38%
/// over a near-white page is a heavy smear. The light palette carries the same request at half
/// weight so an illustration or a hover state keeps the same visual weight in both appearances.
@MainActor private func alpha(of color: Color) -> Double {
    Double((NSColor(color).usingColorSpace(.sRGB) ?? .black).alphaComponent)
}

@MainActor @Test func aWashCarriesLessInkOnALightPageThanOnADarkOne() {
    OpenNOWDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(abs(alpha(of: OpenNOWDesign.Fill.neutral(0.38)) - 0.38) < 0.01)
    withAppearance(.light) {
        #expect(abs(alpha(of: OpenNOWDesign.Fill.neutral(0.38)) - 0.38 * OpenNOWDesign.Fill.lightWashScale) < 0.01)
    }
}
