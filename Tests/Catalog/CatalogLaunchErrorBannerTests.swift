import Testing
import Foundation
@testable import OpenNOW

/// The launch failure a user most needs to read — the seat refused the title — used to be written
/// to `errorMessage`, which doubles as the catalog's transient status line and is cleared by any
/// browse, panel load or action message. On the Show All page that made it flash and vanish.
@Suite @MainActor struct CatalogLaunchErrorBannerTests {
    private func makeModel() -> CatalogViewModel {
        let account = LoginAccount(email: "a@b.c", displayName: "A", providerIdpId: "idp", providerName: "p")
        let session = LoginSession(
            accountEmail: "a@b.c",
            authMethod: "test",
            accessToken: "t",
            clientToken: "c",
            idToken: "i",
            refreshToken: "r",
            deviceId: "d",
            expiresAt: Date().addingTimeInterval(3600),
            clientTokenExpiresAt: Date().addingTimeInterval(3600)
        )
        return CatalogViewModel(account: account, session: session, onRefreshAuth: { true })
    }

    @Test func launchFailureSurvivesATransientMessageClear() {
        let model = makeModel()
        model.reportLaunchFailure("ENTITLEMENT_FAILURE_STATUS 8A91000C")
        #expect(model.displayedErrorMessage == "ENTITLEMENT_FAILURE_STATUS 8A91000C")

        // Any refetch or action message wipes the transient line; the banner must stay.
        model.setActionMessage("Adding to library...")
        #expect(model.errorMessage.isEmpty)
        #expect(model.displayedErrorMessage == "ENTITLEMENT_FAILURE_STATUS 8A91000C")
    }

    @Test func dismissClearsBothMessages() {
        let model = makeModel()
        model.reportLaunchFailure("Seat refused the title.")
        model.dismissLaunchError()
        #expect(model.displayedErrorMessage.isEmpty)
        #expect(model.errorMessage.isEmpty)
        #expect(model.launchErrorMessage.isEmpty)
    }

    @Test func leavingTheResultsPageDropsTheFailure() {
        let model = makeModel()
        model.reportLaunchFailure("Seat refused the title.")
        model.closeShowAll()
        #expect(model.launchErrorMessage.isEmpty)
    }

    @Test func transientMessagesStillWin() {
        let model = makeModel()
        model.errorMessage = "Unable to browse the GeForce NOW catalog."
        #expect(model.displayedErrorMessage == "Unable to browse the GeForce NOW catalog.")
    }
}

/// Entitlement refusals name the seat zone that rejected the launch and must not advise a retry:
/// the same request fails identically until the streaming region changes.
@Suite struct CatalogEntitlementErrorPresentationTests {
    private static let refusal = """
    HTTP 403: {"session":{"sessionId":"5ebbc815-2367-4b26-8067-cf609e7bf072"},"requestStatus":{"countryCode":null,"unifiedErrorCode":-1970208756,"requestId":"25d52964-2a47-45f1-b474-39a9ce5400d3","serverId":"NP-SJC6-06","statusDescription":"ENTITLEMENT_FAILURE_STATUS 8A91000C","statusCode":18}}
    """

    @Test func entitlementFailureNamesTheSeatAndTheFix() {
        let presentation = CatalogErrorPresentation(rawMessage: Self.refusal)
        #expect(presentation.title.contains("NP-SJC6-06"))
        #expect(presentation.title.localizedCaseInsensitiveContains("not licensed"))
        #expect(presentation.hint?.localizedCaseInsensitiveContains("region") == true)
        #expect(presentation.hint?.localizedCaseInsensitiveContains("try again") == false)
        #expect(presentation.technicalDetails == Self.refusal.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func entitlementFailureWithoutAServerIdStillReads() {
        let presentation = CatalogErrorPresentation(rawMessage: "ENTITLEMENT_FAILURE_STATUS 8A91000C")
        #expect(presentation.title.localizedCaseInsensitiveContains("not licensed"))
        #expect(!presentation.title.contains("nil"))
    }

    @Test func unrelatedServiceErrorsKeepTheGenericAdvice() {
        let presentation = CatalogErrorPresentation(rawMessage: "HTTP 400: {\"requestStatus\":{\"statusDescription\":\"INTERNAL_ERROR_STATUS\"}}")
        #expect(!presentation.title.localizedCaseInsensitiveContains("not licensed"))
    }
}
