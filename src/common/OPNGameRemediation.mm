#include "OPNGameRemediation.h"

#include <algorithm>
#include <cctype>

namespace OPN {

bool GameOwnershipRemediation::Required() const {
    return kind != GameOwnershipRemediationKind::None;
}

bool GameServiceStatusOwnedForLaunch(const std::string &status) {
    return status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY";
}

bool GameVariantOwnedForLaunch(const GameVariant &variant) {
    return variant.inLibrary || variant.librarySelected || GameServiceStatusOwnedForLaunch(variant.serviceStatus);
}

static std::string UppercaseASCII(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return (char)std::toupper(character);
    });
    return value;
}

static bool Contains(const std::string &value, const char *needle) {
    return value.find(needle) != std::string::npos;
}

std::string GameStoreDisplayName(const std::string &store) {
    std::string value = UppercaseASCII(store);
    if (Contains(value, "STEAM")) return "Steam";
    if (Contains(value, "EPIC") || Contains(value, "EGS")) return "Epic Games";
    if (Contains(value, "UBISOFT") || Contains(value, "UPLAY")) return "Ubisoft";
    if (Contains(value, "BATTLE")) return "Battle.net";
    if (Contains(value, "XBOX") || Contains(value, "MICROSOFT")) return "Xbox";
    if (Contains(value, "EA") || Contains(value, "ORIGIN")) return "EA";
    if (Contains(value, "GOG")) return "GOG";
    if (store.empty()) return "the selected store";
    std::string display = store;
    display[0] = (char)std::toupper((unsigned char)display[0]);
    return display;
}

static int FirstVariantWithStoreURL(const GameInfo &game) {
    for (size_t i = 0; i < game.variants.size(); i++) {
        if (!game.variants[i].storeUrl.empty()) return (int)i;
    }
    return -1;
}

static const GameVariant *VariantAtIndex(const GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

static std::string GameTitle(const GameInfo &game) {
    return game.title.empty() ? "Selected Game" : game.title;
}

static GameOwnershipRemediation MakeRemediation(GameOwnershipRemediationKind kind,
                                                int storeVariantIndex,
                                                const std::string &gameTitle,
                                                const std::string &storeName) {
    GameOwnershipRemediation remediation;
    remediation.kind = kind;
    remediation.storeVariantIndex = storeVariantIndex;
    remediation.storeName = storeName;
    switch (kind) {
        case GameOwnershipRemediationKind::PurchaseOrAdd:
            remediation.title = "Add Game to Library";
            remediation.reason = gameTitle + " is not marked as owned in your GeForce NOW library for " + storeName + ".";
            remediation.guidance = "Open the store to purchase, claim, or link the game. If you already completed that step, continue anyway.";
            remediation.actionLabel = "Open Store";
            break;
        case GameOwnershipRemediationKind::LinkAccount:
            remediation.title = "Link Store Account";
            remediation.reason = gameTitle + " needs a linked " + storeName + " account before GeForce NOW can launch it.";
            remediation.guidance = "Open the store to link your account. If it is already linked, continue anyway.";
            remediation.actionLabel = "Open Store";
            break;
        case GameOwnershipRemediationKind::InstallToPlay:
            remediation.title = "Install Required";
            remediation.reason = gameTitle + " must be installed or prepared through " + storeName + " before launch.";
            remediation.guidance = "Open the store to install or prepare the game. If this is already complete, continue anyway.";
            remediation.actionLabel = "Open Store";
            break;
        case GameOwnershipRemediationKind::None:
            break;
    }
    return remediation;
}

GameOwnershipRemediation GameOwnershipRemediationForLaunch(const GameInfo &game,
                                                           int variantIndex,
                                                           bool accountLinked) {
    const GameVariant *selectedVariant = VariantAtIndex(game, variantIndex);
    int storeVariantIndex = selectedVariant && !selectedVariant->storeUrl.empty() ? variantIndex : FirstVariantWithStoreURL(game);
    if (storeVariantIndex < 0) return {};

    const GameVariant *storeVariant = VariantAtIndex(game, storeVariantIndex);
    std::string storeName = storeVariant ? GameStoreDisplayName(storeVariant->appStore) : "the selected store";
    bool selectedOwned = selectedVariant ? GameVariantOwnedForLaunch(*selectedVariant) : game.isInLibrary;

    if (game.playType == "INSTALL_TO_PLAY") {
        return MakeRemediation(GameOwnershipRemediationKind::InstallToPlay, storeVariantIndex, GameTitle(game), storeName);
    }
    if (!selectedOwned) {
        return MakeRemediation(GameOwnershipRemediationKind::PurchaseOrAdd, storeVariantIndex, GameTitle(game), storeName);
    }
    if (!accountLinked) {
        return MakeRemediation(GameOwnershipRemediationKind::LinkAccount, storeVariantIndex, GameTitle(game), storeName);
    }
    return {};
}

}
