import Testing
@testable import Starfleet

@Test func starfleetEndpointNamesMatchVendorBackend() {
    #expect(Starfleet.systemName == "Starfleet")
    #expect(Starfleet.Endpoint.token.urlString == "https://login.nvidia.com/token")
    #expect(Starfleet.Endpoint.clientToken.urlString == "https://login.nvidia.com/client_token")
    #expect(Starfleet.GrantType.clientToken.rawValue == "urn:ietf:params:oauth:grant-type:client_token")
}
