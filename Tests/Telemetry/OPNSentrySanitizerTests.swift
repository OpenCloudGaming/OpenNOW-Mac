import Testing
@testable import OpenNOW

/// Every log sink funnels through `sanitizedLogMessage`, and all of them are durable: stderr, the
/// diagnostics file that can be uploaded to a public paste service, and Sentry. These pin that
/// credentials are stripped while the identifiers that make a log worth reading survive.
struct OPNSentrySanitizerTests {
    private static let jwt = "eyJhbGciOiJSUzI1NiIsImtpZCI6IngifQ"
        + ".eyJzdWIiOiIxMjM0NSIsImVtYWlsIjoiYUBiLmMifQ"
        + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    /// The OIDC logout is a GET carrying `id_token_hint`, and `OPNNetworkLog` logs the request URL.
    @Test func stripsIdTokenHintFromTheLogoutRequestURL() {
        let sanitized = OPNSentry.sanitizedLogMessage(
            "HTTP request started operation=auth.serverLogout request=GET "
            + "https://login.nvidia.com/logout?id_token_hint=\(Self.jwt)&ui_locales=en_US"
        )
        #expect(!sanitized.contains(Self.jwt))
        #expect(sanitized.contains("id_token_hint=[redacted-secret]"))
        #expect(sanitized.contains("ui_locales=en_US"))
    }

    @Test func stripsBareJSONWebTokensWhateverFieldTheyArriveIn() {
        let sanitized = OPNSentry.sanitizedLogMessage("session idToken=\(Self.jwt) ok")
        #expect(!sanitized.contains(Self.jwt))
        #expect(sanitized.hasSuffix(" ok"))
    }

    @Test func stripsAuthorizationHeaderValues() {
        let sanitized = OPNSentry.sanitizedLogMessage("headers Authorization: Bearer abcdefghijklmnop")
        #expect(!sanitized.contains("abcdefghijklmnop"))
    }

    @Test func stripsCredentialNamedValues() {
        #expect(!OPNSentry.sanitizedLogMessage("refreshToken=1//0abcdefghij").contains("1//0abcdefghij"))
        #expect(!OPNSentry.sanitizedLogMessage("clientSecret: hunter2hunter2").contains("hunter2hunter2"))
    }

    /// Over-redaction costs real debuggability, so the values that are not credentials stay intact.
    @Test func leavesNonCredentialDiagnosticsReadable() {
        let graphQL = "Request finished operation=games hash=3f2a9c1d4b5e6f708192a3b4c5d6e7f8 status=200 duration=91ms"
        #expect(OPNSentry.sanitizedLogMessage(graphQL) == graphQL)
        let stream = "NVST video fps=120 bitrate=45000 rtpLoss=0 decodeFailed=0"
        #expect(OPNSentry.sanitizedLogMessage(stream) == stream)
    }

    @Test func stillRedactsAddresses() {
        #expect(!OPNSentry.sanitizedLogMessage("peer 10.20.30.40:48322").contains("10.20.30.40"))
    }
}
