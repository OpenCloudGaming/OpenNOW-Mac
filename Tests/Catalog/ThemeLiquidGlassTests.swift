import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Liquid Glass preference and the policy every eligible surface resolves through: the storage
/// contract, the capability and accessibility gate, the NEW row, and the flat path it falls back to.
@Suite(.serialized) struct ThemeLiquidGlassTests {
    private static let requestedOnUnsupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: false, isReduceTransparency: false
    )
    private static let requestedWithReduceTransparency = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: true
    )

    /// The two treatments the rollout converts: the shared control skin and the shared panel backing.
    enum EligibleSurface: String, CaseIterable, Sendable {
        case control
        case panel
    }

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

    /// An upgrade must not turn glass on for anyone, so a key that was never written reads false.
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

    /// The namespace is what carries the choice across Macs, so the key has to sit under it.
    @Test func thePreferenceIsStoredUnderTheInterfaceKey() {
        #expect(OPNThemePreferences.isLiquidGlassEnabledKey == "OpenNOW.Interface.LiquidGlass")
        #expect(OPNCloudSyncSettingsRegistry.isSyncable(OPNThemePreferences.isLiquidGlassEnabledKey))
    }

    // MARK: - The effective policy

    /// The OS floor is written down once, so the settings row and every surface agree on it.
    @Test func thePolicyNamesTheOSFloorOnce() {
        if #available(macOS 26.0, *) {
            #expect(OPNLiquidGlassPolicy.isSupportedOnThisMac)
            #expect(OPNLiquidGlassPolicy.off.isSupported)
            return
        }
        #expect(!OPNLiquidGlassPolicy.isSupportedOnThisMac)
        #expect(!OPNLiquidGlassPolicy.off.isSupported)
    }

    @Test func theDefaultPolicyIsOff() {
        #expect(!OPNLiquidGlassPolicy.off.isRequested)
        #expect(!OPNLiquidGlassPolicy.off.isEffective)
    }

    @Test func glassIsDrawnOnlyWhenEveryConditionHolds() {
        #expect(OPNLiquidGlassPolicy.requestedOnSupportedMac.isEffective)
        #expect(!Self.requestedOnUnsupportedMac.isEffective)
        #expect(!Self.requestedWithReduceTransparency.isEffective)
        #expect(!OPNLiquidGlassPolicy(isRequested: false, isSupported: true, isReduceTransparency: false).isEffective)
    }

    /// The grid repaints when the policy value changes, so each fact has to be part of its identity.
    @Test func everyFactIsPartOfThePolicyIdentity() {
        #expect(OPNLiquidGlassPolicy.requestedOnSupportedMac != .off)
        #expect(OPNLiquidGlassPolicy.requestedOnSupportedMac != Self.requestedOnUnsupportedMac)
        #expect(OPNLiquidGlassPolicy.requestedOnSupportedMac != Self.requestedWithReduceTransparency)
    }

    // MARK: - NEW badge and search

    /// The badge counts on the Look tab, where the row lives.
    @MainActor @Test func theRowIsAssignedToLook() {
        #expect(SettingsNewBadges.group(for: .liquidGlass) == .theme)
    }

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

    // MARK: - The settings row

    /// The row renders in all three states a reader can meet, including on-but-not-in-effect.
    @MainActor @Test func theSettingsRowRendersInEveryState() throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let states: [(name: String, isOn: Bool, isInert: Bool)] = [
            ("off", false, false),
            ("on", true, false),
            ("on-inert", true, true),
        ]
        for state in states {
            let image = try #require(GlassEvidence.renderOffscreen(settingsRow(isOn: state.isOn, isInert: state.isInert)), "\(state.name) did not render")
            #expect(image.size.width > 0)
            writeSnapshot(image, name: "liquid-glass-row-\(state.name).png")
        }
    }

    // MARK: - The flat path

    /// The flat path is one treatment, not three: Off, an unsupported Mac and Reduce Transparency draw
    /// the same pixels, and turning the material on swaps it without a relayout.
    @MainActor @Test(arguments: EligibleSurface.allCases)
    func anIneligiblePolicyDrawsTheSameFlatSurface(surface: EligibleSurface) throws {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let offImage = try #require(GlassEvidence.renderOffscreen(view(for: surface, policy: .off)))
        let unsupportedImage = try #require(GlassEvidence.renderOffscreen(view(for: surface, policy: Self.requestedOnUnsupportedMac)))
        let suppressedImage = try #require(GlassEvidence.renderOffscreen(view(for: surface, policy: Self.requestedWithReduceTransparency)))
        let glassImage = try #require(GlassEvidence.renderOffscreen(view(for: surface, policy: .requestedOnSupportedMac)))

        #expect(pngData(offImage) == pngData(unsupportedImage), "an unsupported Mac did not draw the flat treatment")
        #expect(pngData(offImage) == pngData(suppressedImage), "Reduce Transparency did not draw the flat treatment")
        #expect(offImage.size == glassImage.size, "the glass policy changed the surface's layout")
    }

    // MARK: - Fixtures

    @MainActor @ViewBuilder
    private func view(for surface: EligibleSurface, policy: OPNLiquidGlassPolicy) -> some View {
        switch surface {
        case .control: control(policy: policy)
        case .panel: panel(policy: policy)
        }
    }

    /// One eligible control: the shape every converted control call site draws.
    @MainActor
    private func control(policy: OPNLiquidGlassPolicy) -> some View {
        Text("Resume")
            .font(.opnUI(size: 12, weight: .bold))
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .opnLiquidGlassChrome(
                role: .control,
                fill: OPNDesign.Fill.neutral(0.08),
                stroke: OPNDesign.Stroke.regular,
                isInteractive: true
            )
            .environment(\.opnLiquidGlass, policy)
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
            .opnLiquidGlassChrome(
                role: .panel,
                fill: OPNDesign.Surface.panelRaised,
                stroke: OPNDesign.Stroke.regular
            )
            .environment(\.opnLiquidGlass, policy)
            .padding(20)
            .background(Color.black)
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

    // MARK: - The legibility scrim

    /// The scrim darkens the material a surface over video or over a scrim cannot darken by itself,
    /// and it is contained by the surface's own outline. Unclipped it reached past the rounded
    /// material, so every scrimmed panel wore a black ring: its square corners were painted over the
    /// page, and the panel's shadow — cast from what the view actually draws — squared off with it.
    ///
    /// Composited, because the material and the scrim are drawn by the window server: the two captures
    /// differ only in whether the scrim is there, so the corner outside the rounded shape must come
    /// back unchanged while the surface's own interior is darkened.
    @MainActor @Test(.enabled(if: GlassEvidence.isGlassCaptureAvailable))
    func theScrimIsContainedByTheSurfaceShape() async throws {
        let scrimmed = try await GlassEvidence.captureInWindow(
            scrimProbe(scrim: OPNLiquidGlass.legibilityScrim),
            over: scrimBackdrop,
            size: Self.scrimStageSize,
            named: "liquid-glass-scrim.png"
        )
        let bare = try await GlassEvidence.captureInWindow(
            scrimProbe(scrim: nil),
            over: scrimBackdrop,
            size: Self.scrimStageSize,
            named: "liquid-glass-scrim-none.png"
        )

        let wedge = scrimmed.meanAbsoluteDifference(from: bare, in: Self.scrimCornerWedge)
        let interior = scrimmed.meanAbsoluteDifference(from: bare, in: Self.scrimInterior)

        #expect(wedge < 3, "the scrim painted outside the surface's shape: corner delta \(wedge)")
        #expect(interior > 10, "the scrim stopped darkening the surface: interior delta \(interior)")
    }

    private static let scrimStageSize = CGSize(width: 400, height: 300)
    /// The 300x200 probe is centred in the stage, so its rounded box starts at (50, 50). The wedge is
    /// the couple of points inside that box and outside the `panel` radius; the interior is the
    /// middle of it.
    private static let scrimCornerWedge = CGRect(x: 51.0 / 400, y: 51.0 / 300, width: 2.0 / 400, height: 2.0 / 300)
    private static let scrimInterior = CGRect(x: 190.0 / 400, y: 140.0 / 300, width: 20.0 / 400, height: 20.0 / 300)

    /// Bounded to the stage: the bright backdrop's own ideal size is taller than the window, and a
    /// capture that let it through measured a stage the probe was not centred in.
    private var scrimBackdrop: some View {
        BrightGlassBackdrop().frame(width: Self.scrimStageSize.width, height: Self.scrimStageSize.height)
    }

    /// A `panel`-role glass surface with the corner geometry the setting draws, over the bright
    /// backdrop. No flat fill: in the glass path the only thing that can differ between the two
    /// captures is the scrim.
    @MainActor
    private func scrimProbe(scrim: Color?) -> some View {
        Color.clear
            .frame(width: 300, height: 200)
            .opnLiquidGlassChrome(
                role: .panel,
                fill: OPNDesign.Surface.panelRaised,
                stroke: OPNDesign.Stroke.regular,
                glassScrim: scrim
            )
            .environment(\.opnLiquidGlass, .requestedOnSupportedMac)
            .environment(\.opnCornerGeometry, OPNCornerGeometry(style: .rounded))
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
