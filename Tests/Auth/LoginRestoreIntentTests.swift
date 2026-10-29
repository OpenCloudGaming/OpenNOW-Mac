import Foundation
import SwiftData
import Testing
@testable import OpenNOW

private enum NewAccountHandoff: CaseIterable, Sendable {
    case addAccount, reauthenticateOther
}

private enum FailedRestoreResponse: Int, CaseIterable, Sendable {
    case rejected = 401
    case unavailable = 503

    var requestCount: Int {
        self == .rejected ? 2 : JarvisRetryPolicy.gfnPC.maxRetries + 1
    }
}

@MainActor
private final class LoginRestoreIntentFixture {
    let saved: DetachedAccountTestFixture
    let otherAccount: LoginAccount
    let actions: OPNMainAccountActions
    let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
    let mainTokens: GFNTokenStore.Tokens
    let detachedTokens: GFNTokenStore.Tokens
    private(set) var isRestorePendingAtHandoff = false

    init() throws {
        let saved = try DetachedAccountTestFixture()
        let other = LoginAccount(
            email: "other-\(UUID().uuidString.lowercased())@example.invalid", displayName: "Other owner",
            providerIdpId: "other-provider", providerName: "Other provider", userId: "other-user",
            rememberSession: false, isActive: false
        )
        let context = saved.container.mainContext
        context.insert(other)
        do {
            try context.save()
        } catch {
            saved.tearDown()
            throw error
        }
        saved.login.update(modelContext: context, accounts: [saved.mainAccount, saved.detachedAccount, other], sessions: [saved.mainSession, saved.detachedSession], devices: [])
        saved.detachedSession.expiresAt = .distantPast
        self.saved = saved
        otherAccount = other
        mainTokens = saved.tokens(for: saved.mainSession)
        detachedTokens = saved.tokens(for: saved.detachedSession)
        actions = OPNMainAccountActions(confirmation: OPNConfirmationPresentation(), handoff: handoff)
    }

    func tearDown() {
        saved.login.dismissAccountSwitchNotice()
        handoff.end()
        saved.tearDown()
    }

    func bind() async {
        await actions.bind(login: saved.login).value
    }

    func requestHandoff(_ requested: NewAccountHandoff, isCancelled: Bool) async {
        isRestorePendingAtHandoff = saved.login.isAuthenticating
        switch requested {
        case .addAccount:
            await actions.request(.addAccount)?.value
        case .reauthenticateOther:
            await actions.request(.reauthenticate(.init(account: otherAccount)))?.value
        }
        if isCancelled { saved.login.cancelReauthentication() }
    }

    func beginHandoff(_ requested: NewAccountHandoff, isCancelled: Bool) {
        switch requested {
        case .addAccount:
            saved.login.beginAddAccount()
        case .reauthenticateOther:
            saved.login.beginReauthentication(for: otherAccount)
        }
        if isCancelled { saved.login.cancelReauthentication() }
    }

    func installResponse(_ response: FailedRestoreResponse, beforeFirstResponse: @escaping @MainActor @Sendable () async -> Void = {}) {
        SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
            if SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == 1 {
                let handoffFinished = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await beforeFirstResponse()
                    handoffFinished.signal()
                }
                handoffFinished.wait()
            }
            return SessionManagerURLProtocol.response(
                json: ["error": response == .rejected ? "invalid_grant" : "temporarily_unavailable"],
                status: response.rawValue
            )
        }
    }

    func expectHandoff(_ requested: NewAccountHandoff, isCancelled: Bool) {
        let login = saved.login
        let expectedRequest: LoginSignInRequest = requested == .addAccount ? .addAccount : .reauthenticate(email: otherAccount.email)
        #expect(login.signInRequest == (isCancelled ? nil : expectedRequest))
        if requested == .reauthenticateOther && !isCancelled { #expect(login.reauthAccount === otherAccount) }
        #expect(login.email == (requested == .addAccount ? "" : otherAccount.email))
        #expect(login.selectedProvider.idpId == (requested == .addAccount ? LoginProvider.nvidia.idpId : otherAccount.providerIdpId))
        #expect(login.rememberSession == (requested == .addAccount))
        let expectedMessage = requested == .addAccount || isCancelled ? "" : "\(otherAccount.displayName) is signed out. Sign in again to switch to it."
        #expect(login.validationMessage == expectedMessage)
        #expect(login.successMessage.isEmpty)
        #expect(login.accountSwitchNotice == nil)
        #expect(login.accountChooserReason == nil)
        #expect(!login.isAuthenticating && !login.isLaunchingOAuth)
        #expect(login.activeAccount === saved.mainAccount)
        #expect(login.activeSession === saved.mainSession)
        #expect(saved.mainAccount.isActive && saved.mainSession.isActive)
        #expect(!saved.detachedAccount.isActive && !saved.detachedSession.isActive)
        #expect(saved.tokens(for: saved.mainSession) == mainTokens)
        #expect(saved.tokens(for: saved.detachedSession) == detachedTokens)
        #expect(GFNTokenStore.load(forIdentity: "session.\(saved.detachedSessionID)") == detachedTokens)
        #expect(saved.auth.endedEmails.isEmpty)
    }
}

@MainActor
@Suite struct LoginRestoreIntentTests {
    @Test(.timeLimit(.minutes(1)), arguments: NewAccountHandoff.allCases, FailedRestoreResponse.allCases)
    private func aSuspendedRestoreCannotReplaceANewerDetachedAccountHandoff(_ requested: NewAccountHandoff, _ response: FailedRestoreResponse) async throws {
        try await verifySuspendedRestore(requested, response: response, isNewFlowCancelled: false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: NewAccountHandoff.allCases, FailedRestoreResponse.allCases)
    private func cancellingANewerHandoffDoesNotReviveASuspendedRestore(_ requested: NewAccountHandoff, _ response: FailedRestoreResponse) async throws {
        try await verifySuspendedRestore(requested, response: response, isNewFlowCancelled: true)
    }

    @Test(arguments: NewAccountHandoff.allCases)
    private func aQueuedRestoreCannotStartAfterANewerHandoff(_ requested: NewAccountHandoff) async throws {
        try await verifyQueuedRestore(requested, isNewFlowCancelled: false)
    }

    @Test(arguments: NewAccountHandoff.allCases)
    private func cancellingANewerHandoffDoesNotReviveAQueuedRestore(_ requested: NewAccountHandoff) async throws {
        try await verifyQueuedRestore(requested, isNewFlowCancelled: true)
    }

    private func verifySuspendedRestore(_ requested: NewAccountHandoff, response: FailedRestoreResponse, isNewFlowCancelled: Bool) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try LoginRestoreIntentFixture()
            defer { fixture.tearDown() }
            await fixture.bind()
            fixture.installResponse(response) {
                await fixture.requestHandoff(requested, isCancelled: isNewFlowCancelled)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }

            let restore = fixture.saved.login.restoreAccountSelection(fixture.saved.detachedAccount)
            let generation = fixture.saved.login.loginLaunchGeneration
            await restore.value

            #expect(fixture.saved.login.loginLaunchGeneration > generation)
            #expect(fixture.isRestorePendingAtHandoff)
            fixture.expectHandoff(requested, isCancelled: isNewFlowCancelled)
            let requests = SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com")
            #expect(requests.count == response.requestCount)
            #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/token" })
        }
    }

    private func verifyQueuedRestore(_ requested: NewAccountHandoff, isNewFlowCancelled: Bool) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try LoginRestoreIntentFixture()
            defer { fixture.tearDown() }
            await fixture.bind()
            fixture.installResponse(.rejected)
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }

            let restore = fixture.saved.login.restoreAccountSelection(fixture.saved.detachedAccount)
            let generation = fixture.saved.login.loginLaunchGeneration
            fixture.beginHandoff(requested, isCancelled: isNewFlowCancelled)
            await restore.value

            #expect(fixture.saved.login.loginLaunchGeneration > generation)
            fixture.expectHandoff(requested, isCancelled: isNewFlowCancelled)
            #expect(SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").isEmpty)
        }
    }
}
