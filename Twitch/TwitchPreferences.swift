import Foundation

public struct TwitchBroadcastPreferences: Codable, Equatable, Sendable {
    public enum IngestRegion: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic
        case usWest
        case usEast
        case europe
        case custom

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .automatic: return "Auto"
            case .usWest: return "US West"
            case .usEast: return "US East"
            case .europe: return "Europe"
            case .custom: return "Custom"
            }
        }

        public var rtmpURL: String {
            switch self {
            case .automatic: return "rtmp://live.twitch.tv/app"
            case .usWest: return "rtmp://sfo.contribute.live-video.net/app"
            case .usEast: return "rtmp://iad.contribute.live-video.net/app"
            case .europe: return "rtmp://ams.contribute.live-video.net/app"
            case .custom: return ""
            }
        }
    }

    public enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case source
        case p1080
        case p936
        case p720

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .source: return "Source"
            case .p1080: return "1080p"
            case .p936: return "936p"
            case .p720: return "720p"
            }
        }

        public var targetHeight: Int {
            switch self {
            case .source: return 0
            case .p1080: return 1080
            case .p936: return 936
            case .p720: return 720
            }
        }
    }

    public var clientID = ""
    public var ingestRegion = IngestRegion.automatic
    public var customRTMPURL = ""
    public var resolution = Resolution.p1080
    public var fps = 60
    public var videoBitrateKbps = 6_000
    public var audioBitrateKbps = 160
    public var useEnhancedVideo = true
    public var autoTitleFromGame = true
    public var chatOverlayEnabled = true
    public var eventAlertsEnabled = true

    public var ingestURL: String {
        if ingestRegion == .custom { return customRTMPURL.trimmingCharacters(in: .whitespacesAndNewlines) }
        if ingestRegion == .automatic, let cached = TwitchIngestServerStore.defaultRTMPURL() { return cached }
        return ingestRegion.rtmpURL
    }

    public static let defaultValue = TwitchBroadcastPreferences()

    public init() {}
}

public enum TwitchPreferencesStore {
    private static let key = "OpenNOW.Twitch.BroadcastPreferences"

    public static func load() -> TwitchBroadcastPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .defaultValue }
        return (try? JSONDecoder().decode(TwitchBroadcastPreferences.self, from: data)) ?? .defaultValue
    }

    public static func save(_ preferences: TwitchBroadcastPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public struct TwitchAccountStatus: Equatable, Sendable {
    public var isConnected = false
    public var displayName = ""
    public var login = ""
    public var channelID = ""
    public var streamKeyAvailable = false

    public init(isConnected: Bool = false, displayName: String = "", login: String = "", channelID: String = "", streamKeyAvailable: Bool = false) {
        self.isConnected = isConnected
        self.displayName = displayName
        self.login = login
        self.channelID = channelID
        self.streamKeyAvailable = streamKeyAvailable
    }

    public var summary: String {
        guard isConnected else { return "Not connected" }
        if !displayName.isEmpty { return "Connected as \(displayName)" }
        if !login.isEmpty { return "Connected as \(login)" }
        return "Connected"
    }
}
