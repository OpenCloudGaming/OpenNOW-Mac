import AppKit
import AppKit
import Foundation

@objc(OPNStreamViewControllerSupport)
@MainActor
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

    @objc static func isCommandQEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "q")
    }

    @objc static func isCommandNEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "n")
    }

    @objc static func isCommandMEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "m")
    }

    @objc static func isCommandGEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "g")
    }

    @objc static func isCommandREvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "r")
    }

    @objc static func isCommandHEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "h")
    }

    @objc static func isCommandLEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "l")
    }

    @objc static func isCommandKEvent(_ event: NSEvent?) -> Bool {
        isCommandEvent(event, key: "k")
    }

    @objc(quitColorWithRed:green:blue:alpha:)
    static func quitColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    @objc(statsTextWithText:size:weight:color:alignment:)
    static func statsText(text: String?, size: CGFloat, weight: CGFloat, color: NSColor?, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(frame: .zero)
        label.stringValue = text ?? ""
        label.font = NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight))
        label.textColor = color
        label.alignment = alignment
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    @objc(currentDisplayPixelSizeForWindow:)
    static func currentDisplayPixelSize(for window: NSWindow?) -> NSSize {
        let screen = window?.screen ?? NSScreen.main
        guard let screen else { return NSSize(width: 1920, height: 1080) }
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayId = CGDirectDisplayID(screenNumber.uint32Value)
            let pixelWidth = CGDisplayPixelsWide(displayId)
            let pixelHeight = CGDisplayPixelsHigh(displayId)
            if pixelWidth > 0, pixelHeight > 0 {
                return NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            }
        }
        let scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1
        return NSSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
    }

    private static func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private static func isCommandEvent(_ event: NSEvent?, key: String) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let eventKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return event.modifierFlags.contains(.command) && eventKey == key
    }
}
