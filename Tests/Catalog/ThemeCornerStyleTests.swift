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

    // MARK: - The environment reaches every shape

    /// Each of these renders one surface twice with only the corner geometry changed, so a failure
    /// means SwiftUI stopped resolving the environment where that surface reads it. That is the bug
    /// this family exists for: a `Shape` never sees `@Environment`, which left every fill, border and
    /// clip square no matter what the preference said.
    @MainActor
    private func expectGeometryIsVisible(
        _ surface: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        @ViewBuilder content: () -> some View
    ) throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let square = try #require(render(content().environment(\.opnCornerGeometry, OPNCornerGeometry(style: .square))), "\(surface) did not render")
        let rounded = try #require(render(content().environment(\.opnCornerGeometry, OPNCornerGeometry(style: .rounded))), "\(surface) did not render")
        #expect(square.size == rounded.size, "\(surface) changed layout instead of geometry", sourceLocation: sourceLocation)
        #expect(pngData(square) != pngData(rounded), "\(surface) did not follow the corner geometry", sourceLocation: sourceLocation)
    }

    @MainActor @Test func aFillFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a fill") {
            Color.clear
                .frame(width: 120, height: 60)
                .background(OPNCornerShape(role: .control).fill(OPNDesign.accent))
        }
    }

    @MainActor @Test func aBorderFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a border") {
            Color.clear
                .frame(width: 120, height: 60)
                .overlay { OPNCornerShape(role: .control).strokeBorder(OPNDesign.accent, lineWidth: 2) }
        }
    }

    @MainActor @Test func aClipFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a clip") {
            Color.white
                .frame(width: 120, height: 60)
                .opnCornerClip(role: .control)
        }
    }

    /// The button label is the case a `Shape` cannot serve: SwiftUI resolves a `Button`'s label and
    /// its `ButtonStyle` body in their own contexts, and the environment has to reach both.
    @MainActor @Test func aButtonLabelFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a button label") {
            Button {} label: {
                Text("Play")
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(OPNCornerShape(role: .control).fill(OPNDesign.accent))
            }
            .buttonStyle(.opnPressable)
        }
    }

    @MainActor @Test func theSharedButtonStylesFollowTheCornerGeometry() throws {
        try expectGeometryIsVisible("the shared button styles") { buttonStack }
    }

    @MainActor @Test func aPosterTileFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a poster tile") { posterTile }
    }

    /// Visual evidence for the two surfaces the setting was reported missing on.
    @MainActor @Test func thePosterAndButtonsRenderInBothStyles() throws {
        for style in OPNThemePreferences.CornerStyle.allCases {
            let poster = try #require(render(posterTile.environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))))
            writeSnapshot(poster, name: "corner-style-poster-\(style.rawValue).png")
            let buttons = try #require(render(buttonStack.environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))))
            writeSnapshot(buttons, name: "corner-style-buttons-\(style.rawValue).png")
        }
    }

    @MainActor
    private var posterTile: some View {
        CatalogPosterTile(
            game: posterGame,
            imageURL: nil,
            isSelected: true,
            isSelectionActive: true,
            isQueuedForPatching: false,
            isResumableSession: false,
            showsFreeAccountAccessBadges: false,
            onSelect: {},
            onPlay: {},
            onMarkOwned: {},
            onQueueForPatching: {}
        )
        .environment(\.opnUIScale, 1)
        .frame(width: 260, height: 400)
        .background(Color.black)
    }

    @MainActor
    private var buttonStack: some View {
        VStack(spacing: 12) {
            Button("Compact") {}
                .buttonStyle(OPNCompactButtonStyle(role: .primary, uiScale: 1))
            Button("Modal secondary") {}
                .buttonStyle(OPNModalSecondaryButtonStyle(uiScale: 1))
            Button("Get in") {}
                .buttonStyle(VendorGetInButtonStyle(size: .large, uiScale: 1))
        }
        .padding(16)
        .background(Color.black)
    }

    private var posterGame: OPNCatalogGameObject {
        var info = OPNGameInfo()
        info.id = "corner-style-game"
        info.title = "Corner Style Game"
        return OPNCatalogGameObject(game: info)
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
