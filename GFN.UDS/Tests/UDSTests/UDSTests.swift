import Foundation
import Testing
@testable import UDS

private struct MockUDSTransport: UDSHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://uds.example")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func udsUseCasesMatchVendorEvidence() {
    #expect(UDS.systemName == "UDS")
    #expect(UDS.UseCase.endOfSessionReport.rawValue == "UdsEndOfSessionReport")
    #expect(UDS.UseCase.summonedReport.rawValue == "UdsSummonedReport")
    #expect(UDS.UseCase.toastShown.rawValue == "UDSToastShown")
    #expect(UDS.UseCase.suggestionFeedback.rawValue == "UDSSuggestionFeedback")
    #expect(UDS.UseCase.dialogShown.rawValue == "UDSDialogShown")
    #expect(UDS.LaunchSource.mall.rawValue == "Mall")
    #expect(UDS.TriggerSource.notification.rawValue == "Notification")
}

@Test func udsBuildsAuthenticatedJsonRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let request = try #require(UDSRequestFactory.request(path: "/report", method: "POST", accessToken: "access", body: ["source": "Mall"], configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/report")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody != nil)
}

@Test func udsBuildsVendorReportRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let payload = UDSReportPayload(source: .mall, locale: "en_US", deviceId: "device", sessionId: "session", sessionDurationInSeconds: 30, isVPN: true)
    let request = try #require(UDSRequestFactory.reportRequest(useCase: .endOfSessionReport, payload: payload, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/report?serviceUseCase=UdsEndOfSessionReport")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["source"] as? String == "Mall")
    #expect(json["isVPN"] as? Bool == true)
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
    let service = UDSService(
        configuration: UDSConfiguration(serverURLString: "https://uds.example"),
        transport: MockUDSTransport { request in
            #expect(request.url?.absoluteString == "https://uds.example/report?serviceUseCase=UdsSummonedReport")
            #expect(request.httpMethod == "GET")
            return ["reports": [["streamedAppName": "Game", "sessionId": "session", "recommendationList": [["id": "one"]]]]]
        },
        notificationState: UDSNotificationState(canShowIcon: true, hasNotification: true)
    )
    let report = try await service.fetchSummonedReport(payload: UDSReportPayload(source: .notification), accessToken: "access")
    #expect(report.streamedAppName == "Game")
    #expect(report.recommendationCount == 1)
    #expect(await service.notificationState.toastShown)
}
