import Foundation

struct TwitchBroadcastPreferences: Codable, Equatable, Sendable {
    enum IngestRegion: String, Codable, CaseIterable, Identifiable, Sendable {
        case automatic
        case usWest
        case usEast
        case europe
        case custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: return "Auto"
            case .usWest: return "US West"
            case .usEast: return "US East"
            case .europe: return "Europe"
            case .custom: return "Custom"
            }
        }

        var rtmpURL: String {
            switch self {
            case .automatic: return "rtmp://live.twitch.tv/app"
            case .usWest: return "rtmp://sfo.contribute.live-video.net/app"
            case .usEast: return "rtmp://iad.contribute.live-video.net/app"
            case .europe: return "rtmp://ams.contribute.live-video.net/app"
            case .custom: return ""
            }
        }
    }

    enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case source
        case p1080
        case p936
        case p720

        var id: String { rawValue }

        var label: String {
            switch self {
            case .source: return "Source"
            case .p1080: return "1080p"
            case .p936: return "936p"
            case .p720: return "720p"
            }
        }

        var targetHeight: Int {
            switch self {
            case .source: return 0
            case .p1080: return 1080
            case .p936: return 936
            case .p720: return 720
            }
        }
    }

    var clientID = ""
    var ingestRegion = IngestRegion.automatic
    var customRTMPURL = ""
    var resolution = Resolution.p1080
    var fps = 60
    var videoBitrateKbps = 6_000
    var audioBitrateKbps = 160
    var useEnhancedVideo = true
    var autoTitleFromGame = true
    var chatOverlayEnabled = true
    var eventAlertsEnabled = true

    var ingestURL: String {
        ingestRegion == .custom ? customRTMPURL.trimmingCharacters(in: .whitespacesAndNewlines) : ingestRegion.rtmpURL
    }

    static let defaultValue = TwitchBroadcastPreferences()
}

enum TwitchPreferencesStore {
    private static let key = "OpenNOW.Twitch.BroadcastPreferences"

    static func load() -> TwitchBroadcastPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else { return .defaultValue }
        return (try? JSONDecoder().decode(TwitchBroadcastPreferences.self, from: data)) ?? .defaultValue
    }

    static func save(_ preferences: TwitchBroadcastPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct TwitchAccountStatus: Equatable, Sendable {
    var isConnected = false
    var displayName = ""
    var login = ""
    var channelID = ""
    var streamKeyAvailable = false

    var summary: String {
        guard isConnected else { return "Not connected" }
        if !displayName.isEmpty { return "Connected as \(displayName)" }
        if !login.isEmpty { return "Connected as \(login)" }
        return "Connected"
    }
}
