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

    public init(title: String, message: String, steps: [String], currentStepIndex: Int, isReady: Bool) {
        self.title = title
        self.message = message
        self.steps = steps
        self.currentStepIndex = currentStepIndex
        self.isReady = isReady
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

    public init(sdp: String, sdpMid: String, sdpMLineIndex: Int) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = max(0, sdpMLineIndex)
    }
}

public enum StreamEndReason: String, Codable, Equatable, Hashable, Sendable {
    case completed
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
