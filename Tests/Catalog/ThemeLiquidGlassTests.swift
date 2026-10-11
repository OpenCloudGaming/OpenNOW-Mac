import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

/// The Liquid Glass preference and the policy every eligible surface resolves through: the storage
/// contract, the capability and accessibility gate, the NEW row, and the flat path it falls back to.
@Suite(.serialized) struct ThemeLiquidGlassTests {
    private static let requestedOnSupportedMac = OPNLiquidGlassPolicy(
        isRequested: true, isSupported: true, isReduceTransparency: false
    )
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
        #expect(Self.requestedOnSupportedMac.isEffective)
        #expect(!Self.requestedOnUnsupportedMac.isEffective)
        #expect(!Self.requestedWithReduceTransparency.isEffective)
        #expect(!OPNLiquidGlassPolicy(isRequested: false, isSupported: true, isReduceTransparency: false).isEffective)
    }

    /// The grid repaints when the policy value changes, so each fact has to be part of its identity.
    @Test func everyFactIsPartOfThePolicyIdentity() {
        #expect(Self.requestedOnSupportedMac != .off)
        #expect(Self.requestedOnSupportedMac != Self.requestedOnUnsupportedMac)
        #expect(Self.requestedOnSupportedMac != Self.requestedWithReduceTransparency)
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
            let image = try #require(render(settingsRow(isOn: state.isOn, isInert: state.isInert)), "\(state.name) did not render")
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
        let offImage = try #require(render(view(for: surface, policy: .off)))
        let unsupportedImage = try #require(render(view(for: surface, policy: Self.requestedOnUnsupportedMac)))
        let suppressedImage = try #require(render(view(for: surface, policy: Self.requestedWithReduceTransparency)))
        let glassImage = try #require(render(view(for: surface, policy: Self.requestedOnSupportedMac)))

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
