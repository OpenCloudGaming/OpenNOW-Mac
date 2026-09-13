import Foundation

/// Pure mappings from the account/store/subscription wire objects onto the catalog
/// value types. Free of view-model state so they can be exercised directly.
enum CatalogAccountParsing {
    static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func parseAccountSubscriptions(_ account: OPNUserAccountInfo) -> [String] {
        uniqueNonEmpty(account.subscriptions)
    }

    static func parseStoreAccounts(_ account: OPNUserAccountInfo) -> [CatalogStoreAccount] {
        account.stores.map { store in
            CatalogStoreAccount(
                store: store.store,
                userDisplayName: store.userDisplayName,
                expiresIn: store.expiresIn,
                userIdentifier: store.userIdentifier,
                hasAccountLinkingData: store.hasAccountLinkingData,
                hasAccountSyncingData: store.hasAccountSyncingData,
                totalSyncedGames: store.syncing.totalNumberOfSyncedGfnGames,
                syncState: store.syncing.syncState,
                syncDate: store.syncing.syncDate
            )
        }
    }

    static func parseStoreDefinition(_ definition: OPNStoreDefinition) -> CatalogStoreDefinition {
        CatalogStoreDefinition(
            store: definition.store,
            label: definition.label,
            smallImageUrl: definition.smallImageUrl,
            isAccountLinkingSupported: definition.accountLinkingMetadata.isSupported,
            isAccountLinkingRequired: definition.accountLinkingMetadata.isRequired,
            accountLinkingLabel: definition.accountLinkingMetadata.label
        )
    }

    static func parseSubscriptionDefinition(_ definition: OPNSubscriptionDefinition) -> CatalogSubscriptionDefinition {
        CatalogSubscriptionDefinition(
            subscription: definition.subscription,
            label: definition.label,
            logoURL: definition.logoURL,
            primaryStore: definition.primaryStore
        )
    }

    /// Stores that are delivered by the catalog but do not offer account linking or library
    /// syncing, so surfacing them in Settings > Store Connections would offer buttons that do
    /// nothing. GOG is intentionally absent: it supports account linking and library syncing.
    static let hiddenConnectionStoreKeys: Set<String> = [
        "ea",
        "eaapp",
        "electronicarts",
        "none",
        "nvidia",
        "origin",
        "stove",
        "unknown"
    ]

    static func isHiddenConnectionStore(store: String, displayName: String) -> Bool {
        let rawKey = normalizedStoreKey(store)
        let displayKey = normalizedStoreKey(displayName)
        return hiddenConnectionStoreKeys.contains(rawKey) || hiddenConnectionStoreKeys.contains(displayKey)
    }

    private static func normalizedStoreKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
