#import "OPNAppDelegatePrivate.h"

@implementation AppDelegate (Catalog)

#pragma mark - Store Loading

- (void)loadStorePanelsWithRetry:(BOOL)canRetry {
    using namespace OPN;

    if (!self.storeView) return;
    [self.storeView setLoading:YES];

    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    GameService::Shared().SetAccessToken(apiToken);
    GameService::Shared().SetVpcId("GFN-PC");

    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchMainPanels(
        [weakSelf, accountIdentifier, canRetry](bool success, const std::vector<PanelResult> &panels, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) return;

            if (!success && canRetry && error.find("401") != std::string::npos) {
                AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf) return;
                    if (refreshSuccess) {
                        retrySelf.currentSession = fresh;
                        if (retrySelf.pendingCredentials.stayLoggedIn) {
                            AuthService::Shared().SaveSession(fresh);
                        }
                        [retrySelf refreshAccountMenu];
                        [retrySelf loadStorePanelsWithRetry:NO];
                        return;
                    }

                    AuthSession fallback = AuthService::Shared().LoadSavedSession();
                    if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
                        retrySelf.currentSession = fallback;
                        [retrySelf transitionToScreen:AuthScreen::Store];
                    } else {
                        [retrySelf transitionToScreen:AuthScreen::EmailEntry];
                    }
                }, true);
                return;
            }

            if (!strongSelf.storeView || strongSelf.currentScreen != AuthScreen::Store) return;
            if (!success) {
                NSString *message = error.empty()
                    ? @"Unable to load Store collections."
                    : [NSString stringWithUTF8String:error.c_str()];
                [strongSelf.storeView setError:message];
                return;
            }

            strongSelf.cachedStorePanels = panels;
            strongSelf.cachedStorePanelsAccountIdentifier = accountIdentifier;
            strongSelf.hasCachedStorePanels = YES;
            [strongSelf.storeView setPanels:panels];
            [strongSelf.storeView setLoading:NO];
        });
}

#pragma mark - Catalog Loading

- (void)startGameLibraryRefreshTimer {
    if (self.gameLibraryRefreshTimer) return;
    self.gameLibraryRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 * 60.0
                                                                    target:self
                                                                  selector:@selector(gameLibraryRefreshTimerFired:)
                                                                  userInfo:nil
                                                                   repeats:YES];
}

- (void)stopGameLibraryRefreshTimer {
    [self.gameLibraryRefreshTimer invalidate];
    self.gameLibraryRefreshTimer = nil;
}

- (void)gameLibraryRefreshTimerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshGameLibraryInBackground];
}

- (void)refreshGameLibraryInBackground {
    using namespace OPN;
    if (!self.currentSession.isAuthenticated || self.currentSession.accessToken.empty() || self.gameLibraryRefreshInFlight) {
        return;
    }
    self.gameLibraryRefreshInFlight = YES;
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    __weak __typeof__(self) weakSelf = self;
    [self fetchGameLibraryWithRetry:YES completion:^(BOOL success, const std::vector<GameInfo> &games) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.gameLibraryRefreshInFlight = NO;
        if (!success || accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) return;

        std::string fingerprint = OPNGameLibraryFingerprint(games);
        BOOL changed = !strongSelf.hasCachedGameLibrary
            || strongSelf.cachedGameLibraryAccountIdentifier != accountIdentifier
            || strongSelf.cachedGameLibraryFingerprint != fingerprint;
        if (!changed) return;

        strongSelf.cachedGameLibrary = games;
        strongSelf.cachedGameLibraryFingerprint = fingerprint;
        strongSelf.cachedGameLibraryAccountIdentifier = accountIdentifier;
        strongSelf.hasCachedGameLibrary = YES;
        if (strongSelf.currentScreen == AuthScreen::Catalog && strongSelf.catalogView) {
            [strongSelf.catalogView setGames:games];
        } else if (strongSelf.currentScreen == AuthScreen::Store && strongSelf.storeView) {
            [strongSelf.storeView setLibraryGames:games];
        }
    }];
}

- (void)loadGamesIntoCatalog {
    [self loadGamesIntoCatalogWithRetry:YES];
}

- (void)loadGamesIntoCatalogWithRetry:(BOOL)canRetry {
    using namespace OPN;
    if (!self.catalogView) {
        return;
    }
    [self refreshFeaturedGamesForCatalogWithRetry:canRetry];
    [self refreshActiveSessionsForCatalog];
    [self browseCatalogWithSearch:@"" sortId:@"last_played" filterIds:std::vector<std::string>() canRetry:canRetry retryAttempt:0];
}

- (void)refreshActiveSessionsForCatalog {
    using namespace OPN;
    if (!self.catalogView || self.activeSessionsRefreshInFlight) return;

    self.activeSessionsRefreshInFlight = YES;
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    SessionManager::Shared().SetAccessToken(apiToken);
    SessionManager::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());

    __weak __typeof__(self) weakSelf = self;
    SessionManager::Shared().GetActiveSessions([weakSelf, accountIdentifier](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
        std::vector<ActiveSessionEntry> sessionsCopy = sessions;
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.activeSessionsRefreshInFlight = NO;
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) return;
            if (!strongSelf.catalogView || strongSelf.currentScreen != AuthScreen::Catalog) return;
            if (!ok) {
                OPN::LogError(@"[AppDelegate] Active session hero-state fetch failed: %s", errorCopy.c_str());
                [strongSelf.catalogView setActiveSessionAppIds:std::vector<int>()];
                return;
            }

            std::vector<int> appIds;
            for (const ActiveSessionEntry &session : sessionsCopy) {
                if ((session.status == 1 || session.status == 2 || session.status == 3 || session.status == 6) && session.appId > 0) {
                    appIds.push_back(session.appId);
                }
            }
            [strongSelf.catalogView setActiveSessionAppIds:appIds];
        });
    });
}

- (void)refreshFeaturedGamesForCatalogWithRetry:(BOOL)canRetry {
    using namespace OPN;
    if ((!self.catalogView && !self.storeView) || self.featuredGamesRefreshInFlight) return;

    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    if (self.hasCachedFeaturedGames && self.cachedFeaturedGamesAccountIdentifier == accountIdentifier) {
        if (self.catalogView) [self.catalogView setFeaturedGames:self.cachedFeaturedGames];
        if (self.storeView) [self.storeView setFeaturedGames:self.cachedFeaturedGames];
        return;
    }

    self.featuredGamesRefreshInFlight = YES;
    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    GameService::Shared().SetAccessToken(apiToken);
    GameService::Shared().SetVpcId("GFN-PC");

    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchMarqueePanels(
        [weakSelf, accountIdentifier, canRetry](bool success, const std::vector<PanelResult> &panels, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) {
                strongSelf.featuredGamesRefreshInFlight = NO;
                return;
            }

            if (!success && canRetry && error.find("401") != std::string::npos) {
                strongSelf.featuredGamesRefreshInFlight = NO;
                AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf) return;
                    if (refreshSuccess) {
                        retrySelf.currentSession = fresh;
                        if (retrySelf.pendingCredentials.stayLoggedIn) AuthService::Shared().SaveSession(fresh);
                        [retrySelf refreshAccountMenu];
                        [retrySelf refreshFeaturedGamesForCatalogWithRetry:NO];
                    }
                }, true);
                return;
            }

            strongSelf.featuredGamesRefreshInFlight = NO;
            if (!success) {
                OPN::LogError(@"[AppDelegate] Marquee featured games fetch failed: %s", error.c_str());
                return;
            }

            FeaturedGamesResult featured = OPNFeaturedGamesFromPanels(panels);
            OPN::LogInfo(@"[AppDelegate] featured games resolved from marquee count=%lu explicit=%d", (unsigned long)featured.games.size(), featured.usedExplicitFeaturedSection);
            strongSelf.cachedFeaturedGames = featured.games;
            strongSelf.cachedFeaturedGamesAccountIdentifier = accountIdentifier;
            strongSelf.hasCachedFeaturedGames = YES;
            if (strongSelf.catalogView && strongSelf.currentScreen == AuthScreen::Catalog) {
                [strongSelf.catalogView setFeaturedGames:featured.games];
            }
            if (strongSelf.storeView && strongSelf.currentScreen == AuthScreen::Store) {
                [strongSelf.storeView setFeaturedGames:featured.games];
            }
        });
}

- (void)browseCatalogWithSearch:(NSString *)searchQuery
                          sortId:(NSString *)sortId
                       filterIds:(const std::vector<std::string> &)filterIds
                         canRetry:(BOOL)canRetry {
    [self browseCatalogWithSearch:searchQuery sortId:sortId filterIds:filterIds canRetry:canRetry retryAttempt:0];
}

- (void)browseCatalogWithSearch:(NSString *)searchQuery
                          sortId:(NSString *)sortId
                       filterIds:(const std::vector<std::string> &)filterIds
                         canRetry:(BOOL)canRetry
                     retryAttempt:(NSInteger)retryAttempt {
    using namespace OPN;
    if (!self.catalogView) return;

    NSInteger requestGeneration = ++self.catalogBrowseGeneration;
    OPN::LogInfo(@"[CatalogBrowse] request start generation=%ld search=%@ sort=%@ filters=%lu retryAttempt=%ld", (long)requestGeneration, searchQuery ?: @"", sortId ?: @"", (unsigned long)filterIds.size(), (long)retryAttempt);
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    GameService::Shared().SetAccessToken(apiToken);
    GameService::Shared().SetUserId(accountIdentifier);
    GameService::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
    GameService::Shared().SetVpcId("GFN-PC");
    [self.catalogView setLoading:YES];

    std::string search = searchQuery.length > 0 ? [searchQuery UTF8String] : "";
    std::string selectedSort = sortId.length > 0 ? [sortId UTF8String] : "last_played";
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().BrowseCatalogGames(search, selectedSort, filterIds, 96,
        [weakSelf, accountIdentifier, canRetry, requestGeneration, searchQuery, sortId, filterIds, retryAttempt]
        (bool success, const CatalogBrowseResult &result, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (success) {
                OPN::LogInfo(@"[CatalogBrowse] callback generation=%ld success=%d games=%lu total=%d returned=%d supported=%d hasNext=%d error=%s", (long)requestGeneration, success, (unsigned long)result.games.size(), result.totalCount, result.numberReturned, result.numberSupported, result.hasNextPage, error.c_str());
            } else {
                OPN::LogError(@"[CatalogBrowse] callback generation=%ld success=%d games=%lu total=%d returned=%d supported=%d hasNext=%d error=%s", (long)requestGeneration, success, (unsigned long)result.games.size(), result.totalCount, result.numberReturned, result.numberSupported, result.hasNextPage, error.c_str());
            }
            if (!strongSelf || requestGeneration != strongSelf.catalogBrowseGeneration) {
                OPN::LogInfo(@"[CatalogBrowse] callback ignored stale/nil generation=%ld current=%ld", (long)requestGeneration, strongSelf ? (long)strongSelf.catalogBrowseGeneration : -1L);
                return;
            }
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) {
                OPN::LogInfo(@"[CatalogBrowse] callback ignored account mismatch generation=%ld", (long)requestGeneration);
                return;
            }

            if (!success && canRetry && error.find("401") != std::string::npos) {
                AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf) return;
                    if (refreshSuccess) {
                        retrySelf.currentSession = fresh;
                        if (retrySelf.pendingCredentials.stayLoggedIn) AuthService::Shared().SaveSession(fresh);
                        [retrySelf refreshAccountMenu];
                        [retrySelf browseCatalogWithSearch:searchQuery sortId:sortId filterIds:filterIds canRetry:NO retryAttempt:retryAttempt];
                        return;
                    }
                    [retrySelf.catalogView setLoading:NO];
                    [retrySelf transitionToScreen:AuthScreen::EmailEntry];
                }, true);
                return;
            }

            if (!success) {
                if (canRetry && OPNIsTransientNetworkLostError(error) && retryAttempt < 10) {
                    NSInteger nextAttempt = retryAttempt + 1;
                    NSTimeInterval delay = pow(2.0, (double)retryAttempt);
                    OPN::LogError(@"[AppDelegate] Catalog browse network lost; retry %ld/10 in %.0fs", (long)nextAttempt, delay);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        __typeof__(self) retrySelf = weakSelf;
                        if (!retrySelf || requestGeneration != retrySelf.catalogBrowseGeneration) return;
                        if (accountIdentifier != OPNAuthSessionIdentifier(retrySelf.currentSession)) return;
                        if (!retrySelf.catalogView || retrySelf.currentScreen != AuthScreen::Catalog) return;
                        [retrySelf browseCatalogWithSearch:searchQuery sortId:sortId filterIds:filterIds canRetry:canRetry retryAttempt:nextAttempt];
                    });
                    return;
                }
                [strongSelf.catalogView setLoading:NO];
                NSString *message = error.empty() ? @"Unable to browse catalog." : [NSString stringWithUTF8String:error.c_str()];
                [strongSelf.catalogView setError:message];
                return;
            }
            [strongSelf.catalogView setLoading:NO];
            strongSelf.cachedGameLibrary = result.games;
            strongSelf.cachedGameLibraryFingerprint = OPNGameLibraryFingerprint(result.games);
            strongSelf.cachedGameLibraryAccountIdentifier = accountIdentifier;
            strongSelf.hasCachedGameLibrary = YES;
            [strongSelf.catalogView setCatalogBrowseResult:result];
            [strongSelf startGameLibraryRefreshTimer];
        });
}

- (void)fetchGameLibraryWithRetry:(BOOL)canRetry
                       completion:(void (^)(BOOL success, const std::vector<OPN::GameInfo> &games))completion {
    using namespace OPN;

    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    GameService::Shared().SetAccessToken(apiToken);
    GameService::Shared().SetUserId(accountIdentifier);
    GameService::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
    GameService::Shared().SetVpcId("GFN-PC");

    auto terminalFailureDelivered = std::make_shared<bool>(false);
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().BrowseCatalogGames("", "last_played", {}, 96,
        [weakSelf, canRetry, completion, terminalFailureDelivered, accountIdentifier](bool success, const CatalogBrowseResult &result, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || *terminalFailureDelivered) return;
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) {
                completion(false, std::vector<GameInfo>());
                return;
            }
            if (!success && canRetry && error.find("401") != std::string::npos) {
                AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf || *terminalFailureDelivered) return;
                    if (refreshSuccess) {
                        retrySelf.currentSession = fresh;
                        if (retrySelf.pendingCredentials.stayLoggedIn) AuthService::Shared().SaveSession(fresh);
                        [retrySelf refreshAccountMenu];
                        [retrySelf fetchGameLibraryWithRetry:NO completion:completion];
                        return;
                    }

                    *terminalFailureDelivered = true;
                    AuthSession fallback = AuthService::Shared().LoadSavedSession();
                    if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
                        retrySelf.currentSession = fallback;
                        [retrySelf transitionToScreen:AuthScreen::Store];
                    } else {
                        [retrySelf transitionToScreen:AuthScreen::EmailEntry];
                    }
                    completion(false, std::vector<GameInfo>());
                }, true);
                return;
            }

            completion(success, success ? result.games : std::vector<GameInfo>());
        });
}

@end
