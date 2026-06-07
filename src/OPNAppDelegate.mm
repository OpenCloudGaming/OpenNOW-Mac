#import "OPNAppDelegate.h"
#import "auth/OPNAuthService.h"
#import "games/OPNGameService.h"
#import "streaming/OPNStreamViewController.h"
#include "streaming/OPNSessionManager.h"
#include "streaming/OPNStreamPreferences.h"
#import "views/OPNBackdropView.h"
#import "views/OPNEmailEntryView.h"
#import "views/OPNAuthenticatingView.h"
#import "views/OPNErrorView.h"
#import "views/OPNGameCatalogView.h"
#import "views/OPNSettingsView.h"
#import "views/OPNSessionReportView.h"
#import "views/OPNCloudmatchServerPickerView.h"
#import "common/OPNColorTokens.h"
#import "common/OPNUIHelpers.h"
#include "common/OPNLogCapture.h"
#include "common/OPNLocale.h"
#include "common/OPNDiscordPresence.h"
#include "common/OPNGFNError.h"
#include "common/OPNGameRemediation.h"
#import "common/OPNGitHubUpdater.h"
#import "common/OPNAuthTypes.h"
#import "common/OPNGameTypes.h"
#import <CommonCrypto/CommonDigest.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <memory>
#include <unordered_set>
#include "common/OPNSentry.h"

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
- (void)startDesktopControllerPolling;
- (void)stopDesktopControllerPolling;
- (void)pollDesktopController:(NSTimer *)timer;
- (void)routeDesktopGamepadButtons:(uint16_t)buttons;
@end

@implementation AppDelegate

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

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    using namespace OPN;

    OPN::RecordSentryCounterMetric("opennow.app.launch.count", 1, nil);
    SentryTransaction launchTrace("OpenNOW launch", "app.start");
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
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
    OPN::RecordSentryCounterMetric("opennow.stream.start.count", 1, @{
        @"source": resumeSessionId.empty() ? @"new" : @"resume",
        @"outcome": @"started",
        @"return_screen": OPNMetricScreenName(returnScreen),
        @"account_linked": @(accountLinked),
    });

    self.catalogView = nil;
    self.storeView = nil;
    self.settingsView = nil;

    OPNStreamViewController *streamVC = [[OPNStreamViewController alloc] initWithGameTitle:title
                                                                                      appId:appId
                                                                                   apiToken:apiToken
                                                                              accountLinked:accountLinked
                                                                               selectedStore:selectedStore
                                                                             resumeSessionId:resumeSessionId
                                                                                 resumeServer:resumeServer];
    if (self.currentRemainingPlayTimeAvailable) {
        [streamVC setRemainingPlaytimeHours:self.currentRemainingPlayTimeHours unlimited:self.currentRemainingPlayTimeUnlimited];
    }
    self.currentStreamTitle = title.empty() ? @"Current Stream" : [NSString stringWithUTF8String:title.c_str()];
    self.activeStreamReturnScreen = returnScreen;
    self.streamDashboardHomeVisible = NO;
    OPN::DiscordPresence::Shared().UpdateLaunching(title);

    __weak __typeof__(self) weakSelf = self;
    streamVC.onStreamEnd = ^(BOOL success, const std::string &error, const OPN::SessionHealthReport &report) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        std::string errorCopy = error;
        OPN::SessionHealthReport reportCopy = report;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPN::LogInfo(@"[AppDelegate] Stream ended, restoring previous screen. Success=%d", success);
            OPN::RecordSentryCounterMetric("opennow.stream.end.count", 1, @{
                @"outcome": success ? @"success" : @"failure",
                @"return_screen": OPNMetricScreenName(returnScreen),
            });
            [strongSelf stopStreamDashboardControllerPolling];
            strongSelf.streamDashboardHomeVisible = NO;
            strongSelf.streamingController = nil;
            strongSelf.currentStreamTitle = nil;
            OPN::DiscordPresence::Shared().Clear();
            [strongSelf transitionToScreen:returnScreen];
            if (!success && !errorCopy.empty()) OPN::AppendLogEvent([NSString stringWithFormat:@"[AppDelegate] Stream ended with error before report: %s", errorCopy.c_str()]);
            OPN::SessionReportDisplayDecision decision = OPN::SessionHealthReportDisplayDecisionForReport(reportCopy, OPN::LoadSessionReportDisplayMode());
            OPN::RecordSentryCounterMetric("opennow.stream.report.count", 1, @{
                @"decision": decision.shouldShow ? @"shown" : @"suppressed",
                @"reason": [NSString stringWithUTF8String:decision.reason.c_str()] ?: @"unknown",
            });
            if (decision.shouldShow) {
                [strongSelf showSessionReport:reportCopy];
            } else {
                OPN::AppendLogEvent([NSString stringWithFormat:@"[AppDelegate] Session report suppressed score=%d reason=%s", decision.score, decision.reason.c_str()]);
            }
        });
    };
    streamVC.onDashboardToggleRequested = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;

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

#pragma mark - Screen Transitions

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
        FetchStreamRegions(token, providerBaseUrl, [](const std::vector<StreamRegionOption> &) {
            GameService::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
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
