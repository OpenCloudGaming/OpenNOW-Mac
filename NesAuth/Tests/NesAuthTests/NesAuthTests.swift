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

@Test func nesAuthMapsVendorAuthorizationPolicy() {
    let policy = NesAuthorizationPolicy()
    #expect(policy.result(authType: "JWT_GFN").state == .authorized)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "NVB_R_USER_IS_NOT_ENTITLED").state == .notEntitled)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "351").launchStatus == .notEntitled)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "NVB_R_NETWORK_ERROR").launchStatus == .failed)
}
