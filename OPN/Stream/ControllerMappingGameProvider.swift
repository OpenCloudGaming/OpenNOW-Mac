//  One game's view of the controller mappings. Two accounts can stream different games at once, and
//  the store's own "current game" is whichever one started last, so a stream resolves its mappings
//  from its own launch snapshot instead.

import Combine
import Foundation

@MainActor
final class ControllerMappingGameProvider: ControllerMappingProviding {
    private let store: ControllerMappingStore
    private let gameIdentity: String?

    init(gameIdentity: String, store: ControllerMappingStore = .shared) {
        self.store = store
        let trimmed = gameIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gameIdentity = trimmed.isEmpty ? nil : trimmed
    }

    var revisionPublisher: AnyPublisher<Int, Never> { store.revisionPublisher }

    /// Hardware gating spans every saved profile, so it answers the same for every game.
    var requiresRawSteamTrackpads: Bool { store.requiresRawSteamTrackpads }

    var wantsGyroMotion: Bool { store.wantsGyroMotion }

    func profile(for family: ControllerFamily) -> ControllerMappingProfile? {
        store.profile(for: family, gameIdentity: gameIdentity)
    }
}
