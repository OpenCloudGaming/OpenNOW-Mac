import Foundation

enum OPNProtocolDebugMapper {
    private static let sequence = ProtocolCaptureSequence()

    static func loggingEnabled() -> Bool {
        environmentFlagEnabled("OPN_PROTOCOL_DEBUG") ||
            environmentFlagEnabled("OPN_CAPTURE_PROTOCOL") ||
            ProcessInfo.processInfo.environment["OPN_PROTOCOL_CAPTURE_DIR"] != nil
    }

    static func sanitizedJSONString(fromJSONObject object: Any?) -> String {
        guard let object, !(object is NSNull) else { return "null" }
        let sanitized = sanitizedValue(object, key: nil)
        guard JSONSerialization.isValidJSONObject(sanitized),
              let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: sanitized)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func sanitizedJSONString(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return sanitizedJSONString(fromJSONObject: object)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func captureFilename(label: String?, sequence: UInt) -> String {
        let raw = label?.isEmpty == false ? label!.lowercased() : "payload"
        var safe = ""
        var previousDash = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                safe.unicodeScalars.append(scalar)
                previousDash = false
            } else if !previousDash, !safe.isEmpty {
                safe.append("-")
                previousDash = true
            }
        }
        while safe.last == "-" {
            safe.removeLast()
        }
        if safe.isEmpty { safe = "payload" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        return String(format: "%@-%06llu-%@.json", timestamp, UInt64(sequence), safe)
    }

    static func logJSONObject(label: String?, object: Any?) {
        guard loggingEnabled() else { return }
        let payload = sanitizedJSONString(fromJSONObject: object)
        writeCapture(label: label, payload: payload)
        NSLog("[ProtocolDebug] %@: %@", label ?? "payload", payload)
    }

    static func logJSONData(label: String?, data: Data?) {
        guard loggingEnabled() else { return }
        let payload = sanitizedJSONString(from: data)
        writeCapture(label: label, payload: payload)
        NSLog("[ProtocolDebug] %@: %@", label ?? "payload", payload)
    }

    private static func environmentFlagEnabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    private static func protocolCaptureDirectory() -> String? {
        guard let value = ProcessInfo.processInfo.environment["OPN_PROTOCOL_CAPTURE_DIR"] else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : NSString(string: path).expandingTildeInPath
    }

    private static func normalizedKey(_ key: String?) -> String {
        guard let key else { return "" }
        return key.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "_- ."))
            .joined()
    }

    private static func shouldRedactKey(_ key: String?) -> Bool {
        let normalized = normalizedKey(key)
        if normalized.isEmpty { return false }
        if ["authorization", "cookie", "setcookie", "ip", "email"].contains(normalized) { return true }
        let substrings = [
            "token", "secret", "password", "credential", "devicehashid", "deviceid",
            "userid", "clientid", "sessionid", "subsessionid", "serverip", "clientip", "ipaddress",
            "resourcepath", "signaling", "sdp", "candidate"
        ]
        return substrings.contains { normalized.contains($0) }
    }

    private static func sanitizedValue(_ value: Any?, key: String?) -> Any {
        if shouldRedactKey(key) { return "<redacted>" }
        if let dictionary = value as? [AnyHashable: Any] {
            var sanitized: [String: Any] = [:]
            let metadataKey = dictionary["key"] as? String
            for (rawKey, childValue) in dictionary {
                let childKey = rawKey as? String ?? String(describing: rawKey)
                let effectiveKey = childKey == "value" && metadataKey?.isEmpty == false ? metadataKey : childKey
                sanitized[childKey] = sanitizedValue(childValue, key: effectiveKey)
            }
            return sanitized
        }
        if let array = value as? [Any] {
            return array.map { sanitizedValue($0, key: nil) }
        }
        if let string = value as? String {
            let lower = string.lowercased()
            if lower.hasPrefix("gfnjwt ") || lower.hasPrefix("bearer ") { return "<redacted>" }
        }
        return value ?? NSNull()
    }

    private static func writeCapture(label: String?, payload: String) {
        guard let directory = protocolCaptureDirectory(), !payload.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let filename = captureFilename(label: label, sequence: sequence.next())
            let path = NSString(string: directory).appendingPathComponent(filename)
            try payload.write(toFile: path, atomically: true, encoding: .utf8)
            NSLog("[ProtocolDebug] Wrote sanitized capture: %@", path)
        } catch {
            NSLog("[ProtocolDebug] Failed to write capture in %@: %@", directory, error.localizedDescription)
        }
    }
}

@objc(OPNProtocolDebug)
final class OPNProtocolDebug: NSObject {
    @objc(loggingEnabled)
    static func loggingEnabled() -> Bool {
        OPNProtocolDebugMapper.loggingEnabled()
    }

    @objc(sanitizedJSONStringFromJSONObject:)
    static func sanitizedJSONString(fromJSONObject object: Any?) -> String {
        OPNProtocolDebugMapper.sanitizedJSONString(fromJSONObject: object)
    }

    @objc(sanitizedJSONStringFromData:)
    static func sanitizedJSONString(from data: Data?) -> String {
        OPNProtocolDebugMapper.sanitizedJSONString(from: data)
    }

    @objc(captureFilenameWithLabel:sequence:)
    static func captureFilename(label: String?, sequence: UInt) -> String {
        OPNProtocolDebugMapper.captureFilename(label: label, sequence: sequence)
    }

    @objc(logJSONObjectWithLabel:object:)
    static func logJSONObject(label: String?, object: Any?) {
        OPNProtocolDebugMapper.logJSONObject(label: label, object: object)
    }

    @objc(logJSONDataWithLabel:data:)
    static func logJSONData(label: String?, data: Data?) {
        OPNProtocolDebugMapper.logJSONData(label: label, data: data)
    }
}

private final class ProtocolCaptureSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt = 0

    func next() -> UInt {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
