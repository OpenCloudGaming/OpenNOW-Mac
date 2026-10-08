import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Corner style preference and the semantic geometry it drives: the storage contract (raw
/// values, the Square fallback, the key) and the one policy every app-owned fill, border, clip and
/// focus outline resolves through.
@Suite(.serialized) struct ThemeCornerStyleTests {
    private static let allRoles: [OPNDesign.CornerRole] = [.control, .tile, .card, .panel]

    @Test func anInstallationThatNeverChoseAStyleGetsSquare() {
        withExclusivePreferenceDomain {
            let key = OPNThemePreferences.cornerStyleKey
            let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
            defer {
                if let previous {
                    OPNAppPreferenceStorage.standard.set(previous, forKey: key)
                }
                if previous == nil {
                    OPNAppPreferenceStorage.standard.removeObject(forKey: key)
                }
            }

            OPNAppPreferenceStorage.standard.removeObject(forKey: key)
            #expect(OPNThemePreferences.cornerStyle == .square)

            OPNThemePreferences.cornerStyle = .rounded
            #expect(OPNThemePreferences.cornerStyle == .rounded)
        }
    }

    @Test func aStoredValueThatNamesNoStyleFallsBackToSquare() {
        #expect(OPNThemePreferences.CornerStyle(storedRawValue: "") == .square)
        #expect(OPNThemePreferences.CornerStyle(storedRawValue: "ROUNDED") == .square)
        #expect(OPNThemePreferences.CornerStyle(storedRawValue: "rounded ") == .square)
    }

    @Test func everyStyleNamesItselfWithStableRawValues() {
        #expect(OPNThemePreferences.CornerStyle.allCases.map(\.label) == ["Square", "Rounded"])
        #expect(OPNThemePreferences.CornerStyle.allCases.map(\.rawValue) == ["square", "rounded"])
    }

    @Test func theStyleIsStoredUnderTheInterfaceKey() {
        #expect(OPNThemePreferences.cornerStyleKey == "OpenNOW.Interface.CornerStyle")
    }

    /// Square is radius 0 for every role at every interface scale, so an installation that never
    /// opened the setting draws exactly the geometry the app shipped.
    @Test func squareIsZeroForEveryRoleAtEveryScale() {
        for role in Self.allRoles {
            for scale in [0.5, 1, 1.25, 1.5] as [CGFloat] {
                #expect(OPNDesign.Corner.radius(role, style: .square, scale: scale) == 0)
            }
        }
    }

    /// The Rounded metrics are resolved centrally. Pinned by value so a later edit to one role is a
    /// deliberate, reviewed change rather than drift.
    @Test func roundedUsesTheSemanticRoleMetrics() {
        #expect(OPNDesign.Corner.radius(.control, style: .rounded) == 6)
        #expect(OPNDesign.Corner.radius(.tile, style: .rounded) == 6)
        #expect(OPNDesign.Corner.radius(.card, style: .rounded) == 10)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded) == 12)
    }

    @Test func roundedScalesOnce() {
        #expect(OPNDesign.Corner.radius(.card, style: .rounded, scale: 1.5) == 15)
        #expect(OPNDesign.Corner.radius(.control, style: .rounded, scale: 0.5) == 3)
    }

    @Test func roundedFallsBackToSquareForAnUnusableScale() {
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: 0) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: -1) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: .nan) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: .infinity) == 0)
    }

    @Test func theEnvironmentPolicyMirrorsTheCentralMetrics() {
        let rounded = OPNCornerGeometry(style: .rounded)
        for role in Self.allRoles {
            #expect(rounded.radius(role, scale: 1) == OPNDesign.Corner.radius(role, style: .rounded, scale: 1))
            #expect(rounded.radius(role, scale: 1.5) == OPNDesign.Corner.radius(role, style: .rounded, scale: 1.5))
        }
    }

    @Test func theEnvironmentPolicyDefaultsToSquare() {
        #expect(OPNCornerGeometry.square.style == .square)
        #expect(OPNCornerGeometry.square.radius(.panel) == 0)
    }

    /// A style change is geometry over the same palette, not a new identity, which is what lets a
    /// corner switch repaint in place instead of rebuilding the subtrees keyed on the theme.
    @Test func aStyleChangeIsDistinctGeometryOverTheSameIdentity() {
        #expect(OPNCornerGeometry(style: .square) != OPNCornerGeometry(style: .rounded))
        #expect(OPNCornerGeometry(style: .rounded) == OPNCornerGeometry(style: .rounded))
    }

    @MainActor @Test func cornerStyleIsFindableByItsWords() {
        for query in ["corner", "square", "rounded", "shape"] {
            #expect(
                SettingsSearchIndex.results(for: query).contains { $0.title == "Corner Style" },
                "\(query) does not reach Corner Style"
            )
        }
    }

    // MARK: - Environment reaches the shape

    /// The end-to-end half of the policy: the same view tree rendered twice with only the corner
    /// geometry changed must produce different pixels, or the environment never reached the shape.
    @MainActor @Test func theEnvironmentActuallyReachesTheShape() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let square = try #require(render(card(style: .square)))
        let rounded = try #require(render(card(style: .rounded)))
        #expect(square.size == rounded.size, "the two styles must not change layout")
        #expect(pngData(square) != pngData(rounded), "the corner geometry never reached the shapes")
    }

    /// Visual evidence for the PR: the Appearance card with the Corner Style row in both styles, at
    /// each interface scale and in both palettes, written only when a capture directory was asked
    /// for. The palette is restored after each render so a concurrently rendering suite never sees
    /// the light palette.
    @MainActor @Test func theAppearanceCardRendersInBothStyles() throws {
        defer { OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark) }
        for appearance in [OPNThemePreferences.Appearance.dark, .light] {
            for style in OPNThemePreferences.CornerStyle.allCases {
                for scale in [1.0, 1.25, 1.5] as [CGFloat] {
                    OPNDesign.applyTheme(accent: .cloudGreen, appearance: appearance, systemColorScheme: .dark)
                    let image = try #require(render(card(style: style, uiScale: scale)))
                    #expect(image.size.width > 0)
                    writeSnapshot(image, name: "corner-style-appearance-\(appearance.rawValue)-\(style.rawValue)-s\(scale).png")
                }
            }
        }
    }

    @MainActor
    private func card(style: OPNThemePreferences.CornerStyle, uiScale: CGFloat = 1) -> some View {
        SettingsCard(title: "Appearance", uiScale: uiScale) {
            SettingsOptionRow(
                title: "Appearance",
                subtitle: "Dark, light, or follow the macOS setting.",
                options: ["Match System", "Dark", "Light"],
                selectedIndex: 1,
                uiScale: uiScale
            ) { _ in }
            SettingsDivider(uiScale: uiScale)
            SettingsOptionRow(
                title: "Corner Style",
                subtitle: "Choose square or rounded corners for app controls, cards, and panels.",
                options: ["Square", "Rounded"],
                selectedIndex: style == .rounded ? 1 : 0,
                uiScale: uiScale
            ) { _ in }
            SettingsDivider(uiScale: uiScale)
            HStack(spacing: 10 * uiScale) {
                SettingsActionButton(title: "Apply", uiScale: uiScale) {}
                SettingsActionButton(title: "Cancel", tone: .secondary, uiScale: uiScale) {}
            }
        }
        .frame(width: 1360 * uiScale, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
        .environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))
    }

    @MainActor
    private func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage
    }

    private func pngData(_ image: NSImage) -> Data? {
        image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let png = pngData(image) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }
}
