import Foundation

protocol AuthSessionPersisting {
    func loadSavedSession() -> OPNAuthSession
    func saveSession(_ session: OPNAuthSession)
    func clearSession()
    func saveUserInfo(_ userInfo: JarvisUserInfo)
    func clearUserInfo()
}

public protocol SessionTokenRefreshing: Sendable {
    func refreshSession(forceRefresh: Bool) async throws -> OPNAuthSession
}

extension OPNAuthService: AuthSessionPersisting {}
extension OPNAuthService: SessionTokenRefreshing {}
