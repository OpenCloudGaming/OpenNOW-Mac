import Foundation

public actor TwitchEventSubClient {
    private let eventsContinuation: AsyncStream<TwitchEventSubEvent>.Continuation
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var token: TwitchOAuthToken?
    private var clientID = ""
    private var user: TwitchUser?

    public let events: AsyncStream<TwitchEventSubEvent>

    public init() {
        var continuation: AsyncStream<TwitchEventSubEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    public func connect(clientID: String, token: TwitchOAuthToken, user: TwitchUser) {
        disconnect()
        self.clientID = clientID
        self.token = token
        self.user = user
        eventsContinuation.yield(.state(.connecting))
        let websocket = URLSession.shared.webSocketTask(with: URL(string: "wss://eventsub.wss.twitch.tv/ws")!)
        task = websocket
        websocket.resume()
        receiveTask = Task { await receiveLoop() }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        eventsContinuation.yield(.state(.disconnected))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let task {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { await handle(text: text) }
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                eventsContinuation.yield(.state(.failed(error.localizedDescription.nilIfEmpty ?? "EventSub disconnected")))
                return
            }
        }
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8), let envelope = try? JSONDecoder().decode(EventSubEnvelope.self, from: data) else { return }
        switch envelope.metadata.messageType {
        case "session_welcome":
            guard let sessionID = envelope.payload.session?.id else { return }
            eventsContinuation.yield(.state(.connected("EventSub connected")))
            await createSubscriptions(sessionID: sessionID)
        case "session_reconnect":
            if let reconnectURL = envelope.payload.session?.reconnectURL, let url = URL(string: reconnectURL) {
                reconnect(to: url)
            }
        case "notification":
            if let subscription = envelope.payload.subscription, let event = envelope.payload.event {
                eventsContinuation.yield(.alert(alert(type: subscription.type, event: event)))
            }
        case "revocation":
            if let subscription = envelope.payload.subscription {
                eventsContinuation.yield(.state(.failed("EventSub revoked \(subscription.type)")))
            }
        default:
            break
        }
    }

    private func reconnect(to url: URL) {
        task?.cancel(with: .goingAway, reason: nil)
        let websocket = URLSession.shared.webSocketTask(with: url)
        task = websocket
        websocket.resume()
    }

    private func createSubscriptions(sessionID: String) async {
        guard let token, let user else { return }
        let client = TwitchHelixClient(clientID: clientID, tokenProvider: { token.accessToken })
        var supportedTypes: [String] = []
        for request in subscriptionRequests(userID: user.id) {
            do {
                _ = try await client.createEventSubSubscription(type: request.type, version: request.version, condition: request.condition, sessionID: sessionID)
                supportedTypes.append(request.type)
            } catch {
                continue
            }
        }
        eventsContinuation.yield(.supportedTypes(supportedTypes))
    }

    private func subscriptionRequests(userID: String) -> [SubscriptionRequest] {
        [
            SubscriptionRequest(type: "stream.online", version: "1", condition: ["broadcaster_user_id": userID]),
            SubscriptionRequest(type: "stream.offline", version: "1", condition: ["broadcaster_user_id": userID]),
            SubscriptionRequest(type: "channel.follow", version: "2", condition: ["broadcaster_user_id": userID, "moderator_user_id": userID]),
            SubscriptionRequest(type: "channel.subscribe", version: "1", condition: ["broadcaster_user_id": userID]),
            SubscriptionRequest(type: "channel.subscription.gift", version: "1", condition: ["broadcaster_user_id": userID]),
            SubscriptionRequest(type: "channel.cheer", version: "1", condition: ["broadcaster_user_id": userID]),
            SubscriptionRequest(type: "channel.raid", version: "1", condition: ["to_broadcaster_user_id": userID]),
            SubscriptionRequest(type: "channel.channel_points_custom_reward_redemption.add", version: "1", condition: ["broadcaster_user_id": userID]),
        ]
    }

    private func alert(type: String, event: [String: EventValue]) -> TwitchEventAlert {
        let displayName = event["user_name"]?.stringValue ?? event["from_broadcaster_user_name"]?.stringValue ?? event["broadcaster_user_name"]?.stringValue ?? "Twitch"
        let title: String
        let message: String
        switch type {
        case "stream.online":
            title = "Stream Online"
            message = "Twitch reports the channel is live."
        case "stream.offline":
            title = "Stream Offline"
            message = "Twitch reports the channel ended."
        case "channel.follow":
            title = "New Follow"
            message = "\(displayName) followed the channel."
        case "channel.subscribe":
            title = "New Subscriber"
            message = "\(displayName) subscribed."
        case "channel.subscription.gift":
            let total = event["total"]?.intValue ?? 1
            title = "Gift Subs"
            message = "\(displayName) gifted \(total) sub\(total == 1 ? "" : "s")."
        case "channel.cheer":
            let bits = event["bits"]?.intValue ?? 0
            title = "Cheer"
            message = "\(displayName) cheered \(bits) bits."
        case "channel.raid":
            let viewers = event["viewers"]?.intValue ?? 0
            title = "Raid"
            message = "\(displayName) raided with \(viewers) viewers."
        case "channel.channel_points_custom_reward_redemption.add":
            let reward = event["reward"]?.objectValue?["title"]?.stringValue ?? "Channel Point Reward"
            title = "Reward Redeemed"
            message = "\(displayName) redeemed \(reward)."
        default:
            title = "Twitch Event"
            message = type
        }
        return TwitchEventAlert(id: UUID().uuidString, type: type, title: title, message: message)
    }
}

private struct SubscriptionRequest: Sendable {
    let type: String
    let version: String
    let condition: [String: String]
}

private struct EventSubEnvelope: Decodable {
    let metadata: Metadata
    let payload: Payload

    struct Metadata: Decodable {
        let messageType: String

        private enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
        }
    }

    struct Payload: Decodable {
        let session: Session?
        let subscription: Subscription?
        let event: [String: EventValue]?
    }

    struct Session: Decodable {
        let id: String
        let reconnectURL: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case reconnectURL = "reconnect_url"
        }
    }

    struct Subscription: Decodable {
        let type: String
    }
}

private enum EventValue: Decodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case object([String: EventValue])
    case array([EventValue])
    case null

    var stringValue: String? {
        if case .string(let value) = self { return value }
        if case .int(let value) = self { return String(value) }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        if case .string(let value) = self { return Int(value) }
        return nil
    }

    var objectValue: [String: EventValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode([String: EventValue].self) { self = .object(value) }
        else if let value = try? container.decode([EventValue].self) { self = .array(value) }
        else { self = .null }
    }
}
