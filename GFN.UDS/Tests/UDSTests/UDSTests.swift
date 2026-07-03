import Foundation
import Testing
@testable import UDS

private actor MockUDSState {
    private(set) var requests: [URLRequest] = []
    private var responses: [(Int, [String: Any])]
    private let thrownError: Error?

    init(responses: [(Int, [String: Any])], thrownError: Error? = nil) {
        self.responses = responses
        self.thrownError = thrownError
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let thrownError, requests.count == 1 { throw thrownError }
        let response = responses.isEmpty ? (200, ["reports": []]) : responses.removeFirst()
        let data = (try? JSONSerialization.data(withJSONObject: response.1)) ?? Data()
        let http = HTTPURLResponse(url: request.url ?? URL(string: "https://uds.example")!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
        return (data, http)
    }
}

private struct MockUDSTransport: UDSHTTPTransport {
    let state: MockUDSState

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await state.send(request)
    }
}

@Test func udsUseCasesMatchVendorEvidence() {
    #expect(UDS.systemName == "UDS")
    #expect(UDS.productionBaseURLString == "https://uds.geforcenow.com")
    #expect(UDS.reportPath == "/v1/uds/session/reports")
    #expect(UDS.UseCase.endOfSessionReport.rawValue == "UdsEndOfSessionReport")
    #expect(UDS.UseCase.summonedReport.rawValue == "UdsSummonedReport")
    #expect(UDS.UseCase.toastShown.rawValue == "UDSToastShown")
    #expect(UDS.UseCase.suggestionFeedback.rawValue == "UDSSuggestionFeedback")
    #expect(UDS.UseCase.dialogShown.rawValue == "UDSDialogShown")
    #expect(UDS.LaunchSource.mall.rawValue == "Mall")
    #expect(UDS.TriggerSource.notification.rawValue == "Notification")
}

@Test func udsDefaultConfigurationMatchesLiveConfig() {
    let configuration = UDSConfiguration.production
    #expect(configuration.serverURLString == "https://uds.geforcenow.com")
    #expect(configuration.headers.clientId == "ec7e38d4-03af-4b58-b131-cfb0495903ab")
    #expect(configuration.retryConfiguration.defaultRetries == 2)
    #expect(configuration.retryConfiguration.defaultTimeoutMilliseconds == 5_000)
    #expect(configuration.retryConfiguration.exponentialBackoffMaxDelayMilliseconds == 5_000)
    #expect(configuration.retryConfiguration.exponentialBackoffFirstRetryIntervalMilliseconds == 4_000)
    #expect(configuration.retryConfiguration.exponentGrowthFactor == 1)
    #expect(configuration.retryConfiguration.timeoutInterval == 5)
}

@Test func udsBuildsAuthenticatedJsonRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example", headers: UDSClientHeaders(clientId: "lcars-client"))
    let request = try #require(UDSRequestFactory.request(path: UDS.reportPath, method: "POST", accessToken: "access", deviceId: "device", body: ["source": "Mall"], configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/v1/uds/session/reports")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "NV-Device-ID") == "device")
    #expect(request.value(forHTTPHeaderField: "NV-Client-ID") == "lcars-client")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody != nil)
}

@Test func udsBuildsVendorEndOfSessionReportRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let payload = UDSReportPayload(source: .endOfSession, locale: "en_US", deviceId: "device", sessionId: "session", sessionDurationInSeconds: 30, isVPN: true)
    let request = try #require(UDSRequestFactory.reportRequest(useCase: .endOfSessionReport, payload: payload, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/v1/uds/session/reports")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "NV-Device-ID") == "device")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["source"] as? String == "EndOfSession")
    #expect(json["locale"] as? String == "en_US")
    #expect(json["sessionId"] as? String == "session")
    #expect(json["sessionDurationInSeconds"] as? Int == 30)
    #expect(json["isVPN"] as? Bool == true)
}

@Test func udsBuildsVendorSummonedReportRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let payload = UDSReportPayload(source: .mall, locale: "en_US", deviceId: "device")
    let request = try #require(UDSRequestFactory.reportRequest(useCase: .summonedReport, payload: payload, accessToken: "access", configuration: configuration))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
    #expect(components.path == "/v1/uds/session/reports")
    #expect(items["source"] == "Mall")
    #expect(items["locale"] == "en_US")
    #expect(items["serviceUseCase"] == nil)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
}

@Test func udsModelsNotificationSnoozeAndDiagnosticReports() {
    let notification = UDSNotificationState(canShowIcon: true, hasNotification: true, toastShown: false).afterSummonedReportOpened()
    #expect(!notification.canShowIcon)
    #expect(!notification.hasNotification)
    #expect(notification.toastShown)

    let policy = UDSSnoozePolicy(durationInDays: 2)
    let start = Date(timeIntervalSince1970: 1_000)
    let stop = policy.stopDate(startingAt: start)
    #expect(policy.isSnoozed(until: stop, now: start.addingTimeInterval(10)))
    #expect(!policy.isSnoozed(until: stop, now: start.addingTimeInterval(200_000)))

    let report = UDSDiagnosticReportParser.parse([
        "reports": [[
            "streamedAppName": "Game",
            "sessionId": "session",
            "errorCode": "NVB_R_NETWORK_ERROR",
            "recommendationList": [["id": "one"], ["id": "two"]],
            "areSAScoresGood": true,
        ]],
    ])
    #expect(report.streamedAppName == "Game")
    #expect(report.sessionId == "session")
    #expect(report.recommendationCount == 2)
    #expect(report.areSAScoresGood)
}

@Test func udsServiceFetchesReportsAndUpdatesNotificationState() async throws {
    let state = MockUDSState(responses: [(200, ["reports": [["streamedAppName": "Game", "sessionId": "session", "recommendationList": [["id": "one"]]]]])])
    let service = UDSService(
        configuration: UDSConfiguration(serverURLString: "https://uds.example"),
        transport: MockUDSTransport(state: state),
        notificationState: UDSNotificationState(canShowIcon: true, hasNotification: true)
    )
    let report = try await service.fetchSummonedReport(payload: UDSReportPayload(source: .notification, locale: "en_US", deviceId: "device"), accessToken: "access")
    let request = try #require(await state.requests.first)
    #expect(request.url?.path == "/v1/uds/session/reports")
    #expect(request.httpMethod == "GET")
    #expect(report.streamedAppName == "Game")
    #expect(report.recommendationCount == 1)
    #expect(await service.notificationState.toastShown)
}

@Test func udsServiceRetriesTransportFailure() async throws {
    let retry = UDSRetryConfiguration(defaultRetries: 1, defaultTimeoutMilliseconds: 10, exponentialBackoffMaxDelayMilliseconds: 1, exponentialBackoffFirstRetryIntervalMilliseconds: 1, exponentGrowthFactor: 0)
    let state = MockUDSState(responses: [(200, ["reports": [["streamedAppName": "Game"]]])], thrownError: URLError(.timedOut))
    let service = UDSService(configuration: UDSConfiguration(serverURLString: "https://uds.example", retryConfiguration: retry), transport: MockUDSTransport(state: state))
    let report = try await service.fetchEndOfSessionReport(payload: UDSReportPayload(source: .endOfSession, deviceId: "device"), accessToken: "access")
    #expect(report.streamedAppName == "Game")
    #expect(await state.requests.count == 2)
}

@Test func udsServiceRetriesServerErrorsButNotAuthErrors() async throws {
    let retry = UDSRetryConfiguration(defaultRetries: 1, defaultTimeoutMilliseconds: 10, exponentialBackoffMaxDelayMilliseconds: 1, exponentialBackoffFirstRetryIntervalMilliseconds: 1, exponentGrowthFactor: 0)
    let serverState = MockUDSState(responses: [(500, ["error": "retry"]), (200, ["reports": [["streamedAppName": "Game"]]])])
    let serverService = UDSService(configuration: UDSConfiguration(serverURLString: "https://uds.example", retryConfiguration: retry), transport: MockUDSTransport(state: serverState))
    let report = try await serverService.fetchEndOfSessionReport(payload: UDSReportPayload(source: .endOfSession, deviceId: "device"), accessToken: "access")
    #expect(report.streamedAppName == "Game")
    #expect(await serverState.requests.count == 2)

    let authState = MockUDSState(responses: [(401, ["error": "auth"])])
    let authService = UDSService(configuration: UDSConfiguration(serverURLString: "https://uds.example", retryConfiguration: retry), transport: MockUDSTransport(state: authState))
    await #expect(throws: UDSServiceError.httpStatus(401)) {
        _ = try await authService.fetchEndOfSessionReport(payload: UDSReportPayload(source: .endOfSession, deviceId: "device"), accessToken: "access")
    }
    #expect(await authState.requests.count == 1)
}

@Test func udsBuildsVendorEventReportRequests() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let payload = UDSReportPayload(source: .notification, locale: "en_US", deviceId: "device", sessionId: "session")
    let request = try #require(UDSRequestFactory.reportRequest(useCase: .toastShown, payload: payload, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/v1/uds/session/reports")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "NV-Device-ID") == "device")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["useCase"] as? String == "UDSToastShown")
    #expect(json["triggerSource"] as? String == "Notification")
    #expect(json["source"] as? String == "Notification")
    #expect(json["sessionId"] as? String == "session")
}

@Test func udsServiceSendsVendorEventReports() async throws {
    let state = MockUDSState(responses: [(200, ["accepted": true])])
    let service = UDSService(configuration: UDSConfiguration(serverURLString: "https://uds.example"), transport: MockUDSTransport(state: state))
    let result = try await service.sendEvent(useCase: .suggestionFeedback, payload: UDSReportPayload(source: .mall, deviceId: "device"), accessToken: "access")
    let request = try #require(await state.requests.first)
    #expect(result.accepted)
    #expect(request.url?.path == "/v1/uds/session/reports")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["useCase"] as? String == "UDSSuggestionFeedback")
}
