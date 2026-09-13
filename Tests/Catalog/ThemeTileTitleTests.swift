import Testing
@testable import OpenNOW

@Test func onHoverShowsTheTitleOnlyWhileHoveringOrSelected() {
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .onHover, isHovering: false, isSelected: false) == false)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .onHover, isHovering: true, isSelected: false) == true)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .onHover, isHovering: false, isSelected: true) == true)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .onHover, isHovering: true, isSelected: true) == true)
}

@Test func alwaysShowsTheTitleAtRestAndInEveryOtherState() {
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .always, isHovering: false, isSelected: false) == true)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .always, isHovering: true, isSelected: false) == true)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .always, isHovering: false, isSelected: true) == true)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .always, isHovering: true, isSelected: true) == true)
}

@Test func neverWithholdsTheTitleEvenWhileHoveringOrSelected() {
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .never, isHovering: false, isSelected: false) == false)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .never, isHovering: true, isSelected: false) == false)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .never, isHovering: false, isSelected: true) == false)
    #expect(OpenNOWThemePreferences.showsTileTitle(visibility: .never, isHovering: true, isSelected: true) == false)
}

/// The picker in Settings maps `allCases` by index, so the case order is a UI contract and the raw
/// values are what a stored preference survives a rename by.
@Test func everyTileTitleModeNamesItselfAndTheRawValuesAreStable() {
    let labels = OpenNOWThemePreferences.TileTitleVisibility.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OpenNOWThemePreferences.TileTitleVisibility.allCases == [.onHover, .always, .never])
    #expect(OpenNOWThemePreferences.TileTitleVisibility.allCases.map(\.rawValue) == ["onHover", "always", "never"])
}

@Test func theTileTitleVisibilityIsStoredInTheInterfaceNamespace() {
    #expect(OpenNOWThemePreferences.tileTitleVisibilityKey == "OpenNOW.Interface.TileTitles")
    #expect(OpenNOWThemePreferences.tileTitleVisibilityKey.hasPrefix("OpenNOW.Interface."))
}

@Test func anUnknownStoredTileTitleValueFallsBackToOnHover() {
    #expect(OpenNOWThemePreferences.TileTitleVisibility(rawValue: "jellyfish") ?? .onHover == .onHover)
    #expect(OpenNOWThemePreferences.TileTitleVisibility(rawValue: "") ?? .onHover == .onHover)
}
