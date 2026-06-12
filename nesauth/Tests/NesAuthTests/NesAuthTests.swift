import Testing
@testable import NesAuth

@Test func nesAuthNamesMatchVendorNames() {
    #expect(NesAuth.systemName == "NES Auth")
    #expect(NesAuth.ElementName.auth.rawValue == "gfn-nes-auth")
    #expect(NesAuth.uiServiceName == "gfn/NesAuthUIService")
    #expect(NesAuth.errorRouteName == "streamerError/nesAuthError")
}
