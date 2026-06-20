import Jarvis

final class OPNJarvisSessionStore: JarvisSessionStore, @unchecked Sendable {
    static let shared = OPNJarvisSessionStore()

    private init() {}

    func loadSession() async throws -> JarvisSession {
        OPNAuthService.shared.loadSavedSession()
    }

    func saveSession(_ session: JarvisSession) async throws {
        OPNAuthService.shared.saveSession(session)
    }

    func clearSession() async throws {
        OPNAuthService.shared.clearSession()
    }

    func loadUserInfo() async throws -> JarvisUserInfo {
        let session = OPNAuthService.shared.loadSavedSession()
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
        OPNAuthService.shared.saveUserInfo(userInfo)
    }

    func clearUserInfo() async throws {
        OPNAuthService.shared.clearUserInfo()
    }
}
