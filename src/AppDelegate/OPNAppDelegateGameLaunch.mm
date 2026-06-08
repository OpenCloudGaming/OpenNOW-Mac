#import "OPNAppDelegatePrivate.h"

@implementation AppDelegate (GameLaunch)

- (void)configureGameServiceTokensForSession:(const OPN::AuthSession &)session {
    using namespace OPN;
    std::string apiToken = session.idToken.empty() ? session.accessToken : session.idToken;
    GameService::Shared().SetAccessToken(apiToken);
    GameService::Shared().SetAccountLinkingToken(apiToken);
}

- (void)refreshOwnershipAuthWithCompletion:(void (^)(BOOL refreshed))completion {
    __weak __typeof__(self) weakSelf = self;
    OPN::AuthService::Shared().RefreshSession(^(bool success, const OPN::AuthSession &fresh, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO);
            return;
        }
        if (!success || !fresh.isAuthenticated || fresh.accessToken.empty()) {
            OPN::LogError(@"[AppDelegate] Ownership auth refresh failed: %s", error.c_str());
            if (completion) completion(NO);
            return;
        }
        strongSelf.currentSession = fresh;
        if (strongSelf.pendingCredentials.stayLoggedIn) OPN::AuthService::Shared().SaveSession(fresh);
        [strongSelf configureGameServiceTokensForSession:fresh];
        [strongSelf refreshAccountMenu];
        if (completion) completion(YES);
    }, true);
}

- (void)showOwnershipSyncProgressForGameTitle:(NSString *)gameTitle storeName:(NSString *)storeName {
    NSView *parentView = self.window.contentView;
    if (!parentView) return;

    if (!self.ownershipSyncOverlayView) {
        NSView *overlay = [[NSView alloc] initWithFrame:parentView.bounds];
        overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        overlay.wantsLayer = YES;
        overlay.layer.backgroundColor = OpnColor(0x020304, 0.64).CGColor;

        CGFloat panelWidth = 430.0;
        CGFloat panelHeight = 210.0;
        NSRect panelFrame = NSMakeRect((NSWidth(overlay.bounds) - panelWidth) * 0.5,
                                       (NSHeight(overlay.bounds) - panelHeight) * 0.5,
                                       panelWidth,
                                       panelHeight);
        NSView *panel = [[NSView alloc] initWithFrame:panelFrame];
        panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        panel.wantsLayer = YES;
        panel.layer.backgroundColor = OpnColor(0x0A0C0F, 0.98).CGColor;
        panel.layer.cornerRadius = 24.0;
        panel.layer.borderWidth = 1.0;
        panel.layer.borderColor = OpnColor(0xFFFFFF, 0.14).CGColor;
        panel.layer.shadowColor = NSColor.blackColor.CGColor;
        panel.layer.shadowOpacity = 0.34;
        panel.layer.shadowRadius = 28.0;
        panel.layer.shadowOffset = CGSizeMake(0.0, 16.0);
        [overlay addSubview:panel];

        NSProgressIndicator *spinner = OpnSpinner(NSMakeRect((panelWidth - 34.0) * 0.5, panelHeight - 66.0, 34.0, 34.0));
        [spinner startAnimation:nil];
        [panel addSubview:spinner];

        NSTextField *titleLabel = OpnLabel(@"Syncing Store Library", NSMakeRect(32.0, 92.0, panelWidth - 64.0, 28.0), 19.0, OpnColor(OPN::kTextPrimary), NSFontWeightBold, NSTextAlignmentCenter);
        titleLabel.maximumNumberOfLines = 1;
        [panel addSubview:titleLabel];

        NSTextField *messageLabel = OpnLabel(@"", NSMakeRect(36.0, 48.0, panelWidth - 72.0, 44.0), 13.0, OpnColor(OPN::kTextSecondary), NSFontWeightRegular, NSTextAlignmentCenter);
        messageLabel.maximumNumberOfLines = 2;
        [panel addSubview:messageLabel];

        NSTextField *footerLabel = OpnLabel(@"Waiting for GeForce NOW library updates.", NSMakeRect(36.0, 24.0, panelWidth - 72.0, 18.0), 11.0, OpnColor(0x8E969F), NSFontWeightRegular, NSTextAlignmentCenter);
        [panel addSubview:footerLabel];

        self.ownershipSyncOverlayView = overlay;
        self.ownershipSyncTitleLabel = titleLabel;
        self.ownershipSyncMessageLabel = messageLabel;
        self.ownershipSyncFooterLabel = footerLabel;
        self.ownershipSyncSpinner = spinner;
        OpnDisableFocusHighlights(overlay);
    }

    self.ownershipSyncTitleLabel.stringValue = @"Syncing Store Library";
    NSString *title = gameTitle.length > 0 ? gameTitle : @"this game";
    NSString *store = storeName.length > 0 ? storeName : @"the selected store";
    [self updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Asking GeForce NOW to sync %@ for %@.", store, title]];
    [self updateOwnershipSyncProgressFooter:@"Waiting for GeForce NOW library updates."];

    if (self.ownershipSyncOverlayView.superview != parentView) {
        [self.ownershipSyncOverlayView removeFromSuperview];
        self.ownershipSyncOverlayView.frame = parentView.bounds;
        [parentView addSubview:self.ownershipSyncOverlayView positioned:NSWindowAbove relativeTo:nil];
    }
}

- (void)updateOwnershipSyncProgressMessage:(NSString *)message {
    self.ownershipSyncMessageLabel.stringValue = message.length > 0 ? message : @"Syncing your store library...";
}

- (void)updateOwnershipSyncProgressFooter:(NSString *)footer {
    self.ownershipSyncFooterLabel.stringValue = footer.length > 0 ? footer : @"Waiting for GeForce NOW library updates.";
}

- (void)dismissOwnershipSyncProgress {
    [self.ownershipSyncSpinner stopAnimation:nil];
    [self.ownershipSyncOverlayView removeFromSuperview];
    self.ownershipSyncOverlayView = nil;
    self.ownershipSyncTitleLabel = nil;
    self.ownershipSyncMessageLabel = nil;
    self.ownershipSyncFooterLabel = nil;
    self.ownershipSyncSpinner = nil;
}

- (void)launchGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex returnScreen:(OPN::AuthScreen)returnScreen {
    using namespace OPN;

    if ([self hasVisibleStreamingController]) {
        OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"ignored_active_stream"});
        OPN::LogInfo(@"[AppDelegate] Ignoring game launch while stream is active: title=%@, id=%s", OPNAppStringFromStdString(game.title, @""), game.id.c_str());
        return;
    }

    OPN::GameInfo launchGameInfo = game;
    NSInteger launchGeneration = ++self.gameLaunchGeneration;

    OPN::LogInfo(@"[AppDelegate] Game selected: title=%@, id=%s, uuid=%s, variantIndex=%d", OPNAppStringFromStdString(launchGameInfo.title, @""), launchGameInfo.id.c_str(), launchGameInfo.uuid.c_str(), variantIndex);
    OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{
        @"outcome": @"selected",
        @"return_screen": OPNMetricScreenName(returnScreen),
        @"variant_selected": @(variantIndex >= 0),
    });

    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;
    [self configureGameServiceTokensForSession:self.currentSession];

    std::string effectiveAppId;
    std::string selectedStore;
    bool accountLinked = OPNChooseAccountLinked(launchGameInfo, nullptr);
    if (variantIndex >= 0 && variantIndex < (int)launchGameInfo.variants.size()) {
        const GameVariant &variant = launchGameInfo.variants[(size_t)variantIndex];
        effectiveAppId = variant.id;
        selectedStore = variant.appStore;
        accountLinked = OPNChooseAccountLinked(launchGameInfo, &variant);
        OPN::LogInfo(@"[AppDelegate] Variant: id=%s, store=%s, status=%s, accountLinked=%d",
              variant.id.c_str(), variant.appStore.c_str(), variant.serviceStatus.c_str(), accountLinked);
    }
    if (effectiveAppId.empty()) {
        effectiveAppId = launchGameInfo.launchAppId.empty() ? launchGameInfo.id : launchGameInfo.launchAppId;
    }
    std::string launchStreamingBaseUrl = LoadSelectedStreamingBaseUrlForGame(effectiveAppId);
    OPN::LogInfo(@"[AppDelegate] Using appId=%s, store=%s, accountLinked=%d",
          effectiveAppId.c_str(), selectedStore.c_str(), accountLinked);

    __weak __typeof__(self) weakSelf = self;
    std::string gameTitle = launchGameInfo.title;
    void (^startRequestedGame)(bool) = [^(bool accountLinkedForLaunch) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.gameLaunchGeneration != launchGeneration) {
            OPN::LogInfo(@"[AppDelegate] Ignoring stale launch continuation for appId=%s", effectiveAppId.c_str());
            return;
        }
        [strongSelf startStreamWithTitle:gameTitle
                                   appId:effectiveAppId
                                apiToken:apiToken
                           accountLinked:accountLinkedForLaunch
                            selectedStore:selectedStore
                           returnScreen:returnScreen
                         resumeSessionId:""
                             resumeServer:""];
    } copy];

    void (^continueLaunchAfterServerSelection)(bool) = [^(bool accountLinkedForLaunch) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;
        if (strongSelf.gameLaunchGeneration != launchGeneration) {
            OPN::LogInfo(@"[AppDelegate] Ignoring stale launch probe for appId=%s", effectiveAppId.c_str());
            return;
        }

        SessionManager::Shared().SetAccessToken(apiToken);
        SessionManager::Shared().SetStreamingBaseUrl(launchStreamingBaseUrl);
        OPN::GameInfo requestedGame = launchGameInfo;
        void (^startRequestedGameCopy)(void) = [^{ startRequestedGame(accountLinkedForLaunch); } copy];
        SessionManager::Shared().GetActiveSessions([weakSelf, launchGeneration, startRequestedGameCopy, requestedGame, gameTitle, effectiveAppId, apiToken, returnScreen, launchStreamingBaseUrl](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
            std::vector<ActiveSessionEntry> sessionsCopy = sessions;
            std::string errorCopy = error;
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;
                if (strongSelf.gameLaunchGeneration != launchGeneration) {
                    OPN::LogInfo(@"[AppDelegate] Ignoring stale active-session launch result for appId=%s", effectiveAppId.c_str());
                    return;
                }
                if (!ok) {
                    if (OPNSessionProbeAuthenticationError(errorCopy)) {
                        OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"active_probe_auth_failure"});
                        OPN::LogError(@"[AppDelegate] Active session launch probe authentication failed, aborting launch: %s", errorCopy.c_str());
                        [strongSelf showError:errorCopy canRetry:YES];
                        return;
                    }
                    OPN::LogError(@"[AppDelegate] Active session launch probe failed, continuing launch: %s", errorCopy.c_str());
                    OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"active_probe_failure_continue"});
                    startRequestedGameCopy();
                    return;
                }

                ActiveSessionEntry activeSession;
                ActiveSessionEntry requestedGameSession;
                BOOL foundActiveSession = NO;
                BOOL foundRequestedGameSession = NO;
                for (const ActiveSessionEntry &session : sessionsCopy) {
                    if ((session.status == 1 || session.status == 2 || session.status == 3 || session.status == 6) && !session.sessionId.empty() && !session.serverIp.empty()) {
                        if (!foundRequestedGameSession && OPNGameHasAppId(requestedGame, session.appId)) {
                            requestedGameSession = session;
                            foundRequestedGameSession = YES;
                        }
                        activeSession = session;
                        foundActiveSession = YES;
                        if (foundRequestedGameSession) break;
                    }
                }
                if (foundRequestedGameSession) {
                    OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"resume_same_game"});
                    std::string resumeAppId = requestedGameSession.appId > 0 ? std::to_string(requestedGameSession.appId) : effectiveAppId;
                    std::string resumeTitle = gameTitle.empty() ? std::string("Current Stream") : gameTitle;
                    [strongSelf startStreamWithTitle:resumeTitle
                                               appId:resumeAppId
                                            apiToken:apiToken
                                       accountLinked:true
                                        selectedStore:""
                                        returnScreen:returnScreen
                                      resumeSessionId:requestedGameSession.sessionId
                                          resumeServer:requestedGameSession.serverIp];
                    return;
                }
                if (!foundActiveSession) {
                    OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"start_new_no_active_session"});
                    startRequestedGameCopy();
                    return;
                }

                NSString *sessionTitle = OPNTitleForActiveSessionAppId(activeSession.appId, strongSelf.cachedGameLibrary);
                OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"active_session_prompt"});
                NSString *selectedGameTitle = gameTitle.empty() ? @"Selected Game" : [NSString stringWithUTF8String:gameTitle.c_str()];
                [strongSelf showActiveSessionPromptWithSessionTitle:sessionTitle
                                                  selectedGameTitle:selectedGameTitle
                                                    continueHandler:^{
                    __typeof__(self) promptSelf = weakSelf;
                    if (!promptSelf) return;
                    std::string resumeAppId = activeSession.appId > 0 ? std::to_string(activeSession.appId) : effectiveAppId;
                    std::string resumeTitle = sessionTitle.length > 0 ? [sessionTitle UTF8String] : std::string("Current Stream");
                    [promptSelf startStreamWithTitle:resumeTitle
                                               appId:resumeAppId
                                            apiToken:apiToken
                                       accountLinked:true
                                        selectedStore:""
                                        returnScreen:returnScreen
                                      resumeSessionId:activeSession.sessionId
                                          resumeServer:activeSession.serverIp];
                }
                                                      deleteHandler:^{
                    __typeof__(self) promptSelf = weakSelf;
                    if (!promptSelf) return;
                    [promptSelf showAuthenticatingWithMessage:@"Deleting existing session..."];
                    SessionManager::Shared().SetAccessToken(apiToken);
                    SessionManager::Shared().SetStreamingBaseUrl(launchStreamingBaseUrl);
                    void (^deleteStartRequestedGame)(void) = [startRequestedGameCopy copy];
                    SessionManager::Shared().StopSession(activeSession.sessionId, activeSession.serverIp, [weakSelf, deleteStartRequestedGame](bool stopOk, const std::string &stopError) {
                        std::string stopErrorCopy = stopError;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __typeof__(self) stopSelf = weakSelf;
                            if (!stopSelf) return;
                            if (!stopOk) {
                                [stopSelf showError:stopErrorCopy.empty() ? std::string("Unable to delete the existing session.") : stopErrorCopy canRetry:YES];
                                return;
                            }
                            deleteStartRequestedGame();
                        });
                    });
                }];
            });
        });
    } copy];

    void (^beginServerSelection)(bool) = [^(bool accountLinkedForLaunch) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.gameLaunchGeneration != launchGeneration) {
            OPN::LogInfo(@"[AppDelegate] Ignoring stale server selection for appId=%s", effectiveAppId.c_str());
            return;
        }
        NSString *pickerGameTitle = gameTitle.empty() ? @"Selected Game" : [NSString stringWithUTF8String:gameTitle.c_str()];
        [strongSelf showCloudmatchServerPickerForGameTitle:pickerGameTitle
                                            apiToken:apiToken
                                          completion:^(BOOL confirmed) {
            if (!confirmed) {
                OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"server_selection_cancelled"});
                return;
            }
            OPN::RecordSentryCounterMetric("opennow.game.launch.count", 1, @{@"outcome": @"server_selection_confirmed"});
            __typeof__(self) completionSelf = weakSelf;
            if (!completionSelf || completionSelf.gameLaunchGeneration != launchGeneration) return;
            continueLaunchAfterServerSelection(accountLinkedForLaunch);
        }];
    } copy];

    if ([self presentOwnershipRemediationIfNeededForGame:launchGameInfo
                                            variantIndex:variantIndex
                                           returnScreen:returnScreen
                                           accountLinked:accountLinked
                                          continueHandler:beginServerSelection]) {
        return;
    }
    beginServerSelection(accountLinked);
}

- (BOOL)presentOwnershipRemediationIfNeededForGame:(const OPN::GameInfo &)game
                                       variantIndex:(int)variantIndex
                                      returnScreen:(OPN::AuthScreen)returnScreen
                                      accountLinked:(bool)accountLinked
                                    continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    const GameVariant *selectedVariant = OPNVariantAtIndex(game, variantIndex);
    if (!selectedVariant) return NO;

    (void)accountLinked;

    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    __weak __typeof__(self) weakSelf = self;

    if (game.playType == "INSTALL_TO_PLAY") {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Install Required";
        alert.informativeText = @"This game must be installed or prepared through the selected store before GeForce NOW can launch it.";
        [alert addButtonWithTitle:@"Open Store"];
        [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (returnCode == NSAlertFirstButtonReturn) [strongSelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
        }];
        return YES;
    }

    GameService::Shared().FetchStoreDefinitions([weakSelf, gameCopy, variantIndexCopy, returnScreen, continueHandler](bool definitionsOK, const std::vector<StoreDefinition> &definitions, const std::string &definitionsError) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        std::vector<StoreDefinition> definitionsCopy = definitionsOK ? definitions : std::vector<StoreDefinition>();
        if (!definitionsOK) OPN::LogError(@"[AppDelegate] Store definitions unavailable for ownership flow: %s", definitionsError.c_str());
        GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, returnScreen, definitionsCopy, continueHandler](bool accountOK, const UserAccountInfo &accountInfo, const std::string &accountError) {
            __typeof__(self) accountSelf = weakSelf;
            if (!accountSelf) return;
            UserAccountInfo accountCopy = accountOK ? accountInfo : UserAccountInfo{};
            if (!accountOK) OPN::LogError(@"[AppDelegate] User account unavailable for ownership flow: %s", accountError.c_str());
            const GameVariant *selectedVariant = OPNVariantAtIndex(gameCopy, variantIndexCopy);
            std::vector<std::string> autoResyncStores;
            if (selectedVariant && !GameVariantOwnedForLaunch(*selectedVariant)) {
                autoResyncStores = OPNAutoResyncStoresForGame(gameCopy, definitionsCopy, accountCopy);
            }
            if (!autoResyncStores.empty()) {
                [accountSelf autoResyncOwnershipForGame:gameCopy
                                           variantIndex:variantIndexCopy
                                          returnScreen:returnScreen
                                                stores:autoResyncStores
                                      storeDefinitions:definitionsCopy
                                          retryingAuth:NO
                                       continueHandler:continueHandler];
                return;
            }
            [accountSelf presentOwnershipOptionsForGame:gameCopy
                                           variantIndex:variantIndexCopy
                                           returnScreen:returnScreen
                                       storeDefinitions:definitionsCopy
                                            userAccount:accountCopy
                                        continueHandler:continueHandler];
        });
    });
    return YES;
}

- (void)presentOwnershipOptionsForGame:(const OPN::GameInfo &)game
                           variantIndex:(int)variantIndex
                          returnScreen:(OPN::AuthScreen)returnScreen
                       storeDefinitions:(const std::vector<OPN::StoreDefinition> &)storeDefinitions
                            userAccount:(const OPN::UserAccountInfo &)userAccount
                        continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    const GameVariant *variant = OPNVariantAtIndex(game, variantIndex);
    if (!variant) return;
    std::string store = variant->appStore;
    NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(store).c_str()] ?: @"the selected store";
    NSString *gameTitle = game.title.empty() ? @"Selected Game" : [NSString stringWithUTF8String:game.title.c_str()];
    const StoreDefinition *definition = OPNStoreDefinitionForStore(storeDefinitions, store);
    const StoreAccountInfo *account = OPNStoreAccountForStore(userAccount, store);
    bool selectedVariantOwned = GameVariantOwnedForLaunch(*variant);
    int ownedVariantIndex = OPNFirstOwnedVariantIndex(game, variantIndex);
    const GameVariant *ownedVariant = OPNVariantAtIndex(game, ownedVariantIndex);
    bool gameOwnedOnDifferentVariant = !selectedVariantOwned && (ownedVariant != nullptr || game.isInLibrary);
    bool owned = selectedVariantOwned;
    bool variantSupported = OPNStoreDefinitionSupportsVariant(definition, variant->id);
    bool linkingSupported = variantSupported && (OPNStoreFeatureSupported(definition, "AccountLinkingSso") || (definition && definition->accountLinkingMetadata.isSupported));
    bool syncSupported = variantSupported && OPNStoreFeatureSupported(definition, "AccountGamesSyncing");
    bool connected = OPNStoreAccountConnected(account);
    bool requiredLinkMissing = owned && linkingSupported && definition && definition->accountLinkingMetadata.isRequired && !connected;
    if (owned && !requiredLinkMissing) {
        if (continueHandler) continueHandler(true);
        return;
    }

    enum OwnershipActionTag : NSInteger {
        OwnershipActionLink = 1,
        OwnershipActionSync = 2,
        OwnershipActionMarkOwned = 3,
        OwnershipActionOpenStore = 4,
        OwnershipActionCancel = 5,
        OwnershipActionLaunchOwned = 6,
    };

    NSMutableArray<NSNumber *> *actions = [NSMutableArray array];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = requiredLinkMissing ? @"Link Store Account" : (gameOwnedOnDifferentVariant ? @"Selected Store Not Owned" : (connected && syncSupported ? @"Sync Store Library" : @"Add Game to Library"));
    if (gameOwnedOnDifferentVariant) {
        NSString *ownedStoreName = ownedVariant ? ([NSString stringWithUTF8String:GameStoreDisplayName(ownedVariant->appStore).c_str()] ?: @"another store") : @"another store";
        alert.informativeText = [NSString stringWithFormat:@"You own %@ on %@, but the selected %@ version is not marked as owned in your GeForce NOW library.", gameTitle, ownedStoreName, storeName];
        if (ownedVariant) {
            [alert addButtonWithTitle:[NSString stringWithFormat:@"Launch %@ Version", ownedStoreName]];
            [actions addObject:@(OwnershipActionLaunchOwned)];
        }
        if (connected && syncSupported) {
            [alert addButtonWithTitle:@"Sync Selected Store"];
            [actions addObject:@(OwnershipActionSync)];
        } else if (!connected && linkingSupported) {
            [alert addButtonWithTitle:@"Link Selected Store"];
            [actions addObject:@(OwnershipActionLink)];
        }
    } else if (requiredLinkMissing) {
        alert.informativeText = [NSString stringWithFormat:@"%@ requires a linked %@ account before GeForce NOW can launch it.", gameTitle, storeName];
        [alert addButtonWithTitle:@"Link Account"];
        [actions addObject:@(OwnershipActionLink)];
    } else if (!connected && linkingSupported) {
        alert.informativeText = [NSString stringWithFormat:@"%@ is not marked as owned for %@. Link your %@ account, then OpenNOW will ask GeForce NOW to sync your library.", gameTitle, storeName, storeName];
        [alert addButtonWithTitle:@"Link Account"];
        [actions addObject:@(OwnershipActionLink)];
    } else if (connected && syncSupported) {
        alert.informativeText = [NSString stringWithFormat:@"%@ is not marked as owned for %@. Sync your %@ library through GeForce NOW to refresh ownership.", gameTitle, storeName, storeName];
        [alert addButtonWithTitle:@"Sync Library"];
        [actions addObject:@(OwnershipActionSync)];
    } else {
        alert.informativeText = [NSString stringWithFormat:@"%@ is not marked as owned in your GeForce NOW library for %@. Mark it as owned through GeForce NOW or open the store to purchase or claim it.", gameTitle, storeName];
    }

    if (!requiredLinkMissing) {
        [alert addButtonWithTitle:@"Mark as Owned"];
        [actions addObject:@(OwnershipActionMarkOwned)];
    }
    [alert addButtonWithTitle:@"Open Store"];
    [actions addObject:@(OwnershipActionOpenStore)];
    [alert addButtonWithTitle:@"Cancel"];
    [actions addObject:@(OwnershipActionCancel)];

    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    int ownedVariantIndexCopy = ownedVariantIndex;
    std::string storeCopy = store;
    __weak __typeof__(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSInteger actionIndex = returnCode - NSAlertFirstButtonReturn;
        if (actionIndex < 0 || actionIndex >= (NSInteger)actions.count) return;
        NSInteger action = actions[(NSUInteger)actionIndex].integerValue;
        if (action == OwnershipActionLaunchOwned) {
            [strongSelf launchGame:gameCopy variantIndex:ownedVariantIndexCopy returnScreen:returnScreen];
        } else if (action == OwnershipActionLink) {
            [strongSelf linkAccountForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy syncAfterLink:!requiredLinkMissing retryingAuth:NO continueHandler:continueHandler];
        } else if (action == OwnershipActionSync) {
            [strongSelf syncOwnershipForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy retryingAuth:NO continueHandler:continueHandler];
        } else if (action == OwnershipActionMarkOwned) {
            [strongSelf markVariantOwnedForGame:gameCopy variantIndex:variantIndexCopy continueHandler:continueHandler];
        } else if (action == OwnershipActionOpenStore) {
            [strongSelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
        }
    }];
}

- (void)autoResyncOwnershipForGame:(const OPN::GameInfo &)game
                       variantIndex:(int)variantIndex
                      returnScreen:(OPN::AuthScreen)returnScreen
                            stores:(const std::vector<std::string> &)stores
                  storeDefinitions:(const std::vector<OPN::StoreDefinition> &)storeDefinitions
                     retryingAuth:(BOOL)retryingAuth
                   continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    if (stores.empty()) return;

    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::vector<std::string> storesCopy = stores;
    std::vector<StoreDefinition> definitionsCopy = storeDefinitions;
    NSString *gameTitle = game.title.empty() ? @"Selected Game" : [NSString stringWithUTF8String:game.title.c_str()];
    NSString *storeListName = OPNStoreListDisplayName(storesCopy);

    [self showOwnershipSyncProgressForGameTitle:gameTitle storeName:storeListName];
    self.ownershipSyncTitleLabel.stringValue = @"Checking Connected Libraries";
    NSString *action = retryingAuth ? @"Retrying" : @"Asking";
    [self updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"%@ GeForce NOW to sync %@ before showing ownership options.", action, storeListName]];

    __weak __typeof__(self) weakSelf = self;
    void (^fallbackToOptions)(void) = [^{
        __typeof__(self) fallbackSelf = weakSelf;
        if (!fallbackSelf) return;
        [fallbackSelf dismissOwnershipSyncProgress];
        GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, returnScreen, definitionsCopy, continueHandler](bool accountOK, const UserAccountInfo &accountInfo, const std::string &accountError) {
            __typeof__(self) accountSelf = weakSelf;
            if (!accountSelf) return;
            UserAccountInfo accountCopy = accountOK ? accountInfo : UserAccountInfo{};
            if (!accountOK) OPN::LogError(@"[AppDelegate] User account unavailable after auto-resync: %s", accountError.c_str());
            [accountSelf presentOwnershipOptionsForGame:gameCopy
                                           variantIndex:variantIndexCopy
                                           returnScreen:returnScreen
                                       storeDefinitions:definitionsCopy
                                            userAccount:accountCopy
                                        continueHandler:continueHandler];
        });
    } copy];

    [self updateOwnershipSyncProgressFooter:@"Reading connected-store sync state..."];
    GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, returnScreen, storesCopy, definitionsCopy, retryingAuth, fallbackToOptions, continueHandler](bool baselineOK, const UserAccountInfo &baselineAccount, const std::string &baselineError) {
        __typeof__(self) baselineSelf = weakSelf;
        if (!baselineSelf) return;
        std::vector<OPNSyncObservation> baselines = baselineOK ? OPNSyncObservationsForStores(baselineAccount, storesCopy) : std::vector<OPNSyncObservation>(storesCopy.size());
        if (!baselineOK) OPN::LogError(@"[AppDelegate] User account unavailable before auto-resync baseline: %s", baselineError.c_str());
        [baselineSelf updateOwnershipSyncProgressFooter:@"Sending sync requests to GeForce NOW..."];

    struct AutoResyncState {
        bool anySyncAccepted = false;
        bool unauthorized = false;
        std::string firstError;
    };
    auto syncState = std::make_shared<AutoResyncState>();
    dispatch_group_t syncGroup = dispatch_group_create();
    for (const std::string &store : storesCopy) {
        dispatch_group_enter(syncGroup);
        GameService::Shared().SyncAccountProvider(store, [syncState, syncGroup, store](bool success, const std::string &error) {
            if (success) {
                syncState->anySyncAccepted = true;
            } else {
                if (syncState->firstError.empty()) syncState->firstError = error;
                if (OPNIsUnauthorizedError(error)) syncState->unauthorized = true;
                OPN::LogError(@"[AppDelegate] Auto-resync request failed for %s: %s", store.c_str(), error.c_str());
            }
            dispatch_group_leave(syncGroup);
        });
    }

    dispatch_group_notify(syncGroup, dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (syncState->unauthorized && !retryingAuth) {
            [strongSelf updateOwnershipSyncProgressMessage:@"Refreshing your GeForce NOW sign-in, then retrying connected-library sync..."];
            [strongSelf refreshOwnershipAuthWithCompletion:^(BOOL) {
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                [retrySelf autoResyncOwnershipForGame:gameCopy
                                         variantIndex:variantIndexCopy
                                        returnScreen:returnScreen
                                              stores:storesCopy
                                    storeDefinitions:definitionsCopy
                                       retryingAuth:YES
                                     continueHandler:continueHandler];
            }];
            return;
        }
        if (!syncState->anySyncAccepted) {
            if (!syncState->firstError.empty()) {
                OPN::LogError(@"[AppDelegate] Auto-resync could not start for any connected store: %s", syncState->firstError.c_str());
            }
            if (fallbackToOptions) fallbackToOptions();
            return;
        }

        [strongSelf updateOwnershipSyncProgressMessage:@"GeForce NOW accepted connected-library sync. Monitoring refreshed library data..."];
        NSDate *deadlineAt = [NSDate dateWithTimeIntervalSinceNow:OPNOwnershipSyncMonitorTimeoutSeconds];
        [strongSelf monitorAutoResyncOwnershipForGame:gameCopy
                                         variantIndex:variantIndexCopy
                                        returnScreen:returnScreen
                                              stores:storesCopy
                                           baselines:baselines
                                         deadlineAt:deadlineAt
                                             attempt:0
                                     continueHandler:continueHandler
                                     fallbackHandler:fallbackToOptions];
    });
    });
}

- (void)monitorAutoResyncOwnershipForGame:(const OPN::GameInfo &)game
                             variantIndex:(int)variantIndex
                            returnScreen:(OPN::AuthScreen)returnScreen
                                  stores:(const std::vector<std::string> &)stores
                              baselines:(const std::vector<OPNSyncObservation> &)baselines
                             deadlineAt:(NSDate *)deadlineAt
                                 attempt:(NSInteger)attempt
                         continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler
                         fallbackHandler:(void (^)(void))fallbackHandler {
    using namespace OPN;
    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::vector<std::string> storesCopy = stores;
    std::vector<OPNSyncObservation> baselinesCopy = baselines;
    const GameVariant *selectedVariant = OPNVariantAtIndex(gameCopy, variantIndexCopy);
    GameVariant requestedVariant = selectedVariant ? *selectedVariant : GameVariant{};
    NSString *storeListName = OPNStoreListDisplayName(storesCopy);
    NSInteger displayAttempt = MAX((NSInteger)1, attempt + 1);
    [self updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Checking connected libraries after %@ sync... (%ld)", storeListName, (long)displayAttempt]];
    [self updateOwnershipSyncProgressFooter:OPNSyncRemainingFooter(deadlineAt)];

    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, returnScreen, storesCopy, baselinesCopy, requestedVariant, deadlineAt, attempt, continueHandler, fallbackHandler](bool accountOK, const UserAccountInfo &accountInfo, const std::string &accountError) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *freshFailureMessage = nil;
        if (accountOK) {
            for (const std::string &store : storesCopy) {
                NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(store).c_str()] ?: @"the selected store";
                const StoreAccountInfo *account = OPNStoreAccountForStore(accountInfo, store);
                OPNSyncObservation currentObservation = OPNSyncObservationForStore(accountInfo, store);
                const OPNSyncObservation *baseline = OPNSyncObservationForStoreInList(storesCopy, baselinesCopy, store);
                OPNSyncObservation emptyBaseline;
                const OPNSyncObservation &baselineObservation = baseline ? *baseline : emptyBaseline;
                bool fresh = OPNSyncObservationHasFreshState(currentObservation, baselineObservation);
                if (fresh && OPNSyncStateSucceeded(currentObservation.syncState)) {
                    [strongSelf updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"%@ sync finished. Checking if this game is now in your library...", storeName]];
                }
                if (fresh && OPNSyncStateFailed(currentObservation.syncState) && freshFailureMessage.length == 0) {
                    freshFailureMessage = OPNSyncFailureMessage(currentObservation.syncState, storeName);
                }
                if (account && !account->syncing.syncState.empty() && !OPNSyncStateSucceeded(account->syncing.syncState)) {
                    OPN::LogError(@"[AppDelegate] Auto-resync state for %s: %s", store.c_str(), account->syncing.syncState.c_str());
                }
            }
            [strongSelf updateOwnershipSyncProgressFooter:OPNSyncRemainingFooter(deadlineAt)];
        } else {
            OPN::LogError(@"[AppDelegate] User account unavailable while monitoring auto-resync: %s", accountError.c_str());
        }

        std::string accountIdentifier = OPNAuthSessionIdentifier(strongSelf.currentSession);
        [strongSelf fetchGameLibraryWithRetry:YES completion:^(BOOL success, const std::vector<GameInfo> &games) {
            __typeof__(self) resultSelf = weakSelf;
            if (!resultSelf) return;

            const GameInfo *refreshedGame = nullptr;
            int selectedOwnedIndex = -1;
            int firstOwnedIndex = -1;
            if (success && accountIdentifier == OPNAuthSessionIdentifier(resultSelf.currentSession)) {
                std::string fingerprint = OPNGameLibraryFingerprint(games);
                resultSelf.cachedGameLibrary = games;
                resultSelf.cachedGameLibraryFingerprint = fingerprint;
                resultSelf.cachedGameLibraryAccountIdentifier = accountIdentifier;
                resultSelf.hasCachedGameLibrary = YES;
                if (resultSelf.currentScreen == AuthScreen::Catalog && resultSelf.catalogView) {
                    [resultSelf.catalogView setGames:games];
                } else if (resultSelf.currentScreen == AuthScreen::Store && resultSelf.storeView) {
                    [resultSelf.storeView setLibraryGames:games];
                }

                refreshedGame = OPNFindMatchingGame(games, gameCopy);
                if (refreshedGame) {
                    selectedOwnedIndex = OPNSelectedOwnedVariantIndex(*refreshedGame, requestedVariant);
                    firstOwnedIndex = OPNFirstOwnedVariantIndex(*refreshedGame, -1);
                }
            }

            if (selectedOwnedIndex >= 0) {
                [resultSelf dismissOwnershipSyncProgress];
                if (continueHandler) continueHandler(true);
                return;
            }
            if (refreshedGame && firstOwnedIndex >= 0) {
                GameInfo refreshedCopy = *refreshedGame;
                [resultSelf dismissOwnershipSyncProgress];
                [resultSelf launchGame:refreshedCopy variantIndex:firstOwnedIndex returnScreen:returnScreen];
                return;
            }

            if (freshFailureMessage.length > 0) {
                OPN::LogError(@"[AppDelegate] Auto-resync fresh failure: %@", freshFailureMessage);
                if (fallbackHandler) fallbackHandler();
                return;
            }

            BOOL timedOut = deadlineAt && [deadlineAt timeIntervalSinceNow] <= 0.0;
            if (timedOut) {
                OPN::LogInfo(@"[AppDelegate] Auto-resync did not find ownership before timeout for title=%@", OPNAppStringFromStdString(gameCopy.title, @""));
                if (fallbackHandler) fallbackHandler();
                return;
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNOwnershipSyncPollIntervalSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                [retrySelf monitorAutoResyncOwnershipForGame:gameCopy
                                                variantIndex:variantIndexCopy
                                               returnScreen:returnScreen
                                                     stores:storesCopy
                                                  baselines:baselinesCopy
                                                deadlineAt:deadlineAt
                                                    attempt:attempt + 1
                                            continueHandler:continueHandler
                                            fallbackHandler:fallbackHandler];
            });
        }];
    });
}

- (void)markVariantOwnedForGame:(const OPN::GameInfo &)game
                    variantIndex:(int)variantIndex
                 continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    const GameVariant *variant = OPNVariantAtIndex(game, variantIndex);
    if (!variant || variant->id.empty()) {
        NSBeep();
        return;
    }

    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::string variantId = variant->id;
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().AddOwnedVariant(variantId, [weakSelf, gameCopy, variantIndexCopy, variantId, continueHandler](bool success, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Unable to Mark as Owned";
            alert.informativeText = error.empty() ? @"GeForce NOW did not accept the ownership update." : [NSString stringWithUTF8String:error.c_str()];
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            return;
        }

        GameService::Shared().SelectOwnedVariant(variantId, [weakSelf, gameCopy, variantIndexCopy, continueHandler](bool selectOK, const std::string &selectError) {
            __typeof__(self) selectSelf = weakSelf;
            if (!selectSelf) return;
            if (!selectOK) OPN::LogError(@"[AppDelegate] selectOwnedVariant failed after addOwnedVariant: %s", selectError.c_str());
            [selectSelf refreshLibraryAfterOwnershipChangeForGame:gameCopy
                                                     variantIndex:variantIndexCopy
                                                       requireGame:NO
                                                       completion:^(BOOL) {
                if (continueHandler) continueHandler(true);
            }];
        });
    });
}

- (void)markVariantUnownedForGame:(const OPN::GameInfo &)game
                      variantIndex:(int)variantIndex {
    using namespace OPN;
    const GameVariant *variant = OPNVariantAtIndex(game, variantIndex);
    if (!variant || variant->id.empty() || !GameVariantOwnedForLaunch(*variant)) {
        NSBeep();
        return;
    }

    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::string variantId = variant->id;
    NSString *gameTitle = game.title.empty() ? @"Selected Game" : [NSString stringWithUTF8String:game.title.c_str()];
    NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(variant->appStore).c_str()] ?: @"the selected store";

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.messageText = @"Mark Store Version as Unowned?";
    confirm.informativeText = [NSString stringWithFormat:@"This removes the %@ version of %@ from your GeForce NOW library. You can add it again later by syncing your library or marking it as owned.", storeName, gameTitle];
    [confirm addButtonWithTitle:@"Mark as Unowned"];
    [confirm addButtonWithTitle:@"Cancel"];

    __weak __typeof__(self) weakSelf = self;
    [confirm beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || returnCode != NSAlertFirstButtonReturn) return;

        [strongSelf showOwnershipSyncProgressForGameTitle:gameTitle storeName:storeName];
        strongSelf.ownershipSyncTitleLabel.stringValue = @"Updating GeForce NOW Library";
        [strongSelf updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Asking GeForce NOW to mark the %@ version as unowned.", storeName]];
        [strongSelf updateOwnershipSyncProgressFooter:@"Refreshing library data after the update."];

        GameService::Shared().RemoveOwnedVariant(variantId, [weakSelf, gameCopy, variantIndexCopy, storeName](bool success, const std::string &error) {
            __typeof__(self) resultSelf = weakSelf;
            if (!resultSelf) return;
            BOOL alreadyUnowned = !success && OPNIsNotFoundError(error);
            if (!success && !alreadyUnowned) {
                [resultSelf dismissOwnershipSyncProgress];
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Unable to Mark as Unowned";
                alert.informativeText = error.empty() ? @"GeForce NOW did not accept the ownership update." : [NSString stringWithUTF8String:error.c_str()];
                [alert addButtonWithTitle:@"OK"];
                [alert beginSheetModalForWindow:resultSelf.window completionHandler:nil];
                return;
            }
            if (alreadyUnowned) {
                OPN::LogInfo(@"[AppDelegate] RemoveOwnedVariant reported already-unowned for %@", storeName);
            }

            [resultSelf updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"%@ was updated. Refreshing your GeForce NOW library...", storeName]];
            [resultSelf refreshLibraryAfterOwnershipChangeForGame:gameCopy
                                                     variantIndex:variantIndexCopy
                                                       requireGame:NO
                                                       completion:^(BOOL) {
                __typeof__(self) refreshSelf = weakSelf;
                if (!refreshSelf) return;
                [refreshSelf dismissOwnershipSyncProgress];
            }];
        });
    }];
}

- (void)syncOwnershipForGame:(const OPN::GameInfo &)game
                 variantIndex:(int)variantIndex
                        store:(const std::string &)store
                retryingAuth:(BOOL)retryingAuth
              continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::string storeCopy = store;
    NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(storeCopy).c_str()] ?: @"the selected store";
    NSString *gameTitle = game.title.empty() ? @"Selected Game" : [NSString stringWithUTF8String:game.title.c_str()];
    [self showOwnershipSyncProgressForGameTitle:gameTitle storeName:storeName];
    if (retryingAuth) {
        [self updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Retrying %@ sync with a refreshed GeForce NOW session.", storeName]];
    }
    __weak __typeof__(self) weakSelf = self;
    [self updateOwnershipSyncProgressFooter:@"Reading current store sync state..."];
    GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, storeCopy, retryingAuth, continueHandler](bool baselineOK, const UserAccountInfo &baselineAccount, const std::string &baselineError) {
        __typeof__(self) baselineSelf = weakSelf;
        if (!baselineSelf) return;
        OPNSyncObservation baseline = baselineOK ? OPNSyncObservationForStore(baselineAccount, storeCopy) : OPNSyncObservation{};
        if (!baselineOK) OPN::LogError(@"[AppDelegate] User account unavailable before sync baseline: %s", baselineError.c_str());
        NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(storeCopy).c_str()] ?: @"the selected store";
        [baselineSelf updateOwnershipSyncProgressFooter:@"Sending sync request to GeForce NOW..."];
        if (!retryingAuth) {
            [baselineSelf updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Asking GeForce NOW to sync %@ library ownership.", storeName]];
        }
    GameService::Shared().SyncAccountProvider(storeCopy, [weakSelf, gameCopy, variantIndexCopy, storeCopy, retryingAuth, baseline, continueHandler](bool success, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            if (!retryingAuth && OPNIsUnauthorizedError(error)) {
                [strongSelf updateOwnershipSyncProgressMessage:@"Refreshing your GeForce NOW sign-in, then retrying sync..."];
                [strongSelf refreshOwnershipAuthWithCompletion:^(BOOL refreshed) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf) return;
                    if (refreshed) {
                        [retrySelf syncOwnershipForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy retryingAuth:YES continueHandler:continueHandler];
                        return;
                    }
                    [retrySelf syncOwnershipForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy retryingAuth:YES continueHandler:continueHandler];
                }];
                return;
            }
            [strongSelf dismissOwnershipSyncProgress];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Library Sync Failed";
            alert.informativeText = error.empty() ? @"GeForce NOW could not start the store library sync." : [NSString stringWithUTF8String:error.c_str()];
            [alert addButtonWithTitle:@"Mark as Owned"];
            [alert addButtonWithTitle:@"Open Store"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:strongSelf.window completionHandler:^(NSModalResponse returnCode) {
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                if (returnCode == NSAlertFirstButtonReturn) [retrySelf markVariantOwnedForGame:gameCopy variantIndex:variantIndexCopy continueHandler:continueHandler];
                if (returnCode == NSAlertSecondButtonReturn) [retrySelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
            }];
            return;
        }

        [strongSelf updateOwnershipSyncProgressMessage:@"GeForce NOW accepted the sync. Monitoring store sync status..."];
        NSDate *deadlineAt = [NSDate dateWithTimeIntervalSinceNow:OPNOwnershipSyncMonitorTimeoutSeconds];
        [strongSelf monitorOwnershipSyncForGame:gameCopy
                                   variantIndex:variantIndexCopy
                                          store:storeCopy
                                      baseline:baseline
                                     deadlineAt:deadlineAt
                                         attempt:0
                                      completion:^(BOOL ownedAfterRefresh, NSString *failureMessage) {
            __typeof__(self) resultSelf = weakSelf;
            if (!resultSelf) return;
            [resultSelf dismissOwnershipSyncProgress];
            if (ownedAfterRefresh) {
                if (continueHandler) continueHandler(true);
                return;
            }

            NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(storeCopy).c_str()] ?: @"the selected store";
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = failureMessage.length > 0 ? @"Library Sync Failed" : @"Game Not Found After Sync";
            alert.informativeText = failureMessage.length > 0
                ? failureMessage
                : [NSString stringWithFormat:@"GeForce NOW synced %@, but this game still was not reported as owned. You can mark it as owned through GeForce NOW or open the store to check purchase/claim status.", storeName];
            [alert addButtonWithTitle:@"Mark as Owned"];
            [alert addButtonWithTitle:@"Open Store"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:resultSelf.window completionHandler:^(NSModalResponse returnCode) {
                __typeof__(self) actionSelf = weakSelf;
                if (!actionSelf) return;
                if (returnCode == NSAlertFirstButtonReturn) [actionSelf markVariantOwnedForGame:gameCopy variantIndex:variantIndexCopy continueHandler:continueHandler];
                if (returnCode == NSAlertSecondButtonReturn) [actionSelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
            }];
        }];
    });
    });
}

- (void)monitorOwnershipSyncForGame:(const OPN::GameInfo &)game
                        variantIndex:(int)variantIndex
                               store:(const std::string &)store
                            baseline:(const OPNSyncObservation &)baseline
                          deadlineAt:(NSDate *)deadlineAt
                              attempt:(NSInteger)attempt
                           completion:(void (^)(BOOL ownedAfterRefresh, NSString *failureMessage))completion {
    using namespace OPN;
    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::string storeCopy = store;
    OPNSyncObservation baselineCopy = baseline;
    NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(storeCopy).c_str()] ?: @"the selected store";
    [self updateOwnershipSyncProgressMessage:[NSString stringWithFormat:@"Waiting for %@ to update your GeForce NOW library...", storeName]];
    [self updateOwnershipSyncProgressFooter:OPNSyncRemainingFooter(deadlineAt)];

    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().FetchUserAccount([weakSelf, gameCopy, variantIndexCopy, storeCopy, baselineCopy, deadlineAt, attempt, completion](bool accountOK, const UserAccountInfo &accountInfo, const std::string &accountError) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        OPNSyncObservation currentObservation;
        NSString *storeName = [NSString stringWithUTF8String:GameStoreDisplayName(storeCopy).c_str()] ?: @"the selected store";
        if (accountOK) {
            currentObservation = OPNSyncObservationForStore(accountInfo, storeCopy);
            [strongSelf updateOwnershipSyncProgressMessage:OPNSyncProgressMessage(currentObservation, baselineCopy, storeName, deadlineAt, attempt)];
            [strongSelf updateOwnershipSyncProgressFooter:OPNSyncRemainingFooter(deadlineAt)];
        } else {
            OPN::LogError(@"[AppDelegate] User account unavailable while monitoring sync: %s", accountError.c_str());
        }

        [strongSelf refreshLibraryAfterOwnershipChangeForGame:gameCopy
                                                 variantIndex:variantIndexCopy
                                                   requireGame:YES
                                                   completion:^(BOOL ownedAfterRefresh) {
            __typeof__(self) resultSelf = weakSelf;
            if (!resultSelf) return;
            if (ownedAfterRefresh) {
                if (completion) completion(YES, nil);
                return;
            }

            bool freshFailure = OPNSyncObservationHasFreshState(currentObservation, baselineCopy) && OPNSyncStateFailed(currentObservation.syncState);
            if (freshFailure) {
                NSString *failureMessage = OPNSyncFailureMessage(currentObservation.syncState, storeName);
                if (completion) completion(NO, failureMessage);
                return;
            }

            BOOL timedOut = deadlineAt && [deadlineAt timeIntervalSinceNow] <= 0.0;
            if (timedOut) {
                NSString *failureMessage = nil;
                if (OPNSyncObservationHasFreshState(currentObservation, baselineCopy) && !OPNSyncStateSucceeded(currentObservation.syncState)) {
                    failureMessage = OPNSyncFailureMessage(currentObservation.syncState, storeName);
                }
                if (completion) completion(NO, failureMessage);
                return;
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNOwnershipSyncPollIntervalSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                [retrySelf monitorOwnershipSyncForGame:gameCopy
                                          variantIndex:variantIndexCopy
                                                 store:storeCopy
                                              baseline:baselineCopy
                                            deadlineAt:deadlineAt
                                                attempt:attempt + 1
                                             completion:completion];
            });
        }];
    });
}

- (void)linkAccountForGame:(const OPN::GameInfo &)game
              variantIndex:(int)variantIndex
                     store:(const std::string &)store
             syncAfterLink:(BOOL)syncAfterLink
              retryingAuth:(BOOL)retryingAuth
           continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler {
    using namespace OPN;
    GameInfo gameCopy = game;
    int variantIndexCopy = variantIndex;
    std::string storeCopy = store;
    __weak __typeof__(self) weakSelf = self;
    GameService::Shared().StartAccountLinking(storeCopy, [weakSelf, gameCopy, variantIndexCopy, storeCopy, syncAfterLink, retryingAuth, continueHandler](bool success, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            if (!retryingAuth && OPNIsUnauthorizedError(error)) {
                [strongSelf refreshOwnershipAuthWithCompletion:^(BOOL refreshed) {
                    __typeof__(self) retrySelf = weakSelf;
                    if (!retrySelf) return;
                    if (refreshed) {
                        [retrySelf linkAccountForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy syncAfterLink:syncAfterLink retryingAuth:YES continueHandler:continueHandler];
                        return;
                    }
                    [retrySelf linkAccountForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy syncAfterLink:syncAfterLink retryingAuth:YES continueHandler:continueHandler];
                }];
                return;
            }
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Account Linking Failed";
            alert.informativeText = error.empty() ? @"GeForce NOW did not complete account linking." : [NSString stringWithUTF8String:error.c_str()];
            [alert addButtonWithTitle:@"Mark as Owned"];
            [alert addButtonWithTitle:@"Open Store"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:strongSelf.window completionHandler:^(NSModalResponse returnCode) {
                __typeof__(self) retrySelf = weakSelf;
                if (!retrySelf) return;
                if (returnCode == NSAlertFirstButtonReturn) [retrySelf markVariantOwnedForGame:gameCopy variantIndex:variantIndexCopy continueHandler:continueHandler];
                if (returnCode == NSAlertSecondButtonReturn) [retrySelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
            }];
            return;
        }
        if (syncAfterLink) {
            [strongSelf syncOwnershipForGame:gameCopy variantIndex:variantIndexCopy store:storeCopy retryingAuth:NO continueHandler:continueHandler];
        } else if (continueHandler) {
            continueHandler(true);
        }
    });
}

- (void)refreshLibraryAfterOwnershipChangeForGame:(const OPN::GameInfo &)game
                                     variantIndex:(int)variantIndex
                                      requireGame:(BOOL)requireGame
                                       completion:(void (^)(BOOL ownedAfterRefresh))completion {
    using namespace OPN;
    GameInfo gameCopy = game;
    const GameVariant *variant = OPNVariantAtIndex(game, variantIndex);
    GameVariant variantCopy = variant ? *variant : GameVariant{};
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    __weak __typeof__(self) weakSelf = self;
    [self fetchGameLibraryWithRetry:YES completion:^(BOOL success, const std::vector<GameInfo> &games) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL ownedAfterRefresh = NO;
        if (success && accountIdentifier == OPNAuthSessionIdentifier(strongSelf.currentSession)) {
            std::string fingerprint = OPNGameLibraryFingerprint(games);
            strongSelf.cachedGameLibrary = games;
            strongSelf.cachedGameLibraryFingerprint = fingerprint;
            strongSelf.cachedGameLibraryAccountIdentifier = accountIdentifier;
            strongSelf.hasCachedGameLibrary = YES;
            if (strongSelf.currentScreen == AuthScreen::Catalog && strongSelf.catalogView) {
                [strongSelf.catalogView setGames:games];
            } else if (strongSelf.currentScreen == AuthScreen::Store && strongSelf.storeView) {
                [strongSelf.storeView setLibraryGames:games];
            }
            ownedAfterRefresh = (!variantCopy.id.empty() || !variantCopy.appStore.empty()) ? OPNLibraryContainsOwnedVariant(games, gameCopy, variantCopy) : NO;
        }
        if (completion) completion(requireGame ? ownedAfterRefresh : YES);
    }];
}

- (void)openPurchaseURL:(NSString *)purchaseURL forGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex {
    NSString *trimmedURL = [purchaseURL ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedURL.length == 0) {
        OPN::GameInfo gameCopy = game;
        __weak __typeof__(self) weakSelf = self;
        OPN::LogInfo(@"[AppDelegate] Resolving purchase URL for title=%@, id=%s, variantIndex=%d", OPNAppStringFromStdString(game.title, @""), game.id.c_str(), variantIndex);
        OPN::GameService::Shared().ResolveStoreURL(gameCopy, variantIndex, [weakSelf, gameCopy, variantIndex](bool success, const std::string &storeURL, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!success || storeURL.empty()) {
                OPN::LogError(@"[AppDelegate] Store URL resolution failed for title=%@, id=%s, variantIndex=%d, error=%s", OPNAppStringFromStdString(gameCopy.title, @""), gameCopy.id.c_str(), variantIndex, error.c_str());
                NSBeep();
                return;
            }
            NSString *resolvedURL = [NSString stringWithUTF8String:storeURL.c_str()];
            [strongSelf openPurchaseURL:resolvedURL forGame:gameCopy variantIndex:variantIndex];
        });
        return;
    }

    NSURL *url = [NSURL URLWithString:trimmedURL];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        OPN::LogError(@"[AppDelegate] Invalid purchase URL for title=%@, id=%s, variantIndex=%d, url=%@", OPNAppStringFromStdString(game.title, @""), game.id.c_str(), variantIndex, trimmedURL);
        NSBeep();
        return;
    }

    OPN::LogInfo(@"[AppDelegate] Opening purchase URL for title=%@, id=%s, variantIndex=%d", OPNAppStringFromStdString(game.title, @""), game.id.c_str(), variantIndex);
    if (![[NSWorkspace sharedWorkspace] openURL:url]) {
        OPN::LogError(@"[AppDelegate] Failed to open purchase URL for title=%@, id=%s, variantIndex=%d", OPNAppStringFromStdString(game.title, @""), game.id.c_str(), variantIndex);
        NSBeep();
    }
}

@end
