#import "OPNAppDelegatePrivate.h"

@implementation AppDelegate (Navigation)

- (void)installLibraryRootIfNeeded {
    using namespace OPN;

    BOOL needsRoot = !self.rootView || self.window.contentView != self.rootView;
    if (needsRoot) {
        self.window.contentViewController = nil;
        self.rootView = [[OPNBackdropView alloc] initWithFrame:self.window.contentView.bounds];
        self.rootView.wantsLayer = YES;
        self.rootView.layer.opaque = NO;
        self.rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        __weak __typeof__(self) weakSelf = self;
        self.rootView.onHomeSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.currentScreen != OPN::AuthScreen::Catalog) [strongSelf transitionToScreen:OPN::AuthScreen::Catalog];
            strongSelf.rootView.mode = OPNBackdropModeLibrary;
        };
        self.rootView.onStoreSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.currentScreen == OPN::AuthScreen::Store) return;
            [strongSelf transitionToScreen:OPN::AuthScreen::Store];
        };
        self.rootView.onLibrarySelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.currentScreen != OPN::AuthScreen::Catalog) [strongSelf transitionToScreen:OPN::AuthScreen::Catalog];
            strongSelf.rootView.mode = OPNBackdropModeLibrary;
        };
        self.rootView.onSearchSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.currentScreen != OPN::AuthScreen::Catalog) [strongSelf transitionToScreen:OPN::AuthScreen::Catalog];
            strongSelf.rootView.mode = OPNBackdropModeLibrary;
        };
        self.rootView.onSettingsSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.currentScreen == OPN::AuthScreen::Settings) return;
            [strongSelf transitionToScreen:OPN::AuthScreen::Settings];
        };
        self.rootView.onAccountSelected = ^(NSString *accountIdentifier) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf switchToAccountIdentifier:accountIdentifier];
        };
        self.rootView.onAddAccountSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf addAccount];
        };
        self.rootView.onSignOutSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf performServerLogout];
        };
        self.rootView.onExitSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [NSApp terminate:strongSelf];
        };
        self.window.contentView = self.rootView;
        OpnDisableFocusHighlights(self.rootView);
    }

    if (!self.contentContainer || self.contentContainer.superview != self.rootView) {
        self.contentContainer = [[NSView alloc] initWithFrame:self.rootView.bounds];
        self.contentContainer.wantsLayer = YES;
        self.contentContainer.layer.opaque = NO;
        self.contentContainer.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.contentContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.rootView addSubview:self.contentContainer];
    }
    [self installDesktopTopChromeIfNeeded];
    [self installDesktopAccountSwitcherIfNeeded];
    [self installDesktopSettingsPillIfNeeded];
}

- (void)configureContentContainerForScreen:(OPN::AuthScreen)screen {
    if (self.rootView) {
        if (screen == OPN::AuthScreen::Store) {
            self.rootView.mode = OPNBackdropModeStore;
        } else if (screen == OPN::AuthScreen::Catalog) {
            self.rootView.mode = OPNBackdropModeLibrary;
        } else if (screen == OPN::AuthScreen::Settings) {
            self.rootView.mode = OPNBackdropModeSettings;
        } else {
            self.rootView.mode = OPNBackdropModeAuth;
        }
    }
    self.contentContainer.frame = self.rootView.bounds;
    self.contentContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self updateDesktopTopChrome];
    [self updateDesktopSettingsPill];
}

- (void)completeContentTransitionFromSubviews:(NSArray<NSView *> *)previousSubviews
                                       toView:(NSView *)view
                                     animated:(BOOL)animated
                                      forward:(BOOL)forward {
    if (!view) return;
    view.frame = self.contentContainer.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (!animated || previousSubviews.count == 0) {
        view.alphaValue = 1.0;
        for (NSView *subview in previousSubviews) {
            if (subview != view) [subview removeFromSuperview];
        }
        return;
    }

    CGFloat offset = forward ? 22.0 : -22.0;
    NSRect finalFrame = self.contentContainer.bounds;
    NSRect startingFrame = NSOffsetRect(finalFrame, offset, 0.0);
    NSRect outgoingFrame = NSOffsetRect(finalFrame, -offset * 0.55, 0.0);
    view.wantsLayer = YES;
    view.alphaValue = 0.0;
    view.frame = startingFrame;
    for (NSView *subview in previousSubviews) {
        if (subview == view) continue;
        subview.wantsLayer = YES;
        subview.alphaValue = 1.0;
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.20;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        view.animator.alphaValue = 1.0;
        view.animator.frame = finalFrame;
        for (NSView *subview in previousSubviews) {
            if (subview == view) continue;
            subview.animator.alphaValue = 0.0;
            subview.animator.frame = outgoingFrame;
        }
    } completionHandler:^{
        view.alphaValue = 1.0;
        view.frame = finalFrame;
        for (NSView *subview in previousSubviews) {
            if (subview == view) continue;
            subview.alphaValue = 1.0;
            [subview removeFromSuperview];
        }
    }];
}

- (void)transitionToScreen:(OPN::AuthScreen)screen {
    using namespace OPN;

    [self installLibraryRootIfNeeded];
    AuthScreen previousScreen = self.currentScreen;
    OPN::RecordSentryCounterMetric("opennow.ui.screen_transition.count", 1, @{
        @"from": OPNMetricScreenName(previousScreen),
        @"to": OPNMetricScreenName(screen),
    });
    NSArray<NSView *> *previousSubviews = [self.contentContainer.subviews copy];
    BOOL animatedMainTransition = (previousScreen == AuthScreen::Settings && screen == AuthScreen::Store) ||
        (OPNAppDelegateScreenSupportsDesktopNavigation(previousScreen) && screen == AuthScreen::Settings);
    BOOL forwardTransition = screen == AuthScreen::Settings;
    [self configureContentContainerForScreen:screen];

    if (!animatedMainTransition) {
        for (NSView *subview in previousSubviews) {
            [subview removeFromSuperview];
        }
        previousSubviews = @[];
    }

    self.currentScreen = screen;
    [self updateDesktopTopChrome];
    [self updateDesktopSettingsPill];
    NSRect bounds = self.contentContainer.bounds;

    switch (screen) {
        case AuthScreen::EmailEntry: {
            OPNEmailEntryView *view = [[OPNEmailEntryView alloc] initWithFrame:bounds];
            view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            __weak __typeof__(self) weakSelf = self;
            __weak OPNEmailEntryView *weakSignInView = view;

            view.onSignInWithBrowser = ^{
                __typeof__(self) strongSelf = weakSelf;
                OPNEmailEntryView *signInView = weakSignInView;
                if (!strongSelf || !signInView) return;
                OPN::AuthCredentials creds = strongSelf.pendingCredentials;
                creds.providerIdpId = [signInView selectedProviderIdpId];
                creds.stayLoggedIn = OPN::AuthService::Shared().GetStayLoggedIn();
                strongSelf.pendingCredentials = creds;
                [strongSelf transitionToScreen:OPN::AuthScreen::OAuthBrowser];
            };

            __weak OPNEmailEntryView *weakProviderView = view;
            OPN::GameService::Shared().FetchProviderInfo(self.pendingCredentials.providerIdpId, [weakSelf, weakProviderView](bool success,
                                                                                                                            const OPN::GameProviderInfo &providerInfo,
                                                                                                                            const OPN::GameProviderEndpoint &selectedEndpoint,
                                                                                                                            const std::string &) {
                __typeof__(self) strongSelf = weakSelf;
                OPNEmailEntryView *providerView = weakProviderView;
                if (!strongSelf || !providerView || providerView.superview != strongSelf.contentContainer) return;
                std::string selectedIdpId = selectedEndpoint.idpId.empty() ? strongSelf.pendingCredentials.providerIdpId : selectedEndpoint.idpId;
                [providerView setLoginProviders:providerInfo.endpoints selectedProviderIdpId:selectedIdpId];
                if (!success) {
                    OPN::LogError(@"[AppDelegate] Provider discovery failed; using NVIDIA default for login");
                }
            });

            [self.contentContainer addSubview:view];
            OpnDisableFocusHighlights(view);
            self.window.title = @"OpenNOW";
            break;
        }

        case AuthScreen::OAuthBrowser: {
            __weak __typeof__(self) weakSelf = self;
            [self showAuthenticatingWithMessage:@"Opening browser for sign in..."];
            OPN::AuthService::Shared().StartOAuthLogin(self.pendingCredentials.providerIdpId,
                ^(bool success, const OPN::AuthSession &session, const std::string &error) {
                    __typeof__(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if (success) {
                        OPN::RecordSentryCounterMetric("opennow.auth.login.count", 1, @{@"outcome": @"success"});
                        strongSelf.currentSession = session;
                        if (strongSelf.pendingCredentials.stayLoggedIn)
                            OPN::AuthService::Shared().SaveSession(session);
                        [strongSelf refreshAccountMenu];
                        [strongSelf transitionToStoreAfterProviderSelectionForSession:session];
                    } else {
                        OPN::RecordSentryCounterMetric("opennow.auth.login.count", 1, @{@"outcome": @"failure"});
                        [strongSelf showError:error canRetry:YES];
                    }
                });
            break;
        }

        case AuthScreen::Store: {
            OPN::DiscordPresence::Shared().UpdateBrowsing();
            OPNConfigureLibraryWindow(self.window);
            self.catalogView = nil;
            BOOL restoringCachedStore = self.storeView != nil;

            self.rootView.accountName = OPNAuthSessionDisplayName(self.currentSession);
            self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
            self.rootView.remainingPlayTime = @"--";
            self.currentRemainingPlayTimeAvailable = NO;
            self.rootView.gameCountText = @"";
            [self refreshAccountAvatar];
            [self refreshAccountMenu];
            [self refreshAccountSummary];
            [self refreshStreamRegions];

            OPNGameCatalogView *store = self.storeView ?: [[OPNGameCatalogView alloc] initWithFrame:bounds];
            store.frame = bounds;
            store.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            self.storeView = store;

            if (!restoringCachedStore && self.hasCachedFeaturedGames && self.cachedFeaturedGamesAccountIdentifier == OPNAuthSessionIdentifier(self.currentSession)) {
                [store setFeaturedGames:self.cachedFeaturedGames];
            }

            std::string storePanelsAccountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
            if (!restoringCachedStore && self.hasCachedStorePanels && self.cachedStorePanelsAccountIdentifier == storePanelsAccountIdentifier) {
                [store setPanels:self.cachedStorePanels];
            }

            std::string storeAccountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
            if (!restoringCachedStore && self.hasCachedGameLibrary && self.cachedGameLibraryAccountIdentifier == storeAccountIdentifier) {
                [store setLibraryGames:self.cachedGameLibrary];
            } else if (!restoringCachedStore) {
                __weak __typeof__(self) weakSelfForLibrary = self;
                [self fetchGameLibraryWithRetry:YES completion:^(BOOL success, const std::vector<GameInfo> &games) {
                    __typeof__(self) strongSelf = weakSelfForLibrary;
                    if (!strongSelf || !success || storeAccountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) return;
                    strongSelf.cachedGameLibrary = games;
                    strongSelf.cachedGameLibraryFingerprint = OPNGameLibraryFingerprint(games);
                    strongSelf.cachedGameLibraryAccountIdentifier = storeAccountIdentifier;
                    strongSelf.hasCachedGameLibrary = YES;
                    if (strongSelf.currentScreen == AuthScreen::Store && strongSelf.storeView) {
                        [strongSelf.storeView setLibraryGames:games];
                    }
                }];
            }

            if (!restoringCachedStore) {
                __weak __typeof__(self) weakSelf = self;
                store.onSelectGame = ^(const GameInfo &game, int variantIndex) {
                    __typeof__(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf launchGame:game variantIndex:variantIndex returnScreen:AuthScreen::Store];
                };
                store.onBuyGame = ^(const GameInfo &game, int variantIndex, NSString *purchaseURL) {
                    __typeof__(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf openPurchaseURL:purchaseURL forGame:game variantIndex:variantIndex];
                };
                store.onMarkGameUnowned = ^(const GameInfo &game, int variantIndex) {
                    __typeof__(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf markVariantUnownedForGame:game variantIndex:variantIndex];
                };
                store.onBackRequested = ^{
                    __typeof__(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf transitionToScreen:AuthScreen::Store];
                };
            }

            [self.contentContainer addSubview:store];
            [self completeContentTransitionFromSubviews:previousSubviews toView:store animated:animatedMainTransition forward:forwardTransition];
            OpnDisableFocusHighlights(store);
            self.window.title = @"OpenNOW - Store";
            if (!restoringCachedStore) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.currentScreen != AuthScreen::Store || self.storeView != store) return;
                    [self refreshFeaturedGamesForCatalogWithRetry:YES];
                    [self loadStorePanelsWithRetry:YES];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.currentScreen != AuthScreen::Store || self.storeView != store) return;
                    [self refreshGameLibraryInBackground];
                });
            }
            break;
        }

        case AuthScreen::Catalog: {
            OPN::DiscordPresence::Shared().UpdateBrowsing();
            OPNConfigureLibraryWindow(self.window);
            self.storeView = nil;
            self.settingsView = nil;

            OPNGameCatalogView *catalog = [[OPNGameCatalogView alloc] initWithFrame:bounds];
            catalog.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            self.catalogView = catalog;
            if (self.hasCachedFeaturedGames && self.cachedFeaturedGamesAccountIdentifier == OPNAuthSessionIdentifier(self.currentSession)) {
                [catalog setFeaturedGames:self.cachedFeaturedGames];
            }


            NSString *displayName = [NSString stringWithUTF8String:
                self.currentSession.displayName.c_str()];
            if (displayName.length > 0) {
                [catalog setUserName:displayName];
                self.rootView.accountName = displayName;
            } else {
                NSString *fallbackName = OPNAuthSessionDisplayName(self.currentSession);
                [catalog setUserName:fallbackName];
                self.rootView.accountName = fallbackName;
            }
            self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
            self.rootView.remainingPlayTime = @"--";
            self.currentRemainingPlayTimeAvailable = NO;
            self.rootView.gameCountText = @"";
            [self refreshAccountAvatar];
            [self refreshAccountMenu];
            [self refreshAccountSummary];
            [self refreshStreamRegions];

            __weak __typeof__(self) weakSelf = self;
            catalog.onSignOut = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf performServerLogout];
            };

            catalog.onGameCountChanged = ^(NSInteger count) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.rootView) return;
                strongSelf.rootView.gameCountText = [NSString stringWithFormat:@"%ld %@", (long)count, count == 1 ? @"game" : @"games"];
            };

            catalog.onInterfaceSettingsRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf transitionToScreen:AuthScreen::Settings];
            };

            catalog.onStoreRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf transitionToScreen:AuthScreen::Store];
            };

            catalog.onExitRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [NSApp terminate:strongSelf];
            };

            catalog.onRestartRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf restartApplication];
            };

            catalog.onSelectGame = ^(const GameInfo &game, int variantIndex) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf launchGame:game variantIndex:variantIndex returnScreen:AuthScreen::Catalog];
            };

            catalog.onMarkGameUnowned = ^(const GameInfo &game, int variantIndex) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf markVariantUnownedForGame:game variantIndex:variantIndex];
            };

            catalog.onCatalogBrowseRequested = ^(NSString *searchQuery, NSString *sortId, const std::vector<std::string> &filterIds) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf browseCatalogWithSearch:searchQuery sortId:sortId filterIds:filterIds canRetry:YES];
            };

            [self.contentContainer addSubview:catalog];
            OpnDisableFocusHighlights(catalog);
            self.window.title = @"OpenNOW";
            if ((displayName.length == 0 || OPNStringLooksLikeEmail(displayName)) && !self.currentSession.accessToken.empty()) {
                [catalog setLoading:YES];
                AuthService::Shared().FetchStarFleetUserInfo(
                    self.currentSession.accessToken,
                    ^(bool uiSuccess, NSDictionary *info, const std::string &) {
                        __typeof__(self) s = weakSelf;
                        if (!s) return;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (uiSuccess && info) {
                                NSString *email = info[@"email"];
                                NSString *name = OPNDisplayNameFromUserInfo(info);
                                if (name) {
                                    s.currentSession.displayName = [name UTF8String];
                                    if (email.length > 0) s.currentSession.email = [email UTF8String];
                                    if (s.pendingCredentials.stayLoggedIn)
                                        AuthService::Shared().SaveSession(s.currentSession);
                                    [s.catalogView setUserName:name];
                                    s.rootView.accountName = name;
                                    [s refreshAccountAvatar];
                                    [s refreshAccountMenu];
                                    [s refreshAccountSummary];
                                }
                            }
                            [s loadGamesIntoCatalog];
                        });
                    });
            } else {
                [self loadGamesIntoCatalog];
            }
            break;
        }

        case AuthScreen::Settings: {
            OPNConfigureLibraryWindow(self.window);
            self.rootView.accountName = OPNAuthSessionDisplayName(self.currentSession);
            self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
            self.rootView.remainingPlayTime = @"--";
            self.currentRemainingPlayTimeAvailable = NO;
            self.rootView.gameCountText = @"";
            [self refreshAccountAvatar];
            [self refreshAccountMenu];
            [self refreshAccountSummary];
            [self refreshStreamRegions];
            OPNSettingsView *settings = [[OPNSettingsView alloc] initWithFrame:bounds selectedSectionName:nil];
            settings.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            __weak __typeof__(self) weakSelf = self;
            settings.onBackRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf transitionToScreen:AuthScreen::Store];
            };
            settings.onCheckForUpdatesRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf checkForApplicationUpdates];
            };
            self.settingsView = settings;
            [self.contentContainer addSubview:settings];
            [self completeContentTransitionFromSubviews:previousSubviews toView:settings animated:animatedMainTransition forward:forwardTransition];
            OpnDisableFocusHighlights(settings);
            self.window.title = @"OpenNOW - Settings";
            break;
        }

        case AuthScreen::Error: {
            break;
        }

        default:
            break;
    }
}

- (void)refreshAccountSummary {
    [self refreshAccountSummaryWithRetry:YES];
}

- (void)refreshAccountSummaryWithRetry:(BOOL)canRetry {
    using namespace OPN;
    if (!self.rootView || self.currentSession.accessToken.empty()) {
        return;
    }
    self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
    GameService::Shared().SetAccessToken(self.currentSession.idToken.empty()
        ? self.currentSession.accessToken
        : self.currentSession.idToken);
    std::string userId = self.currentSession.userId;
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchSubscriptionInfo(userId, [weakSelf, canRetry](bool success, const SubscriptionInfo &subscription, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.rootView) return;
        if (!success && canRetry && OPNIsUnauthorizedError(error)) {
            AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &) {
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                if (refreshSuccess) {
                    retrySelf.currentSession = fresh;
                    if (retrySelf.pendingCredentials.stayLoggedIn) {
                        AuthService::Shared().SaveSession(fresh);
                    }
                    [retrySelf refreshAccountMenu];
                    [retrySelf refreshAccountSummaryWithRetry:NO];
                    return;
                }

                OPN::LogError(@"[AppDelegate] Subscription token refresh failed after unauthorized response");
            }, true);
            return;
        }
        if (!success) {
            OPN::LogError(@"[AppDelegate] Subscription fetch failed: %s", error.c_str());
            return;
        }
        strongSelf.rootView.accountStatus = OPNDisplayTier(subscription.membershipTier);
        strongSelf.rootView.remainingPlayTime = OPNFormatRemainingPlayTime(subscription);
        strongSelf.currentRemainingPlayTimeHours = subscription.remainingHours;
        strongSelf.currentRemainingPlayTimeUnlimited = subscription.isUnlimited;
        strongSelf.currentRemainingPlayTimeAvailable = YES;
        [strongSelf updateDesktopAccountSwitcher];
        strongSelf.currentSession.membershipTier = subscription.membershipTier;
        if (AuthService::Shared().GetStayLoggedIn()) {
            AuthService::Shared().SaveSession(strongSelf.currentSession);
        }
    });
}

- (void)refreshAccountAvatar {
    if (!self.rootView) return;
    NSString *email = self.currentSession.email.empty() ? @"" : [NSString stringWithUTF8String:self.currentSession.email.c_str()];
    NSString *avatarURLString = OPNGravatarURLStringForEmail(self.currentSession.email);
    self.rootView.accountAvatarImage = nil;
    if (avatarURLString.length == 0) return;

    NSURL *url = [NSURL URLWithString:avatarURLString];
    if (!url) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    auto trace = OPN::TraceSentryHTTPRequest(request, "Account avatar image");
    __weak __typeof__(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *, NSError *error) {
        OPN::SentryTransactionFinishGuard traceGuard(trace);
        if (error || !data) return;
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image) return;
        traceGuard.SetSuccess(true);
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.rootView) return;
            NSString *currentEmail = strongSelf.currentSession.email.empty() ? @"" : [NSString stringWithUTF8String:strongSelf.currentSession.email.c_str()];
            if (![currentEmail isEqualToString:email]) return;
            strongSelf.rootView.accountAvatarImage = image;
            [strongSelf rebuildDesktopAccountSwitcher];
        });
    }] resume];
}

- (void)refreshStreamRegions {
    using namespace OPN;
    if (self.currentSession.accessToken.empty()) {
        return;
    }
    std::string token = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken
        : self.currentSession.idToken;
    GameService::Shared().SetAccessToken(token);
    GameService::Shared().FetchProviderInfo(self.currentSession.idpId, [token](bool, const GameProviderInfo &, const GameProviderEndpoint &endpoint, const std::string &) {
        std::string providerBaseUrl = endpoint.streamingServiceUrl.empty() ? GameService::Shared().ProviderStreamingBaseUrl() : endpoint.streamingServiceUrl;
        GameService::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
        GameService::Shared().PrewarmLaunchData();
        FetchStreamRegions(token, providerBaseUrl, [](const std::vector<StreamRegionOption> &) {
            GameService::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
            GameService::Shared().PrewarmLaunchData();
            [[NSNotificationCenter defaultCenter] postNotificationName:@"OpenNOW.StreamRegionsUpdated" object:nil];
        });
    });
}

- (void)refreshAccountMenu {
    using namespace OPN;
    if (!self.rootView) return;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    std::string currentIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    for (const AuthSession &session : AuthService::Shared().LoadSavedSessions()) {
        std::string identifier = OPNAuthSessionIdentifier(session);
        if (identifier.empty()) continue;
        NSString *identifierString = [NSString stringWithUTF8String:identifier.c_str()];
        BOOL isCurrentSession = identifier == currentIdentifier;
        NSString *label = isCurrentSession ? OPNAuthSessionDisplayName(self.currentSession) : OPNAuthSessionDisplayName(session);
        [items addObject:@{@"identifier": identifierString, @"label": label}];
    }
    self.rootView.accountMenuItems = items;
    self.rootView.currentAccountIdentifier = currentIdentifier.empty()
        ? @""
        : [NSString stringWithUTF8String:currentIdentifier.c_str()];
    [self rebuildDesktopAccountSwitcher];
    [self updateDesktopAccountSwitcher];
}

- (void)desktopSettingsPillClicked:(NSButton *)sender {
    (void)sender;
    if (self.currentScreen == OPN::AuthScreen::Settings) {
        [self transitionToScreen:OPN::AuthScreen::Store];
        return;
    }
    if (OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen)) {
        [self transitionToScreen:OPN::AuthScreen::Settings];
    }
}

- (void)desktopAccountTypePillClicked:(NSButton *)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:OPNAccountManagementURLString];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        OPN::LogError(@"[AppDelegate] Invalid account management URL: %@", OPNAccountManagementURLString);
        NSBeep();
        return;
    }

    OPN::LogInfo(@"[AppDelegate] Opening account management URL");
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        OPN::LogError(@"[AppDelegate] Failed to open account management URL");
        NSBeep();
    }
}

- (void)transitionToStoreAfterProviderSelectionForSession:(const OPN::AuthSession &)session {
    using namespace OPN;
    std::string token = session.idToken.empty() ? session.accessToken : session.idToken;
    GameService::Shared().SetAccessToken(token);
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchProviderInfo(session.idpId, [weakSelf](bool,
                                                                      const GameProviderInfo &,
                                                                      const GameProviderEndpoint &,
                                                                      const std::string &) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf transitionToScreen:AuthScreen::Store];
    });
}

- (void)addAccount {
    OPN::AuthCredentials creds = self.pendingCredentials;
    creds.stayLoggedIn = true;
    self.pendingCredentials = creds;
    [self transitionToScreen:OPN::AuthScreen::EmailEntry];
}

- (void)switchToAccountIdentifier:(NSString *)identifier {
    using namespace OPN;
    if (identifier.length == 0) return;
    std::string accountId = [identifier UTF8String];
    if (accountId == OPNAuthSessionIdentifier(self.currentSession)) return;

    AuthService::Shared().SetActiveSessionUserId(accountId);
    AuthSession selected = AuthService::Shared().LoadSavedSessionForUserId(accountId);
    if (!selected.isAuthenticated) return;
    self.catalogBrowseGeneration++;
    self.gameLibraryRefreshInFlight = NO;
    self.featuredGamesRefreshInFlight = NO;
    self.activeSessionsRefreshInFlight = NO;
    [self stopGameLibraryRefreshTimer];
    self.currentSession = selected;
    GameService::Shared().SetUserId(OPNAuthSessionIdentifier(selected));
    if (selected.IsAccessTokenValid()) {
        [self transitionToStoreAfterProviderSelectionForSession:selected];
        return;
    }

    [self showAuthenticatingWithMessage:@"Refreshing session..."];
    __weak __typeof__(self) weakSelf = self;
    AuthService::Shared().RefreshSession(^(bool success, const AuthSession &fresh, const std::string &) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            strongSelf.currentSession = fresh;
            AuthService::Shared().SaveSession(fresh);
            [strongSelf refreshAccountMenu];
            [strongSelf transitionToStoreAfterProviderSelectionForSession:fresh];
            return;
        }

        AuthSession fallback = AuthService::Shared().LoadSavedSession();
        if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
            strongSelf.currentSession = fallback;
            [strongSelf transitionToStoreAfterProviderSelectionForSession:fallback];
        } else {
            strongSelf.currentSession.Clear();
            [strongSelf transitionToScreen:AuthScreen::EmailEntry];
        }
    });
}

#pragma mark - Server Logout

- (void)performServerLogout {
    using namespace OPN;
    __weak __typeof__(self) weakSelf = self;
    std::string idToken = self.currentSession.idToken;

    [self showAuthenticatingWithMessage:@"Signing out..."];

    AuthService::Shared().ServerLogout(idToken, OPN::CurrentGFNLocale(),
        ^(bool, const std::string &) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            OPNConfigureLibraryWindow(strongSelf.window);
            AuthSession next = AuthService::Shared().LoadSavedSession();
            if (next.isAuthenticated && next.IsAccessTokenValid()) {
                strongSelf.currentSession = next;
                [strongSelf transitionToScreen:AuthScreen::Store];
                return;
            }

            strongSelf.currentSession.Clear();
            strongSelf.cachedGameLibrary.clear();
            strongSelf.cachedGameLibraryFingerprint.clear();
            strongSelf.cachedGameLibraryAccountIdentifier.clear();
            strongSelf.hasCachedGameLibrary = NO;
            strongSelf.pendingCredentials = AuthCredentials{};
            AuthCredentials creds = strongSelf.pendingCredentials;
            creds.stayLoggedIn = true;
            strongSelf.pendingCredentials = creds;
            [strongSelf refreshAccountMenu];
            [strongSelf transitionToScreen:AuthScreen::EmailEntry];
        });
}

#pragma mark - Overlay Screens

- (void)showAuthenticatingWithMessage:(NSString *)message {
    self.rootView.mode = OPNBackdropModeAuth;
    for (NSView *subview in [self.contentContainer.subviews copy]) {
        [subview removeFromSuperview];
    }
    OPNAuthenticatingView *overlay = [[OPNAuthenticatingView alloc]
        initWithFrame:self.contentContainer.bounds message:message];
    [self.contentContainer addSubview:overlay];
    self.currentScreen = OPN::AuthScreen::Authenticating;
}

- (void)showError:(const std::string &)errorMessage canRetry:(BOOL)canRetry {
    OPN::AuthScreen retryScreen = (self.currentScreen == OPN::AuthScreen::Store ||
                                   self.currentScreen == OPN::AuthScreen::Catalog ||
                                   self.currentScreen == OPN::AuthScreen::Settings)
        ? self.currentScreen
        : OPN::AuthScreen::EmailEntry;
    self.rootView.mode = OPNBackdropModeAuth;
    for (NSView *subview in [self.contentContainer.subviews copy]) {
        [subview removeFromSuperview];
    }
    std::string mappedError = OPN::UserFacingGFNErrorMessage(errorMessage, self.currentStreamTitle.UTF8String ? self.currentStreamTitle.UTF8String : "");
    NSString *msg = [NSString stringWithUTF8String:mappedError.c_str()];
    if (!msg || msg.length == 0) {
        msg = @"An unknown error occurred.";
    }
    OPN::AppendLogEvent([NSString stringWithFormat:@"[AppDelegate] Presenting error: %@", msg]);
    OPN::CopyCapturedLogToClipboard(msg);
    msg = [msg stringByAppendingString:@"\n\nFull log copied to clipboard."];
    OPNErrorView *view = [[OPNErrorView alloc] initWithFrame:self.contentContainer.bounds
                                                      message:msg
                                                    canRetry:canRetry];
    __weak __typeof__(self) weakSelf = self;

    view.onRetry = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf transitionToScreen:retryScreen];
    };

    view.onBackToEmail = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        {
            OPN::AuthCredentials _c = OPN::AuthCredentials{};
            _c.stayLoggedIn = OPN::AuthService::Shared().GetStayLoggedIn();
            strongSelf.pendingCredentials = _c;
        }
        [strongSelf transitionToScreen:OPN::AuthScreen::EmailEntry];
    };

    [self.contentContainer addSubview:view];
    self.currentScreen = OPN::AuthScreen::Error;
}

@end
