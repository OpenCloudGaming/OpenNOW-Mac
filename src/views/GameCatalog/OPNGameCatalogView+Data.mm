#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (Data)

using namespace OPN;

- (void)setLoading:(BOOL)loading {
    BOOL showBlockingLoader = loading && !self.hasContent;
    self.loadingView.hidden = !showBlockingLoader;
    self.buttonHintPillView.hidden = showBlockingLoader;
    self.statusLabel.stringValue = @"";
    if (showBlockingLoader) {
        [self.loadingView startAnimating];
    } else {
        [self.loadingView stopAnimating];
    }
}

- (void)setError:(NSString *)message {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    [self setLoading:NO];
    self.statusLabel.stringValue = message ?: @"";
}

- (void)setGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    _ownedLibraryGames = games;
    self.hasLibraryState = YES;
    std::vector<PanelResult> catalogPanels = OPNCatalogPanelsForGames(games);
    NSInteger gameCount = 0;
    for (const PanelResult &panel : catalogPanels) {
        for (const PanelSection &section : panel.sections) {
            gameCount += (NSInteger)section.games.size();
        }
    }
    if (self.onGameCountChanged) self.onGameCountChanged(gameCount);
    [self setPanels:catalogPanels];
}

- (void)setCatalogBrowseResult:(const OPN::CatalogBrowseResult &)result {
    [self setPanels:OPNCatalogPanelsForGames(result.games)];
    if (self.onGameCountChanged) {
        NSInteger count = result.totalCount > 0 ? result.totalCount : (NSInteger)result.games.size();
        self.onGameCountChanged(count);
    }
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    (void)appIds;
}

- (void)setUserName:(NSString *)name {
    (void)name;
}

- (void)setPanels:(const std::vector<OPN::PanelResult> &)panels {
    std::string fingerprint = OPNStorePanelsFingerprint(panels);
    if (self.hasContent && fingerprint == self.panelsFingerprint) {
        _panels = panels;
        [self mergeKnownStoreMetadataIntoPanels];
        _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
        if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
        [self refreshLibrarySelections];
        return;
    }
    _panels = panels;
    self.panelsFingerprint = fingerprint;
    [self mergeKnownStoreMetadataIntoPanels];
    _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
    self.currentHeroIndex = 0;
    self.initialHeroReady = NO;
    self.initialHeroPreloadInFlight = NO;
    self.initialHeroPreloadGeneration++;
    self.initialHeroImage = nil;
    self.initialHeroIdentity = nil;
    [self configureHeroRotationTimer];
    [self prefetchHeroArtworkCandidates];
    [self renderStoreWhenInitialHeroReady];
}

- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games {
    _featuredGames = games;
    self.currentHeroIndex = 0;
    self.initialHeroReady = NO;
    self.initialHeroPreloadInFlight = NO;
    self.initialHeroPreloadGeneration++;
    self.initialHeroImage = nil;
    self.initialHeroIdentity = nil;
    [self configureHeroRotationTimer];
    [self prefetchHeroArtworkCandidates];
    if (self.hasContent) {
        [self updateDesktopFeaturedHeroOnly];
        return;
    }
    [self renderStoreWhenInitialHeroReady];
}

- (void)setLibraryGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    _ownedLibraryGames = games;
    self.hasLibraryState = YES;
    BOOL changedPanelMetadata = [self mergeKnownStoreMetadataIntoPanels];
    _searchLibrarySnapshot = std::make_shared<const std::vector<GameInfo>>(_ownedLibraryGames);
    _searchPanelsSnapshot = std::make_shared<const std::vector<PanelResult>>(_panels);
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) [self scheduleAsyncSearchForCurrentQuery];
    if (self.rowCards.count > 0 || self.desktopFeaturedHeroViews.count > 0) {
        [self refreshLibrarySelections];
        if (changedPanelMetadata) [self scheduleRenderStore];
    } else if (!_panels.empty()) {
        [self renderStoreWhenInitialHeroReady];
    }
}

- (BOOL)mergeKnownStoreMetadataIntoPanels {
    if (_panels.empty()) return NO;
    std::unordered_map<std::string, const GameInfo *> byUuid;
    std::unordered_map<std::string, const GameInfo *> byId;
    std::unordered_map<std::string, const GameInfo *> byLaunchId;
    std::unordered_map<std::string, const GameInfo *> byTitle;
    auto addIndexedGame = [](std::unordered_map<std::string, const GameInfo *> &index, const std::string &key, const GameInfo &game) {
        if (!key.empty() && index.find(key) == index.end()) index.emplace(key, &game);
    };
    auto normalizedTitle = [](const std::string &title) -> std::string {
        NSString *normalized = OPNStoreSearchNormalizedString(OPNStoreString(title, @""));
        return normalized.length > 0 ? std::string(normalized.UTF8String ?: "") : std::string();
    };
    for (const GameInfo &knownGame : _libraryGames) {
        addIndexedGame(byUuid, knownGame.uuid, knownGame);
        addIndexedGame(byId, knownGame.id, knownGame);
        addIndexedGame(byLaunchId, knownGame.launchAppId, knownGame);
        addIndexedGame(byTitle, normalizedTitle(knownGame.title), knownGame);
    }
    auto findKnownGame = [&](const GameInfo &storeGame) -> const GameInfo * {
        auto lookup = [](const std::unordered_map<std::string, const GameInfo *> &index, const std::string &key) -> const GameInfo * {
            if (key.empty()) return nullptr;
            auto it = index.find(key);
            return it == index.end() ? nullptr : it->second;
        };
        if (const GameInfo *game = lookup(byUuid, storeGame.uuid)) return game;
        if (const GameInfo *game = lookup(byId, storeGame.id)) return game;
        if (const GameInfo *game = lookup(byLaunchId, storeGame.launchAppId)) return game;
        return lookup(byTitle, normalizedTitle(storeGame.title));
    };
    BOOL changed = NO;
    for (PanelResult &panel : _panels) {
        for (PanelSection &section : panel.sections) {
            for (GameInfo &storeGame : section.games) {
                if (self.hasLibraryState && OPNStoreClearGameOwnershipMetadata(storeGame)) changed = YES;
                const GameInfo *knownGame = findKnownGame(storeGame);
                if (knownGame && OPNStoreMergeGameStoreMetadata(storeGame, *knownGame)) changed = YES;
            }
        }
    }
    return changed;
}

- (int)selectedVariantIndexForStoreGame:(const GameInfo &)storeGame {
    for (const GameInfo &libraryGame : _libraryGames) {
        if (!OPNStoreGameMatchesLibraryGame(storeGame, libraryGame)) continue;
        int libraryVariantIndex = OPNStoreSelectedLibraryVariantIndex(libraryGame);
        if (libraryVariantIndex < 0 || libraryVariantIndex >= (int)libraryGame.variants.size()) return storeGame.variants.empty() ? -1 : 0;

        const GameVariant &libraryVariant = libraryGame.variants[(size_t)libraryVariantIndex];
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.id.empty() && storeVariant.id == libraryVariant.id) return (int)i;
        }
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(storeVariant.appStore, libraryVariant.appStore)) return (int)i;
        }
    }
    return storeGame.variants.empty() ? -1 : 0;
}

@end

#pragma clang diagnostic pop
