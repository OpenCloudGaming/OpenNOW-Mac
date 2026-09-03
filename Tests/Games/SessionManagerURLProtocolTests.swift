import Foundation
import Testing
@testable import OpenNOW

// The wildcard handler used to claim every path, which meant it answered - and asserted against -
// requests belonging to whichever test had just finished. That produced a failure attributed to
// "«unknown»", because a URLProtocol runs outside any test's scope, and it only appeared when the
// timing lined up. These pin the scoping that stops it.

@Test func aWildcardHandlerServesOnlyThePathsItDeclared() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql"]) { _ in
            SessionManagerURLProtocol.response(json: ["data": [:]])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        var expected = URLRequest(url: try #require(URL(string: "https://games.geforce.com/graphql")))
        expected.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: expected)

        // Only that the handler saw its own request. Asserting no strays at all would be asserting
        // that no other test leaked one, which is the very thing this scoping exists to tolerate.
        #expect(SessionManagerURLProtocol.recordedRequests(host: host).count == 1)
    }
}

@Test func aRequestOnAnUndeclaredPathNeverReachesTheHandler() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql"]) { _ in
            // The bug this guards: another test's CloudMatch request landing here and being
            // answered with a GraphQL body, or failing this test's expectations as if it were its own.
            Issue.record("A request the handler never declared reached it.")
            return SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let foreign = URLRequest(url: try #require(URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo")))
        let result = try? await URLSession.shared.data(for: foreign)

        #expect(result == nil, "the stray is refused rather than served")
        #expect(SessionManagerURLProtocol.recordedRequests(host: host).isEmpty, "and never counted as this test's traffic")
        #expect(SessionManagerURLProtocol.strayRequestSummaries().contains("GET prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo"))
    }
}

@Test func anUndeclaredPathIsRefusedRatherThanSentToTheRealHost() async throws {
    // Claiming it is the point: leaving it unclaimed sent a test's stray traffic to NVIDIA, which
    // is slow, needs a network, and depends on what the vendor happens to answer.
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host, paths: ["/graphql"]) { _ in
            SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let foreign = URLRequest(url: try #require(URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo")))
        let started = Date()
        _ = try? await URLSession.shared.data(for: foreign)

        #expect(Date().timeIntervalSince(started) < 2, "answered locally, not resolved and dialled")
    }
}

@Test func anamedHostHandlerIsNotPathScoped() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "named-scope.example.test"
        SessionManagerURLProtocol.install(host: host) { _ in
            SessionManagerURLProtocol.response(json: ["ok": true])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        // The host already scopes it, so any path it serves is its own by construction.
        _ = try? await URLSession.shared.data(from: try #require(URL(string: "https://named-scope.example.test/anything/at/all")))

        #expect(SessionManagerURLProtocol.recordedRequests(host: host).count == 1)
    }
}
