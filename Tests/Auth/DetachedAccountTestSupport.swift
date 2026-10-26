import Foundation
import SwiftData
@testable import OpenNOW

final class DetachedRecordingAuthService: LoginAuthServing, @unchecked Sendable {
    private(set) var endedEmails: [String] = []

    func invalidatePendingAuthentication() {}

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "No network in detached-account tests") }
    }

    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "No network in detached-account tests") }
    }

    func endSavedSession(userId: String, email: String) {
        endedEmails.append(email)
    }
}

private final class DetachedProviderInfoService: GameProviderInfoServing, @unchecked Sendable {
    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        Task { @MainActor in completion(false, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "No network in detached-account tests") }
    }
}

@MainActor
final class DetachedAccountTestFixture {
    let container: ModelContainer
    let login: LoginViewModel
    let registry = OPNGameSessionRegistry()
    let auth = DetachedRecordingAuthService()
    let mainAccount: LoginAccount
    let detachedAccount: LoginAccount
    let mainSession: LoginSession
    let detachedSession: LoginSession
    let detachedEmail: String
    let detachedSessionID: String
    private var sessionIDs: [String] = []

    init() throws {
        container = try ModelContainer(
            for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let identity = UUID().uuidString
        mainAccount = makeLoginAccountForTesting(email: "main-\(identity)@example.invalid", userId: "main-\(identity)")
        detachedEmail = "detached-\(identity)@example.invalid"
        detachedAccount = makeLoginAccountForTesting(email: detachedEmail, userId: "detached-\(identity)", isActive: false)
        mainSession = makeLoginSessionForTesting(accountEmail: mainAccount.email, userId: mainAccount.userId)
        detachedSessionID = UUID().uuidString
        detachedSession = makeLoginSessionForTesting(accountEmail: detachedEmail, id: detachedSessionID, userId: detachedAccount.userId)
        detachedSession.isActive = false
        login = LoginViewModel(authService: auth, providerInfoService: DetachedProviderInfoService(), sessionRegistry: registry)
        let context = container.mainContext
        context.insert(mainAccount)
        context.insert(detachedAccount)
        context.insert(mainSession)
        context.insert(detachedSession)
        try context.save()
        login.update(modelContext: context, accounts: [mainAccount, detachedAccount], sessions: [mainSession, detachedSession], devices: [])
        sessionIDs = [mainSession.id, detachedSessionID]
        GFNTokenStore.save(
            .init(accessToken: detachedSession.accessToken, idToken: detachedSession.idToken,
                  refreshToken: detachedSession.refreshToken, clientToken: detachedSession.clientToken),
            forIdentity: "session.\(detachedSessionID)"
        )
    }

    func expireIDTokens() throws {
        for session in [mainSession, detachedSession] {
            let claims: [String: Any] = ["sub": session.userId, "email": session.accountEmail, "exp": 1]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            session.idToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.\(payload)."
        }
    }

    func tokens(for session: LoginSession) -> GFNTokenStore.Tokens {
        .init(accessToken: session.accessToken, idToken: session.idToken, refreshToken: session.refreshToken, clientToken: session.clientToken)
    }

    func insertReplacementSession(id: String = UUID().uuidString) throws -> LoginSession {
        let replacement = makeLoginSessionForTesting(accountEmail: detachedEmail, id: id, userId: detachedAccount.userId)
        replacement.isActive = false
        sessionIDs.append(replacement.id)
        container.mainContext.insert(replacement)
        try container.mainContext.save()
        return replacement
    }

    func tearDown() {
        for id in sessionIDs { GFNTokenStore.delete(forIdentity: "session.\(id)") }
    }
}

actor SuspendedDetachedRefresh {
    enum Failure: Error {
        case unavailable
    }

    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<JarvisSession, Error>?
    private var input: JarvisSession?

    func refresh(_ session: JarvisSession) async throws -> JarvisSession {
        input = session
        started?.resume()
        started = nil
        return try await withCheckedThrowingContinuation { completion = $0 }
    }

    func waitUntilStarted() async {
        guard input == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete(isSuccessful: Bool = true, replacementUserID: String? = nil) {
        guard var session = input else { return }
        defer { completion = nil }
        guard isSuccessful else {
            completion?.resume(throwing: Failure.unavailable)
            return
        }
        session.accessToken = "refreshed-access"
        session.idToken = "refreshed-id"
        session.refreshToken = "refreshed-refresh"
        session.clientToken = "refreshed-client"
        if let replacementUserID { session.userId = replacementUserID }
        completion?.resume(returning: session)
    }
}
