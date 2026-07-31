import Foundation

struct DiscordActivity: Equatable, Sendable {
    var details: String?
    var state: String?
    var largeImageKey: String?
    var largeImageText: String?
    var smallImageKey: String?
    var smallImageText: String?
    var startTimestampSeconds: Int64?
    var instance = false

    func jsonObject() -> [String: Any] {
        var payload: [String: Any] = ["instance": instance]

        if let details, !details.isEmpty { payload["details"] = details }
        if let state, !state.isEmpty { payload["state"] = state }

        var assets: [String: Any] = [:]
        if let largeImageKey, !largeImageKey.isEmpty { assets["large_image"] = largeImageKey }
        if let largeImageText, !largeImageText.isEmpty { assets["large_text"] = largeImageText }
        if let smallImageKey, !smallImageKey.isEmpty { assets["small_image"] = smallImageKey }
        if let smallImageText, !smallImageText.isEmpty { assets["small_text"] = smallImageText }
        if !assets.isEmpty { payload["assets"] = assets }

        if let startTimestampSeconds {
            payload["timestamps"] = ["start": startTimestampSeconds]
        }

        return payload
    }
}
