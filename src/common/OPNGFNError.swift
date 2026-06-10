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

        let lower = errorMessage.lowercased()
        let json = jsonDictionary(from: errorMessage)
        var code = errorCode(from: json)
        let httpCode = httpStatusCode(from: lower)
        let hexCode = hexErrorCode(from: lower)
        let description = errorDescription(from: json)

        if code == noGFNErrorCode, httpCode != noGFNErrorCode { code = httpCode }
        if code == noGFNErrorCode, hexCode != noGFNErrorCode { code = hexCode }

        if lower.contains("gsec_") || lower.contains("src_gsec") || lower.contains("gfn_gsec") {
            return messageWithDetails("GeForce NOW reported an internal game-seat service error. Try launching again; if it keeps happening, choose another region or wait for NVIDIA to recover the service.", code: code, description: description)
        }

        if let rule = structuredRule(for: code, lowerError: lower) {
            return messageWithDetails(rule.message, code: code, description: description)
        }

        if httpCode == 401 || lower.contains("unauthorized") || lower.contains("auth_err") {
            return messageWithDetails("Your NVIDIA session expired. Sign in again, then try launching the game.", code: code, description: description)
        }
        if httpCode == 429 || matches(code: code, lowerError: lower, expectedCode: 3_237_290_301, name: "too_many") || lower.contains("too many requests") {
            return messageWithDetails("Too many GeForce NOW launch requests were sent. Wait a few minutes, then try again.", code: code, description: description)
        }
        if lower.contains("account_link") || lower.contains("account link") || lower.contains("store account") || lower.contains("link_required") || lower.contains("link required") {
            return messageWithDetails("The store account for this game is not linked to GeForce NOW. Open the Store to link the account, then try launching again.", code: code, description: description)
        }
        if lower.contains("install_to_play") || lower.contains("install to play") || lower.contains("install required") || lower.contains("game installation required") {
            return messageWithDetails("This game must be installed or prepared through its store before GeForce NOW can launch it. Open the Store, finish setup, then try again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 86, name: "insufficient_playability_level") || matches(code: code, lowerError: lower, expectedCode: 3_237_290_326, name: "insufficient_playability_level") {
            return messageWithDetails("This stream quality is not available for your current GeForce NOW membership. Lower the streaming quality or upgrade your membership, then try again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 302, name: "session_limit") || matches(code: code, lowerError: lower, expectedCode: 11, name: "session_limit") {
            let message = gameTitle.isEmpty ? "A game is already running in another GeForce NOW session. Close the other stream or continue from the active session." : "\(gameTitle) is already running in another GeForce NOW session. Close the other stream or continue from the active session."
            return messageWithDetails(message, code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 311, name: "session_terminated_another_client") {
            return messageWithDetails("This GeForce NOW session ended because the game was opened from another device or client.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 310, name: "multiple_login") || lower.contains("multiple login") {
            return messageWithDetails("This GeForce NOW session ended because your NVIDIA account was used on another device.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 15_806_465, name: "game_not_owned") || lower.contains("not entitled") || lower.contains("not_entitled") || lower.contains("entitlement required") || lower.contains("ownership required") || lower.contains("purchase required") || lower.contains("license required") {
            return messageWithDetails("This game is not owned or linked on your account. Open the Store or link the required account, then try again.", code: code, description: description)
        }
        if lower.contains("session_ads_required") || lower.contains("isadsrequired") || lower.contains("ad_required") || lower.contains("ads required") || lower.contains("queuepaused") || lower.contains("queue paused") || lower.contains("graceperiodstart") {
            return messageWithDetails("GeForce NOW requires ad playback before this free-tier session can continue. Wait for the ad prompt, finish the ad, then continue launching.", code: code, description: description)
        }
        if lower.contains("parental") || lower.contains("age_restricted") || lower.contains("age restricted") {
            return messageWithDetails("This game is restricted by account age or parental controls. Check the NVIDIA account settings, then try again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_290_311, name: "maintenance") || lower.contains("maintenance") || lower.contains("out_of_service") {
            return messageWithDetails("GeForce NOW is temporarily unavailable for maintenance. Try again later.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_290_302, name: "queue_length_exceeded") || lower.contains("queue length") {
            return messageWithDetails("The GeForce NOW queue is currently full. Try again later.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_290_330, name: "storage_not_available") || lower.contains("storage") {
            return messageWithDetails("GeForce NOW cloud storage is not available for this session. Try again later.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_290_306, name: "game_binaries_not_available") || lower.contains("not available in region") {
            return messageWithDetails("This game is not available in the selected GeForce NOW region. Choose Automatic or another region, then try again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_289_989, name: "system_sleep") || lower.contains("sleep during session") {
            return messageWithDetails("Session setup was interrupted by system sleep. Keep your Mac awake, then try again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 57, name: "session_timelimit") || lower.contains("time limit") || lower.contains("entitlement_timeout") || lower.contains("entitlement timeout") {
            return messageWithDetails("Your GeForce NOW session time limit has been reached. Start a new session when more play time is available.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 301, name: "session_not_active") || matches(code: code, lowerError: lower, expectedCode: 308, name: "no_active_session") || matches(code: code, lowerError: lower, expectedCode: 309, name: "session_not_paused") || lower.contains("stale_active_session") {
            return messageWithDetails("The previous GeForce NOW session is no longer available. Try launching the game again.", code: code, description: description)
        }
        if matches(code: code, lowerError: lower, expectedCode: 3_237_093_894, name: "ice_connection_failed") || matches(code: code, lowerError: lower, expectedCode: 3_237_150_722, name: "frame_loss_timeout") || lower.contains("not connected to internet") || lower.contains("network connection was lost") || lower.contains("network error") || lower.contains("connection lost") || lower.contains("signaling") || lower.contains("webrtc") || lower.contains(" ice ") || lower.contains("ice_connection") {
            return messageWithDetails("There was a network problem connecting to GeForce NOW. Check your connection, then try again.", code: code, description: description)
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return messageWithDetails("GeForce NOW took too long to start the session. Try launching again.", code: code, description: description)
        }
        if (httpCode >= 500 && httpCode <= 599) || lower.contains("server error") || lower.contains("internal server error") {
            return messageWithDetails("GeForce NOW had a server problem while starting the session. Try again later.", code: code, description: description)
        }
        if lower.contains("terminal error state") || lower.contains("session failed") || lower.contains("session ended") {
            let message = sessionWasConnected ? "GeForce NOW ended the running session. Try launching again." : "GeForce NOW ended the session before it was ready. Try launching again."
            return messageWithDetails(message, code: code, description: description)
        }

        return errorMessage
    }

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
final class OPNGFNError: NSObject {
    @objc(userFacingMessageForErrorMessage:gameTitle:)
    static func userFacingMessage(errorMessage: String, gameTitle: String) -> String {
        OPNGFNErrorMapper.userFacingMessage(errorMessage, gameTitle: gameTitle)
    }

    @objc(userFacingMessageForErrorMessage:gameTitle:sessionWasConnected:)
    static func userFacingMessage(errorMessage: String, gameTitle: String, sessionWasConnected: Bool) -> String {
        OPNGFNErrorMapper.userFacingMessage(errorMessage, gameTitle: gameTitle, sessionWasConnected: sessionWasConnected)
    }
}
