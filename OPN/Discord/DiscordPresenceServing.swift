import Foundation

@MainActor
protocol DiscordPresenceServing: AnyObject {
    var isEnabled: Bool { get set }
    func update(_ state: DiscordPresenceState)
}

extension DiscordRichPresence: DiscordPresenceServing {}
