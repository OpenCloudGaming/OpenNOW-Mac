import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Liquid Glass preference and the effective policy every eligible surface resolves through:
/// the storage contract (default off, the key, both transitions), the capability and accessibility
/// gate, the NEW row's provisional release, and the flat path a surface falls back to whenever the
/// answer is no.
@Suite(.serialized) struct ThemeLiquidGlassTests {
    /// The policy a Mac that asked for glass and can draw it resolves to.
    private static let effective = OPNLiquidGlassPolicy(isRequested: true, isSupported: true, isReduceTransparency: false)

    private func withPreservedPreference<Result>(_ body: () -> Result) -> Result {
        withExclusivePreferenceDomain {
            let key = OPNThemePreferences.isLiquidGlassEnabledKey
            let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
            defer {
                if let previous {
                    OPNAppPreferenceStorage.standard.set(previous, forKey: key)
                } else {
                    OPNAppPreferenceStorage.standard.removeObject(forKey: key)
                }
            }
            return body()
        }
    }

    // MARK: - The preference

    /// An upgrade must not turn glass on for anyone. A key that was never written reads false, so an
    /// installation that never opened this setting keeps the appearance it already had.
    @Test func anInstallationThatNeverChoseGetsFlat() {
        withPreservedPreference {
            OPNAppPreferenceStorage.standard.removeObject(forKey: OPNThemePreferences.isLiquidGlassEnabledKey)
            #expect(OPNThemePreferences.isLiquidGlassEnabled == false)
        }
    }

    @Test func bothTransitionsPersist() {
        withPreservedPreference {
            OPNAppPreferenceStorage.standard.removeObject(forKey: OPNThemePreferences.isLiquidGlassEnabledKey)
            OPNThemePreferences.isLiquidGlassEnabled = true
            #expect(OPNThemePreferences.isLiquidGlassEnabled == true)
            OPNThemePreferences.isLiquidGlassEnabled = false
            #expect(OPNThemePreferences.isLiquidGlassEnabled == false)
        }
    }

    /// The namespace is what carries the choice across Macs through iCloud, so the key has to sit
    /// under it. The effective rendering stays capability- and accessibility-gated locally.
    @Test func thePreferenceIsStoredUnderTheInterfaceKey() {
        #expect(OPNThemePreferences.isLiquidGlassEnabledKey == "OpenNOW.Interface.LiquidGlass")
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(OPNThemePreferences.isLiquidGlassEnabledKey))
    }

    // MARK: - The effective policy

    @Test func glassIsDrawnOnlyWhenAskedForSupportedAndNotSuppressed() {
        #expect(Self.effective.isEffective)
        #expect(!OPNLiquidGlassPolicy.off.isEffective)
        // Asked for, but this Mac cannot draw it.
        #expect(!OPNLiquidGlassPolicy(isRequested: true, isSupported: false, isReduceTransparency: false).isEffective)
        // Asked for and drawable, but the system is asking for less transparency. The stored choice
        // survives; only the rendering is suppressed.
        #expect(!OPNLiquidGlassPolicy(isRequested: true, isSupported: true, isReduceTransparency: true).isEffective)
        // Never asked for, even on a capable Mac.
        #expect(!OPNLiquidGlassPolicy(isRequested: false, isSupported: true, isReduceTransparency: false).isEffective)
    }

    /// Off is the shipping default, and the OS floor is written down once.
    @Test func theDefaultPolicyIsOffAndNamesTheOSFloor() {
        #expect(!OPNLiquidGlassPolicy.off.isRequested)
        #expect(OPNLiquidGlassPolicy.off.isSupported == OPNLiquidGlassPolicy.isSupportedOnThisMac)
        if #available(macOS 26.0, *) {
            #expect(OPNLiquidGlassPolicy.isSupportedOnThisMac)
        }
    }

    /// A policy change is a distinct value, which is what lets the hosted grid repaint in place
    /// instead of reloading, and what lets a root re-inject it without rebuilding stream identity.
    @Test func aPolicyChangeIsADistinctValue() {
        #expect(Self.effective != OPNLiquidGlassPolicy.off)
        #expect(Self.effective == OPNLiquidGlassPolicy(isRequested: true, isSupported: true, isReduceTransparency: false))
    }

    // MARK: - NEW badge

    /// The badge counts on the Look tab, where the row lives.
    @MainActor @Test func theRowIsAssignedToLook() {
        #expect(SettingsNewBadges.group(for: .liquidGlass) == .theme)
    }

    // MARK: - Search

    @MainActor @Test func liquidGlassIsFindableByItsWords() {
        for query in ["glass", "liquid glass", "transparency", "blur", "material"] {
            #expect(
                SettingsSearchIndex.results(for: query).contains { $0.title == "Liquid Glass" },
                "\(query) does not reach Liquid Glass"
            )
        }
        let entry = SettingsSearchIndex.entries.first { $0.title == "Liquid Glass" }
        #expect(entry?.group == .theme)
        #expect(entry?.sectionID == "appearance")
    }

    // MARK: - The flat path

    /// Off, an unsupported Mac, and Reduce Transparency all have to land on the treatment the app
    /// already shipped — the same pixels, not a thin approximation of glass.
    @MainActor @Test func anIneligiblePolicyDrawsTheSameFlatSurface() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let offImage = try #require(render(control(policy: .off)))
        let unsupportedImage = try #require(render(control(policy: OPNLiquidGlassPolicy(
            isRequested: true, isSupported: false, isReduceTransparency: false
        ))))
        let suppressedImage = try #require(render(control(policy: OPNLiquidGlassPolicy(
            isRequested: true, isSupported: true, isReduceTransparency: true
        ))))
        let off = try #require(pngData(offImage))
        #expect(off == pngData(unsupportedImage), "an unsupported Mac did not draw the flat treatment")
        #expect(off == pngData(suppressedImage), "Reduce Transparency did not draw the flat treatment")
    }

    /// Turning the setting on is a material swap, not a relayout: the surface keeps its size, so a
    /// control does not jump when the preference flips.
    @MainActor @Test func enablingGlassKeepsTheSurfaceGeometry() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let flat = try #require(render(control(policy: .off)))
        let glass = try #require(render(control(policy: Self.effective)))
        #expect(flat.size == glass.size, "the glass policy changed the surface's layout")
    }

    /// A panel backing is the same story: one eligible surface, one policy, no layout change.
    @MainActor @Test func aPanelBackingFollowsTheSamePolicy() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let flat = try #require(render(panel(policy: .off)))
        let glass = try #require(render(panel(policy: Self.effective)))
        let unsupported = try #require(render(panel(policy: OPNLiquidGlassPolicy(
            isRequested: true, isSupported: false, isReduceTransparency: false
        ))))
        #expect(flat.size == glass.size)
        #expect(pngData(flat) == pngData(unsupported))
    }

    /// The geometry the surface is clipped to is the semantic corner shape, so square stays square
    /// and rounded stays rounded with glass on.
    @MainActor @Test func anEnabledGlassSurfaceFollowsTheCornerGeometry() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let square = try #require(render(control(policy: Self.effective, style: .square)))
        let rounded = try #require(render(control(policy: Self.effective, style: .rounded)))
        #expect(square.size == rounded.size)
        // The flat path is where a shape is drawn into the bitmap, so the geometry is checked there.
        let flatSquare = try #require(render(control(policy: .off, style: .square)))
        let flatRounded = try #require(render(control(policy: .off, style: .rounded)))
        #expect(pngData(flatSquare) != pngData(flatRounded), "the flat path stopped following the corner geometry")
    }

    // MARK: - The settings row

    /// The row renders in all three states a reader can meet: off, on, and on-but-not-in-effect on a
    /// Mac that cannot draw glass — the last one is what `SettingsToggleRow.isInert` exists for.
    @MainActor @Test func theSettingsRowRendersInEveryState() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let states: [(name: String, isOn: Bool, isInert: Bool)] = [
            ("off", false, false),
            ("on", true, false),
            ("on-inert", true, true),
        ]
        for state in states {
            let image = try #require(render(settingsRow(isOn: state.isOn, isInert: state.isInert)), "\(state.name) did not render")
            #expect(image.size.width > 0)
            writeSnapshot(image, name: "liquid-glass-row-\(state.name).png")
        }
    }

    @MainActor
    private func settingsRow(isOn: Bool, isInert: Bool) -> some View {
        SettingsToggleRow(
            title: "Liquid Glass",
            subtitle: "Use Liquid Glass for selected controls and navigation on macOS 26 or later. Off by default. Native macOS window and popover appearance is controlled by the system.",
            isOn: isOn,
            isNew: true,
            isInert: isInert,
            uiScale: 1
        ) { _ in }
        .padding(16)
        .frame(width: 720, alignment: .leading)
        .background(OPNDesign.Surface.panel)
        .environment(\.opnSettingsNarrowRows, false)
    }

    private func writeSnapshot(_ image: NSImage, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["OPN_SNAPSHOT_DIR"],
              let png = pngData(image) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    // MARK: - Fixtures

    /// One eligible control: the shape every converted call site draws, with the policy the caller
    /// under test supplies.
    @MainActor
    private func control(policy: OPNLiquidGlassPolicy, style: OPNThemePreferences.CornerStyle = .square) -> some View {
        Text("Resume")
            .font(.opnUI(size: 12, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .opnLiquidGlassChrome(role: .control, scale: 1, isInteractive: true) {
                OPNCornerShape(role: .control, scale: 1).fill(OPNDesign.Fill.neutral(0.08))
            }
            .environment(\.opnLiquidGlass, policy)
            .environment(\.opnCornerGeometry, OPNCornerGeometry(style: style))
            .padding(20)
            .background(Color.black)
    }

    /// One eligible panel: the shared dropdown backing's treatment.
    @MainActor
    private func panel(policy: OPNLiquidGlassPolicy) -> some View {
        Text("Change game store")
            .font(.opnUI(size: 12, weight: .medium))
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(12)
            .frame(width: 200, alignment: .leading)
            .opnLiquidGlassChrome(role: .panel, scale: 1) {
                ZStack {
                    OPNCornerShape(role: .panel, scale: 1).fill(OPNDesign.Surface.panelRaised)
                    OPNCornerShape(role: .panel, scale: 1).strokeBorder(OPNDesign.Stroke.regular, lineWidth: 1)
                }
            }
            .environment(\.opnLiquidGlass, policy)
            .padding(20)
            .background(Color.black)
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
}
