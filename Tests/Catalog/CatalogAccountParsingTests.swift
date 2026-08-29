import Testing
import Foundation
@testable import OpenNOW

@Test func uniqueNonEmptyTrimsDropsBlanksAndFoldsCase() {
    let values = CatalogAccountParsing.uniqueNonEmpty(["  Steam ", "STEAM", "", "   ", "Epic", "epic ", "GOG"])

    #expect(values == ["Steam", "Epic", "GOG"])
}

@Test func accountSubscriptionsAreDeduplicated() {
    var account = OPNUserAccountInfo()
    account.subscriptions = ["ubisoft_plus", "UBISOFT_PLUS", "", "ea_play"]

    #expect(CatalogAccountParsing.parseAccountSubscriptions(account) == ["ubisoft_plus", "ea_play"])
}

@Test func storeAccountsCarrySyncingDetail() {
    var syncing = OPNStoreAccountSyncingInfo()
    syncing.totalNumberOfSyncedGfnGames = 42
    syncing.syncState = "SYNCED"
    syncing.syncDate = "2026-08-29"

    var store = OPNStoreAccountInfo()
    store.store = "STEAM"
    store.userDisplayName = "player"
    store.expiresIn = "3600"
    store.userIdentifier = "user-1"
    store.hasAccountLinkingData = true
    store.hasAccountSyncingData = true
    store.syncing = syncing

    var account = OPNUserAccountInfo()
    account.stores = [store]

    let parsed = try! #require(CatalogAccountParsing.parseStoreAccounts(account).first)

    #expect(parsed.store == "STEAM")
    #expect(parsed.userDisplayName == "player")
    #expect(parsed.expiresIn == "3600")
    #expect(parsed.userIdentifier == "user-1")
    #expect(parsed.hasAccountLinkingData == true)
    #expect(parsed.hasAccountSyncingData == true)
    #expect(parsed.totalSyncedGames == 42)
    #expect(parsed.syncState == "SYNCED")
    #expect(parsed.syncDate == "2026-08-29")
}

@Test func storeAccountsAreEmptyWhenAccountHasNoStores() {
    #expect(CatalogAccountParsing.parseStoreAccounts(OPNUserAccountInfo()).isEmpty)
}

@Test func storeDefinitionFlattensAccountLinkingMetadata() {
    var metadata = OPNStoreAccountLinkingMetadata()
    metadata.isSupported = true
    metadata.isRequired = true
    metadata.label = "Connect Steam"

    var definition = OPNStoreDefinition()
    definition.store = "STEAM"
    definition.label = "Steam"
    definition.smallImageUrl = "https://example.test/steam.png"
    definition.accountLinkingMetadata = metadata

    let parsed = CatalogAccountParsing.parseStoreDefinition(definition)

    #expect(parsed.store == "STEAM")
    #expect(parsed.label == "Steam")
    #expect(parsed.smallImageUrl == "https://example.test/steam.png")
    #expect(parsed.isAccountLinkingSupported == true)
    #expect(parsed.isAccountLinkingRequired == true)
    #expect(parsed.accountLinkingLabel == "Connect Steam")
}

@Test func subscriptionDefinitionCarriesPrimaryStore() {
    var definition = OPNSubscriptionDefinition()
    definition.subscription = "ubisoft_plus"
    definition.label = "Ubisoft+"
    definition.logoURL = "https://example.test/ubi.png"
    definition.primaryStore = "UPLAY"

    let parsed = CatalogAccountParsing.parseSubscriptionDefinition(definition)

    #expect(parsed.subscription == "ubisoft_plus")
    #expect(parsed.label == "Ubisoft+")
    #expect(parsed.logoURL == "https://example.test/ubi.png")
    #expect(parsed.primaryStore == "UPLAY")
}
