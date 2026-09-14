/// Each appearance now resolves an accent that is already readable on its own page, so the ink and
/// the fill agree - and dark keeps exactly the colour that ships today.
@MainActor @Test func theAccentAndItsInkAgreeOnEveryPage() {
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    let darkAccent = brightness(of: OPNDesign.accent)
    #expect(brightness(of: OPNDesign.accentInk) == darkAccent)
    withAppearance(.light) {
        #expect(brightness(of: OPNDesign.accentInk) == brightness(of: OPNDesign.accent))
        #expect(brightness(of: OPNDesign.accent) < darkAccent, "the light page kept the bright accent")
        // Artwork and video never turn light, so the accent drawn on them does not either.
        #expect(brightness(of: OPNDesign.Fixed.accent) == darkAccent)
    }
}

/// Black reads on the bright accent, white on the deep one; the token has to follow the fill.
@MainActor @Test func theInkOnAnAccentFillFollowsWhichAccentIsUnderIt() {
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(brightness(of: OPNDesign.onAccent) == 0)
    withAppearance(.light) {
        #expect(brightness(of: OPNDesign.onAccent) > 0.9)
    }
}

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

@MainActor private func withAppearance(_ appearance: OPNThemePreferences.Appearance, _ body: () -> Void) {
    OPNDesign.applyAppearance(appearance, systemColorScheme: .dark)
    body()
    OPNDesign.applyAppearance(.dark, systemColorScheme: .dark)
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
    #expect(brightness(of: OPNDesign.Text.primary) > brightness(of: OPNDesign.Surface.app))
    withAppearance(.light) {
        #expect(brightness(of: OPNDesign.Text.primary) < brightness(of: OPNDesign.Surface.app))
    }
}

@MainActor @Test func aNeutralFillWashesAgainstThePageRatherThanAlwaysWhite() {
    let darkFill = brightness(of: OPNDesign.Fill.neutral(0.5))
    withAppearance(.light) {
        #expect(brightness(of: OPNDesign.Fill.neutral(0.5)) < darkFill)
    }
}

/// The palette is pushed from a root view's `body`, so it runs once per body pass on every root.
/// It has to be cheap to call repeatedly and it has to resolve both halves together.
@MainActor @Test func applyingTheSameThemeTwiceIsANoOpButAChangeIsNot() {
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark) == false)
    #expect(OPNDesign.applyTheme(accent: .magenta, appearance: .dark, systemColorScheme: .dark))
    #expect(OPNDesign.applyTheme(accent: .magenta, appearance: .light, systemColorScheme: .dark))
    #expect(brightness(of: OPNDesign.Surface.app) > 0.5, "the light appearance did not reach the surfaces")
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
}

/// Match System has to follow the OS, which is the only case where the system scheme is consulted.
@MainActor @Test func matchSystemFollowsTheOperatingSystemScheme() {
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .system, systemColorScheme: .light)
    #expect(brightness(of: OPNDesign.Surface.app) > 0.5)
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .system, systemColorScheme: .dark)
    #expect(brightness(of: OPNDesign.Surface.app) < 0.5)
}

/// The shipping accents are bright enough to vanish on a light page, so accent-coloured LABELS go
/// through `accentInk`, which darkens until it clears the text contrast floor.
@MainActor @Test func everyAccentStaysReadableAsTextOnALightPage() {
    let surface = OPNThemePreferences.lightPaletteTokens.surfaceApp
    let surfaceLuminance = OPNThemePreferences.relativeLuminance(red: surface.red, green: surface.green, blue: surface.blue)
    for preset in OPNThemePreferences.AccentColor.allCases {
        let components = preset.components
        let ink = OPNThemePreferences.legibleAccentComponents(
            red: components.red,
            green: components.green,
            blue: components.blue,
            onSurfaceLuminance: surfaceLuminance
        )
        let ratio = OPNThemePreferences.contrastRatio(
            red: ink.red, green: ink.green, blue: ink.blue,
            againstRed: surface.red, againstGreen: surface.green, againstBlue: surface.blue
        )
        #expect(ratio >= OPNThemePreferences.minimumTextContrastRatio, "\(preset.label) is unreadable as text on a light page")
    }
}

/// A wash is not symmetric: white at 38% over a near-black page is a soft grey, while black at 38%
/// over a near-white page is a heavy smear. The light palette carries the same request at half
/// weight so an illustration or a hover state keeps the same visual weight in both appearances.
@MainActor private func alpha(of color: Color) -> Double {
    Double((NSColor(color).usingColorSpace(.sRGB) ?? .black).alphaComponent)
}

@MainActor @Test func aWashCarriesLessInkOnALightPageThanOnADarkOne() {
    OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
    #expect(abs(alpha(of: OPNDesign.Fill.neutral(0.38)) - 0.38) < 0.01)
    withAppearance(.light) {
        #expect(abs(alpha(of: OPNDesign.Fill.neutral(0.38)) - 0.38 * OPNDesign.Fill.lightWashScale) < 0.01)
    }
}
