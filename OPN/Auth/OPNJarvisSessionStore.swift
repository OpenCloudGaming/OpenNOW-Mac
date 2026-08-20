
final class OPNJarvisSessionStore: JarvisSessionStore, @unchecked Sendable {
    static let shared = OPNJarvisSessionStore()

    private let authServiceProvider: () -> any AuthSessionPersisting

    init(authServiceProvider: @escaping () -> any AuthSessionPersisting = { OPNAuthService.shared }) {
        self.authServiceProvider = authServiceProvider
    }

    func loadSession() async throws -> JarvisSession {
        authServiceProvider().loadSavedSession()
    }

    func saveSession(_ session: JarvisSession) async throws {
        authServiceProvider().saveSession(session)
    }

    func clearSession() async throws {
        authServiceProvider().clearSession()
    }

    func loadUserInfo() async throws -> JarvisUserInfo {
        let session = authServiceProvider().loadSavedSession()
        guard session.isAuthenticated else { return JarvisUserInfo() }
        return JarvisUserInfo(
            userId: session.userId,
            idpId: session.idpId,
            displayName: session.displayName,
            email: session.email,
            isAuthenticated: true,
            isNetworkCall: false
        )
    }

    func saveUserInfo(_ userInfo: JarvisUserInfo) async throws {
        authServiceProvider().saveUserInfo(userInfo)
    }

    func clearUserInfo() async throws {
        authServiceProvider().clearUserInfo()
    }
}
