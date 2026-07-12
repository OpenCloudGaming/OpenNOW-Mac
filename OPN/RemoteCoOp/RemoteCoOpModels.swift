import Foundation

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
        case .automatic: return "Try a direct WebRTC path first and fall back to relay when needed."
        case .directOnly: return "Only connect when guests can reach the host directly."
        case .relayOnly: return "Force relayed connectivity to avoid exposing peer IP addresses."
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
}

public struct OPNRemoteCoOpPreferences: Codable, Equatable, Sendable {
    public static let launchMetadataEnabledKey = "remoteCoOpEnabled"
    public static let launchMetadataReservedGuestSlotsKey = "remoteCoOpReservedGuestSlots"
    public static let launchMetadataTransportModeKey = "remoteCoOpTransportMode"
    public static let launchMetadataQualityPresetKey = "remoteCoOpQualityPreset"
    public static let launchMetadataRequireHostApprovalKey = "remoteCoOpRequireHostApproval"

    public var isEnabled: Bool
    public var reservedGuestSlots: Int
    public var transportMode: OPNRemoteCoOpTransportMode
    public var qualityPreset: OPNRemoteCoOpQualityPreset
    public var requireHostApproval: Bool

    public init(isEnabled: Bool = false,
                reservedGuestSlots: Int = 1,
                transportMode: OPNRemoteCoOpTransportMode = .automatic,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                requireHostApproval: Bool = true) {
        self.isEnabled = isEnabled
        self.reservedGuestSlots = Self.clampedGuestSlots(reservedGuestSlots)
        self.transportMode = transportMode
        self.qualityPreset = qualityPreset
        self.requireHostApproval = requireHostApproval
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
            Self.launchMetadataRequireHostApprovalKey: String(requireHostApproval),
        ]
    }

    public static func launchPreferences(from metadata: [String: String], fallback: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences(
            isEnabled: bool(metadata[launchMetadataEnabledKey], defaultValue: fallback.isEnabled),
            reservedGuestSlots: int(metadata[launchMetadataReservedGuestSlotsKey], defaultValue: fallback.reservedGuestSlots),
            transportMode: OPNRemoteCoOpTransportMode(rawValue: metadata[launchMetadataTransportModeKey] ?? "") ?? fallback.transportMode,
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: metadata[launchMetadataQualityPresetKey] ?? "") ?? fallback.qualityPreset,
            requireHostApproval: bool(metadata[launchMetadataRequireHostApprovalKey], defaultValue: fallback.requireHostApproval)
        )
    }

    private static func int(_ value: String?, defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return parsed
    }

    private static func bool(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
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

    public init(id: UUID = UUID(), code: String, createdAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
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
