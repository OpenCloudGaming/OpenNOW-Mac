#pragma once

#import "../OPNAppDelegate.h"
#import "../auth/OPNAuthService.h"
#import "../games/OPNGameService.h"
#import "../streaming/OPNStreamViewController.h"
#include "../streaming/OPNSessionManager.h"
#include "../streaming/OPNStreamPreferences.h"
#import "../views/OPNBackdropView.h"
#import "../views/OPNEmailEntryView.h"
#import "../views/OPNAuthenticatingView.h"
#import "../views/OPNErrorView.h"
#import "../views/OPNGameCatalogView.h"
#import "../views/OPNSettingsView.h"
#import "../views/OPNSessionReportView.h"
#import "../views/OPNCloudmatchServerPickerView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#include "../common/OPNLogCapture.h"
#include "../common/OPNLocale.h"
#include "../common/OPNDiscordPresence.h"
#include "../common/OPNGFNError.h"
#include "../common/OPNGameRemediation.h"
#import "../common/OPNGitHubUpdater.h"
#import "../common/OPNAuthTypes.h"
#import "../common/OPNGameTypes.h"
#import <CommonCrypto/CommonDigest.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <memory>
#include <unordered_set>
#include "../common/OPNSentry.h"

struct OPNSyncObservation {
    bool hasData = false;
    int totalNumberOfSyncedGfnGames = 0;
    std::string syncState;
    std::string syncDate;
};

@interface AppDelegate ()
@property (nonatomic, strong) OPNBackdropView *rootView;
@property (nonatomic, strong) OPNGameCatalogView *catalogView;
@property (nonatomic, strong) OPNSettingsView *settingsView;
@property (nonatomic, strong) OPNGameCatalogView *storeView;
@property (nonatomic, strong) OPNStreamViewController *streamingController;
@property (nonatomic, strong) OPNSessionReportView *sessionReportView;
@property (nonatomic, copy) NSString *currentStreamTitle;
@property (nonatomic, assign) OPN::AuthScreen activeStreamReturnScreen;
@property (nonatomic, assign) BOOL streamDashboardHomeVisible;
@property (nonatomic, strong) NSTimer *streamDashboardControllerTimer;
@property (nonatomic, assign) CFTimeInterval streamDashboardStartHoldBegan;
@property (nonatomic, assign) BOOL streamDashboardStartHoldConsumed;
@property (nonatomic, strong) NSTimer *gameLibraryRefreshTimer;
@property (nonatomic, assign) std::vector<OPN::GameInfo> cachedGameLibrary;
@property (nonatomic, assign) std::vector<OPN::GameInfo> cachedFeaturedGames;
@property (nonatomic, assign) std::vector<OPN::PanelResult> cachedStorePanels;
@property (nonatomic, assign) std::string cachedGameLibraryFingerprint;
@property (nonatomic, assign) std::string cachedGameLibraryAccountIdentifier;
@property (nonatomic, assign) std::string cachedFeaturedGamesAccountIdentifier;
@property (nonatomic, assign) std::string cachedStorePanelsAccountIdentifier;
@property (nonatomic, assign) BOOL hasCachedGameLibrary;
@property (nonatomic, assign) BOOL hasCachedFeaturedGames;
@property (nonatomic, assign) BOOL hasCachedStorePanels;
@property (nonatomic, assign) BOOL gameLibraryRefreshInFlight;
@property (nonatomic, assign) BOOL featuredGamesRefreshInFlight;
@property (nonatomic, assign) BOOL activeSessionsRefreshInFlight;
@property (nonatomic, strong) NSView *ownershipSyncOverlayView;
@property (nonatomic, strong) NSTextField *ownershipSyncTitleLabel;
@property (nonatomic, strong) NSTextField *ownershipSyncMessageLabel;
@property (nonatomic, strong) NSTextField *ownershipSyncFooterLabel;
@property (nonatomic, strong) NSProgressIndicator *ownershipSyncSpinner;
@property (nonatomic, assign) NSInteger catalogBrowseGeneration;
@property (nonatomic, assign) BOOL activeSessionResumeInFlight;
@property (nonatomic, assign) NSInteger activeSessionResumeGeneration;
@property (nonatomic, strong) NSView *activeSessionPromptView;
@property (nonatomic, copy) void (^activeSessionContinueHandler)(void);
@property (nonatomic, copy) void (^activeSessionDeleteHandler)(void);
@property (nonatomic, strong) NSTimer *activeSessionPromptControllerTimer;
@property (nonatomic, assign) uint16_t activeSessionPromptPreviousButtons;
@property (nonatomic, strong) OPNCloudmatchServerPickerView *cloudmatchServerPickerView;
@property (nonatomic, assign) NSInteger cloudmatchServerPickerGeneration;
@property (nonatomic, assign) NSInteger gameLaunchGeneration;
@property (nonatomic, strong) NSView *desktopTopChromeView;
@property (nonatomic, strong) NSTextField *desktopBrandLabel;
@property (nonatomic, strong) NSPopUpButton *desktopAccountSwitcher;
@property (nonatomic, strong) NSButton *desktopAccountTypePill;
@property (nonatomic, strong) NSView *desktopRemainingPlayTimePill;
@property (nonatomic, strong) NSTextField *desktopRemainingPlayTimeLabel;
@property (nonatomic, strong) NSButton *desktopSettingsPillButton;
@property (nonatomic, assign) double currentRemainingPlayTimeHours;
@property (nonatomic, assign) BOOL currentRemainingPlayTimeUnlimited;
@property (nonatomic, assign) BOOL currentRemainingPlayTimeAvailable;
@property (nonatomic, strong) OPNGitHubUpdater *githubUpdater;
@property (nonatomic, strong) NSTimer *applicationUpdateCheckTimer;
@property (nonatomic, assign) BOOL updateCheckInFlight;
@property (nonatomic, strong) NSTimer *desktopControllerTimer;
@property (nonatomic, assign) uint16_t desktopControllerPreviousButtons;
@property (nonatomic, assign) uint16_t desktopControllerHeldDirections;
@property (nonatomic, assign) CFTimeInterval desktopControllerLastRepeatTime;
- (void)configureContentContainerForScreen:(OPN::AuthScreen)screen;
- (void)completeContentTransitionFromSubviews:(NSArray<NSView *> *)previousSubviews
                                       toView:(NSView *)view
                                     animated:(BOOL)animated
                                      forward:(BOOL)forward;
- (void)refreshAccountSummary;
- (void)refreshAccountSummaryWithRetry:(BOOL)canRetry;
- (void)refreshAccountAvatar;
- (void)refreshStreamRegions;
- (void)refreshAccountMenu;
- (void)transitionToStoreAfterProviderSelectionForSession:(const OPN::AuthSession &)session;
- (void)addAccount;
- (void)switchToAccountIdentifier:(NSString *)identifier;
- (void)restoreSavedWindowPresentation;
- (void)saveWindowPresentation;
- (void)startGameLibraryRefreshTimer;
- (void)stopGameLibraryRefreshTimer;
- (BOOL)hasVisibleStreamingController;
- (void)toggleStreamDashboardHome;
- (void)showStreamDashboardHome;
- (void)restoreVisibleStreamFromDashboard;
- (void)startStreamDashboardControllerPolling;
- (void)stopStreamDashboardControllerPolling;
- (void)pollStreamDashboardController:(NSTimer *)timer;
- (void)showActiveSessionPromptWithSessionTitle:(NSString *)sessionTitle
                              selectedGameTitle:(NSString *)selectedGameTitle
                                continueHandler:(void (^)(void))continueHandler
                                  deleteHandler:(void (^)(void))deleteHandler;
- (void)dismissActiveSessionPrompt;
- (void)startActiveSessionPromptControllerPolling;
- (void)stopActiveSessionPromptControllerPolling;
- (void)pollActiveSessionPromptController;
- (void)activeSessionContinueClicked:(id)sender;
- (void)activeSessionDeleteClicked:(id)sender;
- (void)showCloudmatchServerPickerForGameTitle:(NSString *)gameTitle
                                      apiToken:(const std::string &)apiToken
                                    completion:(void (^)(BOOL confirmed))completion;
- (void)refreshCloudmatchServerPickerWithToken:(const std::string &)apiToken
                                    generation:(NSInteger)generation;
- (void)dismissCloudmatchServerPicker;
- (void)launchGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex returnScreen:(OPN::AuthScreen)returnScreen;
- (void)openPurchaseURL:(NSString *)purchaseURL forGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex;
- (void)configureGameServiceTokensForSession:(const OPN::AuthSession &)session;
- (void)refreshOwnershipAuthWithCompletion:(void (^)(BOOL refreshed))completion;
- (void)showOwnershipSyncProgressForGameTitle:(NSString *)gameTitle storeName:(NSString *)storeName;
- (void)updateOwnershipSyncProgressMessage:(NSString *)message;
- (void)updateOwnershipSyncProgressFooter:(NSString *)footer;
- (void)dismissOwnershipSyncProgress;
- (BOOL)presentOwnershipRemediationIfNeededForGame:(const OPN::GameInfo &)game
                                       variantIndex:(int)variantIndex
                                      returnScreen:(OPN::AuthScreen)returnScreen
                                      accountLinked:(bool)accountLinked
                                    continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)presentOwnershipOptionsForGame:(const OPN::GameInfo &)game
                           variantIndex:(int)variantIndex
                          returnScreen:(OPN::AuthScreen)returnScreen
                       storeDefinitions:(const std::vector<OPN::StoreDefinition> &)storeDefinitions
                            userAccount:(const OPN::UserAccountInfo &)userAccount
                        continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)autoResyncOwnershipForGame:(const OPN::GameInfo &)game
                       variantIndex:(int)variantIndex
                      returnScreen:(OPN::AuthScreen)returnScreen
                            stores:(const std::vector<std::string> &)stores
                  storeDefinitions:(const std::vector<OPN::StoreDefinition> &)storeDefinitions
                     retryingAuth:(BOOL)retryingAuth
                   continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)monitorAutoResyncOwnershipForGame:(const OPN::GameInfo &)game
                             variantIndex:(int)variantIndex
                          returnScreen:(OPN::AuthScreen)returnScreen
                                  stores:(const std::vector<std::string> &)stores
                              baselines:(const std::vector<OPNSyncObservation> &)baselines
                             deadlineAt:(NSDate *)deadlineAt
                                 attempt:(NSInteger)attempt
                         continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler
                         fallbackHandler:(void (^)(void))fallbackHandler;
- (void)markVariantOwnedForGame:(const OPN::GameInfo &)game
                    variantIndex:(int)variantIndex
                 continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)markVariantUnownedForGame:(const OPN::GameInfo &)game
                      variantIndex:(int)variantIndex;
- (void)syncOwnershipForGame:(const OPN::GameInfo &)game
                 variantIndex:(int)variantIndex
                        store:(const std::string &)store
                retryingAuth:(BOOL)retryingAuth
              continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)linkAccountForGame:(const OPN::GameInfo &)game
              variantIndex:(int)variantIndex
                     store:(const std::string &)store
             syncAfterLink:(BOOL)syncAfterLink
              retryingAuth:(BOOL)retryingAuth
           continueHandler:(void (^)(bool accountLinkedForLaunch))continueHandler;
- (void)refreshLibraryAfterOwnershipChangeForGame:(const OPN::GameInfo &)game
                                     variantIndex:(int)variantIndex
                                        requireGame:(BOOL)requireGame
                                        completion:(void (^)(BOOL ownedAfterRefresh))completion;
- (void)monitorOwnershipSyncForGame:(const OPN::GameInfo &)game
                        variantIndex:(int)variantIndex
                               store:(const std::string &)store
                            baseline:(const OPNSyncObservation &)baseline
                          deadlineAt:(NSDate *)deadlineAt
                              attempt:(NSInteger)attempt
                           completion:(void (^)(BOOL ownedAfterRefresh, NSString *failureMessage))completion;
- (void)startStreamWithTitle:(const std::string &)title
                       appId:(const std::string &)appId
                    apiToken:(const std::string &)apiToken
               accountLinked:(bool)accountLinked
                selectedStore:(const std::string &)selectedStore
                returnScreen:(OPN::AuthScreen)returnScreen
              resumeSessionId:(const std::string &)resumeSessionId
                  resumeServer:(const std::string &)resumeServer;
- (void)checkForActiveSessionResumeIfNeededForScreen:(OPN::AuthScreen)screen;
- (void)restartApplication;
- (void)loadStorePanelsWithRetry:(BOOL)canRetry;
- (void)refreshGameLibraryInBackground;
- (void)fetchGameLibraryWithRetry:(BOOL)canRetry
                        completion:(void (^)(BOOL success, const std::vector<OPN::GameInfo> &games))completion;
- (void)refreshFeaturedGamesForCatalogWithRetry:(BOOL)canRetry;
- (void)refreshActiveSessionsForCatalog;
- (void)browseCatalogWithSearch:(NSString *)searchQuery
                          sortId:(NSString *)sortId
                       filterIds:(const std::vector<std::string> &)filterIds
                         canRetry:(BOOL)canRetry;
- (void)browseCatalogWithSearch:(NSString *)searchQuery
                          sortId:(NSString *)sortId
                       filterIds:(const std::vector<std::string> &)filterIds
                         canRetry:(BOOL)canRetry
                     retryAttempt:(NSInteger)retryAttempt;
- (void)applyApplicationIconTheme;
- (void)applyInterfacePreferencesToCurrentScreen;
- (void)windowGeometryChanged:(NSNotification *)notification;
- (void)installDesktopTopChromeIfNeeded;
- (void)installDesktopAccountSwitcherIfNeeded;
- (void)installDesktopSettingsPillIfNeeded;
- (void)layoutDesktopTopChrome;
- (void)layoutDesktopAccountSwitcher;
- (void)layoutDesktopSettingsPill;
- (void)updateDesktopTopChrome;
- (void)updateDesktopAccountSwitcher;
- (void)updateDesktopSettingsPill;
- (void)rebuildDesktopAccountSwitcher;
- (void)desktopAccountSwitcherChanged:(NSPopUpButton *)sender;
- (void)desktopSettingsPillClicked:(NSButton *)sender;
- (void)startApplicationUpdateChecks;
- (void)stopApplicationUpdateChecks;
- (void)applicationUpdateCheckTimerFired:(NSTimer *)timer;
- (void)checkForApplicationUpdates;
- (void)checkForApplicationUpdatesShowingCurrentStatus:(BOOL)showCurrentStatus;
- (void)installMainMenu;
- (void)showSettingsFromMenu:(id)sender;
- (void)refreshLibraryFromMenu:(id)sender;
- (void)checkForUpdatesFromMenu:(id)sender;
- (void)openAccountManagementFromMenu:(id)sender;
- (void)openOpenNOWWebsiteFromMenu:(id)sender;
- (void)startDesktopControllerPolling;
- (void)stopDesktopControllerPolling;
- (void)pollDesktopController:(NSTimer *)timer;
- (void)routeDesktopGamepadButtons:(uint16_t)buttons;
- (void)transitionToScreen:(OPN::AuthScreen)screen;
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem;
- (void)windowFullScreenStateChanged:(NSNotification *)notification;
- (void)interfacePreferencesChanged:(NSNotification *)notification;
- (void)desktopAccountTypePillClicked:(NSButton *)sender;
- (void)gameLibraryRefreshTimerFired:(NSTimer *)timer;
- (void)loadGamesIntoCatalog;
- (void)loadGamesIntoCatalogWithRetry:(BOOL)canRetry;
- (void)performServerLogout;
- (void)showAuthenticatingWithMessage:(NSString *)message;
- (void)showError:(const std::string &)errorMessage canRetry:(BOOL)canRetry;
- (void)showSessionReport:(const OPN::SessionHealthReport &)report;
- (void)installLibraryRootIfNeeded;
@end

static NSString *const OPNMainWindowFrameAutosaveName = @"OpenNOW.MainWindowFrame";
static NSString *const OPNMainWindowWasFullScreenKey = @"OpenNOW.MainWindowWasFullScreen";

static BOOL OPNWindowIsFullScreen(NSWindow *window) {
    return window && ((window.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen);
}

static NSString *OPNMetricScreenName(OPN::AuthScreen screen) {
    switch (screen) {
        case OPN::AuthScreen::EmailEntry: return @"email_entry";
        case OPN::AuthScreen::Authenticating: return @"authenticating";
        case OPN::AuthScreen::Store: return @"store";
        case OPN::AuthScreen::Catalog: return @"catalog";
        case OPN::AuthScreen::Settings: return @"settings";
        case OPN::AuthScreen::Error: return @"error";
        case OPN::AuthScreen::OAuthBrowser: return @"oauth_browser";
    }
    return @"unknown";
}

static BOOL OPNAppDelegateScreenSupportsDesktopNavigation(OPN::AuthScreen screen) {
    return screen == OPN::AuthScreen::Catalog || screen == OPN::AuthScreen::Store || screen == OPN::AuthScreen::Settings;
}

typedef NS_OPTIONS(uint16_t, OPNDesktopGamepadButton) {
    OPNDesktopGamepadButtonUp = 1u << 0,
    OPNDesktopGamepadButtonDown = 1u << 1,
    OPNDesktopGamepadButtonLeft = 1u << 2,
    OPNDesktopGamepadButtonRight = 1u << 3,
    OPNDesktopGamepadButtonA = 1u << 4,
    OPNDesktopGamepadButtonB = 1u << 5,
    OPNDesktopGamepadButtonY = 1u << 6,
};

static const uint16_t OPNDesktopGamepadDirectionMask = OPNDesktopGamepadButtonUp |
    OPNDesktopGamepadButtonDown |
    OPNDesktopGamepadButtonLeft |
    OPNDesktopGamepadButtonRight;

static NSArray<NSString *> *OPNDesktopBrandIconRelativePaths(void) {
    switch (OpnAppIconThemePreference()) {
        case OPNAppIconThemeGreen:
            return @[
                @"assets/OpenNOW.icns",
                @"assets/logo-mac.png",
                @"assets/logo.png",
            ];
        case OPNAppIconThemeBlue:
            return @[
                @"assets/OpenNOW-SkyBlue.icns",
                @"assets/logo-mac-SkyBlue.png",
                @"assets/OpenNOW.icns",
                @"assets/logo-mac.png",
                @"assets/logo.png",
            ];
        case OPNAppIconThemeBlack:
        default:
            return @[
                @"assets/OpenNOW-Black.icns",
                @"assets/logo-mac-Black.png",
                @"assets/OpenNOW.icns",
                @"assets/logo-mac.png",
                @"assets/logo.png",
            ];
    }
}

static NSImage *OPNDesktopBrandIconImage() {
    OPNAppIconTheme theme = OpnAppIconThemePreference();
    NSString *bundleResource = @"OpenNOW-Black";
    if (theme == OPNAppIconThemeGreen) bundleResource = @"OpenNOW";
    if (theme == OPNAppIconThemeBlue) bundleResource = @"OpenNOW-SkyBlue";
    NSString *bundleIconPath = [[NSBundle mainBundle] pathForResource:bundleResource ofType:@"icns"];
    NSImage *bundleIcon = bundleIconPath.length > 0 ? [[NSImage alloc] initWithContentsOfFile:bundleIconPath] : nil;
    if (bundleIcon) return bundleIcon;

    NSString *workingDirectory = NSFileManager.defaultManager.currentDirectoryPath;
    for (NSString *relativePath in OPNDesktopBrandIconRelativePaths()) {
        NSString *path = [workingDirectory stringByAppendingPathComponent:relativePath];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
        if (image) return image;
    }
    return nil;
}

static CGFloat OPNDesktopChromeScale(CGFloat height) {
    return MIN(1.0, MAX(0.80, MAX(1.0, height) / 900.0));
}

static NSSize OPNResizableWindowMaxSize() {
    return NSMakeSize(16000.0, 16000.0);
}

static void OPNConfigureResizableWindow(NSWindow *window, NSSize minSize, NSSize maxSize) {
    window.styleMask = window.styleMask | NSWindowStyleMaskResizable;
    window.collectionBehavior = window.collectionBehavior | NSWindowCollectionBehaviorFullScreenPrimary;
    NSRect minFrame = [window frameRectForContentRect:NSMakeRect(0, 0, minSize.width, minSize.height)];
    window.minSize = minFrame.size;
    window.maxSize = maxSize;
    window.contentMinSize = minSize;
    window.contentMaxSize = maxSize;
    window.resizeIncrements = NSMakeSize(1.0, 1.0);
    window.contentResizeIncrements = NSMakeSize(1.0, 1.0);
}

static void OPNConfigureLibraryWindow(NSWindow *window) {
    OPNConfigureResizableWindow(window,
                                NSMakeSize(OPN::kWindowMinWidth, OPN::kWindowMinHeight),
                                OPNResizableWindowMaxSize());
    window.styleMask = window.styleMask | NSWindowStyleMaskFullSizeContentView;
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    [window standardWindowButton:NSWindowCloseButton].hidden = NO;
    [window standardWindowButton:NSWindowMiniaturizeButton].hidden = NO;
    [window standardWindowButton:NSWindowZoomButton].hidden = NO;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = OpnColor(OPN::kBackground);
}

static void OPNConfigureStreamWindow(NSWindow *window) {
    OPNConfigureResizableWindow(window,
                                NSMakeSize(OPN::kWindowMinWidth, OPN::kWindowMinHeight),
                                OPNResizableWindowMaxSize());
}

static NSString *OPNDisplayTier(const std::string &tier) {
    NSString *raw = tier.empty() ? @"Free" : [NSString stringWithUTF8String:tier.c_str()];
    NSString *upper = raw.uppercaseString;
    if ([upper isEqualToString:@"ULTIMATE"]) return @"Ultimate";
    if ([upper isEqualToString:@"PRIORITY"] || [upper isEqualToString:@"PERFORMANCE"]) return @"Priority";
    if ([upper isEqualToString:@"FREE"]) return @"Free";
    return raw.capitalizedString;
}

static NSString *const OPNAccountManagementURLString = @"https://www.nvidia.com/en-us/account/gfn/manage/";

static NSString *OPNFormatHours(double hours) {
    if (!std::isfinite(hours) || hours < 0) hours = 0;
    NSInteger totalMinutes = MAX(0, (NSInteger)llround(hours * 60.0));
    NSInteger wholeHours = totalMinutes / 60;
    NSInteger minutes = totalMinutes % 60;
    return [NSString stringWithFormat:@"%ldh %02ldm", (long)wholeHours, (long)minutes];
}

static NSString *OPNFormatRemainingPlayTime(const OPN::SubscriptionInfo &subscription) {
    if (subscription.isUnlimited) return @"Unlimited";
    return [NSString stringWithFormat:@"%@ left", OPNFormatHours(subscription.remainingHours)];
}

static std::string OPNAuthSessionIdentifier(const OPN::AuthSession &session) {
    if (!session.userId.empty()) return session.userId;
    if (!session.email.empty()) return session.email;
    if (!session.displayName.empty()) return session.displayName;
    return session.accessToken;
}

static bool OPNSessionProbeAuthenticationError(const std::string &error) {
    return error.find("HTTP 401") != std::string::npos ||
           error.find("HTTP 403") != std::string::npos ||
           error.find("AUTH_FAILURE") != std::string::npos ||
           error.find("auth_failure") != std::string::npos ||
           error.find("No access token") != std::string::npos;
}

static NSString *OPNAuthSessionDisplayName(const OPN::AuthSession &session) {
    if (!session.displayName.empty()) return [NSString stringWithUTF8String:session.displayName.c_str()];
    if (!session.email.empty()) {
        NSString *email = [NSString stringWithUTF8String:session.email.c_str()];
        NSString *localPart = [email componentsSeparatedByString:@"@"].firstObject;
        return localPart.length > 0 ? localPart : email;
    }
    if (!session.userId.empty()) return [NSString stringWithUTF8String:session.userId.c_str()];
    return @"Account";
}

static BOOL OPNStringLooksLikeEmail(NSString *value) {
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange atRange = [trimmed rangeOfString:@"@"];
    if (atRange.location == NSNotFound || atRange.location == 0 || NSMaxRange(atRange) >= trimmed.length) return NO;
    return [[trimmed substringFromIndex:NSMaxRange(atRange)] containsString:@"."];
}

static NSMenuItem *OPNMenuItem(NSString *title, SEL action, NSString *keyEquivalent, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEquivalent ?: @""];
    item.target = target;
    return item;
}

static NSMenuItem *OPNMenuItemWithModifier(NSString *title, SEL action, NSString *keyEquivalent, NSEventModifierFlags modifiers, id target) {
    NSMenuItem *item = OPNMenuItem(title, action, keyEquivalent, target);
    item.keyEquivalentModifierMask = modifiers;
    return item;
}

static void OPNOpenExternalURLString(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url || url.scheme.length == 0 || url.host.length == 0 || ![NSWorkspace.sharedWorkspace openURL:url]) {
        OPN::LogError(@"[AppDelegate] Failed to open URL: %@", urlString ?: @"");
        NSBeep();
    }
}

static NSString *OPNDisplayNameFromUserInfo(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    NSString *value = [info[@"preferred_username"] isKindOfClass:NSString.class] ? info[@"preferred_username"] : nil;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
}

static NSString *OPNGravatarURLStringForEmail(const std::string &email) {
    if (email.empty()) return nil;
    NSString *rawEmail = [NSString stringWithUTF8String:email.c_str()];
    NSString *normalized = [[rawEmail stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (normalized.length == 0) return nil;

    const char *utf8 = normalized.UTF8String;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(utf8, (CC_LONG)strlen(utf8), digest);
#pragma clang diagnostic pop
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithFormat:@"https://www.gravatar.com/avatar/%@?s=96&d=identicon", hash];
}

static NSImage *OPNAccountSwitcherImageForSession(const OPN::AuthSession &session, NSImage *currentAvatar) {
    (void)session;
    if (currentAvatar) {
        NSImage *image = [currentAvatar copy];
        image.size = NSMakeSize(22.0, 22.0);
        return image;
    }
    return nil;
}

static bool OPNIsTransientNetworkLostError(const std::string &error) {
    if (error.empty()) return false;
    std::string lower = error;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char value) {
        return (char)std::tolower(value);
    });
    return lower.find("network connection was lost") != std::string::npos ||
           lower.find("nsurlerrornetworkconnectionlost") != std::string::npos ||
           lower.find("-1005") != std::string::npos;
}

static bool OPNIsUnauthorizedError(const std::string &error) {
    return error.find("401") != std::string::npos;
}

static bool OPNIsNotFoundError(const std::string &error) {
    return error.find("404") != std::string::npos;
}

static constexpr NSTimeInterval OPNOwnershipSyncMonitorTimeoutSeconds = 15.0;
static constexpr NSTimeInterval OPNOwnershipSyncPollIntervalSeconds = 3.0;

static bool OPNSyncStateSucceeded(const std::string &syncState) {
    return syncState == "SYNC_SUCCESS";
}

static bool OPNSyncStateFailed(const std::string &syncState) {
    return syncState == "SYNC_DENIED" || syncState == "PROFILE_NOT_CREATED" || syncState == "SYNC_FAILED";
}

static bool OPNSyncObservationChanged(const OPNSyncObservation &current, const OPNSyncObservation &baseline) {
    if (!current.hasData || !baseline.hasData) return false;
    return current.syncState != baseline.syncState ||
        current.syncDate != baseline.syncDate ||
        current.totalNumberOfSyncedGfnGames != baseline.totalNumberOfSyncedGfnGames;
}

static bool OPNSyncObservationHasFreshState(const OPNSyncObservation &current, const OPNSyncObservation &baseline) {
    if (!current.hasData) return false;
    if (!baseline.hasData) return false;
    return OPNSyncObservationChanged(current, baseline);
}

static bool OPNStoreStringEquals(const std::string &lhs, const std::string &rhs);
static const OPN::StoreAccountInfo *OPNStoreAccountForStore(const OPN::UserAccountInfo &accountInfo,
                                                            const std::string &store);

static OPNSyncObservation OPNSyncObservationForStore(const OPN::UserAccountInfo &accountInfo,
                                                     const std::string &store) {
    OPNSyncObservation observation;
    const OPN::StoreAccountInfo *account = OPNStoreAccountForStore(accountInfo, store);
    if (!account || !account->hasAccountSyncingData) return observation;
    observation.hasData = true;
    observation.totalNumberOfSyncedGfnGames = account->syncing.totalNumberOfSyncedGfnGames;
    observation.syncState = account->syncing.syncState;
    observation.syncDate = account->syncing.syncDate;
    return observation;
}

static std::vector<OPNSyncObservation> OPNSyncObservationsForStores(const OPN::UserAccountInfo &accountInfo,
                                                                    const std::vector<std::string> &stores) {
    std::vector<OPNSyncObservation> observations;
    observations.reserve(stores.size());
    for (const std::string &store : stores) {
        observations.push_back(OPNSyncObservationForStore(accountInfo, store));
    }
    return observations;
}

static const OPNSyncObservation *OPNSyncObservationForStoreInList(const std::vector<std::string> &stores,
                                                                  const std::vector<OPNSyncObservation> &observations,
                                                                  const std::string &store) {
    for (size_t i = 0; i < stores.size() && i < observations.size(); i++) {
        if (OPNStoreStringEquals(stores[i], store)) return &observations[i];
    }
    return nullptr;
}

static NSTimeInterval OPNSyncRemainingSeconds(NSDate *deadlineAt) {
    if (!deadlineAt) return 0.0;
    return MAX(0.0, [deadlineAt timeIntervalSinceNow]);
}

static NSString *OPNSyncRemainingFooter(NSDate *deadlineAt) {
    NSTimeInterval remaining = OPNSyncRemainingSeconds(deadlineAt);
    if (remaining <= 0.0) return @"Doing one final library refresh.";
    return [NSString stringWithFormat:@"About %.0fs left before showing manual options.", ceil(remaining)];
}

static NSString *OPNSyncProgressMessage(const OPNSyncObservation &current,
                                        const OPNSyncObservation &baseline,
                                        NSString *storeName,
                                        NSDate *deadlineAt,
                                        NSInteger attempt) {
    NSString *displayStore = storeName.length > 0 ? storeName : @"the selected store";
    NSInteger displayAttempt = MAX((NSInteger)1, attempt + 1);
    bool fresh = OPNSyncObservationHasFreshState(current, baseline);
    if (fresh && OPNSyncStateSucceeded(current.syncState)) {
        return [NSString stringWithFormat:@"%@ sync finished. Checking if this game is now in your library...", displayStore];
    }
    if (fresh && OPNSyncStateFailed(current.syncState)) {
        return [NSString stringWithFormat:@"%@ reported a sync problem. Refreshing once more before showing options...", displayStore];
    }
    NSTimeInterval remaining = OPNSyncRemainingSeconds(deadlineAt);
    if (remaining > 0.0) {
        return [NSString stringWithFormat:@"Waiting for %@ to update your GeForce NOW library... (%ld)", displayStore, (long)displayAttempt];
    }
    return [NSString stringWithFormat:@"Refreshing %@ library data one final time...", displayStore];
}

static NSString *OPNSyncFailureMessage(const std::string &syncState, NSString *storeName) {
    NSString *displayStore = storeName.length > 0 ? storeName : @"the selected store";
    if (syncState == "SYNC_DENIED") {
        return [NSString stringWithFormat:@"GeForce NOW could not sync %@ because the store account denied library access. Check your store privacy or connection settings, then try again.", displayStore];
    }
    if (syncState == "PROFILE_NOT_CREATED") {
        return [NSString stringWithFormat:@"GeForce NOW could not sync %@ because the store profile is not ready or could not be found. Open the store profile, then try again.", displayStore];
    }
    if (syncState == "SYNC_FAILED") {
        return [NSString stringWithFormat:@"GeForce NOW reported that %@ library sync failed. Try syncing again or open the store to check the account connection.", displayStore];
    }
    return [NSString stringWithFormat:@"GeForce NOW did not report a successful %@ library sync before the timeout.", displayStore];
}

static bool OPNChooseAccountLinked(const OPN::GameInfo &game, const OPN::GameVariant *selectedVariant) {
    if (game.playType == "INSTALL_TO_PLAY") return false;
    if (selectedVariant) return OPN::GameVariantOwnedForLaunch(*selectedVariant);
    if (game.isInLibrary) return true;
    for (const auto &variant : game.variants) {
        if (OPN::GameVariantOwnedForLaunch(variant)) return true;
    }
    return false;
}

static const OPN::GameVariant *OPNVariantAtIndex(const OPN::GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

static int OPNFirstOwnedVariantIndex(const OPN::GameInfo &game, int excludedVariantIndex) {
    for (size_t i = 0; i < game.variants.size(); i++) {
        if ((int)i == excludedVariantIndex) continue;
        if (!game.variants[i].id.empty() && OPN::GameVariantOwnedForLaunch(game.variants[i])) return (int)i;
    }
    return -1;
}

static bool OPNStoreStringEquals(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); i++) {
        if (std::tolower((unsigned char)lhs[i]) != std::tolower((unsigned char)rhs[i])) return false;
    }
    return true;
}

static const OPN::StoreDefinition *OPNStoreDefinitionForStore(const std::vector<OPN::StoreDefinition> &definitions,
                                                             const std::string &store) {
    for (const OPN::StoreDefinition &definition : definitions) {
        if (OPNStoreStringEquals(definition.store, store)) return &definition;
    }
    return nullptr;
}

static const OPN::StoreAccountInfo *OPNStoreAccountForStore(const OPN::UserAccountInfo &accountInfo,
                                                           const std::string &store) {
    for (const OPN::StoreAccountInfo &storeInfo : accountInfo.stores) {
        if (OPNStoreStringEquals(storeInfo.store, store)) return &storeInfo;
    }
    return nullptr;
}

static bool OPNStoreFeatureSupported(const OPN::StoreDefinition *definition, const std::string &featureType) {
    if (!definition) return false;
    for (const OPN::StoreFeatureInfo &feature : definition->features) {
        if (feature.supported && feature.type == featureType) return true;
    }
    return false;
}

static bool OPNStoreDefinitionSupportsVariant(const OPN::StoreDefinition *definition, const std::string &variantId) {
    if (!definition) return false;
    const std::vector<std::string> &supportedIds = definition->accountLinkingMetadata.supportedVariantIds;
    if (supportedIds.empty()) return true;
    return std::find(supportedIds.begin(), supportedIds.end(), variantId) != supportedIds.end();
}

static bool OPNStoreAccountConnected(const OPN::StoreAccountInfo *accountInfo) {
    return accountInfo != nullptr && !accountInfo->store.empty();
}

static bool OPNStoreVectorContains(const std::vector<std::string> &stores, const std::string &store) {
    for (const std::string &candidate : stores) {
        if (OPNStoreStringEquals(candidate, store)) return true;
    }
    return false;
}

static bool OPNGameMatchesRequested(const OPN::GameInfo &game, const OPN::GameInfo &requestedGame) {
    return (!requestedGame.id.empty() && game.id == requestedGame.id) ||
        (!requestedGame.uuid.empty() && game.uuid == requestedGame.uuid);
}

static const OPN::GameInfo *OPNFindMatchingGame(const std::vector<OPN::GameInfo> &games,
                                                const OPN::GameInfo &requestedGame) {
    for (const OPN::GameInfo &game : games) {
        if (OPNGameMatchesRequested(game, requestedGame)) return &game;
    }
    return nullptr;
}

static int OPNSelectedOwnedVariantIndex(const OPN::GameInfo &game,
                                        const OPN::GameVariant &requestedVariant) {
    for (size_t i = 0; i < game.variants.size(); i++) {
        const OPN::GameVariant &variant = game.variants[i];
        bool sameVariant = (!requestedVariant.id.empty() && variant.id == requestedVariant.id) ||
            (!requestedVariant.appStore.empty() && OPNStoreStringEquals(variant.appStore, requestedVariant.appStore));
        if (sameVariant && OPN::GameVariantOwnedForLaunch(variant)) return (int)i;
    }
    return -1;
}

static std::vector<std::string> OPNAutoResyncStoresForGame(const OPN::GameInfo &game,
                                                           const std::vector<OPN::StoreDefinition> &definitions,
                                                           const OPN::UserAccountInfo &accountInfo) {
    std::vector<std::string> stores;
    for (const OPN::GameVariant &variant : game.variants) {
        if (variant.appStore.empty()) continue;
        const OPN::StoreDefinition *definition = OPNStoreDefinitionForStore(definitions, variant.appStore);
        if (!OPNStoreFeatureSupported(definition, "AccountGamesSyncing")) continue;
        if (!OPNStoreDefinitionSupportsVariant(definition, variant.id)) continue;
        const OPN::StoreAccountInfo *account = OPNStoreAccountForStore(accountInfo, variant.appStore);
        if (!OPNStoreAccountConnected(account)) continue;
        if (!OPNStoreVectorContains(stores, variant.appStore)) stores.push_back(variant.appStore);
    }
    return stores;
}

static NSString *OPNStoreListDisplayName(const std::vector<std::string> &stores) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const std::string &store : stores) {
        NSString *name = [NSString stringWithUTF8String:OPN::GameStoreDisplayName(store).c_str()];
        if (name.length > 0) [names addObject:name];
    }
    if (names.count == 0) return @"connected stores";
    if (names.count == 1) return names.firstObject;
    if (names.count == 2) return [NSString stringWithFormat:@"%@ and %@", names[0], names[1]];
    NSString *lastName = names.lastObject;
    NSArray<NSString *> *leadingNames = [names subarrayWithRange:NSMakeRange(0, names.count - 1)];
    return [NSString stringWithFormat:@"%@, and %@", [leadingNames componentsJoinedByString:@", "], lastName];
}

static bool OPNLibraryContainsOwnedVariant(const std::vector<OPN::GameInfo> &games,
                                           const OPN::GameInfo &requestedGame,
                                           const OPN::GameVariant &requestedVariant) {
    for (const OPN::GameInfo &game : games) {
        if (!OPNGameMatchesRequested(game, requestedGame)) continue;
        if (game.isInLibrary && requestedVariant.id.empty()) return true;
        for (const OPN::GameVariant &variant : game.variants) {
            bool sameVariant = (!requestedVariant.id.empty() && variant.id == requestedVariant.id) ||
                (!requestedVariant.appStore.empty() && OPNStoreStringEquals(variant.appStore, requestedVariant.appStore));
            if (sameVariant && OPN::GameVariantOwnedForLaunch(variant)) return true;
        }
    }
    return false;
}

static bool OPNGameHasAppId(const OPN::GameInfo &game, int appId) {
    if (appId <= 0) return false;
    std::string appIdString = std::to_string(appId);
    if (game.id == appIdString || game.launchAppId == appIdString) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (variant.id == appIdString) return true;
    }
    return false;
}

static NSString *OPNTitleForActiveSessionAppId(int appId, const std::vector<OPN::GameInfo> &games) {
    if (appId <= 0) return @"Current Stream";
    std::string appIdString = std::to_string(appId);
    for (const OPN::GameInfo &game : games) {
        if (game.id == appIdString || game.launchAppId == appIdString) {
            return game.title.empty() ? @"Current Stream" : [NSString stringWithUTF8String:game.title.c_str()];
        }
        for (const OPN::GameVariant &variant : game.variants) {
            if (variant.id == appIdString) {
                return game.title.empty() ? @"Current Stream" : [NSString stringWithUTF8String:game.title.c_str()];
            }
        }
    }
    return @"Current Stream";
}

static bool OPNFeaturedPanelTextMatches(const std::string &value) {
    std::string lower = value;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char character) {
        return (char)std::tolower(character);
    });
    return lower.find("featured") != std::string::npos;
}

static std::string OPNFeaturedGameIdentity(const OPN::GameInfo &game) {
    if (!game.id.empty()) return game.id;
    if (!game.uuid.empty()) return game.uuid;
    if (!game.launchAppId.empty()) return game.launchAppId;
    return game.title;
}

static OPN::FeaturedGamesResult OPNFeaturedGamesFromPanels(const std::vector<OPN::PanelResult> &panels) {
    static const size_t kFeaturedGameLimit = 6;
    auto appendUnique = [](std::vector<OPN::GameInfo> &target, std::unordered_set<std::string> &seen, const OPN::GameInfo &game) {
        std::string identity = OPNFeaturedGameIdentity(game);
        if (identity.empty() || seen.find(identity) != seen.end()) return;
        seen.insert(identity);
        target.push_back(game);
    };

    OPN::FeaturedGamesResult result;
    std::unordered_set<std::string> seenExplicit;
    for (const OPN::PanelResult &panel : panels) {
        bool panelFeatured = OPNFeaturedPanelTextMatches(panel.title) || OPNFeaturedPanelTextMatches(panel.id);
        for (const OPN::PanelSection &section : panel.sections) {
            if (!panelFeatured && !OPNFeaturedPanelTextMatches(section.title) && !OPNFeaturedPanelTextMatches(section.id)) continue;
            for (const OPN::GameInfo &game : section.games) appendUnique(result.games, seenExplicit, game);
        }
    }
    if (!result.games.empty()) {
        if (result.games.size() > kFeaturedGameLimit) result.games.resize(kFeaturedGameLimit);
        result.usedExplicitFeaturedSection = true;
        return result;
    }

    std::unordered_set<std::string> seenCurated;
    for (const OPN::PanelResult &panel : panels) {
        for (const OPN::PanelSection &section : panel.sections) {
            for (const OPN::GameInfo &game : section.games) appendUnique(result.games, seenCurated, game);
        }
    }
    if (result.games.size() > kFeaturedGameLimit) result.games.resize(kFeaturedGameLimit);
    return result;
}

static uint16_t OPNActiveSessionPromptGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;
    uint16_t buttons = 0;
    if (pad.buttonA.value > 0.5) buttons |= 1u << 0;
    if (pad.buttonB.value > 0.5) buttons |= 1u << 1;
    if (pad.buttonY.value > 0.5) buttons |= 1u << 2;
    return buttons;
}

static uint16_t OPNDesktopGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;

    uint16_t buttons = 0;
    CGFloat x = pad.leftThumbstick.xAxis.value;
    CGFloat y = pad.leftThumbstick.yAxis.value;
    if (pad.dpad.up.value > 0.5 || y > 0.55) buttons |= OPNDesktopGamepadButtonUp;
    if (pad.dpad.down.value > 0.5 || y < -0.55) buttons |= OPNDesktopGamepadButtonDown;
    if (pad.dpad.left.value > 0.5 || x < -0.55) buttons |= OPNDesktopGamepadButtonLeft;
    if (pad.dpad.right.value > 0.5 || x > 0.55) buttons |= OPNDesktopGamepadButtonRight;
    if (pad.buttonA.value > 0.5) buttons |= OPNDesktopGamepadButtonA;
    if (pad.buttonB.value > 0.5) buttons |= OPNDesktopGamepadButtonB;
    if (pad.buttonY.value > 0.5) buttons |= OPNDesktopGamepadButtonY;
    return buttons;
}

static NSString *OPNAppStringFromStdString(const std::string &value, NSString *fallback) {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [NSString stringWithUTF8String:value.c_str()];
    return string.length > 0 ? string : (fallback ?: @"");
}

static NSArray<OPNCloudmatchServerOption *> *OPNCloudmatchServerOptionsFromRegions(const std::vector<OPN::StreamRegionOption> &regions) {
    NSMutableArray<OPNCloudmatchServerOption *> *options = [NSMutableArray array];
    NSInteger bestLatency = -1;
    for (const OPN::StreamRegionOption &region : regions) {
        if (region.latencyMs < 0) continue;
        if (bestLatency < 0 || region.latencyMs < bestLatency) bestLatency = region.latencyMs;
    }

    [options addObject:[[OPNCloudmatchServerOption alloc] initWithName:@"Automatic"
                                                                   url:@""
                                                             latencyMs:bestLatency
                                                              automatic:YES]];
    for (const OPN::StreamRegionOption &region : regions) {
        if (region.url.empty()) continue;
        NSString *name = OPNAppStringFromStdString(region.name, @"Cloudmatch");
        NSString *url = OPNAppStringFromStdString(region.url, @"");
        if (url.length == 0) continue;
        [options addObject:[[OPNCloudmatchServerOption alloc] initWithName:name
                                                                       url:url
                                                                 latencyMs:region.latencyMs
                                                                  automatic:NO]];
    }
    return options;
}

static void OPNAppendFingerprintField(std::string &target, const std::string &value) {
    target += std::to_string(value.size());
    target += ':';
    target += value;
    target += '|';
}

static void OPNAppendFingerprintList(std::string &target, std::vector<std::string> values) {
    std::sort(values.begin(), values.end());
    target += '[';
    for (const std::string &value : values) {
        OPNAppendFingerprintField(target, value);
    }
    target += ']';
}

static std::string OPNGameLibraryFingerprint(const std::vector<OPN::GameInfo> &games) {
    std::vector<std::string> entries;
    entries.reserve(games.size());
    for (const OPN::GameInfo &game : games) {
        std::string entry;
        OPNAppendFingerprintField(entry, game.id);
        OPNAppendFingerprintField(entry, game.uuid);
        OPNAppendFingerprintField(entry, game.launchAppId);
        OPNAppendFingerprintField(entry, game.title);
        OPNAppendFingerprintField(entry, game.shortName);
        OPNAppendFingerprintField(entry, game.playabilityState);
        OPNAppendFingerprintField(entry, game.imageUrl);
        OPNAppendFingerprintList(entry, game.availableStores);
        OPNAppendFingerprintList(entry, game.genres);
        std::vector<std::string> variants;
        variants.reserve(game.variants.size());
        for (const OPN::GameVariant &variant : game.variants) {
            std::string variantEntry;
            OPNAppendFingerprintField(variantEntry, variant.id);
            OPNAppendFingerprintField(variantEntry, variant.appStore);
            OPNAppendFingerprintField(variantEntry, variant.storeUrl);
            OPNAppendFingerprintField(variantEntry, variant.serviceStatus);
            OPNAppendFingerprintField(variantEntry, variant.librarySelected ? "1" : "0");
            OPNAppendFingerprintField(variantEntry, variant.inLibrary ? "1" : "0");
            variants.push_back(variantEntry);
        }
        OPNAppendFingerprintList(entry, variants);
        entries.push_back(entry);
    }
    std::sort(entries.begin(), entries.end());
    std::string fingerprint;
    fingerprint.reserve(entries.size() * 128);
    for (const std::string &entry : entries) {
        OPNAppendFingerprintField(fingerprint, entry);
    }
    return fingerprint;
}
