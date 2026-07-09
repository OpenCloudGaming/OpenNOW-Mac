import Foundation

public enum TwitchRealtimeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(String)
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected(let detail): return detail.isEmpty ? "Connected" : detail
        case .failed(let message): return message.isEmpty ? "Failed" : message
        }
    }
}

public struct TwitchChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String
    public let displayName: String
    public let text: String
    public let isAction: Bool
    public let timestamp: Date

    public init(id: String, author: String, displayName: String, text: String, isAction: Bool = false, timestamp: Date = Date()) {
        self.id = id
        self.author = author
        self.displayName = displayName
        self.text = text
        self.isAction = isAction
        self.timestamp = timestamp
    }
}

public struct TwitchEventAlert: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let title: String
    public let message: String
    public let timestamp: Date

    public init(id: String, type: String, title: String, message: String, timestamp: Date = Date()) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timestamp = timestamp
    }
}

public struct TwitchRealtimeHealth: Equatable, Sendable {
    public var accountSummary: String
    public var streamKeyAvailable: Bool
    public var chat: TwitchRealtimeConnectionState
    public var eventSub: TwitchRealtimeConnectionState
    public var supportedAlertTypes: [String]

    public init(accountSummary: String = "Not connected", streamKeyAvailable: Bool = false, chat: TwitchRealtimeConnectionState = .disconnected, eventSub: TwitchRealtimeConnectionState = .disconnected, supportedAlertTypes: [String] = []) {
        self.accountSummary = accountSummary
        self.streamKeyAvailable = streamKeyAvailable
        self.chat = chat
        self.eventSub = eventSub
        self.supportedAlertTypes = supportedAlertTypes
    }
}

public enum TwitchChatEvent: Equatable, Sendable {
    case state(TwitchRealtimeConnectionState)
    case message(TwitchChatMessage)
    case notice(String)
}

public enum TwitchEventSubEvent: Equatable, Sendable {
    case state(TwitchRealtimeConnectionState)
    case supportedTypes([String])
    case alert(TwitchEventAlert)
}

public enum TwitchIRCParser {
    public static func parseMessage(_ line: String, fallbackDate: Date = Date()) -> TwitchChatMessage? {
        guard line.contains(" PRIVMSG ") else { return nil }
        let tags = parseTags(line)
        let displayName = tags["display-name"]?.nilIfEmpty
        let id = tags["id"]?.nilIfEmpty ?? UUID().uuidString
        let author = username(from: line) ?? displayName ?? "viewer"
        guard let text = messageText(from: line)?.nilIfEmpty else { return nil }
        let actionPrefix = "\u{0001}ACTION "
        let actionSuffix = "\u{0001}"
        let isAction = text.hasPrefix(actionPrefix) && text.hasSuffix(actionSuffix)
        let cleanedText = isAction ? String(text.dropFirst(actionPrefix.count).dropLast(actionSuffix.count)) : text
        return TwitchChatMessage(id: id, author: author, displayName: displayName ?? author, text: cleanedText, isAction: isAction, timestamp: fallbackDate)
    }

    private static func parseTags(_ line: String) -> [String: String] {
        guard line.first == "@", let tagEnd = line.firstIndex(of: " ") else { return [:] }
        let tagText = line[line.index(after: line.startIndex)..<tagEnd]
        var tags: [String: String] = [:]
        for part in tagText.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            tags[String(pair[0])] = String(pair[1]).replacingOccurrences(of: "\\s", with: " ")
        }
        return tags
    }

    private static func username(from line: String) -> String? {
        guard let bang = line.firstIndex(of: "!"), let colon = line[..<bang].lastIndex(of: ":") else { return nil }
        return String(line[line.index(after: colon)..<bang]).nilIfEmpty
    }

    private static func messageText(from line: String) -> String? {
        guard let range = line.range(of: " PRIVMSG "), let messageStart = line[range.upperBound...].firstIndex(of: ":") else { return nil }
        return String(line[line.index(after: messageStart)...])
    }
}
