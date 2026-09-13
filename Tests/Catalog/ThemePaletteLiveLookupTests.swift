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
