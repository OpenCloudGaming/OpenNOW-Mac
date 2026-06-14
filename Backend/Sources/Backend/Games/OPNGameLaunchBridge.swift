import AppKit
import Common
import Foundation

public typealias OPNGameLaunchWindowCompletion = @MainActor @Sendable (_ success: Bool, _ message: String) -> Void
public typealias OPNGameLaunchPreparationCompletion = @MainActor @Sendable (_ success: Bool, _ message: String, _ configuration: OPNStreamLaunchConfiguration?) -> Void
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

    public init(title: String, appId: String, apiToken: String, accountLinked: Bool, selectedStore: String, resumeSessionId: String = "", resumeServer: String = "") {
        self.id = UUID()
        self.title = title
        self.appId = appId
        self.apiToken = apiToken
        self.accountLinked = accountLinked
        self.selectedStore = selectedStore
        self.resumeSessionId = resumeSessionId
        self.resumeServer = resumeServer
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
public final class OPNGameLaunchBridge: NSObject, NSWindowDelegate {
    public static let shared = OPNGameLaunchBridge()

    private var windows: [ObjectIdentifier: NSWindow] = [:]

    public func prepareLaunch(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, variantIndex: Int, completion: @escaping OPNGameLaunchPreparationCompletion) {
        prepareLaunchPlan(game: game, accessToken: accessToken, idToken: idToken, userId: userId, variantIndex: variantIndex) { success, message, plan in
            guard success, let plan else {
                completion(false, message, nil)
                return
            }

            switch plan {
            case .ready(let configuration):
                completion(true, message, configuration)
            case .activeSession:
                completion(false, message, nil)
            }
        }
    }

    public func prepareLaunchPlan(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, variantIndex: Int, completion: @escaping OPNGameLaunchPlanCompletion) {
        let token = idToken.isEmpty ? accessToken : idToken
        guard !token.isEmpty else {
            completion(false, "Sign in again before launching a game.", nil)
            return
        }

        let selectedVariantIndex = resolvedVariantIndex(for: game, requestedIndex: variantIndex)
        let selectedVariant = selectedVariantIndex >= 0 && selectedVariantIndex < game.variants.count ? game.variants[selectedVariantIndex] : nil
        let appId = resolvedAppId(game: game, variant: selectedVariant)
        guard !appId.isEmpty else {
            completion(false, "This game does not include a launchable GeForce NOW app id.", nil)
            return
        }

        configureServices(token: token, userId: userId)

        let title = game.title.isEmpty ? "GeForce NOW" : game.title
        let accountLinked = game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true
        let selectedStore = selectedVariant?.appStore ?? ""
        let replacement = OPNStreamLaunchConfiguration(
            title: title,
            appId: appId,
            apiToken: token,
            accountLinked: accountLinked,
            selectedStore: selectedStore
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
                            resumeServer: requestedSession.serverIp
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
                            resumeServer: activeSession.serverIp
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

    public func launch(game: OPNCatalogGameObject, accessToken: String, idToken: String, userId: String, variantIndex: Int, completion: OPNGameLaunchWindowCompletion? = nil) {
        prepareLaunch(game: game, accessToken: accessToken, idToken: idToken, userId: userId, variantIndex: variantIndex) { [weak self] success, message, configuration in
            guard let self, success, let configuration else {
                completion?(false, message)
                return
            }

            self.openStreamWindow(configuration: configuration, completion: completion)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let controller = window.contentViewController as? OPNStreamViewController {
            controller.shutdownForApplicationTermination()
        }
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    private func openStreamWindow(configuration: OPNStreamLaunchConfiguration, completion: OPNGameLaunchWindowCompletion?) {
        let controller = makeStreamViewController(configuration: configuration)
        let windowFrame = streamWindowFrame()
        controller.setInitialViewFrame(NSRect(origin: .zero, size: windowFrame.size))

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = configuration.title
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.delegate = self

        let identifier = ObjectIdentifier(window)
        windows[identifier] = window
        controller.onStreamEnd = { [weak self, weak window] success, error, _ in
            Task { @MainActor in
                completion?(success, error)
                guard let self, let window else { return }
                self.windows.removeValue(forKey: ObjectIdentifier(window))
                if window.isVisible { window.close() }
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completion?(true, "Launching \(configuration.title)...")
    }

    private func makeStreamViewController(configuration: OPNStreamLaunchConfiguration) -> OPNStreamViewController {
        OPNStreamViewController(
            gameTitle: configuration.title,
            appId: configuration.appId,
            apiToken: configuration.apiToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionId: configuration.resumeSessionId,
            resumeServer: configuration.resumeServer
        )
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

    private func resolvedAppId(game: OPNCatalogGameObject, variant: OPNCatalogGameVariantObject?) -> String {
        if let variant, !variant.id.isEmpty { return variant.id }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.id
    }

    private func activeSession(_ session: OPNActiveSessionObject, matches game: OPNCatalogGameObject, appId: String) -> Bool {
        guard session.appId > 0 else { return false }
        let activeAppId = String(session.appId)
        return activeAppId == appId || activeAppId == game.id || activeAppId == game.launchAppId || game.variants.contains { $0.id == activeAppId }
    }

    private func streamWindowFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(visibleFrame.width * 0.86, 1180), visibleFrame.width)
        let height = min(max(visibleFrame.height * 0.86, 720), visibleFrame.height)
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
