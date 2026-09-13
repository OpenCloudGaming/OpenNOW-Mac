//  The store picker's entitlement rows: a variant that is both store-listed and
//  subscription-carrying must render as one store row plus one subscription row, matching the
//  official client's "Choose a game store" split. Regression for Battle.net + Xbox Game Pass
//  titles (Warcraft III: Reforged) collapsing into a single "Xbox Game Pass" row.
//

import Testing
import Foundation
@testable import OpenNOW

@MainActor
struct OpenNOWCatalogPlatformOptionTests {
    private func battleNetReforgedGame() -> OPNCatalogGameObject {
        var variant = OPNGameVariant()
        variant.id = "100508511"
        variant.appStore = "BATTLENET"
        variant.subscriptionIds = ["XBOX_GAME_PASS"]
        variant.inLibrary = true
        variant.libraryStatus = "MANUAL"
        var game = OPNGameInfo()
        game.id = "efb060e9-0e71-4cf8-994a-41c97fa82f3c"
        game.title = "Warcraft® III: Reforged"
        game.isInLibrary = true
        game.variants = [variant]
        return OPNCatalogGameObject(game: game)
    }

    private func context(subscriptions: [String] = []) -> CatalogOptionContext {
        var context = CatalogOptionContext()
        context.accountSubscriptions = subscriptions
        context.storeDefinitions = [CatalogStoreDefinition(store: "BATTLENET", label: "Battle.net", smallImageUrl: "", isAccountLinkingSupported: true, isAccountLinkingRequired: false, accountLinkingLabel: "")]
        context.subscriptionDefinitions = [CatalogSubscriptionDefinition(subscription: "XBOX_GAME_PASS", label: "Xbox Game Pass", logoURL: "https://example.com/xgp.png", primaryStore: "XBOX")]
        return context
    }

    @Test func ownedStoreVariantSplitsIntoStoreAndSubscriptionRows() {
        let game = battleNetReforgedGame()
        let options = CatalogViewModel.platformOptions(for: game, selectedVariantIndex: 0, selectedRowIsSubscription: nil, context: context())

        #expect(options.count == 2)
        #expect(options[0].isSubscription == false)
        #expect(options[0].title == "Battle.net")
        #expect(options[0].isOwned == true)
        #expect(options[0].hasAccess == true)
        #expect(options[0].status == "Owned")
        #expect(options[1].isSubscription == true)
        #expect(options[1].title == "Xbox Game Pass")
        #expect(options[1].isOwned == false)
        #expect(options[1].hasSubscriptionEntitlement == false)
        #expect(options[1].hasAccess == false)
        #expect(options[1].status == "Subscription required")
    }

    @Test func splitRowsKeepSharedVariantIndexAndDistinctIds() {
        let game = battleNetReforgedGame()
        let options = CatalogViewModel.platformOptions(for: game, selectedVariantIndex: 0, selectedRowIsSubscription: nil, context: context())

        #expect(options[0].variantIndex == 0)
        #expect(options[1].variantIndex == 0)
        #expect(options[0].id != options[1].id)
        #expect(options[0].id.hasSuffix("-store"))
        #expect(options[1].id.hasSuffix("-sub"))
    }

    @Test func ownedVariantHighlightsStoreRowByDefault() {
        let game = battleNetReforgedGame()
        let options = CatalogViewModel.platformOptions(for: game, selectedVariantIndex: 0, selectedRowIsSubscription: nil, context: context())

        #expect(options[0].isSelected == true)
        #expect(options[1].isSelected == false)
    }

    @Test func clickedSubscriptionRowKeepsHighlightAfterSelection() {
        let game = battleNetReforgedGame()
        let options = CatalogViewModel.platformOptions(for: game, selectedVariantIndex: 0, selectedRowIsSubscription: true, context: context())

        #expect(options[0].isSelected == false)
        #expect(options[1].isSelected == true)
    }

    @Test func subscriptionEntitlementMarksSubscriptionRowSubscribed() {
        let game = battleNetReforgedGame()
        let options = CatalogViewModel.platformOptions(for: game, selectedVariantIndex: 0, selectedRowIsSubscription: nil, context: context(subscriptions: ["XBOX_GAME_PASS"]))

        #expect(options[0].status == "Owned")
        #expect(options[1].hasSubscriptionEntitlement == true)
        #expect(options[1].hasAccess == true)
        #expect(options[1].status == "Subscribed")
    }

    @Test func storelessOwnedVariantKeepsSingleFallbackRow() {
        var variant = OPNGameVariant()
        variant.id = "145491"
        variant.inLibrary = true
        variant.libraryStatus = "MANUAL"
        var game = OPNGameInfo()
        game.title = "Genshin Impact"
        game.isInLibrary = true
        game.variants = [variant]
        let options = CatalogViewModel.platformOptions(for: OPNCatalogGameObject(game: game), selectedVariantIndex: -1, selectedRowIsSubscription: nil, context: context())

        #expect(options.count == 1)
        #expect(options[0].id == "145491")
        #expect(options[0].title == "GeForce NOW")
        #expect(options[0].isSubscription == false)
        #expect(options[0].isOwned == true)
        #expect(options[0].hasAccess == true)
        #expect(options[0].isSelected == true)
    }

    @Test func multiStoreGameExpandsEveryVariantIntoItsOwnRows() {
        var uplayVariant = OPNGameVariant()
        uplayVariant.id = "106654026"
        uplayVariant.appStore = "UPLAY"
        uplayVariant.subscriptionIds = ["UBISOFT_PREMIUM"]
        var battleNetVariant = OPNGameVariant()
        battleNetVariant.id = "103661812"
        battleNetVariant.appStore = "BATTLENET"
        battleNetVariant.subscriptionIds = ["XBOX_GAME_PASS"]
        var game = OPNGameInfo()
        game.title = "Warcraft® I: Remastered"
        game.variants = [uplayVariant, battleNetVariant]
        var context = CatalogOptionContext()
        context.storeDefinitions = [CatalogStoreDefinition(store: "BATTLENET", label: "Battle.net", smallImageUrl: "", isAccountLinkingSupported: true, isAccountLinkingRequired: false, accountLinkingLabel: "")]
        context.subscriptionDefinitions = [
            CatalogSubscriptionDefinition(subscription: "UBISOFT_PREMIUM", label: "Ubisoft Premium", logoURL: "", primaryStore: "UBISOFT"),
            CatalogSubscriptionDefinition(subscription: "XBOX_GAME_PASS", label: "Xbox Game Pass", logoURL: "", primaryStore: "XBOX"),
        ]

        let options = CatalogViewModel.platformOptions(for: OPNCatalogGameObject(game: game), selectedVariantIndex: -1, selectedRowIsSubscription: nil, context: context)

        #expect(options.count == 4)
        let storeRows = options.filter { !$0.isSubscription }
        let subscriptionRows = options.filter { $0.isSubscription }
        #expect(storeRows.map(\.title) == ["UPLAY", "Battle.net"])
        #expect(subscriptionRows.map(\.title) == ["Ubisoft Premium", "Xbox Game Pass"])
        #expect(storeRows.allSatisfy { !$0.isOwned })
        #expect(Set(options.map(\.id)).count == 4)
    }

    @Test func defaultRowPrefersStoreOnlyWhenOwned() {
        var owned = OPNGameVariant()
        owned.appStore = "BATTLENET"
        owned.subscriptionIds = ["XBOX_GAME_PASS"]
        owned.inLibrary = true
        var unowned = OPNGameVariant()
        unowned.appStore = "BATTLENET"
        unowned.subscriptionIds = ["XBOX_GAME_PASS"]
        var storelessOwned = OPNGameVariant()
        storelessOwned.subscriptionIds = ["XBOX_GAME_PASS"]
        storelessOwned.inLibrary = true

        #expect(CatalogViewModel.defaultRowIsSubscription(variantOwned: true, variant: OPNCatalogGameVariantObject(variant: owned)) == false)
        #expect(CatalogViewModel.defaultRowIsSubscription(variantOwned: false, variant: OPNCatalogGameVariantObject(variant: unowned)) == true)
        #expect(CatalogViewModel.defaultRowIsSubscription(variantOwned: true, variant: OPNCatalogGameVariantObject(variant: storelessOwned)) == true)
    }
}
