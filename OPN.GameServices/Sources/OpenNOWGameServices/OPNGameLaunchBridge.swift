import Common
import Foundation

public typealias OPNGameLaunchPlanCompletion = @MainActor @Sendable (_ success: Bool, _ message: String, _ plan: OPNGameLaunchPlan?) -> Void
public typealias OPNGameLaunchSessionStopCompletion = @MainActor @Sendable (_ success: Bool, _ message: String) -> Void

private final class OPNGameLaunchBridgeSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

public struct OPNStreamLaunchConfiguration: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let appId: String
    public let apiToken: String
    public let accountLinked: Bool
    public let selectedStore: String
    public let resumeSessionId: String
    public let resumeServer: String
    public let metadata: [String: String]

    public init(title: String, appId: String, apiToken: String, accountLinked: Bool, selectedStore: String, resumeSessionId: String = "", resumeServer: String = "", metadata: [String: String] = [:]) {
        self.id = UUID()
        self.title = title
        self.appId = appId
        self.apiToken = apiToken
        self.accountLinked = accountLinked
        self.selectedStore = selectedStore
        self.resumeSessionId = resumeSessionId
        self.resumeServer = resumeServer
        self.metadata = metadata
    }
}

public struct OPNActiveStreamSessionDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let appId: Int
    public let serverIp: String
    public let title: String

    public init(sessionId: String, appId: Int, serverIp: String, title: String) {
        self.id = sessionId
        self.appId = appId
        self.serverIp = serverIp
        self.title = title.isEmpty ? "Current Stream" : title
    }
}

public enum OPNGameLaunchPlan: Equatable, Sendable {
    case ready(OPNStreamLaunchConfiguration)
    case activeSession(active: OPNActiveStreamSessionDescriptor, resume: OPNStreamLaunchConfiguration, replacement: OPNStreamLaunchConfiguration)
}

@MainActor
public final class OPNGameLaunchBridge {
    public static let shared = OPNGameLaunchBridge()

    private init() {}

    public func prepareLaunchPlan(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, idpId: String = "", variantIndex: Int, completion: @escaping OPNGameLaunchPlanCompletion) {
        let token = idToken.isEmpty ? accessToken : idToken
        guard !token.isEmpty else {
            completion(false, "Sign in again before launching a game.", nil)
            return
        }

        let selectedVariantIndex = resolvedVariantIndex(for: game, requestedIndex: variantIndex)
        let selectedVariant = selectedVariantIndex >= 0 && selectedVariantIndex < game.variants.count ? game.variants[selectedVariantIndex] : nil
        let isPatching = game.isPatching || selectedVariant?.isPatching == true
        guard !isPatching else {
            completion(false, "GeForce NOW is patching this game. Try again after patching finishes.", nil)
            return
        }
        configureServices(token: token, userId: userId)
        let gameValue = game.swiftValue
        let gameBox = OPNGameLaunchBridgeSendableValue(game)
        OPNGameService.shared.resolveLaunchAppId(game: gameValue, variantIndex: selectedVariantIndex) { [weak self] appId in
            Task { @MainActor in
                guard let self else { return }
                let game = gameBox.value
                let selectedVariant = selectedVariantIndex >= 0 && selectedVariantIndex < game.variants.count ? game.variants[selectedVariantIndex] : nil
                self.prepareResolvedLaunchPlan(game: game, selectedVariant: selectedVariant, appId: appId, token: token, userId: userId, idpId: idpId, completion: completion)
            }
        }
    }

    private func prepareResolvedLaunchPlan(game: OPNCatalogGameObject, selectedVariant: OPNCatalogGameVariantObject?, appId: String, token: String, userId: String, idpId: String, completion: @escaping OPNGameLaunchPlanCompletion) {
        guard let launchAppId = OPNLaunchAppId.resolve(appId) else {
            completion(false, "This game does not include a launchable GeForce NOW app id.", nil)
            return
        }
        let appId = launchAppId.stringValue
        let title = game.title.isEmpty ? "GeForce NOW" : game.title
        let accountLinked = game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true
        let selectedStore = selectedVariant?.appStore ?? ""
        let launchMetadata = Self.launchMetadata(for: game, userId: userId, idpId: idpId)
        let replacement = OPNStreamLaunchConfiguration(
            title: title,
            appId: appId,
            apiToken: token,
            accountLinked: accountLinked,
            selectedStore: selectedStore,
            metadata: launchMetadata
        )
        let streamingBaseUrl = OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: appId)
        let gameBox = OPNGameLaunchBridgeSendableValue(game)
        OPNActiveSessionService.fetchActiveSessions(accessToken: token, streamingBaseUrl: streamingBaseUrl) { [weak self] ok, sessions, _ in
            let sessionsBox = OPNGameLaunchBridgeSendableValue(sessions)
            Task { @MainActor in
                guard let self else { return }
                let game = gameBox.value
                let sessions = sessionsBox.value
                if ok {
                    if let requestedSession = sessions.first(where: { self.activeSession($0, matches: game, appId: appId) }) {
                        completion(true, "Resuming \(title)...", .ready(OPNStreamLaunchConfiguration(
                            title: title,
                            appId: requestedSession.appId > 0 ? String(requestedSession.appId) : appId,
                            apiToken: token,
                            accountLinked: true,
                            selectedStore: "",
                            resumeSessionId: requestedSession.sessionId,
                            resumeServer: requestedSession.serverIp,
                            metadata: launchMetadata
                        )))
                        return
                    }
                    if let activeSession = sessions.first {
                        let activeTitle = activeSession.appId > 0 ? "App ID \(activeSession.appId)" : "Current Stream"
                        let active = OPNActiveStreamSessionDescriptor(sessionId: activeSession.sessionId, appId: activeSession.appId, serverIp: activeSession.serverIp, title: activeTitle)
                        let resume = OPNStreamLaunchConfiguration(
                            title: active.title,
                            appId: activeSession.appId > 0 ? String(activeSession.appId) : appId,
                            apiToken: token,
                            accountLinked: true,
                            selectedStore: "",
                            resumeSessionId: activeSession.sessionId,
                            resumeServer: activeSession.serverIp,
                            metadata: launchMetadata
                        )
                        completion(true, "Another GeForce NOW session is already active.", .activeSession(active: active, resume: resume, replacement: replacement))
                        return
                    }
                }

                completion(true, "Launching \(title)...", .ready(replacement))
            }
        }
    }

    public func stopActiveSession(_ session: OPNActiveStreamSessionDescriptor, accessToken: String, completion: @escaping OPNGameLaunchSessionStopCompletion) {
        guard !accessToken.isEmpty else {
            completion(false, "Sign in again before ending the active session.")
            return
        }
        OPNActiveSessionService.stopSession(accessToken: accessToken, sessionId: session.id, serverIp: session.serverIp) { success, error in
            Task { @MainActor in
                completion(success, success ? "Session ended." : (error.isEmpty ? "Unable to end the active session." : error))
            }
        }
    }

    private func configureServices(token: String, userId: String) {
        OPNGameService.shared.setAccessToken(token)
        OPNGameService.shared.setAccountLinkingToken(token)
        OPNGameService.shared.setUserId(userId)
        OPNGameService.shared.setVpcId("GFN-PC")
    }

    private func resolvedVariantIndex(for game: OPNCatalogGameObject, requestedIndex: Int) -> Int {
        if requestedIndex >= 0, requestedIndex < game.variants.count { return requestedIndex }
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    private func activeSession(_ session: OPNActiveSessionObject, matches game: OPNCatalogGameObject, appId: String) -> Bool {
        guard session.appId > 0 else { return false }
        let activeAppId = String(session.appId)
        return activeAppId == appId || activeAppId == game.id || activeAppId == game.launchAppId || game.variants.contains { $0.id == activeAppId }
    }

    private static func launchMetadata(for game: OPNCatalogGameObject, userId: String = "", idpId: String = "") -> [String: String] {
        var imageUrls: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            imageUrls.append(trimmed)
        }

        func appendValues(forKey key: String) {
            for value in game.imageUrlsByType[key] ?? [] { append(value) }
            for value in game.imageUrlsByType[key.lowercased()] ?? [] { append(value) }
        }

        appendValues(forKey: "SCREENSHOTS")
        for value in game.screenshotUrls { append(value) }
        appendValues(forKey: "HERO_IMAGE")
        appendValues(forKey: "MARQUEE_HERO_IMAGE")
        appendValues(forKey: "FEATURE_IMAGE")
        append(game.heroImageUrl)
        append(game.imageUrl)

        var metadata: [String: String] = [:]
        if !userId.isEmpty { metadata["userId"] = userId }
        if !idpId.isEmpty { metadata["idpId"] = idpId }
        if !imageUrls.isEmpty { metadata["loadingScreenshotUrls"] = imageUrls.joined(separator: "\n") }
        return metadata
    }
}
