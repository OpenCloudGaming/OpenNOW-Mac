import Foundation
import Testing
@testable import OpenNOW

@Suite("OAuth error messages")
struct OAuthErrorMessageTests {
    @Test("Form-encoded spaces are decoded in callback values")
    func decodesPlusAsSpace() {
        let params = JarvisSessionParser.parseQueryString("error_description=Error+in+idp+callback&state=xyz&error=invalid_request")
        #expect(params["error_description"] == "Error in idp callback")
        #expect(params["error"] == "invalid_request")
        #expect(params["state"] == "xyz")
    }

    @Test("Percent encoding still decodes, and encoded plus survives")
    func decodesPercentEncoding() {
        let params = JarvisSessionParser.parseQueryString("error_description=scope%20is%20required&token=a%2Bb")
        #expect(params["error_description"] == "scope is required")
        #expect(params["token"] == "a+b")
    }

    @Test("Starfleet parses callback values the same way")
    func starfleetParsesFormEncoding() {
        let params = StarfleetTokenParser.parseQueryString("error_description=Error+in+idp+callback")
        #expect(params["error_description"] == "Error in idp callback")
    }

    @Test("NVIDIA diagnostics become recovery steps")
    func mapsNvidiaErrors() {
        #expect(LoginViewModel.signInGuidance(for: "Error in idp callback").contains("SIGN IN WITH A CODE"))
        #expect(LoginViewModel.signInGuidance(for: "idp_id not found").contains("service provider"))
        #expect(LoginViewModel.signInGuidance(for: "SCHEMA_VIOLATION").contains("Language & Region"))
        #expect(LoginViewModel.signInGuidance(for: "access_denied") == "Sign-in was cancelled before NVIDIA finished.")
    }

    @Test("Unknown errors pass through unchanged")
    func passesThroughUnknownErrors() {
        #expect(LoginViewModel.signInGuidance(for: "Browser sign-in timed out") == "Browser sign-in timed out")
    }
}
