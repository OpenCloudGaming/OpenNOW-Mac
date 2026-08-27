import Foundation
import Testing
@testable import OpenNOW

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval

    init(value: TimeInterval) { stored = value }

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        stored += delta
        lock.unlock()
    }
}

@Suite(.serialized) struct SessionProxyTests {
    private func validSettings() -> OPNSessionProxySettings {
        OPNSessionProxySettings(isEnabled: true, scheme: .http, host: "proxy.example.com", port: "3128", username: "")
    }

    @Test func validHostAndPortProduceConfiguration() {
        let configuration = OPNSessionProxyStore.configuration(from: validSettings(), password: "")
        #expect(configuration?.host == "proxy.example.com")
        #expect(configuration?.port == 3128)
        #expect(configuration?.scheme == .http)
    }

    @Test func trimsWhitespaceAroundHostAndPort() {
        var settings = validSettings()
        settings.host = "  proxy.example.com  "
        settings.port = " 8080 "
        let configuration = OPNSessionProxyStore.configuration(from: settings, password: "")
        #expect(configuration?.host == "proxy.example.com")
        #expect(configuration?.port == 8080)
    }

    @Test func rejectsEmptyHostAndEmbeddedScheme() {
        var settings = validSettings()
        settings.host = ""
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "") == nil)
        settings.host = "http://proxy.example.com"
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "") == nil)
        settings.host = "proxy.example.com/path"
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "") == nil)
    }

    @Test func rejectsInvalidPorts() {
        for port in ["", "0", "65536", "-1", "abc", "80.0"] {
            var settings = validSettings()
            settings.port = port
            #expect(OPNSessionProxyStore.configuration(from: settings, password: "") == nil)
        }
        var settings = validSettings()
        settings.port = "1"
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "") != nil)
        settings.port = "65535"
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "") != nil)
    }

    @Test func rejectsPasswordWithoutUsername() {
        let configuration = OPNSessionProxyStore.configuration(from: validSettings(), password: "secret")
        #expect(configuration == nil)
    }

    @Test func httpConfigurationBuildsProxyDictionary() {
        var settings = validSettings()
        settings.username = "user"
        let configuration = OPNSessionProxyStore.configuration(from: settings, password: "pass")
        let dictionary = configuration?.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesHTTPEnable] as? NSNumber == 1)
        #expect(dictionary?[kCFNetworkProxiesHTTPProxy] as? String == "proxy.example.com")
        #expect(dictionary?[kCFNetworkProxiesHTTPPort] as? NSNumber == 3128)
        #expect(dictionary?[kCFNetworkProxiesHTTPSEnable] as? NSNumber == 1)
        #expect(dictionary?[kCFNetworkProxiesHTTPSProxy] as? String == "proxy.example.com")
        #expect(dictionary?[kCFNetworkProxiesHTTPSPort] as? NSNumber == 3128)
        #expect(dictionary?[kCFProxyUsernameKey] as? String == "user")
        #expect(dictionary?[kCFProxyPasswordKey] as? String == "pass")
    }

    @Test func socks5ConfigurationBuildsProxyDictionaryWithoutCredentials() {
        var settings = validSettings()
        settings.scheme = .socks5
        let configuration = OPNSessionProxyStore.configuration(from: settings, password: "")
        let dictionary = configuration?.connectionProxyDictionary
        #expect(dictionary?[kCFNetworkProxiesSOCKSEnable] as? NSNumber == 1)
        #expect(dictionary?[kCFNetworkProxiesSOCKSProxy] as? String == "proxy.example.com")
        #expect(dictionary?[kCFNetworkProxiesSOCKSPort] as? NSNumber == 3128)
        #expect(dictionary?[kCFProxyUsernameKey] == nil)
        #expect(configuration?.credential == nil)
    }

    @Test func credentialsProduceProxyAuthorizationHeader() {
        var settings = validSettings()
        #expect(OPNSessionProxyStore.configuration(from: settings, password: "")?.proxyAuthorizationHeader == nil)
        settings.username = "user"
        let header = OPNSessionProxyStore.configuration(from: settings, password: "pass")?.proxyAuthorizationHeader
        #expect(header == "Basic \("user:pass".data(using: .utf8)!.base64EncodedString())")
    }

    @Test func proxiedSessionCarriesProxyAuthorizationHeader() async {
        await withPreservedProxySettings {
            var settings = validSettings()
            settings.username = "user"
            OPNSessionProxyStore.save(settings)
            OPNSessionProxyStore.savePassword("pass")
            let provider = OPNSessionProxySessionProvider()
            let headers = provider.controlPlaneURLSession().configuration.httpAdditionalHeaders as? [String: String]
            #expect(headers?["Proxy-Authorization"] == "Basic \("user:pass".data(using: .utf8)!.base64EncodedString())")
        }
    }

    @Test func cacheKeyChangesWithCredentials() {
        var settings = validSettings()
        let anonymous = OPNSessionProxyStore.configuration(from: settings, password: "")
        settings.username = "user"
        let authenticated = OPNSessionProxyStore.configuration(from: settings, password: "pass")
        let otherPassword = OPNSessionProxyStore.configuration(from: settings, password: "other")
        #expect(anonymous?.cacheKey != authenticated?.cacheKey)
        #expect(authenticated?.cacheKey != otherPassword?.cacheKey)
    }

    @Test func credentialsProduceURLCredential() {
        var settings = validSettings()
        settings.username = "user"
        let configuration = OPNSessionProxyStore.configuration(from: settings, password: "pass")
        #expect(configuration?.credential?.user == "user")
        #expect(configuration?.credential?.password == "pass")
    }

    @Test func fallsBackToDirectOnRetryableStatusCodes() {
        #expect(OPNSessionProxySessionProvider.directFallbackStatuses == [407, 408, 425, 429, 500, 502, 503, 504])
        #expect(!OPNSessionProxySessionProvider.directFallbackStatuses.contains(200))
        #expect(!OPNSessionProxySessionProvider.directFallbackStatuses.contains(404))
    }

    @Test func fallsBackToDirectOnNetworkErrorsOnly() {
        let retryable: [URLError.Code] = [.cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .timedOut, .dnsLookupFailed]
        for code in retryable {
            #expect(OPNSessionProxySessionProvider.shouldFallbackToDirect(after: URLError(code)))
        }
        #expect(OPNSessionProxySessionProvider.shouldFallbackToDirect(after: URLError(.userAuthenticationRequired)))
        #expect(!OPNSessionProxySessionProvider.shouldFallbackToDirect(after: URLError(.badServerResponse)))
        #expect(!OPNSessionProxySessionProvider.shouldFallbackToDirect(after: URLError(.cancelled)))
        struct NonNetworkError: Error {}
        #expect(!OPNSessionProxySessionProvider.shouldFallbackToDirect(after: NonNetworkError()))
    }

    @Test func providerUsesDirectSessionWhenProxyDisabled() async {
        await withPreservedProxySettings {
            OPNSessionProxyStore.save(OPNSessionProxySettings())
            let provider = OPNSessionProxySessionProvider()
            #expect(provider.controlPlaneURLSession() === URLSession.shared)
        }
    }

    @Test func providerUsesProxiedSessionWhenConfigured() async {
        await withPreservedProxySettings {
            OPNSessionProxyStore.save(validSettings())
            OPNSessionProxyStore.savePassword("")
            let provider = OPNSessionProxySessionProvider()
            #expect(provider.controlPlaneURLSession() !== URLSession.shared)
        }
    }

    @Test func failureCooldownRoutesDirectlyUntilExpiry() async {
        await withPreservedProxySettings {
            OPNSessionProxyStore.save(validSettings())
            OPNSessionProxyStore.savePassword("")
            let clock = MutableClock(value: 1_000)
            let provider = OPNSessionProxySessionProvider(now: { clock.value })
            #expect(provider.controlPlaneURLSession() !== URLSession.shared)
            provider.recordFailure()
            #expect(provider.controlPlaneURLSession() === URLSession.shared)
            clock.advance(by: OPNSessionProxySessionProvider.cooldownDuration - 1)
            #expect(provider.controlPlaneURLSession() === URLSession.shared)
            clock.advance(by: 2)
            #expect(provider.controlPlaneURLSession() !== URLSession.shared)
        }
    }

    @Test func providerReusesSessionPerConfiguration() async {
        await withPreservedProxySettings {
            OPNSessionProxyStore.save(validSettings())
            OPNSessionProxyStore.savePassword("")
            let provider = OPNSessionProxySessionProvider()
            #expect(provider.controlPlaneURLSession() === provider.controlPlaneURLSession())
        }
    }

    @Test func storeRoundTripsSettings() async {
        await withPreservedProxySettings {
            var settings = validSettings()
            settings.scheme = .socks5
            settings.username = "user"
            OPNSessionProxyStore.save(settings)
            #expect(OPNSessionProxyStore.load() == settings)
        }
    }

    @Test func passwordRoundTripsThroughPreferences() async {
        await withPreservedProxySettings {
            guard OPNSessionProxyStore.savePassword("s3cret") else { return }
            #expect(OPNSessionProxyStore.loadPassword() == "s3cret")
            #expect(OPNSessionProxyStore.savePassword(""))
            #expect(OPNSessionProxyStore.loadPassword() == "")
        }
    }

    private func withPreservedProxySettings(_ body: @Sendable () -> Void) async {
        await networkTestIsolationLock.withLock {
        let defaults = UserDefaults.standard
        let keys = [
            "OpenNOW.Stream.SessionProxyEnabled",
            "OpenNOW.Stream.SessionProxyScheme",
            "OpenNOW.Stream.SessionProxyHost",
            "OpenNOW.Stream.SessionProxyPort",
            "OpenNOW.Stream.SessionProxyUsername",
        ]
        let existing = keys.map { defaults.object(forKey: $0) }
        let existingPassword = OPNSessionProxyStore.loadPassword()
        defer {
            for (index, key) in keys.enumerated() {
                if let value = existing[index] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            OPNSessionProxyStore.savePassword(existingPassword)
            OPNSessionProxySessionProvider.shared.resetCooldown()
        }
        body()
        }
    }
}
