import Testing
@testable import OpenNOW

/// The home layout preference: an unknown or empty stored value must never strand the home page
/// with no chosen layout - the page reads the raw value straight out of @AppStorage.
@Test func theHomeLayoutDefaultsToClassicAndAnUnknownValueDoesNotStrandTheHome() {
    #expect(OpenNOWHomeLayout.Mode(rawValue: "jellyfish") ?? .classic == .classic)
    #expect(OpenNOWHomeLayout.Mode(rawValue: "") ?? .classic == .classic)
    #expect(OpenNOWHomeLayout.Mode(rawValue: OpenNOWHomeLayout.Mode.classic.rawValue) == .classic)
}

/// The option row maps `allCases` to chips by index, so the case order is a UI contract and the
/// raw values are what a stored preference survives a rename by.
@Test func everyHomeLayoutModeNamesItselfAndTheChipsMatchTheCases() {
    let labels = OpenNOWHomeLayout.Mode.allCases.map(\.label)
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(OpenNOWHomeLayout.Mode.allCases == [.classic, .poster])
    #expect(OpenNOWHomeLayout.Mode.allCases.map(\.rawValue) == ["classic", "poster"])
}

@Test func theHomeLayoutIsStoredInTheInterfaceNamespace() {
    #expect(OpenNOWHomeLayout.modeKey == "OpenNOW.Interface.HomeLayout")
    #expect(OpenNOWHomeLayout.modeKey.hasPrefix("OpenNOW.Interface."))
}
