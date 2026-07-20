import Testing
@testable import MacForceNow

struct OPNSentryFailedRequestFilterTests {
    @Test func dropsAutoCapturedCloudMatchSessionServerErrors() {
        #expect(OPNSentry.shouldDropAutoCapturedHTTPClientError(
            exceptionTypes: ["HTTPClientError"],
            exceptionValues: ["HTTP Client Error with status code: 500"],
            requestURL: "https://us-texas.cloudmatchbeta.nvidiagrid.net/v2/session"
        ))
    }

    @Test func keepsCloudMatchSessionClientErrors() {
        #expect(!OPNSentry.shouldDropAutoCapturedHTTPClientError(
            exceptionTypes: ["HTTPClientError"],
            exceptionValues: ["HTTP Client Error with status code: 400"],
            requestURL: "https://us-texas.cloudmatchbeta.nvidiagrid.net/v2/session"
        ))
    }

    @Test func keepsNonCloudMatchFailedRequests() {
        #expect(!OPNSentry.shouldDropAutoCapturedHTTPClientError(
            exceptionTypes: ["HTTPClientError"],
            exceptionValues: ["HTTP Client Error with status code: 500"],
            requestURL: "https://api.example.com/v2/session"
        ))
    }

    @Test func keepsRealExceptions() {
        #expect(!OPNSentry.shouldDropAutoCapturedHTTPClientError(
            exceptionTypes: ["Swift.Error"],
            exceptionValues: ["HTTP Client Error with status code: 500"],
            requestURL: "https://us-texas.cloudmatchbeta.nvidiagrid.net/v2/session"
        ))
    }
}
