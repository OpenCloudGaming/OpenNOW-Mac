#import "OPNAppDelegatePrivate.h"

@implementation AppDelegate (Desktop)

- (void)installMainMenu {
    NSString *appName = NSProcessInfo.processInfo.processName.length > 0 ? NSProcessInfo.processInfo.processName : @"OpenNOW";

    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    appMenuItem.submenu = appMenu;
    [appMenu addItem:OPNMenuItem([@"About " stringByAppendingString:appName], @selector(orderFrontStandardAboutPanel:), @"", NSApp)];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:OPNMenuItem(@"Settings...", @selector(showSettingsFromMenu:), @",", self)];
    [appMenu addItem:OPNMenuItem(@"Check for Updates...", @selector(checkForUpdatesFromMenu:), @"", self)];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
    NSMenuItem *servicesItem = OPNMenuItem(@"Services", nil, @"", nil);
    servicesItem.submenu = servicesMenu;
    [appMenu addItem:servicesItem];
    NSApp.servicesMenu = servicesMenu;
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:OPNMenuItem([@"Hide " stringByAppendingString:appName], @selector(hide:), @"h", NSApp)];
    [appMenu addItem:OPNMenuItemWithModifier(@"Hide Others", @selector(hideOtherApplications:), @"h", NSEventModifierFlagCommand | NSEventModifierFlagOption, NSApp)];
    [appMenu addItem:OPNMenuItem(@"Show All", @selector(unhideAllApplications:), @"", NSApp)];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItem:OPNMenuItem([@"Quit " stringByAppendingString:appName], @selector(terminate:), @"q", NSApp)];

    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    fileMenuItem.submenu = fileMenu;
    [fileMenu addItem:OPNMenuItem(@"Refresh Library", @selector(refreshLibraryFromMenu:), @"r", self)];
    [fileMenu addItem:NSMenuItem.separatorItem];
    [fileMenu addItem:OPNMenuItem(@"Close Window", @selector(performClose:), @"w", nil)];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editMenuItem.submenu = editMenu;
    [editMenu addItem:OPNMenuItem(@"Undo", NSSelectorFromString(@"undo:"), @"z", nil)];
    [editMenu addItem:OPNMenuItemWithModifier(@"Redo", NSSelectorFromString(@"redo:"), @"Z", NSEventModifierFlagCommand | NSEventModifierFlagShift, nil)];
    [editMenu addItem:NSMenuItem.separatorItem];
    [editMenu addItem:OPNMenuItem(@"Cut", @selector(cut:), @"x", nil)];
    [editMenu addItem:OPNMenuItem(@"Copy", @selector(copy:), @"c", nil)];
    [editMenu addItem:OPNMenuItem(@"Paste", @selector(paste:), @"v", nil)];
    [editMenu addItem:OPNMenuItem(@"Delete", @selector(delete:), @"", nil)];
    [editMenu addItem:OPNMenuItem(@"Select All", @selector(selectAll:), @"a", nil)];

    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewMenuItem.submenu = viewMenu;
    [viewMenu addItem:OPNMenuItemWithModifier(@"Enter Full Screen", @selector(toggleFullScreen:), @"f", NSEventModifierFlagCommand | NSEventModifierFlagControl, nil)];

    NSMenuItem *accountMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:accountMenuItem];
    NSMenu *accountMenu = [[NSMenu alloc] initWithTitle:@"Account"];
    accountMenuItem.submenu = accountMenu;
    [accountMenu addItem:OPNMenuItem(@"Manage NVIDIA Account...", @selector(openAccountManagementFromMenu:), @"", self)];

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    windowMenuItem.submenu = windowMenu;
    [windowMenu addItem:OPNMenuItem(@"Minimize", @selector(performMiniaturize:), @"m", nil)];
    [windowMenu addItem:OPNMenuItem(@"Zoom", @selector(performZoom:), @"", nil)];
    [windowMenu addItem:NSMenuItem.separatorItem];
    [windowMenu addItem:OPNMenuItem(@"Bring All to Front", @selector(arrangeInFront:), @"", NSApp)];
    NSApp.windowsMenu = windowMenu;

    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [mainMenu addItem:helpMenuItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    helpMenuItem.submenu = helpMenu;
    [helpMenu addItem:OPNMenuItem(@"OpenNOW Help", @selector(openOpenNOWWebsiteFromMenu:), @"?", self)];
    NSApp.helpMenu = helpMenu;

    NSApp.mainMenu = mainMenu;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(showSettingsFromMenu:)) {
        return OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen) && ![self hasVisibleStreamingController];
    }
    if (menuItem.action == @selector(refreshLibraryFromMenu:)) {
        return self.currentSession.isAuthenticated && !self.gameLibraryRefreshInFlight && ![self hasVisibleStreamingController];
    }
    if (menuItem.action == @selector(checkForUpdatesFromMenu:)) {
        return !self.updateCheckInFlight;
    }
    return YES;
}

- (void)showSettingsFromMenu:(id)sender {
    (void)sender;
    if (OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen) && ![self hasVisibleStreamingController]) {
        [self transitionToScreen:OPN::AuthScreen::Settings];
    }
}

- (void)refreshLibraryFromMenu:(id)sender {
    (void)sender;
    if (!self.currentSession.isAuthenticated || self.gameLibraryRefreshInFlight || [self hasVisibleStreamingController]) return;
    [self refreshGameLibraryInBackground];
    [self refreshFeaturedGamesForCatalogWithRetry:YES];
    [self refreshActiveSessionsForCatalog];
}

- (void)checkForUpdatesFromMenu:(id)sender {
    (void)sender;
    [self checkForApplicationUpdatesShowingCurrentStatus:YES];
}

- (void)openAccountManagementFromMenu:(id)sender {
    (void)sender;
    OPNOpenExternalURLString(OPNAccountManagementURLString);
}

- (void)openOpenNOWWebsiteFromMenu:(id)sender {
    (void)sender;
    OPNOpenExternalURLString(@"https://github.com/OpenCloudGaming/OpenNOW-Mac");
}

- (void)restoreSavedWindowPresentation {
    if (![NSUserDefaults.standardUserDefaults boolForKey:OPNMainWindowWasFullScreenKey]) return;
    __weak __typeof__(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window || OPNWindowIsFullScreen(strongSelf.window)) return;
        [strongSelf.window toggleFullScreen:nil];
    });
}

- (void)saveWindowPresentation {
    [NSUserDefaults.standardUserDefaults setBool:OPNWindowIsFullScreen(self.window)
                                          forKey:OPNMainWindowWasFullScreenKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (void)restartApplication {
    [self.window saveFrameUsingName:OPNMainWindowFrameAutosaveName];
    [self saveWindowPresentation];

    NSTask *task = [[NSTask alloc] init];
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if ([bundleURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
        task.arguments = @[@"-n", bundleURL.path];
    } else {
        NSString *executablePath = NSProcessInfo.processInfo.arguments.firstObject;
        if (executablePath.length == 0) executablePath = NSBundle.mainBundle.executablePath;
        if (executablePath.length > 0 && !executablePath.absolutePath) {
            executablePath = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:executablePath];
        }
        task.executableURL = executablePath.length > 0 ? [NSURL fileURLWithPath:executablePath] : nil;
        task.arguments = @[];
        task.currentDirectoryURL = [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath isDirectory:YES];
    }

    NSError *launchError = nil;
    BOOL launched = task.executableURL != nil && [task launchAndReturnError:&launchError];
    if (!launched) OPN::LogError(@"[AppDelegate] Restart launch failed: %@", launchError.localizedDescription ?: @"unknown error");

    if (launched) {
        [NSApp terminate:self];
    }
}

- (void)startApplicationUpdateChecks {
    if (self.applicationUpdateCheckTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self checkForApplicationUpdatesShowingCurrentStatus:NO];
    });
    self.applicationUpdateCheckTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 * 60.0
                                                                        target:self
                                                                      selector:@selector(applicationUpdateCheckTimerFired:)
                                                                      userInfo:nil
                                                                       repeats:YES];
}

- (void)stopApplicationUpdateChecks {
    [self.applicationUpdateCheckTimer invalidate];
    self.applicationUpdateCheckTimer = nil;
}

- (void)applicationUpdateCheckTimerFired:(NSTimer *)timer {
    (void)timer;
    [self checkForApplicationUpdatesShowingCurrentStatus:NO];
}

- (void)checkForApplicationUpdates {
    [self checkForApplicationUpdatesShowingCurrentStatus:YES];
}

- (void)checkForApplicationUpdatesShowingCurrentStatus:(BOOL)showCurrentStatus {
    if (self.updateCheckInFlight) return;
    self.updateCheckInFlight = YES;
    if (!self.githubUpdater) {
        self.githubUpdater = [[OPNGitHubUpdater alloc] initWithOwner:@"OpenCloudGaming" repository:@"OpenNOW-Mac"];
    }

    __weak __typeof__(self) weakSelf = self;
    [self.githubUpdater checkForUpdateWithCompletion:^(OPNGitHubRelease *release, NSError *error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.updateCheckInFlight = NO;
        if (error) {
            if (!showCurrentStatus) return;
            NSAlert *alert = [[NSAlert alloc] init];
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = @"Update check failed";
            alert.informativeText = error.localizedDescription ?: @"OpenNOW could not check GitHub Releases.";
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            return;
        }
        if (!release) {
            if (!showCurrentStatus) return;
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"OpenNOW is up to date";
            alert.informativeText = [NSString stringWithFormat:@"Version %@ is the latest release available on GitHub.", strongSelf.githubUpdater.currentVersion];
            [alert addButtonWithTitle:@"OK"];
            [alert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            return;
        }

        NSString *notes = release.releaseNotes.length > 0 ? release.releaseNotes : @"No release notes were provided.";
        if (notes.length > 1400) notes = [[notes substringToIndex:1400] stringByAppendingString:@"\n..."];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"OpenNOW %@ is available", release.version];
        alert.informativeText = [NSString stringWithFormat:@"Current version: %@\n\nThis update is required to continue using OpenNOW.\n\n%@", strongSelf.githubUpdater.currentVersion, notes];
        [alert addButtonWithTitle:@"Install and Relaunch"];
        [alert beginSheetModalForWindow:strongSelf.window completionHandler:^(NSModalResponse response) {
            (void)response;
            strongSelf.updateCheckInFlight = YES;
            [strongSelf.githubUpdater installRelease:release completion:^(BOOL launchedInstaller, NSError *installError) {
                strongSelf.updateCheckInFlight = NO;
                if (!launchedInstaller || installError) {
                    NSAlert *installAlert = [[NSAlert alloc] init];
                    installAlert.alertStyle = NSAlertStyleWarning;
                    installAlert.messageText = @"Update install failed";
                    installAlert.informativeText = installError.localizedDescription ?: @"OpenNOW could not install the downloaded update.";
                    [installAlert addButtonWithTitle:@"OK"];
                    [installAlert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
                    return;
                }
                [NSApp terminate:strongSelf];
            }];
        }];
    }];
}

- (void)windowFullScreenStateChanged:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self saveWindowPresentation];
    [self layoutDesktopTopChrome];
    [self layoutDesktopAccountSwitcher];
    [self layoutDesktopSettingsPill];
}

- (void)windowGeometryChanged:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self layoutDesktopTopChrome];
    [self layoutDesktopAccountSwitcher];
    [self layoutDesktopSettingsPill];
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self applyApplicationIconTheme];
    [self applyInterfacePreferencesToCurrentScreen];
}

- (void)applyApplicationIconTheme {
    NSImage *icon = OPNDesktopBrandIconImage();
    if (icon) NSApp.applicationIconImage = icon;
}

- (void)applyInterfacePreferencesToCurrentScreen {
    if (!self.rootView) return;
    if (self.currentScreen == OPN::AuthScreen::Store) {
        self.rootView.mode = OPNBackdropModeStore;
    } else if (self.currentScreen == OPN::AuthScreen::Catalog) {
        self.rootView.mode = OPNBackdropModeLibrary;
    } else if (self.currentScreen == OPN::AuthScreen::Settings) {
        self.rootView.mode = OPNBackdropModeSettings;
    }
    [self updateDesktopTopChrome];
    [self updateDesktopAccountSwitcher];
}

- (void)installDesktopTopChromeIfNeeded {
    if (!self.rootView) return;
    if (self.desktopTopChromeView && self.desktopTopChromeView.superview != self.rootView) {
        self.desktopTopChromeView = nil;
        self.desktopBrandLabel = nil;
    }
    if (!self.desktopTopChromeView) {
        NSView *chrome = [[NSView alloc] initWithFrame:NSZeroRect];
        chrome.wantsLayer = YES;
        chrome.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.desktopTopChromeView = chrome;

        NSTextField *brandLabel = OpnLabel(@"OpenNOW", NSZeroRect, 18.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
        brandLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        brandLabel.wantsLayer = YES;
        brandLabel.layer.shadowColor = NSColor.blackColor.CGColor;
        brandLabel.layer.shadowOpacity = 0.95;
        brandLabel.layer.shadowRadius = 3.0;
        brandLabel.layer.shadowOffset = CGSizeZero;
        self.desktopBrandLabel = brandLabel;
        [chrome addSubview:brandLabel];
        [self.rootView addSubview:chrome positioned:NSWindowAbove relativeTo:self.contentContainer];
    }
    [self applyApplicationIconTheme];
    [self layoutDesktopTopChrome];
}

- (void)installDesktopAccountSwitcherIfNeeded {
    if (!self.rootView) return;
    if (self.desktopAccountSwitcher && self.desktopAccountSwitcher.superview != self.rootView) {
        self.desktopAccountSwitcher = nil;
        self.desktopAccountTypePill = nil;
        self.desktopRemainingPlayTimePill = nil;
        self.desktopRemainingPlayTimeLabel = nil;
    }
    if (self.desktopAccountSwitcher) return;
    NSPopUpButton *switcher = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    switcher.target = self;
    switcher.action = @selector(desktopAccountSwitcherChanged:);
    switcher.bordered = NO;
    switcher.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    switcher.contentTintColor = OpnColor(OPN::kTextPrimary, 0.96);
    switcher.focusRingType = NSFocusRingTypeNone;
    switcher.wantsLayer = YES;
    switcher.layer.cornerRadius = 18.0;
    switcher.layer.backgroundColor = OpnColor(OPN::kBlack, 0.50).CGColor;
    switcher.layer.borderColor = NSColor.clearColor.CGColor;
    switcher.layer.borderWidth = 0.0;
    switcher.layer.shadowColor = NSColor.blackColor.CGColor;
    switcher.layer.shadowOpacity = 0.0;
    switcher.layer.shadowRadius = 0.0;
    switcher.layer.shadowOffset = CGSizeZero;
    self.desktopAccountSwitcher = switcher;
    [self.rootView addSubview:switcher positioned:NSWindowAbove relativeTo:self.desktopTopChromeView];

    NSButton *accountTypePill = [[NSButton alloc] initWithFrame:NSZeroRect];
    accountTypePill.bordered = NO;
    accountTypePill.bezelStyle = NSBezelStyleRegularSquare;
    accountTypePill.buttonType = NSButtonTypeMomentaryChange;
    accountTypePill.focusRingType = NSFocusRingTypeNone;
    accountTypePill.target = self;
    accountTypePill.action = @selector(desktopAccountTypePillClicked:);
    accountTypePill.title = @"";
    accountTypePill.wantsLayer = YES;
    accountTypePill.layer.cornerRadius = 10.0;
    accountTypePill.layer.backgroundColor = OpnColor(OPN::kBlack, 0.50).CGColor;
    accountTypePill.layer.borderColor = NSColor.clearColor.CGColor;
    accountTypePill.layer.borderWidth = 0.0;
    accountTypePill.layer.shadowColor = NSColor.blackColor.CGColor;
    accountTypePill.layer.shadowOpacity = 0.0;
    accountTypePill.layer.shadowRadius = 0.0;
    accountTypePill.layer.shadowOffset = CGSizeZero;
    self.desktopAccountTypePill = accountTypePill;
    [self.rootView addSubview:accountTypePill positioned:NSWindowAbove relativeTo:switcher];

    NSView *playTimePill = [[NSView alloc] initWithFrame:NSZeroRect];
    playTimePill.wantsLayer = YES;
    playTimePill.layer.cornerRadius = 14.0;
    playTimePill.layer.backgroundColor = OpnColor(OPN::kBlack, 0.50).CGColor;
    playTimePill.layer.borderColor = NSColor.clearColor.CGColor;
    playTimePill.layer.borderWidth = 0.0;
    playTimePill.layer.shadowColor = NSColor.blackColor.CGColor;
    playTimePill.layer.shadowOpacity = 0.0;
    playTimePill.layer.shadowRadius = 0.0;
    playTimePill.layer.shadowOffset = CGSizeZero;
    self.desktopRemainingPlayTimePill = playTimePill;

    NSTextField *playTimeLabel = OpnLabel(@"Playtime: --", NSZeroRect, 11.0, OpnColor(OPN::kTextPrimary, 0.92), NSFontWeightBold, NSTextAlignmentCenter);
    playTimeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.desktopRemainingPlayTimeLabel = playTimeLabel;
    [playTimePill addSubview:playTimeLabel];
    [self.rootView addSubview:playTimePill positioned:NSWindowAbove relativeTo:self.desktopTopChromeView];

    [self rebuildDesktopAccountSwitcher];
    [self layoutDesktopAccountSwitcher];
    [self updateDesktopAccountSwitcher];
}

- (void)installDesktopSettingsPillIfNeeded {
    if (!self.rootView) return;
    if (self.desktopSettingsPillButton && self.desktopSettingsPillButton.superview != self.rootView) {
        self.desktopSettingsPillButton = nil;
    }
    if (self.desktopSettingsPillButton) return;

    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.bordered = NO;
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.buttonType = NSButtonTypeToggle;
    button.focusRingType = NSFocusRingTypeNone;
    button.target = self;
    button.action = @selector(desktopSettingsPillClicked:);
    button.wantsLayer = YES;
    button.layer.backgroundColor = OpnColor(OPN::kBlack, 0.50).CGColor;
    button.layer.borderColor = NSColor.clearColor.CGColor;
    button.layer.borderWidth = 0.0;
    button.layer.shadowColor = NSColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.0;
    button.layer.shadowRadius = 0.0;
    button.layer.shadowOffset = CGSizeZero;
    self.desktopSettingsPillButton = button;
    [self.rootView addSubview:button positioned:NSWindowAbove relativeTo:self.desktopRemainingPlayTimePill ?: self.desktopTopChromeView];
    [self updateDesktopSettingsPill];
}

- (void)layoutDesktopTopChrome {
    if (!self.desktopTopChromeView || !self.rootView) return;
    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat height = NSHeight(self.rootView.bounds);
    CGFloat scale = OPNDesktopChromeScale(height);
    CGFloat chromeHeight = floor(140.0 * scale);
    self.desktopTopChromeView.frame = NSMakeRect(0.0, 0.0, width, chromeHeight);
    CGFloat brandX = MAX(48.0, floor(width * 0.024));
    NSFont *brandFont = [NSFont systemFontOfSize:18.0 * scale weight:NSFontWeightBlack];
    self.desktopBrandLabel.font = brandFont;
    self.desktopBrandLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:@"OpenNOW" attributes:@{
        NSFontAttributeName: brandFont,
        NSForegroundColorAttributeName: OpnColor(OPN::kTextPrimary),
        NSStrokeColorAttributeName: NSColor.blackColor,
        NSStrokeWidthAttributeName: @(-3.0),
    }];
    self.desktopBrandLabel.frame = NSMakeRect(brandX,
                                              floor((chromeHeight - 28.0 * scale) * 0.5),
                                              180.0 * scale,
                                              28.0 * scale);
}

- (void)layoutDesktopAccountSwitcher {
    if (!self.desktopAccountSwitcher || !self.rootView) return;
    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat scale = OPNDesktopChromeScale(NSHeight(self.rootView.bounds));
    CGFloat switcherWidth = MIN(180.0, MAX(150.0, width * 0.10));
    CGFloat controlHeight = floor(44.0 * scale);
    CGFloat accountX = MAX(24.0, width - switcherWidth - 58.0 * scale);
    CGFloat accountY = floor((140.0 * scale - controlHeight) * 0.5);
    self.desktopAccountSwitcher.frame = NSMakeRect(accountX, accountY, switcherWidth, controlHeight);
    CGFloat accountTypeHeight = floor(20.0 * scale);
    CGFloat accountTypeY = accountY + controlHeight + 6.0 * scale;
    self.desktopAccountTypePill.frame = NSMakeRect(accountX + 10.0 * scale, accountTypeY, switcherWidth - 20.0 * scale, accountTypeHeight);
    self.desktopAccountTypePill.layer.cornerRadius = accountTypeHeight * 0.5;
    CGFloat pillWidth = 172.0 * scale;
    self.desktopRemainingPlayTimePill.frame = NSMakeRect(accountX - pillWidth - 14.0 * scale, accountY, pillWidth, controlHeight);
    self.desktopRemainingPlayTimePill.layer.cornerRadius = controlHeight * 0.5;
    self.desktopRemainingPlayTimeLabel.font = [NSFont systemFontOfSize:11.0 * scale weight:NSFontWeightBold];
    self.desktopRemainingPlayTimeLabel.frame = NSInsetRect(self.desktopRemainingPlayTimePill.bounds, 12.0 * scale, 13.0 * scale);
}

- (void)layoutDesktopSettingsPill {
    if (!self.desktopSettingsPillButton || !self.rootView) return;
    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat scale = OPNDesktopChromeScale(NSHeight(self.rootView.bounds));
    CGFloat switcherWidth = MIN(180.0, MAX(150.0, width * 0.10));
    CGFloat controlHeight = floor(44.0 * scale);
    CGFloat buttonWidth = floor(124.0 * scale);
    CGFloat gap = 14.0 * scale;
    CGFloat accountX = MAX(24.0, width - switcherWidth - 58.0 * scale);
    CGFloat accountY = floor((140.0 * scale - controlHeight) * 0.5);
    CGFloat leftNeighborX = self.desktopRemainingPlayTimePill.hidden ? accountX : NSMinX(self.desktopRemainingPlayTimePill.frame);
    self.desktopSettingsPillButton.frame = NSMakeRect(MAX(24.0, leftNeighborX - buttonWidth - gap),
                                                       accountY,
                                                       buttonWidth,
                                                       controlHeight);
    self.desktopSettingsPillButton.layer.cornerRadius = controlHeight * 0.5;
}

- (void)updateDesktopTopChrome {
    [self installDesktopTopChromeIfNeeded];
    [self updateDesktopAccountSwitcher];
    [self updateDesktopSettingsPill];
    if (!self.desktopTopChromeView) return;
    BOOL visible = OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen);
    self.desktopTopChromeView.hidden = !visible;
    if (!visible) return;
    [self layoutDesktopTopChrome];
}

- (void)updateDesktopAccountSwitcher {
    [self installDesktopAccountSwitcherIfNeeded];
    if (!self.desktopAccountSwitcher) return;
    BOOL visible = OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen);
    self.desktopAccountSwitcher.hidden = !visible;
    NSString *accountType = [self.rootView.accountStatus ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL accountTypeVisible = visible && accountType.length > 0;
    self.desktopAccountTypePill.hidden = !accountTypeVisible;
    CGFloat scale = OPNDesktopChromeScale(NSHeight(self.rootView.bounds));
    NSString *accountTypeTitle = accountType.length > 0 ? [accountType stringByAppendingString:@" Account"] : @"";
    self.desktopAccountTypePill.attributedTitle = [[NSAttributedString alloc] initWithString:accountTypeTitle attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:9.5 * scale weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: OpnColor(OPN::kTextPrimary, 0.96),
    }];
    NSString *remainingPlayTime = [self.rootView.remainingPlayTime ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL playTimeVisible = visible && remainingPlayTime.length > 0;
    self.desktopRemainingPlayTimePill.hidden = !playTimeVisible;
    self.desktopRemainingPlayTimeLabel.stringValue = remainingPlayTime.length > 0 ? [@"Playtime: " stringByAppendingString:remainingPlayTime] : @"Playtime: --";
    if (!visible) return;
    [self layoutDesktopAccountSwitcher];
    [self layoutDesktopSettingsPill];
}

- (void)updateDesktopSettingsPill {
    [self installDesktopSettingsPillIfNeeded];
    if (!self.desktopSettingsPillButton) return;
    BOOL visible = OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen);
    self.desktopSettingsPillButton.hidden = !visible;
    if (!visible) return;

    BOOL selected = self.currentScreen == OPN::AuthScreen::Settings;
    self.desktopSettingsPillButton.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
    NSColor *textColor = selected ? OpnColor(OPN::kBlack, 0.96) : OpnColor(OPN::kTextPrimary, 0.96);
    NSColor *backgroundColor = selected ? OpnColor(OPN::kBrandGreen, 0.94) : OpnColor(OPN::kBlack, 0.50);
    NSFont *font = [NSFont systemFontOfSize:12.0 * OPNDesktopChromeScale(NSHeight(self.rootView.bounds)) weight:NSFontWeightBold];
    self.desktopSettingsPillButton.layer.backgroundColor = backgroundColor.CGColor;
    self.desktopSettingsPillButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"Settings" attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor,
    }];
    [self layoutDesktopSettingsPill];
}

- (void)rebuildDesktopAccountSwitcher {
    if (!self.desktopAccountSwitcher) return;
    [self.desktopAccountSwitcher removeAllItems];

    std::string currentIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    NSString *currentIdentifierString = currentIdentifier.empty() ? @"" : [NSString stringWithUTF8String:currentIdentifier.c_str()];
    NSInteger selectedIndex = 0;
    BOOL addedAnyAccount = NO;

    for (const OPN::AuthSession &session : OPN::AuthService::Shared().LoadSavedSessions()) {
        std::string identifier = OPNAuthSessionIdentifier(session);
        if (identifier.empty()) continue;
        NSString *identifierString = [NSString stringWithUTF8String:identifier.c_str()];
        BOOL isCurrentSession = [identifierString isEqualToString:currentIdentifierString];
        NSString *label = isCurrentSession ? OPNAuthSessionDisplayName(self.currentSession) : OPNAuthSessionDisplayName(session);
        [self.desktopAccountSwitcher addItemWithTitle:label];
        NSMenuItem *item = self.desktopAccountSwitcher.lastItem;
        item.representedObject = identifierString;
        item.image = OPNAccountSwitcherImageForSession(isCurrentSession ? self.currentSession : session, isCurrentSession ? self.rootView.accountAvatarImage : nil);
        if (isCurrentSession) selectedIndex = self.desktopAccountSwitcher.numberOfItems - 1;
        addedAnyAccount = YES;
    }

    if (!addedAnyAccount && self.currentSession.isAuthenticated) {
        [self.desktopAccountSwitcher addItemWithTitle:OPNAuthSessionDisplayName(self.currentSession)];
        self.desktopAccountSwitcher.lastItem.representedObject = currentIdentifierString;
        self.desktopAccountSwitcher.lastItem.image = OPNAccountSwitcherImageForSession(self.currentSession, self.rootView.accountAvatarImage);
    }

    if (self.desktopAccountSwitcher.numberOfItems > 0) {
        [[self.desktopAccountSwitcher menu] addItem:[NSMenuItem separatorItem]];
    }
    [self.desktopAccountSwitcher addItemWithTitle:@"Add Account..." ];
    self.desktopAccountSwitcher.lastItem.representedObject = @"__opennow_add_account__";

    if (selectedIndex >= 0 && selectedIndex < self.desktopAccountSwitcher.numberOfItems) {
        [self.desktopAccountSwitcher selectItemAtIndex:selectedIndex];
    }
}

- (void)desktopAccountSwitcherChanged:(NSPopUpButton *)sender {
    id representedObject = sender.selectedItem.representedObject;
    NSString *identifier = [representedObject isKindOfClass:NSString.class] ? representedObject : @"";
    if ([identifier isEqualToString:@"__opennow_add_account__"]) {
        [self addAccount];
        return;
    }
    [self switchToAccountIdentifier:identifier];
    [self rebuildDesktopAccountSwitcher];
}

- (void)startDesktopControllerPolling {
    if (self.desktopControllerTimer) return;
    self.desktopControllerPreviousButtons = 0;
    self.desktopControllerHeldDirections = 0;
    self.desktopControllerLastRepeatTime = 0.0;
    self.desktopControllerTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                                   target:self
                                                                 selector:@selector(pollDesktopController:)
                                                                 userInfo:nil
                                                                  repeats:YES];
}

- (void)stopDesktopControllerPolling {
    [self.desktopControllerTimer invalidate];
    self.desktopControllerTimer = nil;
    self.desktopControllerPreviousButtons = 0;
    self.desktopControllerHeldDirections = 0;
    self.desktopControllerLastRepeatTime = 0.0;
}

- (void)pollDesktopController:(NSTimer *)timer {
    (void)timer;
    if (!OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen) ||
        self.activeSessionPromptView ||
        self.cloudmatchServerPickerView ||
        self.streamDashboardHomeVisible ||
        (self.streamingController && self.window.contentViewController == self.streamingController)) {
        self.desktopControllerPreviousButtons = 0;
        self.desktopControllerHeldDirections = 0;
        return;
    }

    uint16_t buttons = OPNDesktopGamepadButtons();
    uint16_t pressed = buttons & ~self.desktopControllerPreviousButtons;
    uint16_t directions = buttons & OPNDesktopGamepadDirectionMask;
    CFTimeInterval now = CACurrentMediaTime();
    if (directions == 0) {
        self.desktopControllerHeldDirections = 0;
        self.desktopControllerLastRepeatTime = 0.0;
    } else if (directions != self.desktopControllerHeldDirections || now - self.desktopControllerLastRepeatTime >= 0.18) {
        self.desktopControllerHeldDirections = directions;
        self.desktopControllerLastRepeatTime = now;
        [self routeDesktopGamepadButtons:directions];
    }

    uint16_t actions = pressed & (OPNDesktopGamepadButtonA | OPNDesktopGamepadButtonB | OPNDesktopGamepadButtonY);
    if (actions != 0) [self routeDesktopGamepadButtons:actions];
    self.desktopControllerPreviousButtons = buttons;
}

- (void)routeDesktopGamepadButtons:(uint16_t)buttons {
    if (buttons & OPNDesktopGamepadButtonB) {
        if (self.currentScreen == OPN::AuthScreen::Settings) {
            [self transitionToScreen:OPN::AuthScreen::Store];
        }
        return;
    }

    if (self.currentScreen == OPN::AuthScreen::Catalog) {
        if (buttons & OPNDesktopGamepadButtonLeft) [self.catalogView moveGamepadFocusBy:-1];
        if (buttons & OPNDesktopGamepadButtonRight) [self.catalogView moveGamepadFocusBy:1];
        if (buttons & OPNDesktopGamepadButtonY) [self.catalogView cycleFocusedGamepadVariant];
        if (buttons & OPNDesktopGamepadButtonA) [self.catalogView activateGamepadFocus];
        return;
    }

    if (self.currentScreen == OPN::AuthScreen::Store) {
        NSInteger rowDelta = 0;
        NSInteger columnDelta = 0;
        if (buttons & OPNDesktopGamepadButtonUp) rowDelta -= 1;
        if (buttons & OPNDesktopGamepadButtonDown) rowDelta += 1;
        if (buttons & OPNDesktopGamepadButtonLeft) columnDelta -= 1;
        if (buttons & OPNDesktopGamepadButtonRight) columnDelta += 1;
        if (rowDelta != 0 || columnDelta != 0) [self.storeView moveGamepadFocusByRows:rowDelta columns:columnDelta];
        if (buttons & OPNDesktopGamepadButtonY) [self.storeView cycleFocusedGamepadVariant];
        if (buttons & OPNDesktopGamepadButtonA) [self.storeView activateGamepadFocus];
        return;
    }

    if (self.currentScreen == OPN::AuthScreen::Settings) {
        NSInteger delta = 0;
        if (buttons & OPNDesktopGamepadButtonUp) delta -= 1;
        if (buttons & OPNDesktopGamepadButtonDown) delta += 1;
        if (delta != 0) [self.settingsView moveGamepadSelectionBy:delta];
        if (buttons & OPNDesktopGamepadButtonA) [self.settingsView activateGamepadSelection];
    }
}

@end
