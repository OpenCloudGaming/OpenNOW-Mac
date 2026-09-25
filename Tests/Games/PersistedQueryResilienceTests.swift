//  Persisted-query resilience: the apps-endpoint switch and the PersistedQueryNotFound retry.
//

import Testing
import Foundation
@testable import OpenNOW

private struct GraphQLOutcome: @unchecked Sendable {
    let payload: NSDictionary?
    let message: String
    let requestURLs: [URL]
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func persistedQueryNotFoundBody() -> Data {
    try! JSONSerialization.data(withJSONObject: ["errors": [["message": "PersistedQueryNotFound", "extensions": ["code": "PERSISTED_QUERY_NOT_FOUND"]]]])
}

private func runStubbedGraphQL(request: URLRequest, queryHash: String, handler: @escaping SessionManagerURLProtocol.Handler) async -> GraphQLOutcome {
    await networkTestIsolationLock.withLock {
        SessionManagerURLProtocol.install(host: "*", paths: ["/graphql"], handler: handler)
        defer { SessionManagerURLProtocol.uninstall(host: "*") }
        let outcome: GraphQLOutcome = await withCheckedContinuation { continuation in
            OPNGameService.shared.runGraphQLRequest(request, operationName: "panels/MainV2", queryHash: queryHash, variables: ["panelNames": ["MAIN"]] as NSDictionary) { payload, message in
                continuation.resume(returning: GraphQLOutcome(payload: payload, message: message, requestURLs: []))
            }
        }
        let requestURLs = SessionManagerURLProtocol.recordedRequests(host: "*").compactMap { $0.url }
        return GraphQLOutcome(payload: outcome.payload, message: outcome.message, requestURLs: requestURLs)
    }
}

private func persistedQueryRequest() -> URLRequest {
    var request = URLRequest(url: URL(string: "https://stub.invalid/graphql?requestType=panels/MainV2")!)
    request.httpMethod = "GET"
    return request
}

@Test func persistedQueryNotFoundRetriesOnceAndDeliversSecondResponse() async {
    let counter = AttemptCounter()
    let outcome = await runStubbedGraphQL(request: persistedQueryRequest(), queryHash: OPNGameService.panelsHash) { _ in
        if counter.next() == 1 {
            return (400, persistedQueryNotFoundBody())
        }
        return SessionManagerURLProtocol.response(json: ["data": ["panels": [["id": "main-panel", "name": "MAIN", "sections": []]]]])
    }

    #expect(outcome.message.isEmpty)
    #expect(outcome.payload?["panels"] != nil)
    #expect(counter.value == 2)
    #expect(outcome.requestURLs.count == 2)
    #expect(outcome.requestURLs.first == outcome.requestURLs.last)
}

@Test func otherGraphQLErrorsDoNotRetry() async {
    let counter = AttemptCounter()
    let notFoundBody = try! JSONSerialization.data(withJSONObject: ["errors": [["message": "nope", "extensions": ["code": "SOMETHING_ELSE"]]]])
    let outcome = await runStubbedGraphQL(request: persistedQueryRequest(), queryHash: OPNGameService.panelsHash) { _ in
        counter.next()
        return (400, notFoundBody)
    }

    #expect(outcome.message == "GraphQL error (400): nope")
    #expect(counter.value == 1)
    #expect(outcome.requestURLs.count == 1)
}

@Test func inlineQueriesDoNotRetryPersistedQueryNotFound() async {
    let counter = AttemptCounter()
    var request = URLRequest(url: URL(string: "https://stub.invalid/graphql")!)
    request.httpMethod = "POST"
    let outcome = await runStubbedGraphQL(request: request, queryHash: "inline") { _ in
        counter.next()
        return (400, persistedQueryNotFoundBody())
    }

    #expect(outcome.message == "GraphQL error (400): PersistedQueryNotFound")
    #expect(counter.value == 1)
    #expect(outcome.requestURLs.count == 1)
}

@Test func graphQLFailureMessageCarriesVendorDetail() {
    let notFound = persistedQueryNotFoundBody()
    #expect(OPNGameService.graphQLFailureMessage(statusCode: 400, data: notFound) == "GraphQL error (400): PersistedQueryNotFound")

    let expiredToken = try! JSONSerialization.data(withJSONObject: ["errors": [["message": "Invalid or expired token"]]])
    #expect(OPNGameService.graphQLFailureMessage(statusCode: 401, data: expiredToken) == "GraphQL error (401): Invalid or expired token")

    #expect(OPNGameService.graphQLFailureMessage(statusCode: 502, data: Data("bad gateway".utf8)) == "GraphQL error (502)")
    #expect(OPNGameService.graphQLFailureMessage(statusCode: 500, data: nil) == "GraphQL error (500)")
}

@Test func persistedQueryNotFoundClassification() {
    #expect(OPNGameService.isPersistedQueryNotFound(statusCode: 400, data: persistedQueryNotFoundBody()))
    #expect(!OPNGameService.isPersistedQueryNotFound(statusCode: 200, data: persistedQueryNotFoundBody()))
    #expect(!OPNGameService.isPersistedQueryNotFound(statusCode: 400, data: try! JSONSerialization.data(withJSONObject: ["errors": [["message": "other"]]])))
    #expect(!OPNGameService.isPersistedQueryNotFound(statusCode: 400, data: nil))
    #expect(OPNGameService.firstGraphQLErrorCode(data: persistedQueryNotFoundBody()) == "PERSISTED_QUERY_NOT_FOUND")
    #expect(OPNGameService.firstGraphQLErrorCode(data: try! JSONSerialization.data(withJSONObject: ["errors": [["message": "plain", "extensions": ["code": "OTHER"]]]])) == "OTHER")
}
