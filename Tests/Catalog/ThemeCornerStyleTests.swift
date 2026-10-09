import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Corner style preference and the semantic geometry it drives: the storage contract (raw
/// values, the Square fallback, the key) and the one policy every app-owned fill, border, clip and
/// focus outline resolves through.
@Suite(.serialized) struct ThemeCornerStyleTests {
    private static let allRoles: [OPNDesign.CornerRole] = [.control, .tile, .card, .panel, .callToAction]

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
    /// opened the setting draws exactly the geometry the app shipped - including a call to action,
    /// which is a rectangle there rather than a pill.
    @Test func squareIsZeroForEveryRoleAtEveryScale() {
        for role in Self.allRoles {
            for scale in [0.5, 1, 1.25, 1.5] as [CGFloat] {
                #expect(OPNDesign.Corner.geometry(role, style: .square, scale: scale) == .radius(0))
            }
        }
    }

    /// The Rounded metrics are resolved centrally. Pinned by value so a later edit to one role is a
    /// deliberate, reviewed change rather than drift.
    @Test func roundedUsesTheSemanticRoleMetrics() {
        #expect(OPNDesign.Corner.geometry(.control, style: .rounded) == .radius(6))
        #expect(OPNDesign.Corner.geometry(.tile, style: .rounded) == .radius(6))
        #expect(OPNDesign.Corner.geometry(.card, style: .rounded) == .radius(10))
        #expect(OPNDesign.Corner.geometry(.panel, style: .rounded) == .radius(12))
        #expect(OPNDesign.Corner.geometry(.callToAction, style: .rounded) == .capsule)
    }

    @Test func roundedScalesOnce() {
        #expect(OPNDesign.Corner.geometry(.card, style: .rounded, scale: 1.5) == .radius(15))
        #expect(OPNDesign.Corner.geometry(.control, style: .rounded, scale: 0.5) == .radius(3))
    }

    @Test func roundedFallsBackToSquareForAnUnusableScale() {
        for scale in [0, -1, .nan, .infinity] as [CGFloat] {
            #expect(OPNDesign.Corner.geometry(.panel, style: .rounded, scale: scale) == .radius(0))
            #expect(OPNDesign.Corner.geometry(.callToAction, style: .rounded, scale: scale) == .radius(0))
        }
    }

    @Test func theEnvironmentPolicyResolvesTheCallToActionToAPill() {
        #expect(OPNCornerGeometry(style: .rounded).shape(.callToAction).geometry == .capsule)
        #expect(OPNCornerGeometry(style: .square).shape(.callToAction).geometry == .radius(0))
    }

    @Test func theEnvironmentPolicyDefaultsToSquare() {
        #expect(OPNCornerGeometry.square.style == .square)
        for role in Self.allRoles {
            #expect(OPNCornerGeometry.square.shape(role).geometry == .radius(0))
        }
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

    @MainActor @Test func aCallToActionFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a call to action") { pillShape }
    }

    /// A capsule is not a radius, so the shape has to resolve it per rect: half the shorter side.
    /// The inset is read from the arc's first fully covered row, so it lands a few points inside
    /// half the height - hence the tolerance, which is still far tighter than any radius role.
    @MainActor @Test func aCallToActionDrawsAPillInRoundedAndARectangleInSquare() throws {
        let height: CGFloat = 60
        let square = try #require(render(clippedShape(role: .callToAction, height: height, style: .square)))
        let rounded = try #require(render(clippedShape(role: .callToAction, height: height, style: .rounded)))
        let panel = try #require(render(clippedShape(role: .panel, height: height, style: .rounded)))
        let squareInset = try #require(cornerInset(of: square))
        let roundedInset = try #require(cornerInset(of: rounded))
        let panelInset = try #require(cornerInset(of: panel))
        #expect(squareInset == 0, "a call to action must stay square in Square")
        #expect(abs(roundedInset - height / 2) <= 4, "a call to action is not a pill, measured \(roundedInset)")
        #expect(roundedInset > panelInset * 2, "a call to action is no rounder than a panel radius")
    }

    /// The pill with no geometry of its own, so the caller supplies the environment.
    @MainActor
    private var pillShape: some View {
        Color.white
            .frame(width: 120, height: 30)
            .opnCornerClip(role: .callToAction)
            .background(Color.black)
    }

    @MainActor
    private func clippedShape(role: OPNDesign.CornerRole, height: CGFloat, style: OPNThemePreferences.CornerStyle) -> some View {
        Color.white
            .frame(width: 120, height: height)
            .opnCornerClip(role: role)
            .environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))
            .background(Color.black)
    }

    /// The top-row inset of the bright shape on an opaque black background. A pill's inset is half
    /// its height, which is what separates a capsule from any radius.
    private func cornerInset(of image: NSImage) -> CGFloat? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let isInside: (Int, Int) -> Bool = { x, y in
            (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.5
        }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where isInside(x, y) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        for x in minX...maxX where isInside(x, minY) { return CGFloat(x - minX) / 2 }
        return nil
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

    /// Every shared style on its own, not one composite: a single style falling back to square is
    /// exactly the failure a composite probe would hide.
    @MainActor @Test func everySharedButtonStyleFollowsTheCornerGeometry() throws {
        for sample in sharedButtonSamples {
            try expectGeometryIsVisible(sample.name) { sample.button }
        }
    }

    @MainActor @Test func aPosterTileFollowsTheCornerGeometry() throws {
        try expectGeometryIsVisible("a poster tile") { posterTile }
    }

    /// Visual evidence for the surfaces the setting was reported missing on, and for every shared
    /// button style.
    @MainActor @Test func thePosterAndButtonsRenderInBothStyles() throws {
        for style in OPNThemePreferences.CornerStyle.allCases {
            let poster = try #require(render(posterTile.environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))))
            writeSnapshot(poster, name: "corner-style-poster-\(style.rawValue).png")
            let buttons = try #require(render(buttonStack(style: style)))
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

    /// The control-radius style and every call-to-action style, each one labelled so the probe and
    /// the evidence figure read the same list.
    @MainActor
    private var sharedButtonSamples: [(name: String, button: AnyView)] {
        [
            ("the compact row action", AnyView(Button("Compact") {}.buttonStyle(OPNCompactButtonStyle(role: .primary, uiScale: 1)))),
            ("the modal secondary", AnyView(Button("Cancel") {}.buttonStyle(OPNModalSecondaryButtonStyle(uiScale: 1)))),
            ("the modal destructive", AnyView(Button("Delete") {}.buttonStyle(OPNModalDestructiveButtonStyle(uiScale: 1)))),
            ("the vendor get-in", AnyView(Button("Play") {}.buttonStyle(VendorGetInButtonStyle(size: .large, uiScale: 1)))),
            ("the vendor get-in regular", AnyView(Button("Play") {}.buttonStyle(VendorGetInButtonStyle(uiScale: 1)))),
            ("the launch primary", AnyView(Button("Launch") {}.buttonStyle(VendorLaunchPrimaryButtonStyle()))),
            ("the launch secondary", AnyView(Button("Cancel") {}.buttonStyle(VendorLaunchSecondaryButtonStyle()))),
            ("the ownership primary", AnyView(Button("Get") {}.buttonStyle(CatalogOwnershipPrimaryButtonStyle(uiScale: 1)))),
            ("the ownership secondary", AnyView(Button("Own") {}.buttonStyle(CatalogOwnershipSecondaryButtonStyle(uiScale: 1)))),
            ("the session banner", AnyView(Button("Resume") {}.buttonStyle(VendorActiveSessionBannerButtonStyle(primary: true)))),
        ]
    }

    @MainActor
    private func buttonStack(style: OPNThemePreferences.CornerStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sharedButtonSamples.enumerated()), id: \.offset) { _, sample in
                Text(sample.name)
                    .font(.caption)
                    .foregroundStyle(.white)
                sample.button
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color.black)
        .environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))
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
