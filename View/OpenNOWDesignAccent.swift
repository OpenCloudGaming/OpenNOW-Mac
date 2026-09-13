import SwiftUI

/// How a chosen accent preset becomes the colours the app paints with: the value for the page it
/// is drawn on, its lightened and ink variants, what to write on top of it, and the bright value
/// that artwork-backed surfaces keep whatever the appearance.
extension OpenNOWDesign {
    nonisolated(unsafe) static var resolvedAccent = color(OpenNOWThemePreferences.AccentColor.cloudGreen.components)
    nonisolated(unsafe) static var resolvedAccentSoft = color(OpenNOWThemePreferences.AccentColor.cloudGreen.components)
    nonisolated(unsafe) static var resolvedAccentInk = color(OpenNOWThemePreferences.AccentColor.cloudGreen.components)
    nonisolated(unsafe) static var resolvedOnAccent = Color.black

    static func color(_ components: (red: Double, green: Double, blue: Double)) -> Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }

    /// The chosen preset, resolved for the page it is drawn on: the shipping bright value on a dark
    /// page, its deeper twin on a light one, where the bright value would glare.
    static var accent: Color { resolvedAccent }

    /// The lightened accent, for text and glyphs that sit beside an accent fill.
    static var accentSoft: Color { resolvedAccentSoft }

    /// The accent as TEXT, guaranteed to clear the contrast floor against the page behind it.
    static var accentInk: Color { resolvedAccentInk }

    /// What to write ON an accent fill: black over the bright accent, white over the deep one.
    static var onAccent: Color { resolvedOnAccent }

    /// For the few controls that have to compensate for the appearance rather than just take a
    /// colour from it - a native control whose own chrome does not follow this palette.
    static var isLightAppearance: Bool { !isDarkPalette }

    /// Both halves of the theme feed this, so each of them calls it rather than resolving a colour
    /// the other half has already moved out from under.
    static func resolveAccentColors() {
        let components = appliedAccent.components(isDark: isDarkPalette)
        resolvedAccent = color(components)
        resolvedAccentSoft = color(lightenedAccentComponents(red: components.red, green: components.green, blue: components.blue))
        resolvedAccentInk = accentInkColor(components: components)
        resolvedOnAccent = isDarkPalette ? .black : Fixed.ink(0.96)
        brightAccent = color(appliedAccent.components)
    }

    /// The light twin already clears the floor by construction; this keeps the guarantee true for
    /// any preset added later whose twin is too bright to read against the page.
    static func accentInkColor(components: (red: Double, green: Double, blue: Double)) -> Color {
        guard !isDarkPalette else { return color(components) }
        let surface = OpenNOWThemePreferences.lightPaletteTokens.surfaceApp
        let legible = OpenNOWThemePreferences.legibleAccentComponents(
            red: components.red,
            green: components.green,
            blue: components.blue,
            onSurfaceLuminance: OpenNOWThemePreferences.relativeLuminance(red: surface.red, green: surface.green, blue: surface.blue)
        )
        return color(legible)
    }

    static func applyAccent(_ preset: OpenNOWThemePreferences.AccentColor) {
        appliedAccent = preset
        resolveAccentColors()
    }
}
