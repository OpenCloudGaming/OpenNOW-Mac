import Foundation

struct OPNLaunchEntitlements: Equatable, Sendable {
    static let none = OPNLaunchEntitlements()
    static let settingsKey = "accountEntitlements"
    static let metadataKey = "launchEntitlements"
    static let providerMetadataKey = "providerStreamingBaseURL"

    let dlss: DlssEntitlements
    let audioChannelCount: Int
    let isInGameSettingsPersistenceEntitled: Bool

    init(dlss: DlssEntitlements = .none, audioChannelCount: Int = 2, isInGameSettingsPersistenceEntitled: Bool = false) {
        self.dlss = dlss
        self.audioChannelCount = min(max(audioChannelCount, 2), 8)
        self.isInGameSettingsPersistenceEntitled = isInGameSettingsPersistenceEntitled
    }

    init(subscription: OPNSubscriptionInfo) {
        self.init(
            dlss: subscription.dlssEntitlements,
            audioChannelCount: subscription.entitledAudioChannelCount,
            isInGameSettingsPersistenceEntitled: subscription.isInGameSettingsPersistenceEntitled
        )
    }

    init(settings: [String: Any]) {
        self.init(stored: settings[Self.settingsKey] as? [String: Any] ?? [:])
    }

    init(metadata: [String: String]) {
        let stored = metadata[Self.metadataKey]?.data(using: .utf8).flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        self.init(stored: stored ?? [:])
    }

    private init(stored: [String: Any]) {
        self.init(
            dlss: OPNStreamPreferences.dlssEntitlements(from: stored["dlss"] as? [String: Any] ?? [:]),
            audioChannelCount: stored["audioChannelCount"] as? Int ?? 2,
            isInGameSettingsPersistenceEntitled: stored["isInGameSettingsPersistenceEntitled"] as? Bool ?? false
        )
    }

    var storedDictionary: [String: Any] {
        [
            "dlss": OPNStreamPreferences.dlssEntitlementsDictionary(dlss),
            "audioChannelCount": audioChannelCount,
            "isInGameSettingsPersistenceEntitled": isInGameSettingsPersistenceEntitled,
        ]
    }

    var metadataValue: String {
        guard let encoded = try? JSONSerialization.data(withJSONObject: storedDictionary, options: .sortedKeys),
              let value = String(data: encoded, encoding: .utf8) else { return "{}" }
        return value
    }
}

extension StreamLaunchConfiguration {
    var launchEntitlements: OPNLaunchEntitlements { OPNLaunchEntitlements(metadata: metadata) }

    func snapshottingEntitlements(_ entitlements: OPNLaunchEntitlements, providerStreamingBaseURL: String) -> StreamLaunchConfiguration {
        var metadata = metadata
        metadata[OPNLaunchEntitlements.metadataKey] = entitlements.metadataValue
        metadata[OPNLaunchEntitlements.providerMetadataKey] = providerStreamingBaseURL
        return StreamLaunchConfiguration(
            id: id,
            title: title,
            applicationID: applicationID,
            accessToken: accessToken,
            accountLinked: accountLinked,
            selectedStore: selectedStore,
            resumeSessionID: resumeSessionID,
            resumeServer: resumeServer,
            metadata: metadata
        )
    }
}
