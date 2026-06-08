#import "OPNAppDelegatePrivate.h"

@implementation AppDelegate (Streaming)

- (BOOL)hasVisibleStreamingController {
    if (!self.streamingController) return NO;
    if (self.streamDashboardHomeVisible) return YES;
    if (self.window.contentViewController == self.streamingController) return YES;
    OPN::LogInfo(@"[AppDelegate] Clearing stale streaming controller before launch/session check");
    self.streamingController = nil;
    self.currentStreamTitle = nil;
    return NO;
}

- (void)toggleStreamDashboardHome {
    if (!self.streamingController) return;
    if (self.streamDashboardHomeVisible) {
        [self restoreVisibleStreamFromDashboard];
    } else {
        [self showStreamDashboardHome];
    }
}

- (void)showStreamDashboardHome {
    if (!self.streamingController || self.streamDashboardHomeVisible) return;
    self.streamDashboardHomeVisible = YES;
    self.streamDashboardStartHoldBegan = CACurrentMediaTime();
    self.streamDashboardStartHoldConsumed = YES;
    [self.streamingController setStreamInputSuppressed:YES];
    self.window.contentViewController = nil;
    [self transitionToScreen:OPN::AuthScreen::Store];
    self.rootView.mode = OPNBackdropModeStore;
    [self startStreamDashboardControllerPolling];
    OPN::LogInfo(@"[AppDelegate] Stream dashboard Home shown");
}

- (void)restoreVisibleStreamFromDashboard {
    if (!self.streamingController) return;
    [self stopStreamDashboardControllerPolling];
    self.streamDashboardHomeVisible = NO;
    NSRect preservedFrame = self.window.frame;
    BOOL preserveFrame = !OPNWindowIsFullScreen(self.window);
    [self.streamingController setInitialViewFrame:self.window.contentView.bounds];
    self.streamingController.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    OPNConfigureStreamWindow(self.window);
    self.window.contentViewController = self.streamingController;
    OpnDisableFocusHighlights(self.streamingController.view);
    [self.streamingController setStreamInputSuppressed:NO];
    if (preserveFrame) [self.window setFrame:preservedFrame display:YES animate:NO];
    [self.window makeKeyAndOrderFront:nil];
    OPN::LogInfo(@"[AppDelegate] Stream restored from dashboard Home");
}

- (void)startStreamDashboardControllerPolling {
    [self stopStreamDashboardControllerPolling];
    self.streamDashboardControllerTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                           target:self
                                                                         selector:@selector(pollStreamDashboardController:)
                                                                         userInfo:nil
                                                                          repeats:YES];
}

- (void)stopStreamDashboardControllerPolling {
    [self.streamDashboardControllerTimer invalidate];
    self.streamDashboardControllerTimer = nil;
    self.streamDashboardStartHoldBegan = 0;
    self.streamDashboardStartHoldConsumed = NO;
}

- (void)pollStreamDashboardController:(NSTimer *)timer {
    (void)timer;
    if (!self.streamDashboardHomeVisible || !self.streamingController) {
        [self stopStreamDashboardControllerPolling];
        return;
    }
    BOOL startDown = NO;
    for (GCController *controller in [GCController controllers]) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) continue;
        if (pad.buttonMenu.value > 0.5) {
            startDown = YES;
            break;
        }
    }
    if (!startDown) {
        self.streamDashboardStartHoldBegan = 0;
        self.streamDashboardStartHoldConsumed = NO;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.streamDashboardStartHoldBegan <= 0) {
        self.streamDashboardStartHoldBegan = now;
        return;
    }
    if (self.streamDashboardStartHoldConsumed || now - self.streamDashboardStartHoldBegan < 3.0) return;
    self.streamDashboardStartHoldConsumed = YES;
    [self restoreVisibleStreamFromDashboard];
}

- (void)showActiveSessionPromptWithSessionTitle:(NSString *)sessionTitle
                              selectedGameTitle:(NSString *)selectedGameTitle
                                continueHandler:(void (^)(void))continueHandler
                                  deleteHandler:(void (^)(void))deleteHandler {
    [self dismissActiveSessionPrompt];
    self.activeSessionContinueHandler = continueHandler;
    self.activeSessionDeleteHandler = deleteHandler;

    NSView *host = self.contentContainer ?: self.window.contentView;
    NSView *overlay = [[NSView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    overlay.wantsLayer = YES;
    overlay.layer.backgroundColor = OpnColor(0x020304, 0.82).CGColor;

    CGFloat panelWidth = MIN(640.0, MAX(420.0, NSWidth(host.bounds) - 96.0));
    CGFloat panelHeight = 330.0;
    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(host.bounds) - panelWidth) / 2.0),
                                                            floor((NSHeight(host.bounds) - panelHeight) / 2.0),
                                                            panelWidth,
                                                            panelHeight)];
    panel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    panel.wantsLayer = YES;
    panel.layer.cornerRadius = 28.0;
    panel.layer.backgroundColor = OpnColor(0x0A0C0F, 0.98).CGColor;
    panel.layer.borderWidth = 1.5;
    panel.layer.borderColor = OpnColor(0xFFFFFF, 0.16).CGColor;
    panel.layer.shadowColor = NSColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.58;
    panel.layer.shadowRadius = 46.0;
    panel.layer.shadowOffset = CGSizeMake(0.0, 20.0);
    [overlay addSubview:panel];

    NSView *accentBar = [[NSView alloc] initWithFrame:NSMakeRect(34.0, panelHeight - 38.0, 80.0, 3.0)];
    accentBar.wantsLayer = YES;
    accentBar.layer.cornerRadius = 1.5;
    accentBar.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.88).CGColor;
    [panel addSubview:accentBar];

    NSTextField *eyebrow = OpnLabel(@"ACTIVE SESSION", NSMakeRect(34.0, panelHeight - 72.0, panelWidth - 68.0, 18.0), 12.0, OpnColor(OPN::kBrandGreen), NSFontWeightBold);
    [panel addSubview:eyebrow];

    NSTextField *title = OpnLabel(@"Resume or Replace", NSMakeRect(32.0, panelHeight - 124.0, panelWidth - 64.0, 42.0), 31.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
    [panel addSubview:title];

    NSString *safeSessionTitle = sessionTitle.length > 0 ? sessionTitle : @"the active cloud session";
    NSString *safeSelectedTitle = selectedGameTitle.length > 0 ? selectedGameTitle : @"the selected game";
    NSString *body = [NSString stringWithFormat:@"%@ is already running. Continue that stream, or delete it and launch %@.", safeSessionTitle, safeSelectedTitle];
    NSTextField *bodyLabel = OpnLabel(body, NSMakeRect(34.0, panelHeight - 188.0, panelWidth - 68.0, 54.0), 15.0, OpnColor(OPN::kTextSecondary), NSFontWeightMedium);
    bodyLabel.maximumNumberOfLines = 3;
    [panel addSubview:bodyLabel];

    NSView *divider = [[NSView alloc] initWithFrame:NSMakeRect(34.0, 112.0, panelWidth - 68.0, 1.0)];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    [panel addSubview:divider];

    CGFloat buttonY = 44.0;
    CGFloat buttonGap = 14.0;
    CGFloat buttonWidth = floor((panelWidth - 68.0 - buttonGap) / 2.0);
    NSButton *continueButton = OpnButton(@"A  Continue Session", NSMakeRect(34.0, buttonY, buttonWidth, 48.0), OpnColor(0x11161A, 0.98), OpnColor(OPN::kBrandGreen), true, OpnColor(OPN::kBrandGreen, 0.52));
    continueButton.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    continueButton.target = self;
    continueButton.action = @selector(activeSessionContinueClicked:);
    [panel addSubview:continueButton];

    NSButton *deleteButton = OpnButton(@"Y  Delete Session", NSMakeRect(NSMaxX(continueButton.frame) + buttonGap, buttonY, buttonWidth, 48.0), OpnColor(0x111114, 0.98), OpnColor(OPN::kErrorRed), true, OpnColor(OPN::kErrorRed, 0.46));
    deleteButton.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    deleteButton.target = self;
    deleteButton.action = @selector(activeSessionDeleteClicked:);
    [panel addSubview:deleteButton];

    NSTextField *hint = OpnLabel(@"Choose how to handle the existing cloud session before launching.", NSMakeRect(34.0, 18.0, panelWidth - 68.0, 18.0), 12.0, OpnColor(OPN::kTextMuted), NSFontWeightMedium, NSTextAlignmentCenter);
    [panel addSubview:hint];

    self.activeSessionPromptView = overlay;
    [host addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    [self startActiveSessionPromptControllerPolling];
}

- (void)dismissActiveSessionPrompt {
    [self stopActiveSessionPromptControllerPolling];
    [self.activeSessionPromptView removeFromSuperview];
    self.activeSessionPromptView = nil;
    self.activeSessionContinueHandler = nil;
    self.activeSessionDeleteHandler = nil;
}

- (void)startActiveSessionPromptControllerPolling {
    if (self.activeSessionPromptControllerTimer) return;
    self.activeSessionPromptPreviousButtons = OPNActiveSessionPromptGamepadButtons();
    self.activeSessionPromptControllerTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                                               target:self
                                                                             selector:@selector(pollActiveSessionPromptController)
                                                                             userInfo:nil
                                                                              repeats:YES];
}

- (void)stopActiveSessionPromptControllerPolling {
    [self.activeSessionPromptControllerTimer invalidate];
    self.activeSessionPromptControllerTimer = nil;
    self.activeSessionPromptPreviousButtons = 0;
}

- (void)pollActiveSessionPromptController {
    if (!self.activeSessionPromptView) {
        [self stopActiveSessionPromptControllerPolling];
        return;
    }
    uint16_t buttons = OPNActiveSessionPromptGamepadButtons();
    uint16_t pressed = buttons & (uint16_t)~self.activeSessionPromptPreviousButtons;
    if (pressed & (1u << 0)) {
        [self activeSessionContinueClicked:nil];
        return;
    }
    if (pressed & (1u << 2)) {
        [self activeSessionDeleteClicked:nil];
        return;
    }
    self.activeSessionPromptPreviousButtons = buttons;
}

- (void)activeSessionContinueClicked:(id)sender {
    (void)sender;
    void (^handler)(void) = self.activeSessionContinueHandler;
    [self dismissActiveSessionPrompt];
    if (handler) handler();
}

- (void)activeSessionDeleteClicked:(id)sender {
    (void)sender;
    void (^handler)(void) = self.activeSessionDeleteHandler;
    [self dismissActiveSessionPrompt];
    if (handler) handler();
}

- (void)showCloudmatchServerPickerForGameTitle:(NSString *)gameTitle
                                      apiToken:(const std::string &)apiToken
                                    completion:(void (^)(BOOL confirmed))completion {
    [self dismissCloudmatchServerPicker];
    NSView *host = self.contentContainer ?: self.window.contentView;
    if (!host) {
        if (completion) completion(NO);
        return;
    }

    NSInteger generation = ++self.cloudmatchServerPickerGeneration;
    OPNCloudmatchServerPickerView *picker = [[OPNCloudmatchServerPickerView alloc] initWithFrame:host.bounds gameTitle:gameTitle ?: @""];
    picker.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.cloudmatchServerPickerView = picker;

    std::vector<OPN::StreamRegionOption> cachedRegions = OPN::LoadCachedStreamRegions();
    NSString *selectedRegionUrl = OPNAppStringFromStdString(OPN::LoadSelectedStreamRegionUrl(), @"");
    [picker setOptions:OPNCloudmatchServerOptionsFromRegions(cachedRegions)
     selectedRegionUrl:selectedRegionUrl
            refreshing:YES];
    [picker setStatusMessage:cachedRegions.empty()
        ? @"Finding routes..."
        : @"Refreshing ping..."
                      isError:NO];

    __weak __typeof__(self) weakSelf = self;
    __weak OPNCloudmatchServerPickerView *weakPicker = picker;
    std::string tokenCopy = apiToken;
    void (^completionCopy)(BOOL) = [completion copy];
    picker.onConfirm = ^(OPNCloudmatchServerOption *option) {
        __typeof__(self) strongSelf = weakSelf;
        OPNCloudmatchServerPickerView *strongPicker = weakPicker;
        if (!strongSelf || !strongPicker || strongSelf.cloudmatchServerPickerView != strongPicker) return;

        std::string selectedUrl;
        if (option.url.length > 0) selectedUrl = [option.url UTF8String];
        OPN::SaveSelectedStreamRegionUrl(selectedUrl);
        OPN::LogInfo(@"[AppDelegate] Cloudmatch server selected: %s", selectedUrl.empty() ? "automatic" : selectedUrl.c_str());
        [strongSelf dismissCloudmatchServerPicker];
        if (completionCopy) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionCopy(YES);
            });
        }
    };
    picker.onCancel = ^{
        __typeof__(self) strongSelf = weakSelf;
        OPNCloudmatchServerPickerView *strongPicker = weakPicker;
        if (!strongSelf || !strongPicker || strongSelf.cloudmatchServerPickerView != strongPicker) return;
        OPN::LogInfo(@"[AppDelegate] Cloudmatch server selection cancelled");
        [strongSelf dismissCloudmatchServerPicker];
        if (completionCopy) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionCopy(NO);
            });
        }
    };
    picker.onRefresh = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshCloudmatchServerPickerWithToken:tokenCopy generation:generation];
    };

    [host addSubview:picker positioned:NSWindowAbove relativeTo:nil];
    [self.window makeFirstResponder:picker];
    [self refreshCloudmatchServerPickerWithToken:apiToken generation:generation];
}

- (void)refreshCloudmatchServerPickerWithToken:(const std::string &)apiToken
                                    generation:(NSInteger)generation {
    OPNCloudmatchServerPickerView *picker = self.cloudmatchServerPickerView;
    if (!picker || generation != self.cloudmatchServerPickerGeneration) return;

    [picker setRefreshing:YES];
    [picker setStatusMessage:@"Pinging routes..." isError:NO];

    __weak __typeof__(self) weakSelf = self;
    __weak OPNCloudmatchServerPickerView *weakPicker = picker;
    std::string tokenCopy = apiToken;
    std::string idpId = self.currentSession.idpId;
    OPN::GameService::Shared().SetAccessToken(tokenCopy);
    OPN::GameService::Shared().FetchProviderInfo(idpId, [weakSelf, weakPicker, generation, tokenCopy](bool, const OPN::GameProviderInfo &, const OPN::GameProviderEndpoint &endpoint, const std::string &) {
        std::string providerBaseUrl = endpoint.streamingServiceUrl.empty() ? OPN::GameService::Shared().ProviderStreamingBaseUrl() : endpoint.streamingServiceUrl;
        OPN::FetchStreamRegions(tokenCopy, providerBaseUrl, [weakSelf, weakPicker, generation](const std::vector<OPN::StreamRegionOption> &regions) {
            __typeof__(self) strongSelf = weakSelf;
            OPNCloudmatchServerPickerView *strongPicker = weakPicker;
            if (!strongSelf || !strongPicker) return;
            if (generation != strongSelf.cloudmatchServerPickerGeneration || strongSelf.cloudmatchServerPickerView != strongPicker) return;

            NSString *selectedRegionUrl = OPNAppStringFromStdString(OPN::LoadSelectedStreamRegionUrl(), @"");
            [strongPicker setOptions:OPNCloudmatchServerOptionsFromRegions(regions)
                   selectedRegionUrl:selectedRegionUrl
                          refreshing:NO];
            if (regions.empty()) {
                [strongPicker setStatusMessage:@"Discovery failed. Automatic can still launch." isError:YES];
            } else {
                [strongPicker setStatusMessage:@"Ping updated." isError:NO];
            }
        });
    });
}

- (void)dismissCloudmatchServerPicker {
    self.cloudmatchServerPickerGeneration++;
    [self.cloudmatchServerPickerView removeFromSuperview];
    self.cloudmatchServerPickerView = nil;
}

- (void)startStreamWithTitle:(const std::string &)title
                       appId:(const std::string &)appId
                    apiToken:(const std::string &)apiToken
               accountLinked:(bool)accountLinked
                selectedStore:(const std::string &)selectedStore
                returnScreen:(OPN::AuthScreen)returnScreen
              resumeSessionId:(const std::string &)resumeSessionId
                  resumeServer:(const std::string &)resumeServer {
    using namespace OPN;

    if ([self hasVisibleStreamingController]) {
        OPN::RecordSentryCounterMetric("opennow.stream.start.count", 1, @{
            @"source": resumeSessionId.empty() ? @"new" : @"resume",
            @"outcome": @"ignored_active_stream",
            @"return_screen": OPNMetricScreenName(returnScreen),
        });
        OPN::LogInfo(@"[AppDelegate] Ignoring stream start while stream is active: title=%@, appId=%s", OPNAppStringFromStdString(title, @""), appId.c_str());
        return;
    }

    // Capture C++ params by value so they are available inside the async refresh block.
    std::string titleCopy = title;
    std::string appIdCopy = appId;
    std::string apiTokenCopy = apiToken;
    std::string selectedStoreCopy = selectedStore;
    std::string resumeSessionIdCopy = resumeSessionId;
    std::string resumeServerCopy = resumeServer;

    // Refresh the GFN JWT before launch. An expired token causes AUTH_FAILURE_STATUS at the
    // NVIDIA API, surfaced as "Your NVIDIA session expired." Refreshing here prevents that.
    __weak __typeof__(self) weakSelf = self;
    AuthService::Shared().RefreshSession(^(bool refreshSuccess, const AuthSession &fresh, const std::string &refreshError) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;

        OPN::RecordSentryCounterMetric("opennow.stream.start.count", 1, @{
            @"source": resumeSessionIdCopy.empty() ? @"new" : @"resume",
            @"outcome": @"started",
            @"return_screen": OPNMetricScreenName(returnScreen),
            @"account_linked": @(accountLinked),
        });

        std::string effectiveToken = apiTokenCopy;
        if (refreshSuccess && fresh.isAuthenticated) {
            std::string freshToken = fresh.idToken.empty() ? fresh.accessToken : fresh.idToken;
            if (!freshToken.empty()) {
                effectiveToken = freshToken;
                strongSelf.currentSession = fresh;
                if (strongSelf.pendingCredentials.stayLoggedIn) AuthService::Shared().SaveSession(fresh);
                [strongSelf refreshAccountMenu];
                OPN::LogInfo(@"[AppDelegate] Auth token refreshed successfully before stream launch");
            }
        } else {
            OPN::LogError(@"[AppDelegate] Auth token refresh failed before stream launch: %s", refreshError.c_str());
            // If the stored token is also expired, abort and send the user back to sign-in.
            if (!strongSelf.currentSession.IsAccessTokenValid()) {
                OPN::LogError(@"[AppDelegate] Session token is expired and refresh failed; redirecting to sign-in");
                [strongSelf transitionToScreen:AuthScreen::EmailEntry];
                return;
            }
        }

        strongSelf.catalogView = nil;
        strongSelf.storeView = nil;
        strongSelf.settingsView = nil;

        OPNStreamViewController *streamVC = [[OPNStreamViewController alloc] initWithGameTitle:titleCopy
                                                                                          appId:appIdCopy
                                                                                       apiToken:effectiveToken
                                                                                  accountLinked:accountLinked
                                                                                   selectedStore:selectedStoreCopy
                                                                                 resumeSessionId:resumeSessionIdCopy
                                                                                     resumeServer:resumeServerCopy];
        if (strongSelf.currentRemainingPlayTimeAvailable) {
            [streamVC setRemainingPlaytimeHours:strongSelf.currentRemainingPlayTimeHours unlimited:strongSelf.currentRemainingPlayTimeUnlimited];
        }
        strongSelf.currentStreamTitle = titleCopy.empty() ? @"Current Stream" : [NSString stringWithUTF8String:titleCopy.c_str()];
        strongSelf.activeStreamReturnScreen = returnScreen;
        strongSelf.streamDashboardHomeVisible = NO;
        OPN::DiscordPresence::Shared().UpdateLaunching(titleCopy);

        streamVC.onStreamEnd = ^(BOOL success, const std::string &error, const OPN::SessionHealthReport &report) {
            __typeof__(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            std::string errorCopy2 = error;
            OPN::SessionHealthReport reportCopy = report;
            dispatch_async(dispatch_get_main_queue(), ^{
                OPN::LogInfo(@"[AppDelegate] Stream ended, restoring previous screen. Success=%d", success);
                [innerSelf stopStreamDashboardControllerPolling];
                innerSelf.streamDashboardHomeVisible = NO;
                innerSelf.streamingController = nil;
                innerSelf.currentStreamTitle = nil;
                OPN::DiscordPresence::Shared().Clear();
                [innerSelf transitionToScreen:returnScreen];
                if (!success && !errorCopy2.empty()) OPN::AppendLogEvent([NSString stringWithFormat:@"[AppDelegate] Stream ended with error before report: %s", errorCopy2.c_str()]);
                OPN::SessionReportDisplayDecision decision = OPN::SessionHealthReportDisplayDecisionForReport(reportCopy, OPN::LoadSessionReportDisplayMode());
                if (decision.shouldShow) {
                    [innerSelf showSessionReport:reportCopy];
                } else {
                    OPN::AppendLogEvent([NSString stringWithFormat:@"[AppDelegate] Session report suppressed score=%d reason=%s", decision.score, decision.reason.c_str()]);
                }
            });
        };
        streamVC.onDashboardToggleRequested = ^{
            __typeof__(self) innerSelf = weakSelf;
            if (!innerSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [innerSelf toggleStreamDashboardHome];
            });
        };

        NSRect preservedFrame = strongSelf.window.frame;
        BOOL preserveFrame = !OPNWindowIsFullScreen(strongSelf.window);
        [streamVC setInitialViewFrame:strongSelf.window.contentView.bounds];
        streamVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        OPNConfigureStreamWindow(strongSelf.window);
        strongSelf.window.contentViewController = streamVC;
        OpnDisableFocusHighlights(streamVC.view);
        if (preserveFrame) {
            [strongSelf.window setFrame:preservedFrame display:YES animate:NO];
        }
        strongSelf.streamingController = streamVC;
        [strongSelf.window makeKeyAndOrderFront:nil];
        if (OpnAutoFullScreenEnabled() && !OPNWindowIsFullScreen(strongSelf.window)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) innerSelf = weakSelf;
                if (!OPNWindowIsFullScreen(innerSelf.window)) {
                    [innerSelf.window toggleFullScreen:nil];
                }
            });
        }
        OPN::LogInfo(@"[AppDelegate] Window setup complete");
    });
}

- (void)checkForActiveSessionResumeIfNeededForScreen:(OPN::AuthScreen)screen {
    using namespace OPN;
    if (screen != AuthScreen::Catalog && screen != AuthScreen::Store) return;
    if (self.streamingController || self.activeSessionResumeInFlight) return;
    if (!self.currentSession.isAuthenticated || self.currentSession.accessToken.empty()) return;

    self.activeSessionResumeInFlight = YES;
    NSInteger generation = ++self.activeSessionResumeGeneration;
    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken
        : self.currentSession.idToken;
    SessionManager::Shared().SetAccessToken(apiToken);
    SessionManager::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
    std::string persistedSessionId = SessionManager::Shared().LoadPersistedActiveSessionId();

    __weak __typeof__(self) weakSelf = self;
    SessionManager::Shared().GetActiveSessions([weakSelf, generation, accountIdentifier, apiToken, screen, persistedSessionId](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
        std::vector<ActiveSessionEntry> sessionsCopy = sessions;
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.activeSessionResumeInFlight = NO;
            if (generation != strongSelf.activeSessionResumeGeneration) return;
            if (accountIdentifier != OPNAuthSessionIdentifier(strongSelf.currentSession)) return;
            if (strongSelf.streamingController || strongSelf.currentScreen != screen) return;
            if (!ok) {
                OPN::LogError(@"[AppDelegate] Active session probe failed: %s", errorCopy.c_str());
                return;
            }

            ActiveSessionEntry activeSession;
            BOOL foundActiveSession = NO;
            if (!persistedSessionId.empty()) {
                for (const ActiveSessionEntry &session : sessionsCopy) {
                    if (session.sessionId == persistedSessionId && (session.status == 1 || session.status == 2 || session.status == 3 || session.status == 6) && !session.serverIp.empty() && session.appId > 0) {
                        activeSession = session;
                        foundActiveSession = YES;
                        break;
                    }
                }
                if (!foundActiveSession) {
                    OPN::LogInfo(@"[AppDelegate] Persisted active sessionId=%s was not returned by active sessions; clearing", persistedSessionId.c_str());
                    SessionManager::Shared().ClearPersistedActiveSessionId(persistedSessionId);
                    return;
                }
            } else {
                for (const ActiveSessionEntry &session : sessionsCopy) {
                    if ((session.status == 1 || session.status == 2 || session.status == 3 || session.status == 6) && !session.sessionId.empty() && !session.serverIp.empty() && session.appId > 0) {
                        activeSession = session;
                        foundActiveSession = YES;
                        break;
                    }
                }
            }
            if (!foundActiveSession) return;

            std::string appId = std::to_string(activeSession.appId);
            NSString *streamTitle = OPNTitleForActiveSessionAppId(activeSession.appId, strongSelf.cachedGameLibrary);
            std::string title = streamTitle.length > 0 ? streamTitle.UTF8String : "Current Stream";
            [strongSelf startStreamWithTitle:title
                                       appId:appId
                                    apiToken:apiToken
                               accountLinked:true
                                selectedStore:""
                                returnScreen:screen
                              resumeSessionId:activeSession.sessionId
                                  resumeServer:activeSession.serverIp];
            OPN::LogInfo(@"[AppDelegate] Silently resuming active session %s for appId=%d", activeSession.sessionId.c_str(), activeSession.appId);
        });
    });
}


- (void)showSessionReport:(const OPN::SessionHealthReport &)report {
    if (!self.contentContainer) return;
    [self.sessionReportView removeFromSuperview];
    OPNSessionReportView *view = [[OPNSessionReportView alloc] initWithFrame:self.contentContainer.bounds report:report];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    __weak __typeof__(self) weakSelf = self;
    view.onDone = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.sessionReportView removeFromSuperview];
        strongSelf.sessionReportView = nil;
    };
    self.sessionReportView = view;
    [self.contentContainer addSubview:view positioned:NSWindowAbove relativeTo:nil];
    OpnDisableFocusHighlights(view);
    OPN::AppendLogEvent(@"[AppDelegate] Presented session health report");
}

@end
