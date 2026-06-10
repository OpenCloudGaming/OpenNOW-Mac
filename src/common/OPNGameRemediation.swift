import Foundation

enum OPNGameOwnershipRemediationKind: Int, Sendable {
    case none = 0
    case purchaseOrAdd
    case linkAccount
    case installToPlay
}

struct OPNGameOwnershipRemediation: Equatable, Sendable {
    var kind: OPNGameOwnershipRemediationKind = .none
    var storeVariantIndex = -1
    var storeName = ""
    var title = ""
    var reason = ""
    var guidance = ""
    var actionLabel = ""

    var required: Bool { kind != .none }
}

enum OPNGameRemediation {
    static func gameServiceStatusOwnedForLaunch(_ status: String) -> Bool {
        status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY"
    }

    static func gameVariantOwnedForLaunch(_ variant: OPNGameVariant) -> Bool {
        variant.inLibrary || variant.librarySelected || gameServiceStatusOwnedForLaunch(variant.serviceStatus)
    }

    static func gameStoreDisplayName(_ store: String) -> String {
        let value = store.uppercased()
        if value.contains("STEAM") { return "Steam" }
        if value.contains("EPIC") || value.contains("EGS") { return "Epic Games" }
        if value.contains("UBISOFT") || value.contains("UPLAY") { return "Ubisoft" }
        if value.contains("BATTLE") { return "Battle.net" }
        if value.contains("XBOX") || value.contains("MICROSOFT") { return "Xbox" }
        if value.contains("EA") || value.contains("ORIGIN") { return "EA" }
        if value.contains("GOG") { return "GOG" }
        if store.isEmpty { return "the selected store" }
        return store.prefix(1).uppercased() + store.dropFirst()
    }

    static func gameOwnershipRemediationForLaunch(
        game: OPNGameInfo,
        variantIndex: Int,
        accountLinked: Bool
    ) -> OPNGameOwnershipRemediation {
        let selectedVariant = variant(at: variantIndex, in: game)
        let storeVariantIndex = selectedVariant?.storeUrl.isEmpty == false ? variantIndex : firstVariantWithStoreURL(in: game)
        guard storeVariantIndex >= 0 else { return OPNGameOwnershipRemediation() }

        let storeVariant = variant(at: storeVariantIndex, in: game)
        let storeName = storeVariant.map { gameStoreDisplayName($0.appStore) } ?? "the selected store"
        let selectedOwned = selectedVariant.map(gameVariantOwnedForLaunch) ?? game.isInLibrary

        if game.playType == "INSTALL_TO_PLAY" {
            return makeRemediation(kind: .installToPlay, storeVariantIndex: storeVariantIndex, gameTitle: gameTitle(game), storeName: storeName)
        }
        if !selectedOwned {
            return makeRemediation(kind: .purchaseOrAdd, storeVariantIndex: storeVariantIndex, gameTitle: gameTitle(game), storeName: storeName)
        }
        if !accountLinked {
            return makeRemediation(kind: .linkAccount, storeVariantIndex: storeVariantIndex, gameTitle: gameTitle(game), storeName: storeName)
        }
        return OPNGameOwnershipRemediation()
    }

    private static func firstVariantWithStoreURL(in game: OPNGameInfo) -> Int {
        game.variants.firstIndex { !$0.storeUrl.isEmpty } ?? -1
    }

    private static func variant(at index: Int, in game: OPNGameInfo) -> OPNGameVariant? {
        guard index >= 0, index < game.variants.count else { return nil }
        return game.variants[index]
    }

    private static func gameTitle(_ game: OPNGameInfo) -> String {
        game.title.isEmpty ? "Selected Game" : game.title
    }

    private static func makeRemediation(
        kind: OPNGameOwnershipRemediationKind,
        storeVariantIndex: Int,
        gameTitle: String,
        storeName: String
    ) -> OPNGameOwnershipRemediation {
        var remediation = OPNGameOwnershipRemediation()
        remediation.kind = kind
        remediation.storeVariantIndex = storeVariantIndex
        remediation.storeName = storeName

        switch kind {
        case .purchaseOrAdd:
            remediation.title = "Add Game to Library"
            remediation.reason = "\(gameTitle) is not marked as owned in your GeForce NOW library for \(storeName)."
            remediation.guidance = "Open the store to purchase, claim, or link the game. If you already completed that step, continue anyway."
            remediation.actionLabel = "Open Store"
        case .linkAccount:
            remediation.title = "Link Store Account"
            remediation.reason = "\(gameTitle) needs a linked \(storeName) account before GeForce NOW can launch it."
            remediation.guidance = "Open the store to link your account. If it is already linked, continue anyway."
            remediation.actionLabel = "Open Store"
        case .installToPlay:
            remediation.title = "Install Required"
            remediation.reason = "\(gameTitle) must be installed or prepared through \(storeName) before launch."
            remediation.guidance = "Open the store to install or prepare the game. If this is already complete, continue anyway."
            remediation.actionLabel = "Open Store"
        case .none:
            break
        }

        return remediation
    }
}

@objc(OPNGameRemediationBridge)
final class OPNGameRemediationBridge: NSObject {
    @objc(gameVariantOwnedForLaunchWithInLibrary:librarySelected:serviceStatus:)
    static func gameVariantOwnedForLaunch(inLibrary: Bool, librarySelected: Bool, serviceStatus: String) -> Bool {
        inLibrary || librarySelected || OPNGameRemediation.gameServiceStatusOwnedForLaunch(serviceStatus)
    }

    @objc(gameStoreDisplayName:)
    static func gameStoreDisplayName(_ store: String) -> String {
        OPNGameRemediation.gameStoreDisplayName(store)
    }
}
