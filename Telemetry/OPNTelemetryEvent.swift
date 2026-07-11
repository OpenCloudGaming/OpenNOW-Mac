import Foundation

public enum OPNTelemetryPrivacyLevel: String, CaseIterable, Sendable {
    case behavioral = "Behavioral"
    case functional = "Functional"
    case technical = "Technical"
}

public enum OPNTelemetryPersonalization: String, CaseIterable, Sendable {
    case userPreferred = "UserPreferred"
}

public enum OPNTelemetryEventName: String, CaseIterable, Sendable {
    case applicationInstall = "Application_Install"
    case authenticationProvider = "AuthenticationProvider"
    case autoUpdate = "AutoUpdate"
    case checkGFN = "CheckGFN"
    case exception = "Exception"
    case gameQuitEvent = "Game_Quit_Event"
    case gfnSession = "GFNSession"
    case httpFailure = "HTTPFailure"
    case httpSuccess = "HTTPSuccess"
    case launchProcess = "LaunchProcess"
    case loginStart = "LoginStart"
    case networkTest = "NetworkTest"
    case networkTestHTTP = "NetworkTest_Http_Event"
    case networkTestException = "NetworkTest_Exception_Event"
    case pageLoadPerformanceMetrics = "PageLoadPerformanceMetrics"
    case popUpDialogClosed = "PopUpDialogClosed"
    case popUpDialogShown = "PopUpDialogShown"
    case routingStatus = "RoutingStatus"
    case settingSnapshot = "SettingSnapshot"
    case streamingProfile = "StreamingProfile"
    case streamingQualityChanged = "StreamingQualityChangedEvent"
    case systemInfo = "SystemInfo"
    case uiAction = "UIAction"
    case userSession = "UserSession"
    case udsDialogShown = "UDSDialogShown"
    case udsEndOfSessionReport = "UdsEndOfSessionReport"
    case udsSuggestionFeedback = "UDSSuggestionFeedback"
    case gameLaunchEvent = "Game_Launch_Event"
    case gameLaunchMetrics = "Game_Launch_Metrics"

    public var privacyLevel: OPNTelemetryPrivacyLevel {
        switch self {
        case .applicationInstall, .networkTest, .userSession:
            .behavioral
        case .authenticationProvider, .autoUpdate, .checkGFN, .exception, .gameQuitEvent, .gfnSession, .httpFailure, .httpSuccess, .launchProcess, .networkTestHTTP, .pageLoadPerformanceMetrics, .popUpDialogShown, .routingStatus, .streamingQualityChanged, .systemInfo, .uiAction, .udsDialogShown, .udsEndOfSessionReport, .udsSuggestionFeedback, .gameLaunchMetrics:
            .functional
        case .gameLaunchEvent, .loginStart, .networkTestException, .popUpDialogClosed, .settingSnapshot, .streamingProfile:
            .technical
        }
    }

    public var personalization: OPNTelemetryPersonalization {
        .userPreferred
    }
}

public struct OPNTelemetryCommonData: Equatable, Sendable {
    public let appId: String
    public let clientVersion: String
    public let deviceId: String
    public let locale: String
    public let sessionId: String

    public init(appId: String = "opennow", clientVersion: String = "", deviceId: String = "", locale: String = "", sessionId: String = "") {
        self.appId = appId
        self.clientVersion = clientVersion
        self.deviceId = deviceId
        self.locale = locale
        self.sessionId = sessionId
    }

    public var dictionary: [String: String] {
        [
            "appId": appId,
            "clientVersion": clientVersion,
            "deviceId": deviceId,
            "locale": locale,
            "sessionId": sessionId,
        ].filter { !$0.value.isEmpty }
    }
}

public struct OPNTelemetryEvent: Equatable, Sendable {
    public let name: OPNTelemetryEventName
    public let timestamp: String
    public let parameters: [String: String]
    public let privacyLevel: OPNTelemetryPrivacyLevel
    public let personalization: OPNTelemetryPersonalization

    public init(name: OPNTelemetryEventName, timestamp: String = OPNTelemetryEvent.currentTimestamp(), parameters: [String: String] = [:], privacyLevel: OPNTelemetryPrivacyLevel? = nil, personalization: OPNTelemetryPersonalization? = nil) {
        self.name = name
        self.timestamp = timestamp
        self.parameters = parameters
        self.privacyLevel = privacyLevel ?? name.privacyLevel
        self.personalization = personalization ?? name.personalization
    }

    public var dictionary: [String: Any] {
        [
            "name": name.rawValue,
            "timestamp": timestamp,
            "parameters": parameters,
            "privacyLevel": privacyLevel.rawValue,
            "personalization": personalization.rawValue,
        ]
    }

    public static func currentTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

public enum OPNTelemetryRecorder {
    @discardableResult
    public static func record(_ event: OPNTelemetryEvent, commonData: OPNTelemetryCommonData = OPNTelemetryCommonData()) -> Bool {
        guard OPNSentry.isTelemetryEnabled() else { return false }
        let attributes = sentryAttributes(event: event, commonData: commonData)
        _ = OPNSentry.recordCounterMetric(key: "opennow.telemetry.events.count", value: 1, attributes: attributes)
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Telemetry", message: logMessage(event: event, commonData: commonData)))
        return true
    }

    static func sentryAttributes(event: OPNTelemetryEvent, commonData: OPNTelemetryCommonData) -> [String: Any] {
        var attributes: [String: Any] = [
            "opennow.event": event.name.rawValue,
            "opennow.privacy_level": event.privacyLevel.rawValue,
            "opennow.personalization": event.personalization.rawValue,
        ]
        for (key, value) in commonData.dictionary {
            attributes["opennow.common.\(key)"] = sanitizedTelemetryValue(key: key, value: value)
        }
        for (key, value) in event.parameters where !key.isEmpty {
            attributes["opennow.parameter.\(OPNSentry.sanitizedLogMessage(key))"] = sanitizedTelemetryValue(key: key, value: value)
        }
        return attributes.filter { !$0.key.isEmpty }
    }

    static func logMessage(event: OPNTelemetryEvent, commonData: OPNTelemetryCommonData) -> String {
        let parameterText = sortedPairs(event.parameters)
        let commonText = sortedPairs(commonData.dictionary)
        return "Event name=\(event.name.rawValue) privacy=\(event.privacyLevel.rawValue) personalization=\(event.personalization.rawValue) timestamp=\(event.timestamp) parameters=\(parameterText) common=\(commonText)"
    }

    private static func sortedPairs(_ dictionary: [String: String]) -> String {
        let pairs = dictionary.keys.sorted().map { key in
            "\(OPNSentry.sanitizedLogMessage(key))=\(sanitizedTelemetryValue(key: key, value: dictionary[key] ?? ""))"
        }
        return pairs.isEmpty ? "[]" : "[\(pairs.joined(separator: ","))]"
    }

    private static func sanitizedTelemetryValue(key: String, value: String) -> String {
        if key.localizedCaseInsensitiveContains("version") { return value }
        return OPNSentry.sanitizedLogMessage(value)
    }
}
