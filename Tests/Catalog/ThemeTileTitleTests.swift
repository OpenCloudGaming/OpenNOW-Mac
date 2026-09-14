import Testing
@testable import OpenNOW

@Test func onHoverShowsTheTitleOnlyWhileHoveringOrSelected() {
    #expect(OPNThemePreferences.showsTileTitle(visibility: .onHover, isHovering: false, isSelected: false) == false)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .onHover, isHovering: true, isSelected: false) == true)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .onHover, isHovering: false, isSelected: true) == true)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .onHover, isHovering: true, isSelected: true) == true)
}

@Test func alwaysShowsTheTitleAtRestAndInEveryOtherState() {
    #expect(OPNThemePreferences.showsTileTitle(visibility: .always, isHovering: false, isSelected: false) == true)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .always, isHovering: true, isSelected: false) == true)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .always, isHovering: false, isSelected: true) == true)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .always, isHovering: true, isSelected: true) == true)
}

@Test func neverWithholdsTheTitleEvenWhileHoveringOrSelected() {
    #expect(OPNThemePreferences.showsTileTitle(visibility: .never, isHovering: false, isSelected: false) == false)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .never, isHovering: true, isSelected: false) == false)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .never, isHovering: false, isSelected: true) == false)
    #expect(OPNThemePreferences.showsTileTitle(visibility: .never, isHovering: true, isSelected: true) == false)
}

/// The picker in Settings maps `allCases` by index, so the case order is a UI contract and the raw
/// values are what a stored preference survives a rename by.
@Test func everyTileTitleModeNamesItselfAndTheRawValuesAreStable() {
    let labels = OPNThemePreferences.TileTitleVisibility.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OPNThemePreferences.TileTitleVisibility.allCases == [.onHover, .always, .never])
    #expect(OPNThemePreferences.TileTitleVisibility.allCases.map(\.rawValue) == ["onHover", "always", "never"])
}

@Test func theTileTitleVisibilityIsStoredInTheInterfaceNamespace() {
    #expect(OPNThemePreferences.tileTitleVisibilityKey == "OpenNOW.Interface.TileTitles")
    #expect(OPNThemePreferences.tileTitleVisibilityKey.hasPrefix("OpenNOW.Interface."))
}

@Test func anUnknownStoredTileTitleValueFallsBackToOnHover() {
    #expect(OPNThemePreferences.TileTitleVisibility(rawValue: "jellyfish") ?? .onHover == .onHover)
    #expect(OPNThemePreferences.TileTitleVisibility(rawValue: "") ?? .onHover == .onHover)
}
