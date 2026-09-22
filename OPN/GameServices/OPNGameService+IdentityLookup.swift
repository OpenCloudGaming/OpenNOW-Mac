//  Resolving stored game identities — what a user collection keeps as membership — against the
//  catalog, without a browse query and with no loaded catalog to look them up in.
//

import AppKit
import Foundation

extension OPNGameService {
    /// The most identities one metadata request may carry, matching the chunk `enrichGames` sends.
    static let catalogIdentityBatchSize = 40

    /// Resolves stored game identities to catalog rows, keyed by the identity that was asked for.
    /// Identities the catalog does not carry are simply absent from the result.
    func resolveCatalogGames(byIdentities identities: [String], completion: @escaping @MainActor @Sendable ([String: OPNGameInfo]) -> Void) {
        let requested = Self.orderedIdentities(identities)
        guard !requested.isEmpty else {
            Task { @MainActor in completion([:]) }
            return
        }
        resolveCatalogVpcId(token: accessToken, providerStreamingBaseUrl: providerStreamingBaseURL()) { [weak self] resolvedVpcId in
            guard let self else { return }
            let vpcId = resolvedVpcId.isEmpty ? "GFN-PC" : resolvedVpcId
            let state = CatalogIdentityLookupState()
            let group = DispatchGroup()
            for start in stride(from: 0, to: requested.count, by: Self.catalogIdentityBatchSize) {
                let chunk = Array(requested[start..<min(start + Self.catalogIdentityBatchSize, requested.count)])
                group.enter()
                Self.appMetadataLimiter.submit { [weak self] finished in
                    guard let self else {
                        group.leave()
                        finished()
                        return
                    }
                    self.fetchAppMetadata(appIds: chunk, vpcId: vpcId) { [weak self] data, _ in
                        guard let self else {
                            group.leave()
                            finished()
                            return
                        }
                        let items = (data?["apps"] as? NSDictionary)?["items"] as? [NSDictionary] ?? []
                        let itemsBox = NSDictionaryArrayBox(items)
                        Self.workQueue.async {
                            let games = itemsBox.values.map { self.parseGameItem($0) }
                            state.record(games, requested: chunk)
                            group.leave()
                            finished()
                        }
                    }
                }
            }
            group.notify(queue: Self.workQueue) {
                let lookup = state.lookup
                Task { @MainActor in completion(lookup) }
            }
        }
    }

    /// The identities a lookup should ask for: trimmed, blank-free, and deduped in first-seen order.
    static func orderedIdentities(_ identities: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for identity in identities {
            let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}

/// The lookup's shared result across its batches: every metadata row filed under each requested
/// identity it answers to, so a variant id and a catalog id for one game both resolve.
private final class CatalogIdentityLookupState: @unchecked Sendable {
    private let lock = NSLock()
    private var gamesByIdentity: [String: OPNGameInfo] = [:]

    var lookup: [String: OPNGameInfo] {
        lock.withLock { gamesByIdentity }
    }

    func record(_ games: [OPNGameInfo], requested: [String]) {
        let requestedSet = Set(requested)
        lock.withLock {
            for game in games {
                for alias in Self.aliases(of: game) where requestedSet.contains(alias) {
                    gamesByIdentity[alias] = game
                }
            }
        }
    }

    private static func aliases(of game: OPNGameInfo) -> Set<String> {
        var aliases: Set<String> = [game.catalogIdentity]
        for value in [game.uuid, game.launchAppId] + game.variants.map(\.id) where !value.isEmpty {
            aliases.insert(value)
        }
        aliases.remove("")
        return aliases
    }
}
