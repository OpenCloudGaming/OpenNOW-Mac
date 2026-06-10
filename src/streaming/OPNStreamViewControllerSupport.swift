import Foundation

@objc(OPNStreamViewControllerSupport)
final class OPNStreamViewControllerSupport: NSObject {
    @objc static func shouldReportTerminalStreamFailure(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return true }
        if message == "Session ended due to inactivity." { return false }
        if message == "Microphone permission denied" { return false }
        if message.contains("NVIDIA session expired") { return false }
        return true
    }

    @objc static func boundedStreamFailureMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        guard message.count > 700 else { return message }
        let endIndex = message.index(message.startIndex, offsetBy: 700)
        return String(message[..<endIndex]) + "..."
    }

    @objc static func streamMetricAttributes(
        outcome: String?,
        recovering: Bool,
        backend: String?,
        codec: String?,
        resolution: String?,
        fps: Int32
    ) -> [String: Any] {
        [
            "outcome": nonEmpty(outcome, fallback: "unknown"),
            "recovery": recovering,
            "backend": nonEmpty(backend, fallback: "unknown"),
            "codec": nonEmpty(codec, fallback: "unknown"),
            "resolution": nonEmpty(resolution, fallback: "unknown"),
            "fps": Int(fps),
        ]
    }

    @objc static func streamFailureReportMessage(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "Stream failed" }
        guard let jsonRange = message.range(of: "{") else {
            return boundedStreamFailureMessage(message)
        }

        let prefix = message[..<jsonRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = String(message[jsonRange.lowerBound...])
        guard let jsonData = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return boundedStreamFailureMessage(message)
        }

        let requestStatus = json["requestStatus"] as? [String: Any]
        let statusCode = requestStatus?["statusCode"] as? NSNumber
        let statusDescription = requestStatus?["statusDescription"] as? String
        let requestId = requestStatus?["requestId"] as? String
        let serverId = requestStatus?["serverId"] as? String
        let otherSessions = json["otherUserSessions"] as? [Any]

        var parts: [String] = []
        if !prefix.isEmpty { parts.append(prefix) }
        if let statusCode { parts.append("statusCode=\(statusCode.intValue)") }
        if let statusDescription, !statusDescription.isEmpty { parts.append("description=\(statusDescription)") }
        if let serverId, !serverId.isEmpty { parts.append("serverId=\(serverId)") }
        if let requestId, !requestId.isEmpty { parts.append("requestId=\(requestId)") }
        if let otherSessions { parts.append("otherSessions=\(otherSessions.count)") }
        return parts.isEmpty ? boundedStreamFailureMessage(message) : parts.joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }
}
