import Foundation

public struct StreamLaunchConfiguration: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let applicationID: String
    public let accessToken: String
    public let accountLinked: Bool
    public let selectedStore: String
    public let resumeSessionID: String
    public let resumeServer: String
    public let metadata: [String: String]

    public init(id: UUID = UUID(),
                title: String,
                applicationID: String,
                accessToken: String,
                accountLinked: Bool,
                selectedStore: String,
                resumeSessionID: String = "",
                resumeServer: String = "",
                metadata: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.applicationID = applicationID
        self.accessToken = accessToken
        self.accountLinked = accountLinked
        self.selectedStore = selectedStore
        self.resumeSessionID = resumeSessionID
        self.resumeServer = resumeServer
        self.metadata = metadata
    }

    public var resumesExistingSession: Bool {
        !resumeSessionID.isEmpty && !resumeServer.isEmpty
    }
}

public enum StreamLaunchStep: Int, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case checkNetworkRoute
    case allocateCloudSession
    case receiveStreamOffer
    case negotiateWebRTC
    case connected

    public var title: String {
        switch self {
        case .checkNetworkRoute:
            "Check network route"
        case .allocateCloudSession:
            "Allocate cloud session"
        case .receiveStreamOffer:
            "Receive stream offer"
        case .negotiateWebRTC:
            "Negotiate WebRTC"
        case .connected:
            "Connected"
        }
    }
}

public struct StreamProgress: Codable, Equatable, Sendable {
    public let title: String
    public let message: String
    public let steps: [String]
    public let currentStepIndex: Int
    public let isReady: Bool
    public let queuePosition: Int?
    public let sessionLimitStartedAtEpochSeconds: Double?
    public let sessionLimitSeconds: Int?

    public init(title: String, message: String, steps: [String], currentStepIndex: Int, isReady: Bool, queuePosition: Int? = nil, sessionLimitStartedAtEpochSeconds: Double? = nil, sessionLimitSeconds: Int? = nil) {
        self.title = title
        self.message = message
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.isReady = isReady
        self.queuePosition = queuePosition
        self.sessionLimitStartedAtEpochSeconds = sessionLimitStartedAtEpochSeconds
        self.sessionLimitSeconds = sessionLimitSeconds
    }

    public init(configuration: StreamLaunchConfiguration, step: StreamLaunchStep, message: String, isReady: Bool = false) {
        self.init(
            title: configuration.title.isEmpty ? "Stream" : configuration.title,
            message: message,
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: step.rawValue,
            isReady: isReady
        )
    }
}

public struct StreamSessionLimitUpdate: Codable, Equatable, Sendable {
    public let remainingSeconds: Int
    public let presentDurationSeconds: Int?
    public let timerType: String

    public init?(remainingSeconds: Int, presentDurationSeconds: Int? = nil, timerType: String = "") {
        guard remainingSeconds > 0, remainingSeconds <= 86_400 else { return nil }
        self.remainingSeconds = remainingSeconds
        self.presentDurationSeconds = presentDurationSeconds.map { max(0, $0) }
        self.timerType = timerType
    }

    public static func parse(from data: Data) -> StreamSessionLimitUpdate? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parse(from: value)
    }

    private static func parse(from value: Any) -> StreamSessionLimitUpdate? {
        if let dictionary = value as? [String: Any] { return parse(from: dictionary) }
        if let array = value as? [Any] { return array.lazy.compactMap(parse(from:)).first }
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return parse(from: json)
        }
        return nil
    }

    private static func parse(from dictionary: [String: Any]) -> StreamSessionLimitUpdate? {
        if isSessionLengthTimer(dictionary), let update = update(from: dictionary) ?? nestedTimerUpdate(from: dictionary) {
            return update
        }
        for key in ["message", "payload", "data", "eventData", "customMessage"] {
            if let value = dictionary[key], let update = parse(from: value) { return update }
        }
        return nil
    }

    private static func nestedTimerUpdate(from dictionary: [String: Any]) -> StreamSessionLimitUpdate? {
        guard let timerData = dictionary["timerData"] as? [String: Any] else { return nil }
        return update(from: timerData)
    }

    private static func update(from dictionary: [String: Any]) -> StreamSessionLimitUpdate? {
        guard let remainingSeconds = remainingSeconds(in: dictionary) else { return nil }
        let presentDurationSeconds = milliseconds(dictionary["presentDurationMS"]).map { Int(($0 / 1000.0).rounded()) }
        return StreamSessionLimitUpdate(
            remainingSeconds: remainingSeconds,
            presentDurationSeconds: presentDurationSeconds,
            timerType: string(dictionary["timerType"])
        )
    }

    private static func remainingSeconds(in dictionary: [String: Any]) -> Int? {
        for key in ["beforeEventMS", "remainingSessionLimitMs", "remainingSessionLimitMilliseconds", "sessionLimitRemainingMs", "sessionLimitRemainingMilliseconds"] {
            if let value = milliseconds(dictionary[key]) {
                let seconds = Int((value / 1000.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
        }
        for key in ["timeRemaining", "remainingTime", "remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingSessionLimitSeconds", "sessionLimitRemainingSeconds"] {
            if let value = number(dictionary[key]) {
                let seconds = Int(value.rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
        }
        for key in ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes", "remainingSessionLimitMinutes", "sessionLimitRemainingMinutes"] {
            if let value = number(dictionary[key]) {
                let seconds = Int((value * 60.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
        }
        return nil
    }

    private static func isSessionLengthTimer(_ dictionary: [String: Any]) -> Bool {
        ["messageType", "type", "eventType"].contains { key in
            string(dictionary[key]).caseInsensitiveCompare("SESSION_LENGTH_TIMER") == .orderedSame
        }
    }

    private static func milliseconds(_ value: Any?) -> Double? { number(value) }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}

public struct StreamSessionAdPresentation: Equatable, Sendable {
    public let adId: String
    public let title: String
    public let mediaUrl: String
    public let durationMs: Int

    public init(adId: String, title: String, mediaUrl: String, durationMs: Int) {
        self.adId = adId
        self.title = title
        self.mediaUrl = mediaUrl
        self.durationMs = durationMs
    }
}

public protocol StreamSessionAdPresenter: Sendable {
    func playRequiredSessionAd(_ ad: StreamSessionAdPresentation) async throws -> Int
}

public struct StreamSessionDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let applicationID: String
    public let serverAddress: String
    public let title: String
    public let metadata: [String: String]

    public init(id: String, applicationID: String, serverAddress: String, title: String, metadata: [String: String] = [:]) {
        self.id = id
        self.applicationID = applicationID
        self.serverAddress = serverAddress
        self.title = title.isEmpty ? "Current Stream" : title
        self.metadata = metadata
    }
}

public struct StreamSessionConflict: Equatable, Sendable {
    public let sessionID: String
    public let applicationID: String
    public let serverAddress: String
    public let isResumable: Bool

    public init(sessionID: String, applicationID: String, serverAddress: String, isResumable: Bool = false) {
        self.sessionID = sessionID
        self.applicationID = applicationID
        self.serverAddress = serverAddress
        self.isResumable = isResumable
    }

    public var reportMetadata: [String: String] {
        [
            "sessionConflictReason": "sessionLimit",
            "sessionConflictSessionID": sessionID,
            "sessionConflictApplicationID": applicationID,
            "sessionConflictServerAddress": serverAddress,
            "sessionConflictIsResumable": String(isResumable),
        ]
    }

    public init?(reportMetadata: [String: String]) {
        guard reportMetadata["sessionConflictReason"] == "sessionLimit" else { return nil }
        let sessionID = reportMetadata["sessionConflictSessionID"] ?? ""
        let serverAddress = reportMetadata["sessionConflictServerAddress"] ?? ""
        guard !sessionID.isEmpty, !serverAddress.isEmpty else { return nil }
        self.init(
            sessionID: sessionID,
            applicationID: reportMetadata["sessionConflictApplicationID"] ?? "",
            serverAddress: serverAddress,
            isResumable: reportMetadata["sessionConflictIsResumable"] == "true"
        )
    }
}

public struct StreamOffer: Codable, Equatable, Sendable {
    public let session: StreamSessionDescriptor
    public let sdp: String
    public let metadata: [String: String]

    public init(session: StreamSessionDescriptor, sdp: String, metadata: [String: String] = [:]) {
        self.session = session
        self.sdp = sdp
        self.metadata = metadata
    }
}

public struct StreamAnswer: Codable, Equatable, Sendable {
    public let sdp: String
    public let metadata: [String: String]

    public init(sdp: String, metadata: [String: String] = [:]) {
        self.sdp = sdp
        self.metadata = metadata
    }
}

public struct StreamIceCandidate: Codable, Equatable, Hashable, Sendable {
    public let sdp: String
    public let sdpMid: String
    public let sdpMLineIndex: Int
    public let usernameFragment: String
    public let isEndOfCandidates: Bool

    public init(sdp: String, sdpMid: String, sdpMLineIndex: Int, usernameFragment: String = "", isEndOfCandidates: Bool = false) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = max(0, sdpMLineIndex)
        self.usernameFragment = usernameFragment
        self.isEndOfCandidates = isEndOfCandidates
    }

    public static let endOfCandidates = StreamIceCandidate(sdp: "", sdpMid: "", sdpMLineIndex: 0, isEndOfCandidates: true)
}

public enum StreamEndReason: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case paused
    case userRequested
    case remoteEnded
    case failed
}

public struct StreamReport: Codable, Equatable, Sendable {
    public let title: String
    public let success: Bool
    public let reason: StreamEndReason
    public let message: String
    public let durationSeconds: Double
    public let metadata: [String: String]

    public init(title: String,
                success: Bool,
                reason: StreamEndReason,
                message: String,
                durationSeconds: Double,
                metadata: [String: String] = [:]) {
        self.title = title
        self.success = success
        self.reason = reason
        self.message = message
        self.durationSeconds = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        self.metadata = metadata
    }
}

public enum StreamingPathState: Equatable, Sendable {
    case idle
    case starting(StreamProgress)
    case running(StreamSessionDescriptor)
    case ended(StreamReport)
}

public enum StreamingPathError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidOffer
    case notRunning
}
