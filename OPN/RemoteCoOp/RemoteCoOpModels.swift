import Foundation
import CryptoKit

public enum OPNRemoteCoOpTransportMode: String, CaseIterable, Codable, Equatable, Sendable {
    case automatic
    case directOnly
    case relayOnly

    public var label: String {
        switch self {
        case .automatic: return "Auto"
        case .directOnly: return "Direct Only"
        case .relayOnly: return "Relay Only"
        }
    }

    public var description: String {
        switch self {
        case .automatic: return "Default. Try direct WebRTC first and fall back to relay through TURN when routers or firewalls block direct paths."
        case .directOnly: return "Only connect when guests can reach the host directly. This may expose peer network information."
        case .relayOnly: return "Force TURN relay connectivity to avoid exposing direct peer IP candidates."
        }
    }

    public var iceTransportPolicy: OPNRemoteCoOpICETransportPolicy {
        switch self {
        case .automatic, .directOnly: .all
        case .relayOnly: .relay
        }
    }

    public var allowsRelayFallback: Bool {
        switch self {
        case .automatic, .relayOnly: true
        case .directOnly: false
        }
    }

    public var hidesDirectPeerCandidates: Bool {
        self == .relayOnly
    }
}

public enum OPNRemoteCoOpICETransportPolicy: String, Codable, Equatable, Sendable {
    case all
    case relay
}

public enum OPNRemoteCoOpLatencyMode: String, CaseIterable, Codable, Equatable, Sendable {
    case quality
    case lowLatency

    public var label: String {
        switch self {
        case .quality: return "Quality"
        case .lowLatency: return "Low Latency"
        }
    }

    public var description: String {
        switch self {
        case .quality: return "Prioritizes image quality with higher bitrate targets. Best for watching or stable LAN sessions."
        case .lowLatency: return "Prioritizes responsiveness by reducing buffering and letting WebRTC lower quality before queueing frames."
        }
    }
}

public struct OPNRemoteCoOpICEServer: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.username = username?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.credential = credential?.nilIfEmpty
    }
}

public struct OPNRemoteCoOpNetworkConfiguration: Codable, Equatable, Sendable {
    public var transportMode: OPNRemoteCoOpTransportMode
    public var iceTransportPolicy: OPNRemoteCoOpICETransportPolicy
    public var latencyMode: OPNRemoteCoOpLatencyMode
    public var iceServers: [OPNRemoteCoOpICEServer]
    public var dataChannelInputEnabled: Bool
    public var websocketInputFallbackEnabled: Bool
    public var directPeerCandidateWarning: String

    public init(transportMode: OPNRemoteCoOpTransportMode,
                latencyMode: OPNRemoteCoOpLatencyMode = .quality,
                iceServers: [OPNRemoteCoOpICEServer] = [],
                dataChannelInputEnabled: Bool = true,
                websocketInputFallbackEnabled: Bool = true,
                directPeerCandidateWarning: String = "") {
        self.transportMode = transportMode
        self.iceTransportPolicy = transportMode.iceTransportPolicy
        self.latencyMode = latencyMode
        self.iceServers = iceServers
        self.dataChannelInputEnabled = dataChannelInputEnabled
        self.websocketInputFallbackEnabled = websocketInputFallbackEnabled
        self.directPeerCandidateWarning = directPeerCandidateWarning.isEmpty ? Self.warning(for: transportMode) : directPeerCandidateWarning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transportMode = try container.decodeIfPresent(OPNRemoteCoOpTransportMode.self, forKey: .transportMode) ?? .automatic
        iceTransportPolicy = try container.decodeIfPresent(OPNRemoteCoOpICETransportPolicy.self, forKey: .iceTransportPolicy) ?? transportMode.iceTransportPolicy
        latencyMode = try container.decodeIfPresent(OPNRemoteCoOpLatencyMode.self, forKey: .latencyMode) ?? .quality
        iceServers = try container.decodeIfPresent([OPNRemoteCoOpICEServer].self, forKey: .iceServers) ?? []
        dataChannelInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .dataChannelInputEnabled) ?? true
        websocketInputFallbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .websocketInputFallbackEnabled) ?? true
        let warning = try container.decodeIfPresent(String.self, forKey: .directPeerCandidateWarning) ?? ""
        directPeerCandidateWarning = warning.isEmpty ? Self.warning(for: transportMode) : warning
    }

    public static func warning(for mode: OPNRemoteCoOpTransportMode) -> String {
        switch mode {
        case .automatic:
            return "Automatic mode may use direct peer candidates before falling back to TURN relay. Use Relay Only to hide direct IP candidates."
        case .directOnly:
            return "Direct Only mode can expose direct peer IP candidates and may fail behind strict routers or firewalls."
        case .relayOnly:
            return "Relay Only mode uses TURN relay candidates to avoid exposing direct peer IP candidates."
        }
    }
}

public enum OPNRemoteCoOpQualityPreset: String, CaseIterable, Codable, Equatable, Sendable {
    case p720f30
    case p720f60
    case p1080f60

    public var label: String {
        switch self {
        case .p720f30: return "720p 30 FPS"
        case .p720f60: return "720p 60 FPS"
        case .p1080f60: return "1080p 60 FPS"
        }
    }

    public var width: Int {
        switch self {
        case .p720f30, .p720f60: return 1280
        case .p1080f60: return 1920
        }
    }

    public var height: Int {
        switch self {
        case .p720f30, .p720f60: return 720
        case .p1080f60: return 1080
        }
    }

    public var fps: Int {
        switch self {
        case .p720f30: return 30
        case .p720f60, .p1080f60: return 60
        }
    }

    public var videoMaxBitrateBps: Int {
        switch self {
        case .p720f30: return 6_000_000
        case .p720f60: return 12_000_000
        case .p1080f60: return 20_000_000
        }
    }

    public var videoMinBitrateBps: Int {
        switch self {
        case .p720f30: return 2_500_000
        case .p720f60: return 5_000_000
        case .p1080f60: return 8_000_000
        }
    }

    public func videoMaxBitrateBps(for latencyMode: OPNRemoteCoOpLatencyMode) -> Int {
        switch latencyMode {
        case .quality:
            return videoMaxBitrateBps
        case .lowLatency:
            switch self {
            case .p720f30: return 4_000_000
            case .p720f60: return 8_000_000
            case .p1080f60: return 12_000_000
            }
        }
    }

    public func videoMinBitrateBps(for latencyMode: OPNRemoteCoOpLatencyMode) -> Int? {
        switch latencyMode {
        case .quality:
            return videoMinBitrateBps
        case .lowLatency:
            return nil
        }
    }
}

public struct OPNRemoteCoOpPreferences: Codable, Equatable, Sendable {
    public static let launchMetadataEnabledKey = "remoteCoOpEnabled"
    public static let launchMetadataReservedGuestSlotsKey = "remoteCoOpReservedGuestSlots"
    public static let launchMetadataTransportModeKey = "remoteCoOpTransportMode"
    public static let launchMetadataQualityPresetKey = "remoteCoOpQualityPreset"
    public static let launchMetadataLatencyModeKey = "remoteCoOpLatencyMode"
    public static let launchMetadataRequireHostApprovalKey = "remoteCoOpRequireHostApproval"
    public static let launchMetadataSignalingServerURLKey = "remoteCoOpSignalingServerURL"
    public static let launchMetadataGuestJoinBaseURLKey = "remoteCoOpGuestJoinBaseURL"
    public static let launchMetadataHideGuestInviteDetailsKey = "remoteCoOpHideGuestInviteDetails"

    public static let defaultSignalingServerURL = "ws://jayian.dev:8788/remote-coop"
    public static let defaultGuestJoinBaseURL = "http://jayian.dev:8788/"

    public var isEnabled: Bool
    public var reservedGuestSlots: Int
    public var transportMode: OPNRemoteCoOpTransportMode
    public var qualityPreset: OPNRemoteCoOpQualityPreset
    public var latencyMode: OPNRemoteCoOpLatencyMode
    public var requireHostApproval: Bool
    public var signalingServerURL: String
    public var guestJoinBaseURL: String
    public var hideGuestInviteDetails: Bool

    public init(isEnabled: Bool = false,
                reservedGuestSlots: Int = 1,
                transportMode: OPNRemoteCoOpTransportMode = .automatic,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                latencyMode: OPNRemoteCoOpLatencyMode = .quality,
                requireHostApproval: Bool = true,
                signalingServerURL: String = Self.defaultSignalingServerURL,
                guestJoinBaseURL: String = Self.defaultGuestJoinBaseURL,
                hideGuestInviteDetails: Bool = false) {
        self.isEnabled = isEnabled
        self.reservedGuestSlots = Self.clampedGuestSlots(reservedGuestSlots)
        self.transportMode = transportMode
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.requireHostApproval = requireHostApproval
        self.signalingServerURL = Self.normalizedURLString(signalingServerURL, fallback: Self.defaultSignalingServerURL)
        self.guestJoinBaseURL = Self.normalizedURLString(guestJoinBaseURL, fallback: Self.defaultGuestJoinBaseURL)
        self.hideGuestInviteDetails = hideGuestInviteDetails
    }

    public var effectiveReservedGuestSlots: Int {
        isEnabled ? Self.clampedGuestSlots(reservedGuestSlots) : 0
    }

    public static func clampedGuestSlots(_ value: Int) -> Int {
        min(3, max(0, value))
    }

    public var launchMetadata: [String: String] {
        [
            Self.launchMetadataEnabledKey: String(isEnabled),
            Self.launchMetadataReservedGuestSlotsKey: String(Self.clampedGuestSlots(reservedGuestSlots)),
            Self.launchMetadataTransportModeKey: transportMode.rawValue,
            Self.launchMetadataQualityPresetKey: qualityPreset.rawValue,
            Self.launchMetadataLatencyModeKey: latencyMode.rawValue,
            Self.launchMetadataRequireHostApprovalKey: String(requireHostApproval),
            Self.launchMetadataSignalingServerURLKey: signalingServerURL,
            Self.launchMetadataGuestJoinBaseURLKey: guestJoinBaseURL,
            Self.launchMetadataHideGuestInviteDetailsKey: String(hideGuestInviteDetails),
        ]
    }

    public static func launchPreferences(from metadata: [String: String], fallback: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences(
            isEnabled: bool(metadata[launchMetadataEnabledKey], defaultValue: fallback.isEnabled),
            reservedGuestSlots: int(metadata[launchMetadataReservedGuestSlotsKey], defaultValue: fallback.reservedGuestSlots),
            transportMode: OPNRemoteCoOpTransportMode(rawValue: metadata[launchMetadataTransportModeKey] ?? "") ?? fallback.transportMode,
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: metadata[launchMetadataQualityPresetKey] ?? "") ?? fallback.qualityPreset,
            latencyMode: OPNRemoteCoOpLatencyMode(rawValue: metadata[launchMetadataLatencyModeKey] ?? "") ?? fallback.latencyMode,
            requireHostApproval: bool(metadata[launchMetadataRequireHostApprovalKey], defaultValue: fallback.requireHostApproval),
            signalingServerURL: string(metadata[launchMetadataSignalingServerURLKey], defaultValue: fallback.signalingServerURL),
            guestJoinBaseURL: string(metadata[launchMetadataGuestJoinBaseURLKey], defaultValue: fallback.guestJoinBaseURL),
            hideGuestInviteDetails: bool(metadata[launchMetadataHideGuestInviteDetailsKey], defaultValue: fallback.hideGuestInviteDetails)
        )
    }

    public static func normalizedURLString(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func int(_ value: String?, defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return parsed
    }

    private static func bool(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
    }

    private static func string(_ value: String?, defaultValue: String) -> String {
        normalizedURLString(value ?? "", fallback: defaultValue)
    }
}

public enum OPNRemoteCoOpInviteTokenError: LocalizedError, Equatable, Sendable {
    case malformed
    case invalidSignature
    case expired

    public var errorDescription: String? {
        switch self {
        case .malformed: return "Remote Co-Op invite token is malformed."
        case .invalidSignature: return "Remote Co-Op invite token signature is invalid."
        case .expired: return "Remote Co-Op invite token has expired."
        }
    }
}

public struct OPNRemoteCoOpInviteTokenPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let inviteID: UUID
    public let code: String
    public let applicationID: String
    public let title: String
    public let createdAtEpochSeconds: TimeInterval
    public let expiresAtEpochSeconds: TimeInterval
    public let reservedGuestSlots: Int
    public let transportMode: OPNRemoteCoOpTransportMode
    public let qualityPreset: OPNRemoteCoOpQualityPreset
    public let latencyMode: OPNRemoteCoOpLatencyMode
    public let requireHostApproval: Bool
    public let hideGuestInviteDetails: Bool

    public init(version: Int = 1,
                inviteID: UUID,
                code: String,
                applicationID: String,
                title: String,
                createdAt: Date,
                expiresAt: Date,
                preferences: OPNRemoteCoOpPreferences) {
        self.version = version
        self.inviteID = inviteID
        self.code = code
        self.applicationID = preferences.hideGuestInviteDetails ? "" : applicationID
        self.title = preferences.hideGuestInviteDetails ? "" : title
        self.createdAtEpochSeconds = createdAt.timeIntervalSince1970
        self.expiresAtEpochSeconds = expiresAt.timeIntervalSince1970
        self.reservedGuestSlots = preferences.effectiveReservedGuestSlots
        self.transportMode = preferences.transportMode
        self.qualityPreset = preferences.qualityPreset
        self.latencyMode = preferences.latencyMode
        self.requireHostApproval = preferences.requireHostApproval
        self.hideGuestInviteDetails = preferences.hideGuestInviteDetails
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        inviteID = try container.decode(UUID.self, forKey: .inviteID)
        code = try container.decode(String.self, forKey: .code)
        applicationID = try container.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAtEpochSeconds = try container.decode(TimeInterval.self, forKey: .createdAtEpochSeconds)
        expiresAtEpochSeconds = try container.decode(TimeInterval.self, forKey: .expiresAtEpochSeconds)
        reservedGuestSlots = try container.decodeIfPresent(Int.self, forKey: .reservedGuestSlots) ?? 0
        transportMode = try container.decodeIfPresent(OPNRemoteCoOpTransportMode.self, forKey: .transportMode) ?? .automatic
        qualityPreset = try container.decodeIfPresent(OPNRemoteCoOpQualityPreset.self, forKey: .qualityPreset) ?? .p720f60
        latencyMode = try container.decodeIfPresent(OPNRemoteCoOpLatencyMode.self, forKey: .latencyMode) ?? .quality
        requireHostApproval = try container.decodeIfPresent(Bool.self, forKey: .requireHostApproval) ?? true
        hideGuestInviteDetails = try container.decodeIfPresent(Bool.self, forKey: .hideGuestInviteDetails) ?? false
    }

    public var createdAt: Date { Date(timeIntervalSince1970: createdAtEpochSeconds) }
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtEpochSeconds) }
}

public struct OPNRemoteCoOpInviteTokenSigner: Equatable, Sendable {
    private let secret: Data

    public init() {
        self.secret = Self.randomSecret()
    }

    public init(secret: Data) {
        self.secret = secret.isEmpty ? Self.randomSecret() : secret
    }

    public func token(for payload: OPNRemoteCoOpInviteTokenPayload) throws -> String {
        let payloadData = try Self.encoder().encode(payload)
        let signature = HMAC<SHA256>.authenticationCode(for: payloadData, using: SymmetricKey(data: secret))
        return "\(Self.base64URLEncoded(payloadData)).\(Self.base64URLEncoded(Data(signature)))"
    }

    public func verify(_ token: String, now: Date = Date()) throws -> OPNRemoteCoOpInviteTokenPayload {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let payloadData = Self.base64URLDecoded(String(parts[0])),
              let signatureData = Self.base64URLDecoded(String(parts[1])) else { throw OPNRemoteCoOpInviteTokenError.malformed }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: payloadData, using: SymmetricKey(data: secret)))
        guard expected == signatureData else { throw OPNRemoteCoOpInviteTokenError.invalidSignature }
        let payload = try JSONDecoder().decode(OPNRemoteCoOpInviteTokenPayload.self, from: payloadData)
        guard payload.expiresAt > now else { throw OPNRemoteCoOpInviteTokenError.expired }
        return payload
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func randomSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 { base64.append(String(repeating: "=", count: 4 - padding)) }
        return Data(base64Encoded: base64)
    }
}

public enum OPNRemoteCoOpParticipantRole: String, Codable, Equatable, Sendable {
    case host
    case guest
    case spectator
}

public enum OPNRemoteCoOpParticipantConnectionState: String, Codable, Equatable, Sendable {
    case waitingForApproval
    case connecting
    case connected
    case disconnected
    case failed
}

public struct OPNRemoteCoOpParticipant: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var role: OPNRemoteCoOpParticipantRole
    public var connectionState: OPNRemoteCoOpParticipantConnectionState
    public var inputEnabled: Bool
    public var playerIndex: Int?
    public var joinedAt: Date
    public var lastActivityAt: Date

    public init(id: UUID = UUID(),
                displayName: String,
                role: OPNRemoteCoOpParticipantRole,
                connectionState: OPNRemoteCoOpParticipantConnectionState,
                inputEnabled: Bool = false,
                playerIndex: Int? = nil,
                joinedAt: Date = Date(),
                lastActivityAt: Date = Date()) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName
        self.role = role
        self.connectionState = connectionState
        self.inputEnabled = inputEnabled
        self.playerIndex = playerIndex.map { min(3, max(1, $0)) }
        self.joinedAt = joinedAt
        self.lastActivityAt = lastActivityAt
    }
}

public struct OPNRemoteCoOpInvite: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let code: String
    public let createdAt: Date
    public let expiresAt: Date
    public let token: String
    public let joinURL: URL?
    public let applicationID: String
    public let title: String
    public let hideGuestInviteDetails: Bool

    public init(id: UUID = UUID(),
                code: String,
                createdAt: Date = Date(),
                expiresAt: Date,
                token: String = "",
                joinURL: URL? = nil,
                applicationID: String = "",
                title: String = "",
                hideGuestInviteDetails: Bool = false) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.token = token
        self.joinURL = joinURL
        self.applicationID = applicationID
        self.title = title
        self.hideGuestInviteDetails = hideGuestInviteDetails
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }
}

public struct OPNRemoteCoOpInputPacket: Codable, Equatable, Sendable {
    public let participantID: UUID
    public let sequenceNumber: UInt64
    public let buttons: GamepadButtons
    public let leftTrigger: Float
    public let rightTrigger: Float
    public let leftStickX: Float
    public let leftStickY: Float
    public let rightStickX: Float
    public let rightStickY: Float
    public let sentAtNanoseconds: UInt64

    public init(participantID: UUID,
                sequenceNumber: UInt64,
                buttons: GamepadButtons = [],
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                leftStickX: Float = 0,
                leftStickY: Float = 0,
                rightStickX: Float = 0,
                rightStickY: Float = 0,
                sentAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.participantID = participantID
        self.sequenceNumber = sequenceNumber
        self.buttons = buttons
        self.leftTrigger = Self.clampUnit(leftTrigger)
        self.rightTrigger = Self.clampUnit(rightTrigger)
        self.leftStickX = Self.clampSignedUnit(leftStickX)
        self.leftStickY = Self.clampSignedUnit(leftStickY)
        self.rightStickX = Self.clampSignedUnit(rightStickX)
        self.rightStickY = Self.clampSignedUnit(rightStickY)
        self.sentAtNanoseconds = sentAtNanoseconds
    }

    private static func clampUnit(_ value: Float) -> Float {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private static func clampSignedUnit(_ value: Float) -> Float {
        min(1, max(-1, value.isFinite ? value : 0))
    }
}
