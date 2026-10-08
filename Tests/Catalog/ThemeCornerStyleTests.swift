import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Corner style preference and the semantic geometry it drives. The preference is a storage and
/// UI contract - stable raw values, a Square fallback, and the Interface key namespace - and the
/// geometry is the single policy every app-owned fill, border, clip and focus outline resolves
/// through.
@Suite struct ThemeCornerStyleTests {
    private let allRoles: [OPNDesign.CornerRole] = [.control, .tile, .card, .panel]

    @Test func theShippingDefaultIsSquare() {
        #expect(OPNThemePreferences.CornerStyle(rawValue: "square") == .square)
        #expect(OPNThemePreferences.CornerStyle.allCases.first == .square)
    }

    @Test func anUnknownOrMissingStoredValueFallsBackToSquare() {
        #expect(OPNThemePreferences.CornerStyle(rawValue: "rounded ") ?? .square == .square)
        #expect(OPNThemePreferences.CornerStyle(rawValue: "") ?? .square == .square)
        #expect(OPNThemePreferences.CornerStyle(rawValue: "ROUNDED") ?? .square == .square)
        #expect(OPNThemePreferences.CornerStyle(rawValue: "Rounded") ?? .square == .square)
    }

    /// The picker maps `allCases` by index and the raw values are what a stored preference survives
    /// a rename by, so both the order and the raw values are a storage/UI contract.
    @Test func everyStyleNamesItselfAndTheRawValuesAreStable() {
        #expect(OPNThemePreferences.CornerStyle.allCases.map(\.label) == ["Square", "Rounded"])
        #expect(OPNThemePreferences.CornerStyle.allCases.map(\.rawValue) == ["square", "rounded"])
    }

    @Test func theStyleIsStoredInTheInterfaceNamespace() {
        #expect(OPNThemePreferences.cornerStyleKey == "OpenNOW.Interface.CornerStyle")
        #expect(OPNThemePreferences.cornerStyleKey.hasPrefix("OpenNOW.Interface."))
    }

    /// Square is radius 0 for every role at every interface scale, so an installation that never
    /// opened the setting draws exactly the geometry the app shipped.
    @Test func squareIsZeroForEveryRoleAndScale() {
        for role in allRoles {
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

    /// The radius is multiplied by the interface scale exactly once, and an unusable scale degrades
    /// to square rather than producing a NaN path.
    @Test func roundedScalesOnceAndRejectsAnUnusableScale() {
        #expect(OPNDesign.Corner.radius(.card, style: .rounded, scale: 1.5) == 15)
        #expect(OPNDesign.Corner.radius(.control, style: .rounded, scale: 0.5) == 3)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: 0) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: -1) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: .nan) == 0)
        #expect(OPNDesign.Corner.radius(.panel, style: .rounded, scale: .infinity) == 0)
    }

    /// The environment policy resolves through the same central metrics, and its default is square
    /// so a surface that renders before the root injects anything still sees today's look.
    @Test func theEnvironmentPolicyMirrorsTheCentralMetricsAndDefaultsToSquare() {
        #expect(OPNCornerGeometry.square.style == .square)
        #expect(OPNCornerGeometry.square.radius(.panel) == 0)
        let rounded = OPNCornerGeometry(style: .rounded)
        for role in allRoles {
            #expect(rounded.radius(role, scale: 1) == OPNDesign.Corner.radius(role, style: .rounded, scale: 1))
            #expect(rounded.radius(role, scale: 1.5) == OPNDesign.Corner.radius(role, style: .rounded, scale: 1.5))
        }
    }

    /// A style change is a geometry change over the same palette, not a new theme identity, which is
    /// what lets a corner switch repaint in place instead of rebuilding subtrees.
    @Test func twoStylesAreDistinctGeometryOverTheSameIdentity() {
        #expect(OPNCornerGeometry(style: .square) != OPNCornerGeometry(style: .rounded))
        #expect(OPNCornerGeometry(style: .rounded) == OPNCornerGeometry(style: .rounded))
    }

    /// The preference rides the Interface prefix, so it is backed up and restored with the rest of
    /// the Look settings and needs no registry change.
    @Test func theStyleTravelsWithTheOtherInterfacePreferences() {
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(OPNThemePreferences.cornerStyleKey))
        #expect(!OPNCloudSyncSettingsRegistry.isDenied(OPNThemePreferences.cornerStyleKey))
    }

    /// Corner style is findable by the words a reader would use, and its result targets the card it
    /// actually lives in.
    @MainActor @Test func cornerStyleIsFindableAndTargetsTheAppearanceCard() throws {
        let entry = try #require(SettingsSearchIndex.entries.first { $0.title == "Corner Style" })
        #expect(entry.group == .theme)
        #expect(entry.sectionID == "appearance")
        for query in ["corner", "square", "rounded", "shape"] {
            #expect(
                SettingsSearchIndex.results(for: query).contains { $0.title == "Corner Style" },
                "\(query) does not reach Corner Style"
            )
        }
    }

    // MARK: - Environment reaches the shape

    /// The end-to-end half of the policy: the same view tree, rendered twice with only the corner
    /// geometry changed, must produce different pixels. If the environment ever stopped reaching
    /// `OPNCornerShape`, every fill and border in the app would silently fall back to square and
    /// this is the test that fails.
    @MainActor @Test func theEnvironmentActuallyReachesTheShape() throws {
        let square = try #require(render(card(style: .square)))
        let rounded = try #require(render(card(style: .rounded)))
        #expect(square.size == rounded.size, "the two styles must not change layout")
        #expect(pngData(square) != pngData(rounded), "the corner geometry never reached the shapes")
    }

    /// Visual evidence for the PR: the Appearance card with the Corner Style row in both settings,
    /// at each interface scale, written only when a capture directory was asked for.
    @MainActor @Test func theAppearanceCardRendersInBothStyles() throws {
        for style in OPNThemePreferences.CornerStyle.allCases {
            for scale in [1.0, 1.25, 1.5] as [CGFloat] {
                let image = try #require(render(card(style: style, uiScale: scale)))
                #expect(image.size.width > 0)
                writeSnapshot(image, name: "corner-style-appearance-\(style.rawValue)-s\(scale).png")
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
