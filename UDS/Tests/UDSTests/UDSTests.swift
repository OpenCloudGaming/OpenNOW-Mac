import Foundation
import Testing
@testable import UDS

@Test func udsUseCasesMatchVendorEvidence() {
    #expect(UDS.systemName == "UDS")
    #expect(UDS.UseCase.endOfSessionReport.rawValue == "UdsEndOfSessionReport")
    #expect(UDS.UseCase.summonedReport.rawValue == "UdsSummonedReport")
    #expect(UDS.UseCase.toastShown.rawValue == "UDSToastShown")
    #expect(UDS.UseCase.suggestionFeedback.rawValue == "UDSSuggestionFeedback")
    #expect(UDS.UseCase.dialogShown.rawValue == "UDSDialogShown")
}

@Test func udsBuildsAuthenticatedJsonRequest() throws {
    let configuration = UDSConfiguration(serverURLString: "https://uds.example")
    let request = try #require(UDSRequestFactory.request(path: "/report", method: "POST", accessToken: "access", body: ["source": "Mall"], configuration: configuration))
    #expect(request.url?.absoluteString == "https://uds.example/report")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody != nil)
}
