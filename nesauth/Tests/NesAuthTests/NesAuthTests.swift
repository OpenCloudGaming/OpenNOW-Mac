import Testing
@testable import NesAuth

@Test func nesAuthNamesMatchVendorNames() {
    #expect(NesAuth.systemName == "NES Auth")
    #expect(NesAuth.ElementName.auth.rawValue == "gfn-nes-auth")
    #expect(NesAuth.uiServiceName == "gfn/NesAuthUIService")
    #expect(NesAuth.errorRouteName == "streamerError/nesAuthError")
    #expect(NesAuth.Operation.getServiceUrls.rawValue == "NES_Get_ServiceUrls")
    #expect(NesAuth.Operation.getClientStreamingQuality.rawValue == "NES_GetClientStreamingQuality")
    #expect(NesAuth.LaunchStatus.autoAuthorization.rawValue == "NesAutoAuthorization")
}
