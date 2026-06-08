#import "OPNGameCatalogPrivate.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation OPNGameCatalogView (Search)

using namespace OPN;

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.searchField) return;
    self.searchQuery = self.searchField.stringValue ?: @"";
    self.searchGeneration++;
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    if (OPNStoreSearchNormalizedString(self.searchQuery).length > 0) {
        self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:kStoreSearchDebounceInterval
                                                                     target:self
                                                                   selector:@selector(performAsyncSearchTimerFired:)
                                                                   userInfo:nil
                                                                    repeats:NO];
        return;
    }
    [self scheduleAsyncSearchForCurrentQuery];
}

- (void)scheduleAsyncSearchForCurrentQuery {
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    NSString *query = self.searchQuery ?: @"";
    NSString *normalizedQuery = OPNStoreSearchNormalizedString(query);
    self.searchGeneration++;
    NSInteger generation = self.searchGeneration;

    if (normalizedQuery.length == 0) {
        self.searchInFlight = NO;
        self.completedSearchQuery = @"";
        _filteredLibraryGames.clear();
        _filteredPanels.clear();
        self.currentHeroIndex = 0;
        self.initialHeroReady = NO;
        self.initialHeroPreloadInFlight = NO;
        self.initialHeroPreloadGeneration++;
        self.initialHeroImage = nil;
        self.initialHeroIdentity = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return;
            [self renderStoreWhenInitialHeroReady];
        });
        return;
    }

    self.searchInFlight = YES;
    std::shared_ptr<const std::vector<GameInfo>> libraryGames = _searchLibrarySnapshot ?: std::make_shared<const std::vector<GameInfo>>(_ownedLibraryGames);
    std::shared_ptr<const std::vector<PanelResult>> panels = _searchPanelsSnapshot ?: std::make_shared<const std::vector<PanelResult>>(_panels);
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(self.searchQueue, ^{
        std::vector<GameInfo> filteredLibraryGames = OPNStoreSearchFilteredGames(*libraryGames, query);
        std::vector<PanelResult> filteredPanels = OPNStoreSearchFilteredPanels(*panels, query);
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.searchGeneration) return;
            strongSelf.searchInFlight = NO;
            strongSelf.completedSearchQuery = query;
            strongSelf->_filteredLibraryGames = filteredLibraryGames;
            strongSelf->_filteredPanels = filteredPanels;
            strongSelf.currentHeroIndex = 0;
            strongSelf.initialHeroReady = NO;
            strongSelf.initialHeroPreloadInFlight = NO;
            strongSelf.initialHeroPreloadGeneration++;
            strongSelf.initialHeroImage = nil;
            strongSelf.initialHeroIdentity = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != strongSelf.searchGeneration) return;
                [strongSelf renderStoreWhenInitialHeroReady];
            });
        });
    });
}

- (void)performAsyncSearchTimerFired:(NSTimer *)timer {
    (void)timer;
    self.searchDebounceTimer = nil;
    [self scheduleAsyncSearchForCurrentQuery];
}

@end

#pragma clang diagnostic pop
