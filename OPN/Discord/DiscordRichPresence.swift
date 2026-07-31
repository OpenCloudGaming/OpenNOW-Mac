import Foundation

enum DiscordRichPresenceConfig {
    static let applicationID = "1532758257528213564"
    static let smallImageKey = "app_icon"
    static let enabledDefaultsKey = "discord.richPresence.enabled"
}

struct DiscordGamePresence: Equatable, Sendable {
    var title: String
    var artworkURL: String?

    init(title: String, artworkURL: String?) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.artworkURL = artworkURL
    }
}

enum DiscordPresenceState: Equatable, Sendable {
    case launching(DiscordGamePresence)
    case queued(DiscordGamePresence, position: Int)
    case streaming(DiscordGamePresence)
    case idle
}

@MainActor
final class DiscordRichPresence {
    static let shared = DiscordRichPresence()

    private let client: DiscordIPCClient?
    private let defaults: UserDefaults
    private let pid: Int32

    private var lastActivity: DiscordActivity?
    private var currentGameTitle: String?
    private var streamStartSeconds: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pid = ProcessInfo.processInfo.processIdentifier
        if DiscordRichPresenceConfig.applicationID.isEmpty {
            self.client = nil
        } else {
            self.client = DiscordIPCClient(clientID: DiscordRichPresenceConfig.applicationID)
        }
        if defaults.object(forKey: DiscordRichPresenceConfig.enabledDefaultsKey) == nil {
            defaults.set(true, forKey: DiscordRichPresenceConfig.enabledDefaultsKey)
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: DiscordRichPresenceConfig.enabledDefaultsKey) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: DiscordRichPresenceConfig.enabledDefaultsKey)
            if !newValue { clearNow() }
        }
    }

    func update(_ state: DiscordPresenceState) {
        guard let client, isEnabled else { return }

        let activity = activity(for: state)
        guard activity != lastActivity else { return }
        lastActivity = activity

        Task { await client.setActivity(activity, pid: pid) }
    }

    private func activity(for state: DiscordPresenceState) -> DiscordActivity? {
        switch state {
        case .idle:
            resetTimer(for: nil)
            return nil

        case let .launching(game):
            resetTimer(for: game.title)
            return activity(game: game, state: "Preparing to stream", timestamp: nil)

        case let .queued(game, position):
            resetTimer(for: game.title)
            let label = position > 0 ? "In queue · #\(position)" : "In queue"
            return activity(game: game, state: label, timestamp: nil)

        case let .streaming(game):
            let start = stampTimer(for: game.title)
            return activity(game: game, state: "Streaming via MacForce Now", timestamp: start)
        }
    }

    private func activity(game: DiscordGamePresence, state: String, timestamp: Int64?) -> DiscordActivity {
        DiscordActivity(
            details: game.title,
            state: state,
            largeImageKey: game.artworkURL,
            largeImageText: game.artworkURL != nil ? game.title : nil,
            smallImageKey: DiscordRichPresenceConfig.smallImageKey,
            smallImageText: "MacForce Now",
            startTimestampSeconds: timestamp
        )
    }

    private func resetTimer(for title: String?) {
        if title != currentGameTitle {
            currentGameTitle = title
            streamStartSeconds = nil
        }
    }

    private func stampTimer(for title: String) -> Int64 {
        if title != currentGameTitle {
            currentGameTitle = title
            streamStartSeconds = nil
        }
        if let existing = streamStartSeconds { return existing }
        let now = Int64(Date().timeIntervalSince1970)
        streamStartSeconds = now
        return now
    }

    private func clearNow() {
        lastActivity = nil
        currentGameTitle = nil
        streamStartSeconds = nil
        guard let client else { return }
        let pid = pid
        Task { await client.setActivity(nil, pid: pid) }
    }
}
