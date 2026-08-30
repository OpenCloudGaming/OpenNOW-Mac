import Foundation

enum OPNGFNErrorMapper {
    private static let noGFNErrorCode = Int64.min

    private struct ErrorRule: Sendable {
        let code: Int64
        let symbol: String
        let needle: String
        let message: String
    }

    private static let structuredRules: [ErrorRule] = [
        ErrorRule(code: 0xC0F5213D, symbol: "SRC_TOO_MANY_REQUESTS", needle: "src_too_many", message: "Too many GeForce NOW launch requests were sent. Wait a few minutes, then try again."),
        ErrorRule(code: 0xC0F52156, symbol: "SRC_INSUFFICIENT_PLAYABILITY_LEVEL", needle: "src_insufficient_playability_level", message: "This stream quality is not available for your current GeForce NOW membership. Lower the streaming quality or upgrade your membership, then try again."),
        ErrorRule(code: 0xC0F52147, symbol: "SRC_MAINTENANCE", needle: "src_maintenance", message: "GeForce NOW is temporarily unavailable for maintenance. Try again later."),
        ErrorRule(code: 0xC0F5213E, symbol: "SRC_QUEUE_LENGTH_EXCEEDED", needle: "src_queue_length_exceeded", message: "The GeForce NOW queue is currently full. Try again later."),
        ErrorRule(code: 0xC0F5215A, symbol: "SRC_STORAGE_NOT_AVAILABLE", needle: "src_storage_not_available", message: "GeForce NOW cloud storage is not available for this session. Try again later."),
        ErrorRule(code: 0xC0F52142, symbol: "SRC_GAME_BINARIES_NOT_AVAILABLE", needle: "src_game_binaries_not_available", message: "This game is not available in the selected GeForce NOW region. Choose Automatic or another region, then try again."),
        ErrorRule(code: 0xC0F52005, symbol: "SRC_SYSTEM_SLEEP", needle: "src_system_sleep", message: "Session setup was interrupted by system sleep. Keep your Mac awake, then try again."),
        ErrorRule(code: 0xC0F22206, symbol: "NVB_ICE_CONNECTION_FAILED", needle: "ice_connection_failed", message: "There was a network problem connecting to GeForce NOW. Check your connection, then try again."),
        ErrorRule(code: 0xC0F30002, symbol: "NVB_FRAME_LOSS_TIMEOUT", needle: "frame_loss_timeout", message: "There was a network problem connecting to GeForce NOW. Check your connection, then try again."),
        ErrorRule(code: 0x00F13001, symbol: "GAME_NOT_OWNED", needle: "game_not_owned", message: "This game is not owned or linked on your account. Open the Store or link the required account, then try again.")
    ]

    static func userFacingMessage(_ errorMessage: String, gameTitle: String = "") -> String {
        userFacingMessage(errorMessage, gameTitle: gameTitle, sessionWasConnected: false)
    }

    static func userFacingMessage(_ errorMessage: String, gameTitle: String, sessionWasConnected: Bool) -> String {
        if errorMessage.isEmpty { return "An unknown error occurred." }

        let context = Context(errorMessage: errorMessage, gameTitle: gameTitle, sessionWasConnected: sessionWasConnected)
        // Ahead of `structuredRule`, as it has always been: a game-seat-service failure whose text
        // also names an entitlement or network code is still a GSEC failure, and its guidance
        // (retry, change region, wait for NVIDIA) is the one that helps.
        if context.contains("gsec_", "src_gsec", "gfn_gsec") {
            return context.detailed("GeForce NOW reported an internal game-seat service error. Try launching again; if it keeps happening, choose another region or wait for NVIDIA to recover the service.")
        }
        if let rule = structuredRule(for: context.code, lowerError: context.lower) {
            return context.detailed(rule.message)
        }
        guard let rule = messageRules.first(where: { $0.matches(context) }) else { return errorMessage }
        return context.detailed(rule.message(context))
    }

    /// One error, parsed once: every rule below reads its verdict off this.
    private struct Context: Sendable {
        let lower: String
        let code: Int64
        let httpCode: Int64
        let description: String?
        let gameTitle: String
        let sessionWasConnected: Bool

        init(errorMessage: String, gameTitle: String, sessionWasConnected: Bool) {
            let lowered = errorMessage.lowercased()
            let json = OPNGFNErrorMapper.jsonDictionary(from: errorMessage)
            let http = OPNGFNErrorMapper.httpStatusCode(from: lowered)
            let hex = OPNGFNErrorMapper.hexErrorCode(from: lowered)
            var resolved = OPNGFNErrorMapper.errorCode(from: json)
            if resolved == noGFNErrorCode, http != noGFNErrorCode { resolved = http }
            if resolved == noGFNErrorCode, hex != noGFNErrorCode { resolved = hex }

            lower = lowered
            code = resolved
            httpCode = http
            description = OPNGFNErrorMapper.errorDescription(from: json)
            self.gameTitle = gameTitle
            self.sessionWasConnected = sessionWasConnected
        }

        /// True when the numeric code matches, or the error text names it.
        func matches(_ expectedCode: Int64, _ name: String) -> Bool {
            OPNGFNErrorMapper.matches(code: code, lowerError: lower, expectedCode: expectedCode, name: name)
        }

        func contains(_ needles: String...) -> Bool {
            needles.contains { lower.contains($0) }
        }

        func detailed(_ message: String) -> String {
            OPNGFNErrorMapper.messageWithDetails(message, code: code, description: description)
        }
    }

    /// One classification rule. Order matters — the first match wins, so the specific rules come
    /// before the catch-all network/timeout/server ones.
    private struct MessageRule: Sendable {
        let matches: @Sendable (Context) -> Bool
        let message: @Sendable (Context) -> String

        init(_ matches: @escaping @Sendable (Context) -> Bool, _ message: String) {
            self.matches = matches
            self.message = { _ in message }
        }

        init(_ matches: @escaping @Sendable (Context) -> Bool, message: @escaping @Sendable (Context) -> String) {
            self.matches = matches
            self.message = message
        }
    }

    private static let messageRules: [MessageRule] = [
        MessageRule({ $0.httpCode == 401 || $0.contains("unauthorized", "auth_err") },
                    "Your NVIDIA session expired. Sign in again, then try launching the game."),
        MessageRule({ $0.httpCode == 429 || $0.matches(3_237_290_301, "too_many") || $0.contains("too many requests") },
                    "Too many GeForce NOW launch requests were sent. Wait a few minutes, then try again."),
        MessageRule({ $0.contains("account_link", "account link", "store account", "link_required", "link required") },
                    "The store account for this game is not linked to GeForce NOW. Open the Store to link the account, then try launching again."),
        MessageRule({ $0.contains("install_to_play", "install to play", "install required", "game installation required") },
                    "This game must be installed or prepared through its store before GeForce NOW can launch it. Open the Store, finish setup, then try again."),
        MessageRule({ $0.matches(41, "app_patching_status") || $0.contains("app patching", "app_patching_status") },
                    "GeForce NOW is patching this game before launch. Try again after patching finishes."),
        MessageRule({ $0.matches(86, "insufficient_playability_level") || $0.matches(3_237_290_326, "insufficient_playability_level") },
                    "This stream quality is not available for your current GeForce NOW membership. Lower the streaming quality or upgrade your membership, then try again."),
        MessageRule({ $0.matches(302, "session_limit") || $0.matches(11, "session_limit") }, message: { context in
            context.gameTitle.isEmpty
                ? "A game is already running in another GeForce NOW session. Close the other stream or continue from the active session."
                : "\(context.gameTitle) is already running in another GeForce NOW session. Close the other stream or continue from the active session."
        }),
        MessageRule({ $0.matches(311, "session_terminated_another_client") },
                    "This GeForce NOW session ended because the game was opened from another device or client."),
        MessageRule({ $0.matches(310, "multiple_login") || $0.contains("multiple login") },
                    "This GeForce NOW session ended because your NVIDIA account was used on another device."),
        MessageRule({ $0.matches(15_806_465, "game_not_owned")
            || $0.contains("not entitled", "not_entitled", "entitlement required", "ownership required", "purchase required", "license required") },
                    "This game is not owned or linked on your account. Open the Store or link the required account, then try again."),
        MessageRule({ $0.contains("session_ads_required", "isadsrequired", "ad_required", "ads required", "queuepaused", "queue paused", "graceperiodstart") },
                    "GeForce NOW requires ad playback before this free-tier session can continue. Wait for the ad prompt, finish the ad, then continue launching."),
        MessageRule({ $0.contains("parental", "age_restricted", "age restricted") },
                    "This game is restricted by account age or parental controls. Check the NVIDIA account settings, then try again."),
        MessageRule({ $0.matches(3_237_290_311, "maintenance") || $0.contains("maintenance", "out_of_service") },
                    "GeForce NOW is temporarily unavailable for maintenance. Try again later."),
        MessageRule({ $0.matches(3_237_290_302, "queue_length_exceeded") || $0.contains("queue length") },
                    "The GeForce NOW queue is currently full. Try again later."),
        MessageRule({ $0.matches(3_237_290_330, "storage_not_available") || $0.contains("storage") },
                    "GeForce NOW cloud storage is not available for this session. Try again later."),
        MessageRule({ $0.matches(3_237_290_306, "game_binaries_not_available") || $0.contains("not available in region") },
                    "This game is not available in the selected GeForce NOW region. Choose Automatic or another region, then try again."),
        MessageRule({ $0.matches(3_237_289_989, "system_sleep") || $0.contains("sleep during session") },
                    "Session setup was interrupted by system sleep. Keep your Mac awake, then try again."),
        MessageRule({ $0.matches(57, "session_timelimit") || $0.contains("time limit", "entitlement_timeout", "entitlement timeout") },
                    "Your GeForce NOW session time limit has been reached. Start a new session when more play time is available."),
        MessageRule({ $0.matches(301, "session_not_active") || $0.matches(308, "no_active_session")
            || $0.matches(309, "session_not_paused") || $0.contains("stale_active_session") },
                    "The previous GeForce NOW session is no longer available. Try launching the game again."),
        MessageRule({ $0.matches(3_237_093_894, "ice_connection_failed") || $0.matches(3_237_150_722, "frame_loss_timeout")
            || $0.contains("not connected to internet", "network connection was lost", "network error", "connection lost", "signaling", "webrtc", " ice ", "ice_connection") },
                    "There was a network problem connecting to GeForce NOW. Check your connection, then try again."),
        MessageRule({ $0.contains("timeout", "timed out") },
                    "GeForce NOW took too long to start the session. Try launching again."),
        MessageRule({ ($0.httpCode >= 500 && $0.httpCode <= 599) || $0.contains("server error", "internal server error") },
                    "GeForce NOW had a server problem while starting the session. Try again later."),
        MessageRule({ $0.contains("terminal error state", "session failed", "session ended") }, message: { context in
            context.sessionWasConnected
                ? "GeForce NOW ended the running session. Try launching again."
                : "GeForce NOW ended the session before it was ready. Try launching again."
        })
    ]

    private static func jsonDictionary(from errorMessage: String) -> [String: Any]? {
        guard let start = errorMessage.firstIndex(of: "{") else { return nil }
        let jsonText = String(errorMessage[start...])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary
    }

    private static func numberValue(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        guard let string = value as? String, !string.isEmpty else { return nil }
        return parseInteger(string)
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func dictionaryValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func errorCode(from json: [String: Any]?) -> Int64 {
        guard let json else { return noGFNErrorCode }
        let requestStatus = dictionaryValue(json["requestStatus"])
        if let unifiedErrorCode = numberValue(requestStatus?["unifiedErrorCode"]), unifiedErrorCode != 0 { return unifiedErrorCode }
        if let requestStatusCode = numberValue(requestStatus?["statusCode"]) { return requestStatusCode }
        let result = dictionaryValue(json["result"])
        if let resultCode = numberValue(result?["result"]) { return resultCode }
        if let statusCode = numberValue(json["statusCode"]) { return statusCode }
        if let code = numberValue(json["code"]) { return code }
        if let errorCode = numberValue(json["errorCode"]) { return errorCode }
        if let unifiedErrorCode = numberValue(json["unifiedErrorCode"]), unifiedErrorCode != 0 { return unifiedErrorCode }
        return noGFNErrorCode
    }

    private static func errorDescription(from json: [String: Any]?) -> String? {
        guard let json else { return nil }
        let requestStatus = dictionaryValue(json["requestStatus"])
        if let requestDescription = stringValue(requestStatus?["statusDescription"]) { return requestDescription }
        if let errorMessage = stringValue(json["errorMessage"]) { return errorMessage }
        if let message = stringValue(json["message"]) { return message }
        return nil
    }

    private static func httpStatusCode(from lowerError: String) -> Int64 {
        guard let range = lowerError.range(of: "http ") else { return noGFNErrorCode }
        let suffix = lowerError[range.upperBound...]
        guard let first = suffix.first, first.isNumber else { return noGFNErrorCode }
        let digits = suffix.prefix { $0.isNumber }
        return Int64(digits) ?? noGFNErrorCode
    }

    private static func hexErrorCode(from lowerError: String) -> Int64 {
        if let range = lowerError.range(of: "0x") {
            let suffix = lowerError[range.upperBound...]
            guard let first = suffix.first, first.isHexDigit else { return noGFNErrorCode }
            let token = suffix.prefix { $0.isHexDigit }
            return Int64(token, radix: 16) ?? noGFNErrorCode
        }

        var index = lowerError.startIndex
        while index < lowerError.endIndex {
            while index < lowerError.endIndex, !lowerError[index].isHexDigit {
                index = lowerError.index(after: index)
            }
            let tokenStart = index
            var hasDigit = false
            var hasAlpha = false
            while index < lowerError.endIndex, lowerError[index].isHexDigit {
                hasDigit = hasDigit || lowerError[index].isNumber
                hasAlpha = hasAlpha || lowerError[index].isLetter
                index = lowerError.index(after: index)
            }
            let token = lowerError[tokenStart..<index]
            if token.count >= 6, hasDigit, hasAlpha {
                return Int64(token, radix: 16) ?? noGFNErrorCode
            }
        }
        return noGFNErrorCode
    }

    private static func structuredRule(for code: Int64, lowerError: String) -> ErrorRule? {
        structuredRules.first { rule in
            code == rule.code || lowerError.contains(rule.symbol.lowercased()) || lowerError.contains(rule.needle)
        }
    }

    private static func messageWithDetails(_ message: String, code: Int64, description: String?) -> String {
        var result = message.isEmpty ? "An unknown GeForce NOW error occurred." : message
        if code != noGFNErrorCode {
            result += "\n\nGeForce NOW error \(code)"
            if let description, !description.isEmpty { result += ": \(description)" }
            result += "."
        } else if let description, !description.isEmpty {
            result += "\n\n\(description)"
        }
        return result
    }

    private static func matches(code: Int64, lowerError: String, expectedCode: Int64, name: String) -> Bool {
        code == expectedCode || lowerError.contains(name)
    }

    private static func parseInteger(_ text: String) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return Int64(value.dropFirst(2), radix: 16)
        }
        return Int64(value)
    }
}

@objc(OPNGFNError)
public final class OPNGFNError: NSObject {
    @objc(userFacingMessageForErrorMessage:gameTitle:)
    public static func userFacingMessage(errorMessage: String, gameTitle: String) -> String {
        OPNGFNErrorMapper.userFacingMessage(errorMessage, gameTitle: gameTitle)
    }

    @objc(userFacingMessageForErrorMessage:gameTitle:sessionWasConnected:)
    public static func userFacingMessage(errorMessage: String, gameTitle: String, sessionWasConnected: Bool) -> String {
        OPNGFNErrorMapper.userFacingMessage(errorMessage, gameTitle: gameTitle, sessionWasConnected: sessionWasConnected)
    }
}
