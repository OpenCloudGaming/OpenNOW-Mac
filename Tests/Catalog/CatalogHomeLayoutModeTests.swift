import Testing
@testable import OpenNOW

/// The home layout preference: an unknown or empty stored value must never strand the home page
/// with no chosen layout - the page reads the raw value straight out of @AppStorage.
@Test func theHomeLayoutDefaultsToClassicAndAnUnknownValueDoesNotStrandTheHome() {
    #expect(OPNHomeLayout.Mode(rawValue: "jellyfish") ?? .classic == .classic)
    #expect(OPNHomeLayout.Mode(rawValue: "") ?? .classic == .classic)
    #expect(OPNHomeLayout.Mode(rawValue: OPNHomeLayout.Mode.classic.rawValue) == .classic)
}

/// The option row maps `allCases` to chips by index, so the case order is a UI contract and the
/// raw values are what a stored preference survives a rename by.
@Test func everyHomeLayoutModeNamesItselfAndTheChipsMatchTheCases() {
    let labels = OPNHomeLayout.Mode.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OPNHomeLayout.Mode.allCases == [.classic, .poster])
    #expect(OPNHomeLayout.Mode.allCases.map(\.rawValue) == ["classic", "poster"])
}

@Test func theHomeLayoutIsStoredInTheInterfaceNamespace() {
    #expect(OPNHomeLayout.modeKey == "OpenNOW.Interface.HomeLayout")
    #expect(OPNHomeLayout.modeKey.hasPrefix("OpenNOW.Interface."))
}
