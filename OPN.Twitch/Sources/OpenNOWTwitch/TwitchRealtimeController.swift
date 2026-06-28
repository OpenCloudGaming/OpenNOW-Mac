import Combine
import Foundation

@MainActor
public final class TwitchRealtimeController: ObservableObject {
    @Published public private(set) var accountStatus = TwitchAccountStatus()
    @Published public private(set) var chatState = TwitchRealtimeConnectionState.disconnected
    @Published public private(set) var eventSubState = TwitchRealtimeConnectionState.disconnected
    @Published public private(set) var chatMessages: [TwitchChatMessage] = []
    @Published public private(set) var eventAlerts: [TwitchEventAlert] = []
    @Published public private(set) var supportedAlertTypes: [String] = []

    private let maxMessages = 80
    private let maxAlerts = 30
    private let chatClient = TwitchChatClient()
    private let eventSubClient = TwitchEventSubClient()
    private var chatTask: Task<Void, Never>?
    private var eventSubTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var isStarted = false

    public init() {}

    public var health: TwitchRealtimeHealth {
        TwitchRealtimeHealth(accountSummary: accountStatus.summary, streamKeyAvailable: accountStatus.streamKeyAvailable, chat: chatState, eventSub: eventSubState, supportedAlertTypes: supportedAlertTypes)
    }

    public func start(clientID: String = TwitchOAuthService.clientID) {
        guard !isStarted else { return }
        isStarted = true
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.connect(clientID: clientID)
        }
    }

    public func restart(clientID: String = TwitchOAuthService.clientID) {
        stop()
        start(clientID: clientID)
    }

    public func stop() {
        isStarted = false
        startTask?.cancel()
        startTask = nil
        chatTask?.cancel()
        eventSubTask?.cancel()
        chatTask = nil
        eventSubTask = nil
        Task { await chatClient.disconnect() }
        Task { await eventSubClient.disconnect() }
        chatState = .disconnected
        eventSubState = .disconnected
        supportedAlertTypes = []
    }

    public func refreshHealth(clientID: String = TwitchOAuthService.clientID) async {
        do {
            accountStatus = try await TwitchOAuthService.refreshStatus(clientID: clientID)
        } catch {
            accountStatus = TwitchAccountStatus(streamKeyAvailable: TwitchStreamKeyStore.exists())
        }
    }

    public func sendChatMessage(_ message: String) {
        Task { await chatClient.send(message: message) }
    }

    public func clearAlerts() {
        eventAlerts = []
    }

    private func connect(clientID: String) async {
        do {
            let token = try await TwitchOAuthService.validStoredToken(clientID: clientID)
            let client = TwitchHelixClient(clientID: clientID, tokenProvider: { token.accessToken })
            let user = try await client.currentUser()
            accountStatus = try await TwitchOAuthService.refreshStatus(clientID: clientID)
            listenToChat()
            listenToEventSub()
            await chatClient.connect(token: token, login: user.login)
            await eventSubClient.connect(clientID: clientID, token: token, user: user)
        } catch {
            let message = Self.message(for: error)
            chatState = .failed(message)
            eventSubState = .failed(message)
        }
    }

    private func listenToChat() {
        chatTask?.cancel()
        chatTask = Task { [weak self] in
            guard let self else { return }
            for await event in chatClient.events {
                await MainActor.run { self.handle(chatEvent: event) }
            }
        }
    }

    private func listenToEventSub() {
        eventSubTask?.cancel()
        eventSubTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventSubClient.events {
                await MainActor.run { self.handle(eventSubEvent: event) }
            }
        }
    }

    private func handle(chatEvent: TwitchChatEvent) {
        switch chatEvent {
        case .state(let state):
            chatState = state
        case .message(let message):
            chatMessages.append(message)
            if chatMessages.count > maxMessages { chatMessages.removeFirst(chatMessages.count - maxMessages) }
        case .notice(let message):
            chatMessages.append(TwitchChatMessage(id: UUID().uuidString, author: "twitch", displayName: "Twitch", text: message))
            if chatMessages.count > maxMessages { chatMessages.removeFirst(chatMessages.count - maxMessages) }
        }
    }

    private func handle(eventSubEvent: TwitchEventSubEvent) {
        switch eventSubEvent {
        case .state(let state):
            eventSubState = state
        case .supportedTypes(let types):
            supportedAlertTypes = types.sorted()
        case .alert(let alert):
            guard supportedAlertTypes.isEmpty || supportedAlertTypes.contains(alert.type) else { return }
            eventAlerts.append(alert)
            if eventAlerts.count > maxAlerts { eventAlerts.removeFirst(eventAlerts.count - maxAlerts) }
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Twitch realtime connection failed." : error.localizedDescription
    }
}
