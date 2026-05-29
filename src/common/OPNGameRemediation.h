#pragma once

#include "OPNGameTypes.h"

#include <string>

namespace OPN {

enum class GameOwnershipRemediationKind {
    None = 0,
    PurchaseOrAdd,
    LinkAccount,
    InstallToPlay,
};

struct GameOwnershipRemediation {
    GameOwnershipRemediationKind kind = GameOwnershipRemediationKind::None;
    int storeVariantIndex = -1;
    std::string storeName;
    std::string title;
    std::string reason;
    std::string guidance;
    std::string actionLabel;

    bool Required() const;
};

bool GameServiceStatusOwnedForLaunch(const std::string &status);
bool GameVariantOwnedForLaunch(const GameVariant &variant);
std::string GameStoreDisplayName(const std::string &store);
GameOwnershipRemediation GameOwnershipRemediationForLaunch(const GameInfo &game,
                                                           int variantIndex,
                                                           bool accountLinked);

}
