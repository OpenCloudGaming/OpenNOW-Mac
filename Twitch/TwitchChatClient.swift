import Foundation

public actor TwitchChatClient {
    private let eventsContinuation: AsyncStream<TwitchChatEvent>.Continuation
    private var task: URLSessionWebSocketTask?
    private var login = ""
    private var receiveTask: Task<Void, Never>?

    public let events: AsyncStream<TwitchChatEvent>

    public init() {
        var continuation: AsyncStream<TwitchChatEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    public func connect(token: TwitchOAuthToken, login: String) {
        disconnect()
        let trimmedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedLogin.isEmpty else {
            eventsContinuation.yield(.state(.failed("Missing channel login")))
            return
        }
        self.login = trimmedLogin
        eventsContinuation.yield(.state(.connecting))
        let websocket = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        task = websocket
        websocket.resume()
        sendRaw("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
        sendRaw("PASS oauth:\(token.accessToken)")
        sendRaw("NICK \(trimmedLogin)")
        sendRaw("JOIN #\(trimmedLogin)")
        eventsContinuation.yield(.state(.connected("Chat connected")))
        receiveTask = Task { await receiveLoop() }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        eventsContinuation.yield(.state(.disconnected))
    }

    public func send(message: String) {
        let trimmedMessage = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(450))
        guard !trimmedMessage.isEmpty, !login.isEmpty else { return }
        sendRaw("PRIVMSG #\(login) :\(trimmedMessage)")
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let task {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text: text) }
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled else { return }
                eventsContinuation.yield(.state(.failed(error.localizedDescription.nilIfEmpty ?? "Chat disconnected")))
                return
            }
        }
    }

    private func handle(text: String) {
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.hasPrefix("PING") {
                sendRaw(line.replacingOccurrences(of: "PING", with: "PONG"))
            } else if line.contains(" RECONNECT") {
                eventsContinuation.yield(.state(.failed("Twitch requested chat reconnect")))
            } else if let message = TwitchIRCParser.parseMessage(line) {
                eventsContinuation.yield(.message(message))
            } else if line.contains(" NOTICE "), let notice = line.split(separator: ":", maxSplits: 2).last {
                eventsContinuation.yield(.notice(String(notice)))
            }
        }
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text + "\r\n")) { [eventsContinuation] error in
            if let error { eventsContinuation.yield(.state(.failed(error.localizedDescription))) }
        }
    }
}
