import Foundation

public struct NativeNVSTSessionPayload: Equatable, Sendable {
    public let effectiveServerAddress: String
    public let tokenType: String
    public let hasToken: Bool
    public let appID: String
    public let sessionIdentifier: String
    public let streamingProfileGUID: String
    public let audioModeFormat: String
    public let missingStartFields: [String]

    public init(allocation: NativeNVSTSessionAllocation) {
        let object = Self.object(from: allocation.rawSessionJSON)
        let sessionInfo = Self.object(from: allocation.sessionInfoJSON)
        let settings = Self.object(from: allocation.settingsJSON)
        let rawServerAddress = Self.string(object["serverAddress"])
        let sessionRequestData = object["sessionRequestData"] as? [String: Any]
        effectiveServerAddress = rawServerAddress.isEmpty ? allocation.session.serverAddress : rawServerAddress
        tokenType = Self.firstNonEmpty(Self.string(object["tokenType"]), Self.string(object["authType"]), Self.string((object["auth"] as? [String: Any])?["type"]), allocation.authTokenType)
        hasToken = !Self.firstNonEmpty(Self.string(object["token"]), Self.string(object["authToken"]), Self.string(object["jwt"]), Self.string((object["auth"] as? [String: Any])?["token"]), Self.string(object["sessionToken"]), allocation.authToken).isEmpty
        let rawAppID = Self.string(object["appId"])
        let requestAppID = Self.string(sessionRequestData?["appId"])
        appID = Self.firstNonEmpty(rawAppID, requestAppID, allocation.session.applicationID)
        let rawSession = Self.string(object["session"])
        let rawSessionID = Self.string(object["sessionId"])
        sessionIdentifier = Self.firstNonEmpty(rawSession, rawSessionID, allocation.session.id)
        streamingProfileGUID = Self.firstNonEmpty(
            Self.string((object["streamingProfile"] as? [String: Any])?["streamingProfileGuid"]),
            Self.string((object["negotiatedStreamProfile"] as? [String: Any])?["streamingProfileGuid"]),
            Self.string((sessionInfo["streamingProfile"] as? [String: Any])?["streamingProfileGuid"]),
            Self.string((sessionInfo["negotiatedStreamProfile"] as? [String: Any])?["streamingProfileGuid"]),
            Self.string((settings["streamingProfile"] as? [String: Any])?["streamingProfileGuid"])
        )
        audioModeFormat = Self.string(object["audioModeFormat"])
        missingStartFields = Self.missingStartFields(
            effectiveServerAddress: effectiveServerAddress,
            tokenType: tokenType,
            hasToken: hasToken,
            appID: appID,
            sessionIdentifier: sessionIdentifier,
            streamingProfileGUID: streamingProfileGUID
        )
    }

    public var telemetryAttributes: [String: String] {
        [
            "nativeServerAddress": effectiveServerAddress,
            "nativeTokenType": tokenType,
            "nativeHasToken": hasToken ? "true" : "false",
            "nativeAppId": appID,
            "nativeSession": sessionIdentifier,
            "nativeStreamingProfileGuid": streamingProfileGUID,
            "nativeAudioModeFormat": audioModeFormat,
            "nativeMissingStartFields": missingStartFields.joined(separator: ","),
        ]
    }

    private static func object(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSString { return (value as String).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private static func missingStartFields(effectiveServerAddress: String,
                                           tokenType: String,
                                           hasToken: Bool,
                                           appID: String,
                                           sessionIdentifier: String,
                                           streamingProfileGUID: String) -> [String] {
        var fields: [String] = []
        if effectiveServerAddress.isEmpty { fields.append("serverAddress") }
        if tokenType.isEmpty { fields.append("tokenType") }
        if !hasToken { fields.append("token") }
        if appID.isEmpty { fields.append("appId") }
        if sessionIdentifier.isEmpty { fields.append("session") }
        if streamingProfileGUID.isEmpty { fields.append("streamingProfile.streamingProfileGuid") }
        return fields
    }
}
