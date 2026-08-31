import Foundation
import CryptoKit

/// How hard the guest's connection is allowed to try to reach the host.
///
/// `relayOnly` used to be a third case, forcing every candidate through a TURN relay. It existed
/// because the deployed broker also ran coturn; with the broker gone there is no relay to force, so
/// the mode could only ever fail. Dropping it also drops the only way to keep a guest from learning
/// the host's address - a real cost, accepted deliberately rather than overlooked.
public enum OPNRemoteCoOpTransportMode: String, CaseIterable, Codable, Equatable, Sendable {
    /// Discover this Mac's public address through STUN so a guest on another network can reach it.
    case automatic
    /// Offer only addresses on this machine's own interfaces. Same network only, and nothing about
    /// the host's public address is revealed.
    case directOnly

    public var label: String {
        switch self {
        case .automatic: return "Auto"
        case .directOnly: return "Same Network"
        }
    }

    public var description: String {
        switch self {
        case .automatic: return "Default. Uses STUN to find a route to guests on other networks, which reveals this Mac's public address to them."
        case .directOnly: return "Only accept guests on your own network. Nothing about your public address is shared."
        }
    }

    /// Always `.all`: the `.relay` policy discards host and server-reflexive candidates, which is
    /// only meaningful when a TURN relay is available to replace them.
    public var iceTransportPolicy: OPNRemoteCoOpICETransportPolicy { .all }

    /// Whether STUN should be offered. Without it a guest only ever sees this machine's private
    /// interface addresses, which is exactly what limits `directOnly` to one network.
    public var usesSTUN: Bool {
        self == .automatic
    }
}

public enum OPNRemoteCoOpICETransportPolicy: String, Codable, Equatable, Sendable {
    case all
    /// No longer produced. Kept so a guest page cached from an older release still decodes the
    /// network configuration rather than failing to parse it.
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
    /// Public STUN servers offered when the transport mode allows it.
    ///
    /// Without these a guest only ever receives this machine's private interface addresses, so media
    /// cannot connect from another network however well signaling works - which is the state a
    /// locally hosted session was previously in, and the reason a LAN session's selected route was
    /// always `host/udp -> host/udp`. The deployed broker supplied the same default.
    ///
    /// Two providers rather than one so a single operator's outage does not take Remote Co-Op with
    /// it. STUN reveals nothing but the address the server already sees.
    public static let defaultSTUNServers = [
        "stun:stun.l.google.com:19302",
        "stun:stun.cloudflare.com:3478"
    ]

    public static func iceServers(for transportMode: OPNRemoteCoOpTransportMode) -> [OPNRemoteCoOpICEServer] {
        guard transportMode.usesSTUN else { return [] }
        return [OPNRemoteCoOpICEServer(urls: defaultSTUNServers)]
    }

    public var transportMode: OPNRemoteCoOpTransportMode
    public var iceTransportPolicy: OPNRemoteCoOpICETransportPolicy
    public var latencyMode: OPNRemoteCoOpLatencyMode
    public var iceServers: [OPNRemoteCoOpICEServer]
    public var dataChannelInputEnabled: Bool
    public var websocketInputFallbackEnabled: Bool
    public var directPeerCandidateWarning: String

    /// `iceServers` defaults to whatever the transport mode calls for. It used to default to empty,
    /// and every construction site took that default - so a locally hosted guest was never given a
    /// STUN server at all.
    public init(transportMode: OPNRemoteCoOpTransportMode,
                latencyMode: OPNRemoteCoOpLatencyMode = .quality,
                iceServers: [OPNRemoteCoOpICEServer]? = nil,
                dataChannelInputEnabled: Bool = true,
                websocketInputFallbackEnabled: Bool = true,
                directPeerCandidateWarning: String = "") {
        self.transportMode = transportMode
        self.iceTransportPolicy = transportMode.iceTransportPolicy
        self.latencyMode = latencyMode
        self.iceServers = iceServers ?? Self.iceServers(for: transportMode)
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

    /// Shown to the guest, so it describes what *they* are about to reveal and to whom.
    public static func warning(for mode: OPNRemoteCoOpTransportMode) -> String {
        switch mode {
        case .automatic:
            return "This session connects you and the host directly, so each of you can see the other's network address."
        case .directOnly:
            return "This session only accepts guests on the host's own network."
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
    public static let launchMetadataAlphaOptedInKey = "remoteCoOpAlphaOptedIn"
    public static let launchMetadataEnabledKey = "remoteCoOpEnabled"
    public static let launchMetadataReservedGuestSlotsKey = "remoteCoOpReservedGuestSlots"
    public static let launchMetadataTransportModeKey = "remoteCoOpTransportMode"
    public static let launchMetadataQualityPresetKey = "remoteCoOpQualityPreset"
    public static let launchMetadataLatencyModeKey = "remoteCoOpLatencyMode"
    public static let launchMetadataRequireHostApprovalKey = "remoteCoOpRequireHostApproval"
    public static let launchMetadataHideGuestInviteDetailsKey = "remoteCoOpHideGuestInviteDetails"
    public static let launchMetadataPublicAddressKey = "remoteCoOpPublicAddress"


    public var isAlphaOptedIn: Bool
    public var isEnabled: Bool
    public var reservedGuestSlots: Int
    public var transportMode: OPNRemoteCoOpTransportMode
    public var qualityPreset: OPNRemoteCoOpQualityPreset
    public var latencyMode: OPNRemoteCoOpLatencyMode
    public var requireHostApproval: Bool
    public var hideGuestInviteDetails: Bool
    /// Public base URL a tunnel exposes this Mac's local server on, e.g. an ngrok or Cloudflare
    /// address. Empty means guests are given the LAN address.
    ///
    /// Not a separate hosting mode: a tunnel does not change who serves the session, only the
    /// address guests are told to reach it at. The tunnel also terminates TLS on its own hostname
    /// with a certificate browsers already trust, which is the one thing local hosting cannot do
    /// for itself.
    public var publicAddress: String

    public init(isAlphaOptedIn: Bool = true,
                isEnabled: Bool = false,
                reservedGuestSlots: Int = 1,
                transportMode: OPNRemoteCoOpTransportMode = .automatic,
                qualityPreset: OPNRemoteCoOpQualityPreset = .p720f60,
                latencyMode: OPNRemoteCoOpLatencyMode = .lowLatency,
                requireHostApproval: Bool = true,
                hideGuestInviteDetails: Bool = false,
                publicAddress: String = "") {
        self.isAlphaOptedIn = isAlphaOptedIn
        self.isEnabled = isEnabled
        self.reservedGuestSlots = Self.clampedGuestSlots(reservedGuestSlots)
        self.transportMode = transportMode
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.requireHostApproval = requireHostApproval
        self.hideGuestInviteDetails = hideGuestInviteDetails
        self.publicAddress = publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tunnel address, only when it is usable.
    ///
    /// Must be `https`: the guest page needs a secure context for `RTCPeerConnection`, and a tunnel
    /// serving plaintext would leave the guest unable to connect for exactly the reason the previous
    /// deployment's bare-IP `http://` default did.
    public var effectivePublicAddress: URL? {
        guard !publicAddress.isEmpty else { return nil }
        guard let url = URL(string: publicAddress), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    public var isAvailable: Bool {
        isAlphaOptedIn && isEnabled
    }

    public var effectiveReservedGuestSlots: Int {
        isAvailable ? Self.clampedGuestSlots(reservedGuestSlots) : 0
    }

    public static func clampedGuestSlots(_ value: Int) -> Int {
        min(3, max(0, value))
    }

    public var launchMetadata: [String: String] {
        guard isAlphaOptedIn else {
            return [
                Self.launchMetadataAlphaOptedInKey: String(false),
                Self.launchMetadataEnabledKey: String(false),
                Self.launchMetadataReservedGuestSlotsKey: String(0),
            ]
        }

        return [
            Self.launchMetadataAlphaOptedInKey: String(isAlphaOptedIn),
            Self.launchMetadataEnabledKey: String(isEnabled),
            Self.launchMetadataReservedGuestSlotsKey: String(Self.clampedGuestSlots(reservedGuestSlots)),
            Self.launchMetadataTransportModeKey: transportMode.rawValue,
            Self.launchMetadataQualityPresetKey: qualityPreset.rawValue,
            Self.launchMetadataLatencyModeKey: latencyMode.rawValue,
            Self.launchMetadataRequireHostApprovalKey: String(requireHostApproval),
            Self.launchMetadataHideGuestInviteDetailsKey: String(hideGuestInviteDetails),
            Self.launchMetadataPublicAddressKey: publicAddress,
        ]
    }

    public static func launchPreferences(from metadata: [String: String], fallback: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences(
            isAlphaOptedIn: bool(metadata[launchMetadataAlphaOptedInKey], defaultValue: fallback.isAlphaOptedIn),
            isEnabled: bool(metadata[launchMetadataEnabledKey], defaultValue: fallback.isEnabled),
            reservedGuestSlots: int(metadata[launchMetadataReservedGuestSlotsKey], defaultValue: fallback.reservedGuestSlots),
            transportMode: OPNRemoteCoOpTransportMode(rawValue: metadata[launchMetadataTransportModeKey] ?? "") ?? fallback.transportMode,
            qualityPreset: OPNRemoteCoOpQualityPreset(rawValue: metadata[launchMetadataQualityPresetKey] ?? "") ?? fallback.qualityPreset,
            latencyMode: OPNRemoteCoOpLatencyMode(rawValue: metadata[launchMetadataLatencyModeKey] ?? "") ?? fallback.latencyMode,
            requireHostApproval: bool(metadata[launchMetadataRequireHostApprovalKey], defaultValue: fallback.requireHostApproval),
            hideGuestInviteDetails: bool(metadata[launchMetadataHideGuestInviteDetailsKey], defaultValue: fallback.hideGuestInviteDetails),
            publicAddress: metadata[launchMetadataPublicAddressKey] ?? fallback.publicAddress
        )
    }

    public static func normalizedURLString(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }


    static func int(_ value: String?, defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return parsed
    }

    static func bool(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
    }

    static func string(_ value: String?, defaultValue: String) -> String {
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

    /// The signer a host session uses by default.
    ///
    /// A fresh random key per launch, because OpenNOW is now both the signer and the verifier: it
    /// mints an invite and checks the token a guest presents back, all in one process. Nothing else
    /// needs the key, so there is nothing to distribute and nothing to keep in sync.
    ///
    /// This used to read a shared secret from the environment and then the keychain, so a separately
    /// deployed broker could verify signatures too. That sharing was the single largest source of
    /// "every join is rejected": the two sides derived different keys from identical configuration,
    /// and nothing surfaced the mismatch.
    public static func perSession() -> OPNRemoteCoOpInviteTokenSigner {
        OPNRemoteCoOpInviteTokenSigner()
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
        guard Self.constantTimeEqual(expected, signatureData) else { throw OPNRemoteCoOpInviteTokenError.invalidSignature }
        let payload = try JSONDecoder().decode(OPNRemoteCoOpInviteTokenPayload.self, from: payloadData)
        guard payload.expiresAt > now else { throw OPNRemoteCoOpInviteTokenError.expired }
        return payload
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
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
                hideGuestInviteDetails: Bool = false,
                publicAddress: String = "") {
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
