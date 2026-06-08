#import "AppDelegate/OPNAppDelegatePrivate.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    using namespace OPN;

    OPN::RecordSentryCounterMetric("opennow.app.launch.count", 1, nil);
    SentryTransaction launchTrace("OpenNOW launch", "app.start");
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self installMainMenu];
    [self applyApplicationIconTheme];

    NSRect frame = NSMakeRect(0, 0, kWindowWidth, kWindowHeight);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable |
                                                        NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"OpenNOW";
    OPNConfigureLibraryWindow(self.window);
    if (![self.window setFrameUsingName:OPNMainWindowFrameAutosaveName]) {
        [self.window center];
    }
    self.window.frameAutosaveName = OPNMainWindowFrameAutosaveName;
    [self installLibraryRootIfNeeded];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowFullScreenStateChanged:)
                                                 name:NSWindowDidEnterFullScreenNotification
                                               object:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowFullScreenStateChanged:)
                                                 name:NSWindowDidExitFullScreenNotification
                                               object:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(windowGeometryChanged:)
                                                 name:NSWindowDidResizeNotification
                                               object:self.window];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(interfacePreferencesChanged:)
                                                 name:OPNInterfacePreferencesDidChangeNotification
                                               object:nil];
    self.githubUpdater = [[OPNGitHubUpdater alloc] initWithOwner:@"OpenCloudGaming" repository:@"OpenNOW-Mac"];
    {
        OPN::AuthCredentials creds = self.pendingCredentials;
        creds.stayLoggedIn = AuthService::Shared().GetStayLoggedIn();
        self.pendingCredentials = creds;
    }

    AuthSession saved = AuthService::Shared().LoadSavedSession();
    BOOL shouldAutoSignIn = saved.isAuthenticated && AuthService::Shared().GetStayLoggedIn();
    BOOL canUseSavedSessionAsIs = saved.IsAccessTokenValid() && saved.IsClientTokenValid();
    BOOL canRefreshSavedSession = saved.IsAccessTokenValid() || !saved.refreshToken.empty() || !saved.clientToken.empty();
    OPN::RecordSentryCounterMetric("opennow.auth.startup.count", 1, @{
        @"saved_session": @(saved.isAuthenticated),
        @"auto_sign_in": @(shouldAutoSignIn),
        @"refresh_needed": @(shouldAutoSignIn && canRefreshSavedSession && !canUseSavedSessionAsIs),
    });
    if (shouldAutoSignIn && canUseSavedSessionAsIs) {
        self.currentSession = saved;
        [self transitionToScreen:AuthScreen::Store];
    } else if (shouldAutoSignIn && canRefreshSavedSession) {
        [self showAuthenticatingWithMessage:@"Refreshing session..."];
        __weak __typeof__(self) weakSelf = self;
        AuthService::Shared().RefreshSession(^(bool success, const AuthSession &fresh,
                                                const std::string &) {
            __typeof__(self) s = weakSelf;
            if (!s) return;
            if (success) {
                OPN::RecordSentryCounterMetric("opennow.auth.refresh.count", 1, @{@"source": @"startup", @"outcome": @"success"});
                s.currentSession = fresh;
                AuthService::Shared().SaveSession(fresh);
                [s refreshAccountMenu];
                [s transitionToScreen:AuthScreen::Store];
            } else {
                OPN::RecordSentryCounterMetric("opennow.auth.refresh.count", 1, @{@"source": @"startup", @"outcome": @"failure"});
                OPN::AuthSession fallback = AuthService::Shared().LoadSavedSession();
                if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
                    s.currentSession = fallback;
                    [s transitionToScreen:AuthScreen::Store];
                } else {
                    [s transitionToScreen:AuthScreen::EmailEntry];
                }
            }
        });
    } else {
        [self transitionToScreen:AuthScreen::EmailEntry];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self restoreSavedWindowPresentation];
    [self startApplicationUpdateChecks];
    [self startDesktopControllerPolling];
    launchTrace.SetStatus(true);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    OPN::RecordSentryCounterMetric("opennow.app.lifecycle.count", 1, @{@"phase": @"terminate"});
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.window saveFrameUsingName:OPNMainWindowFrameAutosaveName];
    [self saveWindowPresentation];
    [self stopApplicationUpdateChecks];
    [self stopDesktopControllerPolling];
    [self stopGameLibraryRefreshTimer];
    [self stopActiveSessionPromptControllerPolling];
    [self stopStreamDashboardControllerPolling];
    self.desktopAccountSwitcher = nil;
    self.desktopRemainingPlayTimePill = nil;
    self.desktopRemainingPlayTimeLabel = nil;
    if (self.streamingController) {
        [self.streamingController shutdownForApplicationTermination];
        self.streamingController = nil;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.streamingController) {
        [self.streamingController shutdownForApplicationTermination];
        self.streamingController = nil;
    }
    return NSTerminateNow;
}

@end
