import Foundation

enum OPNCloudMatchSessionState: Int, Sendable {
    case initializing = 1
    case readyForConnection = 2
    case streaming = 3
    case paused = 6

    var isVendorResumable: Bool {
        switch self {
        case .readyForConnection, .streaming, .paused:
            true
        case .initializing:
            false
        }
    }

    var isReadyForConnection: Bool {
        self == .readyForConnection || self == .streaming
    }

    var canContinuePolling: Bool {
        self == .initializing || self == .paused
    }
}

struct OPNActiveSessionDescriptor: Equatable, Sendable {
    let sessionId: String
    let appId: Int
    let state: OPNCloudMatchSessionState
    let controlServer: String
    let signalingHost: String
    let streamingBaseUrl: String
    let gpuType: String

    var status: Int { state.rawValue }

    var resumeServer: String { controlServer.isEmpty ? signalingHost : controlServer }

    var signalingUrl: String {
        let host = signalingHost.isEmpty ? controlServer : signalingHost
        return host.isEmpty ? "" : "wss://\(host):443/nvst/"
    }
}

enum OPNActiveSessionParser {
    static func descriptor(from dictionary: [String: Any], streamingBaseUrl: String) -> OPNActiveSessionDescriptor? {
        let sessionId = string(dictionary["sessionId"])
        guard !sessionId.isEmpty else { return nil }
        guard let state = OPNCloudMatchSessionState(rawValue: int(dictionary["status"])), state.isVendorResumable else { return nil }

        let requestData = dictionary["sessionRequestData"] as? [String: Any]
        let controlInfo = dictionary["sessionControlInfo"] as? [String: Any]
        let controlServer = usableEndpointHost(string(controlInfo?["ip"]))
        let signalingHost = firstSignalingHost(from: dictionary)
        let resumeServer = controlServer.isEmpty ? signalingHost : controlServer
        guard !resumeServer.isEmpty else { return nil }

        return OPNActiveSessionDescriptor(
            sessionId: sessionId,
            appId: int(requestData?["appId"]),
            state: state,
            controlServer: controlServer,
            signalingHost: signalingHost,
            streamingBaseUrl: streamingBaseUrl,
            gpuType: string(dictionary["gpuType"])
        )
    }

    private static func firstSignalingHost(from dictionary: [String: Any]) -> String {
        for item in array(dictionary["connectionInfo"]).compactMap({ $0 as? [String: Any] }) where int(item["usage"]) == 14 {
            let ip = usableEndpointHost(string(item["ip"]))
            if !ip.isEmpty { return ip }
            if let host = extractHost(from: string(item["resourcePath"])), !host.isEmpty { return host }
        }
        return ""
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func usableEndpointHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { return "" }
        return trimmed
    }

    private static func extractHost(from value: String) -> String? {
        if let host = URL(string: value)?.host, !host.isEmpty { return host }
        let withoutScheme = value.replacingOccurrences(of: "rtsps://", with: "").replacingOccurrences(of: "wss://", with: "")
        return withoutScheme.split(separator: "/").first?.split(separator: ":").first.map(String.init)
    }
}
