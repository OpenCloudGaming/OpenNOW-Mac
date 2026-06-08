#import "OPNGameCatalogPrivate.h"

bool OPNStoreGameMatchesLibraryGame(const OPN::GameInfo &storeGame, const OPN::GameInfo &libraryGame) {
    if (!storeGame.uuid.empty() && storeGame.uuid == libraryGame.uuid) return true;
    if (!storeGame.id.empty() && storeGame.id == libraryGame.id) return true;
    if (!storeGame.launchAppId.empty() && storeGame.launchAppId == libraryGame.launchAppId) return true;
    if (!storeGame.title.empty() && OPNStoreStringEqualsCaseInsensitive(storeGame.title, libraryGame.title)) return true;
    return false;
}

bool OPNStoreVariantMatchesMetadata(const OPN::GameVariant &target, const OPN::GameVariant &source) {
    if (!target.id.empty() && !source.id.empty() && target.id == source.id) return true;
    if (!target.appStore.empty() && !source.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(target.appStore, source.appStore)) return true;
    return false;
}

bool OPNStoreContainsStoreName(const std::vector<std::string> &stores, const std::string &store) {
    for (const std::string &entry : stores) {
        if (OPNStoreStringEqualsCaseInsensitive(entry, store)) return true;
    }
    return false;
}

bool OPNStoreServiceStatusOwnedForLaunch(const std::string &status) {
    return status == "MANUAL" || status == "PLATFORM_SYNC" || status == "IN_LIBRARY";
}

bool OPNStoreClearGameOwnershipMetadata(OPN::GameInfo &game) {
    bool changed = false;
    if (game.isInLibrary) {
        game.isInLibrary = false;
        changed = true;
    }
    for (OPN::GameVariant &variant : game.variants) {
        if (variant.inLibrary) {
            variant.inLibrary = false;
            changed = true;
        }
        if (variant.librarySelected) {
            variant.librarySelected = false;
            changed = true;
        }
        if (OPNStoreServiceStatusOwnedForLaunch(variant.serviceStatus)) {
            variant.serviceStatus.clear();
            changed = true;
        }
    }
    return changed;
}

bool OPNStoreMergeGameStoreMetadata(OPN::GameInfo &target, const OPN::GameInfo &source) {
    bool changed = false;
    if (target.launchAppId.empty() && !source.launchAppId.empty()) {
        target.launchAppId = source.launchAppId;
        changed = true;
    }
    for (const std::string &store : source.availableStores) {
        if (!store.empty() && !OPNStoreContainsStoreName(target.availableStores, store)) {
            target.availableStores.push_back(store);
            changed = true;
        }
    }
    for (const OPN::GameVariant &sourceVariant : source.variants) {
        if (sourceVariant.appStore.empty()) continue;
        bool merged = false;
        for (OPN::GameVariant &targetVariant : target.variants) {
            if (!OPNStoreVariantMatchesMetadata(targetVariant, sourceVariant)) continue;
            if (targetVariant.id.empty() && !sourceVariant.id.empty()) {
                targetVariant.id = sourceVariant.id;
                changed = true;
            }
            if (targetVariant.appStore.empty()) {
                targetVariant.appStore = sourceVariant.appStore;
                changed = true;
            }
            if (targetVariant.storeUrl.empty() && !sourceVariant.storeUrl.empty()) {
                targetVariant.storeUrl = sourceVariant.storeUrl;
                changed = true;
            }
            if (targetVariant.serviceStatus.empty() && !sourceVariant.serviceStatus.empty()) {
                targetVariant.serviceStatus = sourceVariant.serviceStatus;
                changed = true;
            }
            if (!targetVariant.librarySelected && sourceVariant.librarySelected) {
                targetVariant.librarySelected = true;
                changed = true;
            }
            if (!targetVariant.inLibrary && sourceVariant.inLibrary) {
                targetVariant.inLibrary = true;
                changed = true;
            }
            merged = true;
            break;
        }
        if (!merged && !sourceVariant.storeUrl.empty()) {
            target.variants.push_back(sourceVariant);
            if (!OPNStoreContainsStoreName(target.availableStores, sourceVariant.appStore)) {
                target.availableStores.push_back(sourceVariant.appStore);
            }
            changed = true;
        }
    }
    return changed;
}

void OPNStoreAppendFingerprintField(std::string &fingerprint, const std::string &value) {
    fingerprint.append(std::to_string(value.size()));
    fingerprint.push_back(':');
    fingerprint.append(value);
    fingerprint.push_back('|');
}

std::string OPNStorePanelsFingerprint(const std::vector<OPN::PanelResult> &panels) {
    std::string fingerprint;
    fingerprint.reserve(panels.size() * 64);
    for (const OPN::PanelResult &panel : panels) {
        OPNStoreAppendFingerprintField(fingerprint, panel.id);
        OPNStoreAppendFingerprintField(fingerprint, panel.title);
        for (const OPN::PanelSection &section : panel.sections) {
            OPNStoreAppendFingerprintField(fingerprint, section.id);
            OPNStoreAppendFingerprintField(fingerprint, section.title);
            for (const OPN::GameInfo &game : section.games) {
                OPNStoreAppendFingerprintField(fingerprint, game.id);
                OPNStoreAppendFingerprintField(fingerprint, game.title);
                OPNStoreAppendFingerprintField(fingerprint, game.imageUrl);
                OPNStoreAppendFingerprintField(fingerprint, game.heroImageUrl);
                fingerprint.append(game.isInLibrary ? "1" : "0");
                fingerprint.push_back('|');
                for (const OPN::GameVariant &variant : game.variants) {
                    OPNStoreAppendFingerprintField(fingerprint, variant.id);
                    OPNStoreAppendFingerprintField(fingerprint, variant.appStore);
                    OPNStoreAppendFingerprintField(fingerprint, variant.storeUrl);
                    OPNStoreAppendFingerprintField(fingerprint, variant.serviceStatus);
                    fingerprint.append(variant.inLibrary ? "1" : "0");
                    fingerprint.append(variant.librarySelected ? "1" : "0");
                    fingerprint.push_back('|');
                }
            }
        }
    }
    return fingerprint;
}

bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game);
OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game);

std::vector<OPN::PanelResult> OPNCatalogPanelsForGames(const std::vector<OPN::GameInfo> &sourceGames) {
    std::vector<OPN::PanelResult> panels;
    OPN::PanelResult panel;
    panel.id = "catalog";
    panel.title = "Library";
    panel.__typename = "CatalogPanel";

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    OPN::PanelSection currentSection;
    currentSection.id = "catalog-section-1";
    currentSection.title = "Library";
    currentSection.__typename = "CatalogSection";

    NSInteger sectionIndex = 1;
    for (const OPN::GameInfo &game : sourceGames) {
        if (!OPNCatalogGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo catalogGame = OPNCatalogGameWithAccessibleVariants(game);
        NSString *identity = OpnGameIdentityForHero(catalogGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];

        if (currentSection.games.size() >= 24) {
            panel.sections.push_back(currentSection);
            sectionIndex++;
            currentSection = OPN::PanelSection();
            currentSection.id = "catalog-section-" + std::to_string((long)sectionIndex);
            currentSection.title = "Library";
            currentSection.__typename = "CatalogSection";
        }
        currentSection.games.push_back(catalogGame);
    }

    if (!currentSection.games.empty()) panel.sections.push_back(currentSection);
    if (!panel.sections.empty()) panels.push_back(panel);
    return panels;
}

OPN::PanelSection OPNCatalogSingleLibrarySectionForGames(const std::vector<OPN::GameInfo> &sourceGames) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    OPN::PanelSection section;
    section.id = "owned-library";
    section.title = "Library";
    section.__typename = "CatalogSection";
    for (const OPN::GameInfo &game : sourceGames) {
        if (!OPNCatalogGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo catalogGame = OPNCatalogGameWithAccessibleVariants(game);
        NSString *identity = OpnGameIdentityForHero(catalogGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];
        section.games.push_back(catalogGame);
    }
    return section;
}

bool OPNStoreVariantIsLibrarySelected(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary || OPNStoreServiceStatusOwnedForLaunch(variant.serviceStatus);
}

bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game) {
    if (game.isInLibrary) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsLibrarySelected(variant)) return true;
    }
    return game.variants.empty();
}

OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game) {
    OPN::GameInfo catalogGame = game;
    catalogGame.isInLibrary = true;
    std::vector<OPN::GameVariant> variants;
    for (OPN::GameVariant variant : game.variants) {
        if (!OPNStoreVariantIsLibrarySelected(variant)) continue;
        variant.inLibrary = true;
        variants.push_back(variant);
    }
    if (!variants.empty()) catalogGame.variants = variants;
    return catalogGame;
}

int OPNStoreSelectedLibraryVariantIndex(const OPN::GameInfo &libraryGame) {
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (libraryGame.variants[i].librarySelected) return (int)i;
    }
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (OPNStoreVariantIsLibrarySelected(libraryGame.variants[i])) return (int)i;
    }
    return libraryGame.variants.empty() ? -1 : 0;
}

bool OPNStoreVariantIsOwned(const OPN::GameVariant &variant) {
    return OPN::GameVariantOwnedForLaunch(variant);
}

bool OPNStoreVariantIsNotOwned(const OPN::GameVariant &variant) {
    return !OPNStoreVariantIsOwned(variant);
}

const OPN::GameVariant *OPNStoreVariantAtIndex(const OPN::GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

bool OPNStoreVariantCanBeMarkedUnowned(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *variant = OPNStoreVariantAtIndex(game, variantIndex);
    return variant && !variant->id.empty() && OPNStoreVariantIsOwned(*variant);
}

bool OPNStoreGameNeedsPurchase(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *selectedVariant = OPNStoreVariantAtIndex(game, variantIndex);
    if (selectedVariant) return OPNStoreVariantIsNotOwned(*selectedVariant);
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsNotOwned(variant)) return true;
    }
    return false;
}

NSString *OPNStorePrimaryActionTitle(const OPN::GameInfo &game, int variantIndex, BOOL prominent) {
    if (OPNStoreGameNeedsPurchase(game, variantIndex)) {
        return prominent ? @"Add to Library" : @"ADD";
    }
    return prominent ? @"Play Now" : @"PLAY";
}

std::string OPNStoreGameProfileAppId(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *variant = OPNStoreVariantAtIndex(game, variantIndex);
    if (variant && !variant->id.empty()) return variant->id;
    if (!game.launchAppId.empty()) return game.launchAppId;
    return game.id;
}

NSString *OPNStoreAvailabilityTitle(const OPN::GameInfo &game, int variantIndex) {
    if (OPNStoreGameNeedsPurchase(game, variantIndex)) return @"Not owned";
    std::string appId = OPNStoreGameProfileAppId(game, variantIndex);
    if (!appId.empty() && OPN::StreamPreferenceProfileEnabledForGame(appId)) return @"Profile active";
    NSInteger storeCount = MAX((NSInteger)game.availableStores.size(), (NSInteger)game.variants.size());
    return storeCount > 1 ? [NSString stringWithFormat:@"%ld stores", (long)storeCount] : @"Cloud ready";
}
