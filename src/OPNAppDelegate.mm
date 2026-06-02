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
#import "views/OPNStoreView.h"
#import "views/OPNCloudmatchServerPickerView.h"
#import "common/OPNColorTokens.h"
#import "common/OPNUIHelpers.h"
#include "common/OPNLogCapture.h"
#include "common/OPNLocale.h"
#include "common/OPNGFNError.h"
#include "common/OPNGameRemediation.h"
#import "common/OPNGitHubUpdater.h"
#import "common/OPNAuthTypes.h"
#import "common/OPNGameTypes.h"
#import <CommonCrypto/CommonDigest.h>
#import <GameController/GameController.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <memory>
#include <unordered_set>
#include "common/OPNSentry.h"

@interface AppDelegate ()
@property (nonatomic, strong) OPNBackdropView *rootView;
@property (nonatomic, strong) OPNGameCatalogView *catalogView;
@property (nonatomic, strong) OPNSettingsView *settingsView;
@property (nonatomic, strong) OPNStoreView *storeView;
@property (nonatomic, strong) OPNStreamViewController *streamingController;
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
@property (nonatomic, strong) id controllerModeShortcutMonitor;
@property (nonatomic, strong) NSView *desktopTopChromeView;
@property (nonatomic, strong) NSView *desktopBrandIconView;
@property (nonatomic, strong) NSTextField *desktopBrandLabel;
@property (nonatomic, strong) NSView *desktopNavigationBar;
@property (nonatomic, copy) NSArray<NSButton *> *desktopNavigationButtons;
@property (nonatomic, strong) NSPopUpButton *desktopAccountSwitcher;
@property (nonatomic, strong) NSView *desktopRemainingPlayTimePill;
@property (nonatomic, strong) NSTextField *desktopRemainingPlayTimeLabel;
@property (nonatomic, assign) double currentRemainingPlayTimeHours;
@property (nonatomic, assign) BOOL currentRemainingPlayTimeUnlimited;
@property (nonatomic, assign) BOOL currentRemainingPlayTimeAvailable;
@property (nonatomic, strong) OPNGitHubUpdater *githubUpdater;
@property (nonatomic, strong) NSTimer *applicationUpdateCheckTimer;
@property (nonatomic, assign) BOOL updateCheckInFlight;
- (void)configureContentContainerForScreen:(OPN::AuthScreen)screen;
- (void)refreshAccountSummary;
- (void)refreshAccountSummaryWithRetry:(BOOL)canRetry;
- (void)refreshAccountAvatar;
- (void)refreshStreamRegions;
- (void)refreshAccountMenu;
- (void)transitionToCatalogAfterProviderSelectionForSession:(const OPN::AuthSession &)session;
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
- (BOOL)presentOwnershipRemediationIfNeededForGame:(const OPN::GameInfo &)game
                                      variantIndex:(int)variantIndex
                                     accountLinked:(bool)accountLinked
                                   continueHandler:(void (^)(void))continueHandler;
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
- (void)showControllerHomePage;
- (void)switchControllerPageBy:(NSInteger)delta;
- (void)installControllerModeShortcutMonitor;
- (void)toggleControllerModeFromShortcut;
- (void)applyInterfacePreferencesToCurrentScreen;
- (void)installDesktopNavigationBarIfNeeded;
- (void)installDesktopAccountSwitcherIfNeeded;
- (void)layoutDesktopNavigationBar;
- (void)layoutDesktopAccountSwitcher;
- (void)updateDesktopNavigationBar;
- (void)updateDesktopAccountSwitcher;
- (void)rebuildDesktopAccountSwitcher;
- (void)desktopNavigationButtonClicked:(NSButton *)sender;
- (void)desktopAccountSwitcherChanged:(NSPopUpButton *)sender;
- (void)startApplicationUpdateChecks;
- (void)stopApplicationUpdateChecks;
- (void)applicationUpdateCheckTimerFired:(NSTimer *)timer;
- (void)checkForApplicationUpdates;
- (void)checkForApplicationUpdatesShowingCurrentStatus:(BOOL)showCurrentStatus;
@end

@implementation AppDelegate

static NSString *const OPNMainWindowFrameAutosaveName = @"OpenNOW.MainWindowFrame";
static NSString *const OPNMainWindowWasFullScreenKey = @"OpenNOW.MainWindowWasFullScreen";

static BOOL OPNWindowIsFullScreen(NSWindow *window) {
    return window && ((window.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen);
}

static BOOL OPNAppDelegateIsCommandIEvent(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown) return NO;
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & NSEventModifierFlagCommand) == 0) return NO;
    if ((flags & (NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return [key isEqualToString:@"i"];
}

static BOOL OPNAppDelegateScreenSupportsDesktopNavigation(OPN::AuthScreen screen) {
    return screen == OPN::AuthScreen::Catalog || screen == OPN::AuthScreen::Store || screen == OPN::AuthScreen::Settings;
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

static bool OPNIsOwnedLibraryStatus(const std::string &status) {
    return OPN::GameServiceStatusOwnedForLaunch(status);
}

static bool OPNChooseAccountLinked(const OPN::GameInfo &game, const OPN::GameVariant *selectedVariant) {
    if (game.playType == "INSTALL_TO_PLAY") return false;
    if (selectedVariant && OPNIsOwnedLibraryStatus(selectedVariant->serviceStatus)) return true;
    if (game.isInLibrary) return true;
    for (const auto &variant : game.variants) {
        if (OPNIsOwnedLibraryStatus(variant.serviceStatus)) return true;
    }
    return false;
}

static const OPN::GameVariant *OPNVariantAtIndex(const OPN::GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
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
            if (!panelFeatured && !OPNFeaturedPanelTextMatches(section.title)) continue;
            for (const OPN::GameInfo &game : section.games) appendUnique(result.games, seenExplicit, game);
        }
    }
    if (!result.games.empty()) {
        result.usedExplicitFeaturedSection = true;
        return result;
    }

    std::unordered_set<std::string> seenCurated;
    for (const OPN::PanelResult &panel : panels) {
        for (const OPN::PanelSection &section : panel.sections) {
            for (const OPN::GameInfo &game : section.games) appendUnique(result.games, seenCurated, game);
        }
    }
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

- (void)switchControllerPageBy:(NSInteger)delta {
    if (!OpnControllerModeEnabled() || delta == 0) return;
    NSArray<NSString *> *pages = @[@"home", @"library", @"store", @"settings"];
    NSInteger currentIndex = 0;
    for (NSUInteger index = 0; index < pages.count; index++) {
        NSString *page = pages[index];
        BOOL selected = ([page isEqualToString:@"home"] && self.currentScreen == OPN::AuthScreen::Catalog && self.rootView.mode == OPNBackdropModeHome) ||
                        ([page isEqualToString:@"library"] && self.currentScreen == OPN::AuthScreen::Catalog && self.rootView.mode == OPNBackdropModeLibrary) ||
                        ([page isEqualToString:@"store"] && self.currentScreen == OPN::AuthScreen::Store) ||
                        ([page isEqualToString:@"settings"] && self.currentScreen == OPN::AuthScreen::Settings);
        if (selected) {
            currentIndex = (NSInteger)index;
            break;
        }
    }
    NSInteger nextIndex = (currentIndex + delta) % (NSInteger)pages.count;
    if (nextIndex < 0) nextIndex += (NSInteger)pages.count;
    OpnPlayConsoleTone(OPNConsoleToneChange);
    NSString *nextPage = pages[(NSUInteger)nextIndex];
    if ([nextPage isEqualToString:@"home"]) {
        if (self.currentScreen != OPN::AuthScreen::Catalog) [self transitionToScreen:OPN::AuthScreen::Catalog];
        [self.catalogView showControllerHome];
        self.rootView.mode = OPNBackdropModeHome;
    } else if ([nextPage isEqualToString:@"library"]) {
        if (self.currentScreen != OPN::AuthScreen::Catalog) [self transitionToScreen:OPN::AuthScreen::Catalog];
        [self.catalogView showControllerLibrary];
        self.rootView.mode = OPNBackdropModeLibrary;
    } else if ([nextPage isEqualToString:@"store"]) {
        if (self.currentScreen != OPN::AuthScreen::Store) [self transitionToScreen:OPN::AuthScreen::Store];
    } else if ([nextPage isEqualToString:@"settings"]) {
        if (self.currentScreen != OPN::AuthScreen::Settings) [self transitionToScreen:OPN::AuthScreen::Settings];
    }
}

- (void)showControllerHomePage {
    if (!OpnControllerModeEnabled()) return;
    if (self.currentScreen != OPN::AuthScreen::Catalog) {
        [self transitionToScreen:OPN::AuthScreen::Catalog];
    }
    [self.catalogView showControllerHome];
    self.rootView.mode = OPNBackdropModeHome;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    using namespace OPN;

    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

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
                                             selector:@selector(interfacePreferencesChanged:)
                                                 name:OPNInterfacePreferencesDidChangeNotification
                                               object:nil];
    [self installControllerModeShortcutMonitor];
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
    if (shouldAutoSignIn && canUseSavedSessionAsIs) {
        self.currentSession = saved;
        [self transitionToScreen:AuthScreen::Catalog];
    } else if (shouldAutoSignIn && canRefreshSavedSession) {
        [self showAuthenticatingWithMessage:@"Refreshing session..."];
        __weak __typeof__(self) weakSelf = self;
        AuthService::Shared().RefreshSession(^(bool success, const AuthSession &fresh,
                                                const std::string &) {
            __typeof__(self) s = weakSelf;
            if (!s) return;
            if (success) {
                s.currentSession = fresh;
                AuthService::Shared().SaveSession(fresh);
                [s refreshAccountMenu];
                [s transitionToScreen:AuthScreen::Catalog];
            } else {
                OPN::AuthSession fallback = AuthService::Shared().LoadSavedSession();
                if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
                    s.currentSession = fallback;
                    [s transitionToScreen:AuthScreen::Catalog];
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
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.window saveFrameUsingName:OPNMainWindowFrameAutosaveName];
    [self saveWindowPresentation];
    [self stopApplicationUpdateChecks];
    [self stopGameLibraryRefreshTimer];
    [self stopActiveSessionPromptControllerPolling];
    [self stopStreamDashboardControllerPolling];
    if (self.controllerModeShortcutMonitor) {
        [NSEvent removeMonitor:self.controllerModeShortcutMonitor];
        self.controllerModeShortcutMonitor = nil;
    }
    self.desktopNavigationButtons = @[];
    self.desktopNavigationBar = nil;
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
    [self layoutDesktopNavigationBar];
    [self layoutDesktopAccountSwitcher];
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self applyInterfacePreferencesToCurrentScreen];
}

- (void)installControllerModeShortcutMonitor {
    if (self.controllerModeShortcutMonitor) return;
    __weak __typeof__(self) weakSelf = self;
    self.controllerModeShortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                               handler:^NSEvent *(NSEvent *event) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.window || event.window != strongSelf.window) return event;
        if (!OPNAppDelegateIsCommandIEvent(event)) return event;
        [strongSelf toggleControllerModeFromShortcut];
        return (NSEvent *)nil;
    }];
}

- (void)toggleControllerModeFromShortcut {
    BOOL enabled = !OpnControllerModeEnabled();
    OpnSetControllerModeEnabled(enabled);
    OpnPlayConsoleTone(OPNConsoleToneChange);
    OPN::LogInfo(@"[AppDelegate] Controller mode toggled via Command-I: %d", enabled);
}

- (void)applyInterfacePreferencesToCurrentScreen {
    if (!self.rootView) return;
    if (self.currentScreen == OPN::AuthScreen::Store) {
        self.rootView.mode = OPNBackdropModeStore;
    } else if (self.currentScreen == OPN::AuthScreen::Catalog) {
        self.rootView.mode = OpnControllerModeEnabled() ? OPNBackdropModeHome : OPNBackdropModeLibrary;
    } else if (self.currentScreen == OPN::AuthScreen::Settings) {
        self.rootView.mode = OPNBackdropModeSettings;
    }
    [self updateDesktopNavigationBar];
    [self updateDesktopAccountSwitcher];
}

- (NSButton *)desktopNavigationButtonWithTitle:(NSString *)title tag:(NSInteger)tag {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = title ?: @"";
    button.tag = tag;
    button.bordered = NO;
    button.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    button.target = self;
    button.action = @selector(desktopNavigationButtonClicked:);
    button.wantsLayer = YES;
    button.layer.cornerRadius = 14.0;
    button.focusRingType = NSFocusRingTypeNone;
    if (@available(macOS 11.0, *)) {
        NSString *symbolName = tag == 1 ? @"storefront" : (tag == 0 ? @"books.vertical" : @"gearshape");
        NSImage *symbol = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:title];
        if (symbol) {
            button.image = symbol;
            button.imagePosition = NSImageLeft;
            button.imageScaling = NSImageScaleProportionallyDown;
        }
    }
    return button;
}

- (void)installDesktopNavigationBarIfNeeded {
    if (!self.rootView) return;
    if (self.desktopTopChromeView && self.desktopTopChromeView.superview != self.rootView) {
        self.desktopTopChromeView = nil;
        self.desktopBrandIconView = nil;
        self.desktopBrandLabel = nil;
    }
    if (!self.desktopTopChromeView) {
        NSView *chrome = [[NSView alloc] initWithFrame:NSZeroRect];
        chrome.wantsLayer = YES;
        chrome.layer.backgroundColor = OpnColor(0x000000, 0.98).CGColor;
        self.desktopTopChromeView = chrome;

        NSView *brandIcon = [[NSView alloc] initWithFrame:NSZeroRect];
        brandIcon.wantsLayer = YES;
        brandIcon.layer.cornerRadius = 14.0;
        brandIcon.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.94).CGColor;
        brandIcon.layer.borderWidth = 1.0;
        brandIcon.layer.borderColor = OpnColor(0xFFFFFF, 0.22).CGColor;
        self.desktopBrandIconView = brandIcon;
        [chrome addSubview:brandIcon];

        NSTextField *brandGlyph = OpnLabel(@"ON", NSZeroRect, 14.0, OpnColor(0x173019, 0.96), NSFontWeightBlack, NSTextAlignmentCenter);
        brandGlyph.identifier = @"brandGlyph";
        [brandIcon addSubview:brandGlyph];

        NSTextField *brandLabel = OpnLabel(@"OpenNOW", NSZeroRect, 18.0, OpnColor(OPN::kTextPrimary), NSFontWeightBlack);
        brandLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.desktopBrandLabel = brandLabel;
        [chrome addSubview:brandLabel];
        [self.rootView addSubview:chrome positioned:NSWindowAbove relativeTo:self.contentContainer];
    }
    if (self.desktopNavigationBar && self.desktopNavigationBar.superview != self.rootView) {
        self.desktopNavigationBar = nil;
        self.desktopNavigationButtons = @[];
    }
    if (self.desktopNavigationBar) return;
    NSView *bar = [[NSView alloc] initWithFrame:NSZeroRect];
    bar.wantsLayer = YES;
    bar.layer.cornerRadius = 0.0;
    bar.layer.backgroundColor = NSColor.clearColor.CGColor;
    bar.layer.borderWidth = 0.0;
    bar.layer.shadowColor = NSColor.blackColor.CGColor;
    bar.layer.shadowOpacity = 0.0;
    bar.layer.shadowRadius = 0.0;
    bar.layer.shadowOffset = CGSizeZero;
    self.desktopNavigationBar = bar;

    NSArray<NSButton *> *buttons = @[
        [self desktopNavigationButtonWithTitle:@"Store" tag:1],
        [self desktopNavigationButtonWithTitle:@"Library" tag:0],
        [self desktopNavigationButtonWithTitle:@"Settings" tag:2],
    ];
    self.desktopNavigationButtons = buttons;
    for (NSButton *button in buttons) [bar addSubview:button];
    [self.rootView addSubview:bar positioned:NSWindowAbove relativeTo:self.contentContainer];
    [self layoutDesktopNavigationBar];
    [self updateDesktopNavigationBar];
}

- (void)installDesktopAccountSwitcherIfNeeded {
    if (!self.rootView) return;
    if (self.desktopAccountSwitcher && self.desktopAccountSwitcher.superview != self.rootView) {
        self.desktopAccountSwitcher = nil;
        self.desktopRemainingPlayTimePill = nil;
        self.desktopRemainingPlayTimeLabel = nil;
    }
    if (self.desktopAccountSwitcher) return;
    NSPopUpButton *switcher = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    switcher.target = self;
    switcher.action = @selector(desktopAccountSwitcherChanged:);
    switcher.bordered = NO;
    switcher.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    switcher.contentTintColor = OpnColor(OPN::kTextPrimary);
    switcher.focusRingType = NSFocusRingTypeNone;
    switcher.wantsLayer = YES;
    switcher.layer.cornerRadius = 18.0;
    switcher.layer.backgroundColor = OpnColor(0x07140D, 0.86).CGColor;
    switcher.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.24).CGColor;
    switcher.layer.borderWidth = 1.0;
    switcher.layer.shadowColor = NSColor.blackColor.CGColor;
    switcher.layer.shadowOpacity = 0.34;
    switcher.layer.shadowRadius = 20.0;
    switcher.layer.shadowOffset = CGSizeMake(0.0, 10.0);
    self.desktopAccountSwitcher = switcher;
    [self.rootView addSubview:switcher positioned:NSWindowAbove relativeTo:self.contentContainer];

    NSView *playTimePill = [[NSView alloc] initWithFrame:NSZeroRect];
    playTimePill.wantsLayer = YES;
    playTimePill.layer.cornerRadius = 14.0;
    playTimePill.layer.backgroundColor = OpnColor(0x050A08, 0.78).CGColor;
    playTimePill.layer.borderColor = OpnColor(0xFFFFFF, 0.11).CGColor;
    playTimePill.layer.borderWidth = 1.0;
    playTimePill.layer.shadowColor = NSColor.blackColor.CGColor;
    playTimePill.layer.shadowOpacity = 0.20;
    playTimePill.layer.shadowRadius = 14.0;
    playTimePill.layer.shadowOffset = CGSizeMake(0.0, 8.0);
    self.desktopRemainingPlayTimePill = playTimePill;

    NSTextField *playTimeLabel = OpnLabel(@"Playtime: --", NSZeroRect, 11.0, OpnColor(OPN::kTextSecondary), NSFontWeightSemibold, NSTextAlignmentCenter);
    playTimeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.desktopRemainingPlayTimeLabel = playTimeLabel;
    [playTimePill addSubview:playTimeLabel];
    [self.rootView addSubview:playTimePill positioned:NSWindowAbove relativeTo:self.contentContainer];

    [self rebuildDesktopAccountSwitcher];
    [self layoutDesktopAccountSwitcher];
    [self updateDesktopAccountSwitcher];
}

- (void)layoutDesktopNavigationBar {
    if (!self.desktopNavigationBar || !self.rootView) return;
    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat chromeHeight = 140.0;
    self.desktopTopChromeView.frame = NSMakeRect(0.0, 0.0, width, chromeHeight);
    CGFloat brandX = MAX(48.0, floor(width * 0.024));
    self.desktopBrandIconView.frame = NSMakeRect(brandX, 43.0, 54.0, 54.0);
    for (NSView *subview in self.desktopBrandIconView.subviews) {
        if ([subview.identifier isEqualToString:@"brandGlyph"]) subview.frame = self.desktopBrandIconView.bounds;
    }
    self.desktopBrandLabel.frame = NSMakeRect(NSMaxX(self.desktopBrandIconView.frame) + 20.0, 58.0, 180.0, 28.0);

    CGFloat barWidth = 500.0;
    CGFloat barHeight = 116.0;
    CGFloat x = floor((width - barWidth) * 0.5);
    self.desktopNavigationBar.frame = NSMakeRect(x, 24.0, barWidth, barHeight);
    CGFloat buttonWidth = floor(barWidth / 3.0);
    CGFloat buttonX = 0.0;
    for (NSButton *button in self.desktopNavigationButtons) {
        button.frame = NSMakeRect(buttonX, 0.0, buttonWidth, barHeight);
        buttonX += buttonWidth;
    }
}

- (void)layoutDesktopAccountSwitcher {
    if (!self.desktopAccountSwitcher || !self.rootView) return;
    CGFloat width = NSWidth(self.rootView.bounds);
    CGFloat switcherWidth = MIN(180.0, MAX(150.0, width * 0.10));
    CGFloat accountX = MAX(24.0, width - switcherWidth - 58.0);
    self.desktopAccountSwitcher.frame = NSMakeRect(accountX, 52.0, switcherWidth, 44.0);
    CGFloat pillWidth = 128.0;
    self.desktopRemainingPlayTimePill.frame = NSMakeRect(accountX - pillWidth - 14.0, 52.0, pillWidth, 44.0);
    self.desktopRemainingPlayTimePill.layer.cornerRadius = 22.0;
    self.desktopRemainingPlayTimeLabel.frame = NSInsetRect(self.desktopRemainingPlayTimePill.bounds, 8.0, 13.0);
}

- (void)updateDesktopNavigationBar {
    [self installDesktopNavigationBarIfNeeded];
    [self updateDesktopAccountSwitcher];
    if (!self.desktopNavigationBar) return;
    BOOL visible = !OpnControllerModeEnabled() && OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen);
    self.desktopTopChromeView.hidden = !visible;
    self.desktopNavigationBar.hidden = !visible;
    if (!visible) return;
    [self layoutDesktopNavigationBar];
    for (NSButton *button in self.desktopNavigationButtons) {
        BOOL selected = (button.tag == 0 && self.currentScreen == OPN::AuthScreen::Catalog) ||
            (button.tag == 1 && self.currentScreen == OPN::AuthScreen::Store) ||
            (button.tag == 2 && self.currentScreen == OPN::AuthScreen::Settings);
        button.font = [NSFont systemFontOfSize:16.0 weight:selected ? NSFontWeightBlack : NSFontWeightBold];
        button.contentTintColor = selected ? OpnColor(OPN::kTextPrimary) : OpnColor(OPN::kTextSecondary, 0.88);
        button.layer.backgroundColor = selected ? OpnColor(OPN::kBrandGreen, 0.12).CGColor : NSColor.clearColor.CGColor;
        button.layer.borderWidth = selected ? 0.0 : 1.0;
        button.layer.borderColor = OpnColor(0xFFFFFF, selected ? 0.0 : 0.0).CGColor;
    }
}

- (void)updateDesktopAccountSwitcher {
    [self installDesktopAccountSwitcherIfNeeded];
    if (!self.desktopAccountSwitcher) return;
    BOOL visible = !OpnControllerModeEnabled() && OPNAppDelegateScreenSupportsDesktopNavigation(self.currentScreen);
    self.desktopAccountSwitcher.hidden = !visible;
    NSString *remainingPlayTime = [self.rootView.remainingPlayTime ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL playTimeVisible = visible && remainingPlayTime.length > 0;
    self.desktopRemainingPlayTimePill.hidden = !playTimeVisible;
    self.desktopRemainingPlayTimeLabel.stringValue = remainingPlayTime.length > 0 ? [@"Playtime: " stringByAppendingString:remainingPlayTime] : @"Playtime: --";
    if (!visible) return;
    [self layoutDesktopAccountSwitcher];
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
        NSString *label = OPNAuthSessionDisplayName(session);
        NSString *title = [identifierString isEqualToString:currentIdentifierString]
            ? [NSString stringWithFormat:@"%@  (Current)", label]
            : label;
        [self.desktopAccountSwitcher addItemWithTitle:title];
        NSMenuItem *item = self.desktopAccountSwitcher.lastItem;
        item.representedObject = identifierString;
        item.image = OPNAccountSwitcherImageForSession(session, [identifierString isEqualToString:currentIdentifierString] ? self.rootView.accountAvatarImage : nil);
        if ([identifierString isEqualToString:currentIdentifierString]) selectedIndex = self.desktopAccountSwitcher.numberOfItems - 1;
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

- (void)desktopNavigationButtonClicked:(NSButton *)sender {
    if (sender.tag == 0) {
        if (self.currentScreen != OPN::AuthScreen::Catalog) [self transitionToScreen:OPN::AuthScreen::Catalog];
        return;
    }
    if (sender.tag == 1) {
        if (self.currentScreen != OPN::AuthScreen::Store) [self transitionToScreen:OPN::AuthScreen::Store];
        return;
    }
    if (sender.tag == 2 && self.currentScreen != OPN::AuthScreen::Settings) {
        [self transitionToScreen:OPN::AuthScreen::Settings];
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
    [self transitionToScreen:OPN::AuthScreen::Catalog];
    [self.catalogView showControllerHome];
    self.rootView.mode = OPNBackdropModeHome;
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

    self.catalogView.controllerInputSuspended = YES;
    self.storeView.controllerInputSuspended = YES;

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
        ? @"Discovering cloudmatch servers and measuring ping..."
        : @"Refreshing cloudmatch ping before launch..."
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
        if (completionCopy) completionCopy(YES);
    };
    picker.onCancel = ^{
        __typeof__(self) strongSelf = weakSelf;
        OPNCloudmatchServerPickerView *strongPicker = weakPicker;
        if (!strongSelf || !strongPicker || strongSelf.cloudmatchServerPickerView != strongPicker) return;
        OPN::LogInfo(@"[AppDelegate] Cloudmatch server selection cancelled");
        [strongSelf dismissCloudmatchServerPicker];
        if (completionCopy) completionCopy(NO);
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
    [picker setStatusMessage:@"Pinging cloudmatch servers..." isError:NO];

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
                [strongPicker setStatusMessage:@"Server discovery failed. Automatic can still launch using the default route." isError:YES];
            } else {
                [strongPicker setStatusMessage:@"Latency updated. Lower ping usually means a more responsive stream." isError:NO];
            }
        });
    });
}

- (void)dismissCloudmatchServerPicker {
    self.cloudmatchServerPickerGeneration++;
    [self.cloudmatchServerPickerView removeFromSuperview];
    self.cloudmatchServerPickerView = nil;
    self.catalogView.controllerInputSuspended = NO;
    self.storeView.controllerInputSuspended = NO;
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
        OPN::LogInfo(@"[AppDelegate] Ignoring stream start while stream is active: title=%@, appId=%s", OPNAppStringFromStdString(title, @""), appId.c_str());
        return;
    }

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

    __weak __typeof__(self) weakSelf = self;
    streamVC.onStreamEnd = ^(BOOL success, const std::string &error) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPN::LogInfo(@"[AppDelegate] Stream ended, restoring previous screen. Success=%d", success);
            [strongSelf stopStreamDashboardControllerPolling];
            strongSelf.streamDashboardHomeVisible = NO;
            strongSelf.streamingController = nil;
            strongSelf.currentStreamTitle = nil;
            [strongSelf transitionToScreen:returnScreen];
            if (!success && !errorCopy.empty()) {
                [strongSelf showError:errorCopy canRetry:YES];
            }
        });
    };
    streamVC.onDashboardToggleRequested = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf toggleStreamDashboardHome];
        });
    };

    NSRect preservedFrame = self.window.frame;
    BOOL preserveFrame = !OPNWindowIsFullScreen(self.window);
    [streamVC setInitialViewFrame:self.window.contentView.bounds];
    streamVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    OPNConfigureStreamWindow(self.window);
    self.window.contentViewController = streamVC;
    OpnDisableFocusHighlights(streamVC.view);
    if (preserveFrame) {
        [self.window setFrame:preservedFrame display:YES animate:NO];
    }
    self.streamingController = streamVC;
    [self.window makeKeyAndOrderFront:nil];
    if (OpnAutoFullScreenEnabled() && !OPNWindowIsFullScreen(self.window)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!OPNWindowIsFullScreen(self.window)) {
                [self.window toggleFullScreen:nil];
            }
        });
    }
    OPN::LogInfo(@"[AppDelegate] Window setup complete");
}

- (void)launchGame:(const OPN::GameInfo &)game variantIndex:(int)variantIndex returnScreen:(OPN::AuthScreen)returnScreen {
    using namespace OPN;

    if ([self hasVisibleStreamingController]) {
        OPN::LogInfo(@"[AppDelegate] Ignoring game launch while stream is active: title=%@, id=%s", OPNAppStringFromStdString(game.title, @""), game.id.c_str());
        return;
    }

    OPN::LogInfo(@"[AppDelegate] Game selected: title=%@, id=%s, uuid=%s, variantIndex=%d", OPNAppStringFromStdString(game.title, @""), game.id.c_str(), game.uuid.c_str(), variantIndex);

    std::string apiToken = self.currentSession.idToken.empty()
        ? self.currentSession.accessToken : self.currentSession.idToken;

    std::string effectiveAppId;
    std::string selectedStore;
    bool accountLinked = OPNChooseAccountLinked(game, nullptr);
    if (variantIndex >= 0 && variantIndex < (int)game.variants.size()) {
        const GameVariant &variant = game.variants[(size_t)variantIndex];
        effectiveAppId = variant.id;
        selectedStore = variant.appStore;
        accountLinked = OPNChooseAccountLinked(game, &variant);
        OPN::LogInfo(@"[AppDelegate] Variant: id=%s, store=%s, status=%s, accountLinked=%d",
              variant.id.c_str(), variant.appStore.c_str(), variant.serviceStatus.c_str(), accountLinked);
    }
    if (effectiveAppId.empty()) {
        effectiveAppId = game.launchAppId.empty() ? game.id : game.launchAppId;
    }
    OPN::LogInfo(@"[AppDelegate] Using appId=%s, store=%s, accountLinked=%d",
          effectiveAppId.c_str(), selectedStore.c_str(), accountLinked);

    __weak __typeof__(self) weakSelf = self;
    std::string gameTitle = game.title;
    auto startRequestedGame = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf startStreamWithTitle:gameTitle
                                   appId:effectiveAppId
                                apiToken:apiToken
                           accountLinked:accountLinked
                            selectedStore:selectedStore
                            returnScreen:returnScreen
                          resumeSessionId:""
                              resumeServer:""];
    };

    auto continueLaunchAfterServerSelection = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;

        SessionManager::Shared().SetAccessToken(apiToken);
        SessionManager::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
        OPN::GameInfo requestedGame = game;
        SessionManager::Shared().GetActiveSessions([weakSelf, startRequestedGame, requestedGame, gameTitle, effectiveAppId, apiToken, returnScreen](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
            std::vector<ActiveSessionEntry> sessionsCopy = sessions;
            std::string errorCopy = error;
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || [strongSelf hasVisibleStreamingController]) return;
                if (!ok) {
                    OPN::LogError(@"[AppDelegate] Active session launch probe failed, continuing launch: %s", errorCopy.c_str());
                    startRequestedGame();
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
                    startRequestedGame();
                    return;
                }

                NSString *sessionTitle = OPNTitleForActiveSessionAppId(activeSession.appId, strongSelf.cachedGameLibrary);
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
                    SessionManager::Shared().SetStreamingBaseUrl(LoadSelectedStreamingBaseUrl());
                    SessionManager::Shared().StopSession(activeSession.sessionId, activeSession.serverIp, [weakSelf, startRequestedGame](bool stopOk, const std::string &stopError) {
                        std::string stopErrorCopy = stopError;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __typeof__(self) stopSelf = weakSelf;
                            if (!stopSelf) return;
                            if (!stopOk) {
                                [stopSelf showError:stopErrorCopy.empty() ? std::string("Unable to delete the existing session.") : stopErrorCopy canRetry:YES];
                                return;
                            }
                            startRequestedGame();
                        });
                    });
                }];
            });
        });
    };

    auto beginServerSelection = ^{
        NSString *pickerGameTitle = gameTitle.empty() ? @"Selected Game" : [NSString stringWithUTF8String:gameTitle.c_str()];
        [self showCloudmatchServerPickerForGameTitle:pickerGameTitle
                                            apiToken:apiToken
                                          completion:^(BOOL confirmed) {
            if (!confirmed) return;
            continueLaunchAfterServerSelection();
        }];
    };

    if ([self presentOwnershipRemediationIfNeededForGame:game
                                            variantIndex:variantIndex
                                           accountLinked:accountLinked
                                         continueHandler:beginServerSelection]) {
        return;
    }
    beginServerSelection();
}

- (BOOL)presentOwnershipRemediationIfNeededForGame:(const OPN::GameInfo &)game
                                      variantIndex:(int)variantIndex
                                     accountLinked:(bool)accountLinked
                                   continueHandler:(void (^)(void))continueHandler {
    OPN::GameOwnershipRemediation remediation = OPN::GameOwnershipRemediationForLaunch(game, variantIndex, accountLinked);
    if (!remediation.Required()) return NO;
    int storeVariantIndex = remediation.storeVariantIndex >= 0 ? remediation.storeVariantIndex : variantIndex;
    const OPN::GameVariant *storeVariant = OPNVariantAtIndex(game, storeVariantIndex);
    if (!storeVariant) return NO;

    OPN::GameInfo gameCopy = game;
    int variantIndexCopy = storeVariantIndex;
    NSString *title = [NSString stringWithUTF8String:remediation.title.c_str()] ?: @"Store Account Required";
    NSString *reason = [NSString stringWithUTF8String:remediation.reason.c_str()] ?: @"This game requires store account setup before launch.";
    NSString *guidance = [NSString stringWithUTF8String:remediation.guidance.c_str()] ?: @"Open the store to finish setup. If you already completed that step, continue anyway.";
    NSString *actionLabel = [NSString stringWithUTF8String:remediation.actionLabel.c_str()] ?: @"Open Store";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = [NSString stringWithFormat:@"%@ %@", reason, guidance];
    [alert addButtonWithTitle:actionLabel];
    [alert addButtonWithTitle:@"Continue Anyway"];
    [alert addButtonWithTitle:@"Cancel"];
    __weak __typeof__(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (returnCode == NSAlertFirstButtonReturn) {
            [strongSelf openPurchaseURL:@"" forGame:gameCopy variantIndex:variantIndexCopy];
            return;
        }
        if (returnCode == NSAlertSecondButtonReturn && continueHandler) continueHandler();
    }];
    return YES;
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
    if (!OpnControllerModeEnabled()) return;
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

    __weak __typeof__(self) weakSelf = self;
    SessionManager::Shared().GetActiveSessions([weakSelf, generation, accountIdentifier, apiToken, screen](bool ok, const std::vector<ActiveSessionEntry> &sessions, const std::string &error) {
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
            for (const ActiveSessionEntry &session : sessionsCopy) {
                if ((session.status == 2 || session.status == 3) && !session.sessionId.empty() && !session.serverIp.empty() && session.appId > 0) {
                    activeSession = session;
                    foundActiveSession = YES;
                    break;
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
            [strongSelf.catalogView showControllerHome];
            strongSelf.rootView.mode = OPNBackdropModeHome;
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
            [strongSelf.catalogView showControllerLibrary];
            strongSelf.rootView.mode = OPNBackdropModeLibrary;
        };
        self.rootView.onSearchSelected = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.currentScreen != OPN::AuthScreen::Catalog) [strongSelf transitionToScreen:OPN::AuthScreen::Catalog];
            [strongSelf.catalogView showControllerLibrary];
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
    [self installDesktopNavigationBarIfNeeded];
    [self installDesktopAccountSwitcherIfNeeded];
}

- (void)configureContentContainerForScreen:(OPN::AuthScreen)screen {
    if (self.rootView) {
        if (screen == OPN::AuthScreen::Store) {
            self.rootView.mode = OPNBackdropModeStore;
        } else if (screen == OPN::AuthScreen::Catalog) {
            self.rootView.mode = OpnControllerModeEnabled() ? OPNBackdropModeHome : OPNBackdropModeLibrary;
        } else if (screen == OPN::AuthScreen::Settings) {
            self.rootView.mode = OPNBackdropModeSettings;
        } else {
            self.rootView.mode = OPNBackdropModeAuth;
        }
    }
    self.contentContainer.frame = self.rootView.bounds;
    self.contentContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self updateDesktopNavigationBar];
}

- (void)transitionToScreen:(OPN::AuthScreen)screen {
    using namespace OPN;

    [self installLibraryRootIfNeeded];
    [self configureContentContainerForScreen:screen];

    for (NSView *subview in [self.contentContainer.subviews copy]) {
        [subview removeFromSuperview];
    }

    self.currentScreen = screen;
    [self updateDesktopNavigationBar];
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
                        strongSelf.currentSession = session;
                        if (strongSelf.pendingCredentials.stayLoggedIn)
                            OPN::AuthService::Shared().SaveSession(session);
                        [strongSelf refreshAccountMenu];
                        [strongSelf transitionToCatalogAfterProviderSelectionForSession:session];
                    } else {
                        [strongSelf showError:error canRetry:YES];
                    }
                });
            break;
        }

        case AuthScreen::Store: {
            OPNConfigureLibraryWindow(self.window);
            self.catalogView = nil;
            self.settingsView = nil;

            self.rootView.accountName = OPNAuthSessionDisplayName(self.currentSession);
            self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
            self.rootView.remainingPlayTime = @"--";
            self.currentRemainingPlayTimeAvailable = NO;
            self.rootView.gameCountText = @"";
            [self refreshAccountAvatar];
            [self refreshAccountMenu];
            [self refreshAccountSummary];
            [self refreshStreamRegions];

            OPNStoreView *store = [[OPNStoreView alloc] initWithFrame:bounds];
            store.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            self.storeView = store;

            std::string storePanelsAccountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
            if (self.hasCachedStorePanels && self.cachedStorePanelsAccountIdentifier == storePanelsAccountIdentifier) {
                [store setPanels:self.cachedStorePanels];
            }

            std::string storeAccountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
            if (self.hasCachedGameLibrary && self.cachedGameLibraryAccountIdentifier == storeAccountIdentifier) {
                [store setLibraryGames:self.cachedGameLibrary];
            } else {
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
            store.onPreviousPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:-1];
            };
            store.onNextPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:1];
            };
            store.onBackRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf showControllerHomePage];
            };

            [self.contentContainer addSubview:store];
            OpnDisableFocusHighlights(store);
            self.window.title = @"OpenNOW - Store";
            [self loadStorePanelsWithRetry:YES];
            break;
        }

        case AuthScreen::Catalog: {
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

            catalog.onControllerSurfaceChanged = ^(BOOL homeSurface) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.rootView || strongSelf.currentScreen != AuthScreen::Catalog) return;
                strongSelf.rootView.mode = homeSurface ? OPNBackdropModeHome : OPNBackdropModeLibrary;
            };

            catalog.onExitRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [NSApp terminate:strongSelf];
            };
            catalog.onPreviousPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:-1];
            };
            catalog.onNextPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:1];
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

            catalog.onCatalogBrowseRequested = ^(NSString *searchQuery, NSString *sortId, const std::vector<std::string> &filterIds) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf browseCatalogWithSearch:searchQuery sortId:sortId filterIds:filterIds canRetry:YES];
            };

            [self.contentContainer addSubview:catalog];
            OpnDisableFocusHighlights(catalog);
            self.window.title = @"OpenNOW";
            if (displayName.length == 0 && !self.currentSession.accessToken.empty()) {
                [catalog setLoading:YES];
                AuthService::Shared().FetchStarFleetUserInfo(
                    self.currentSession.accessToken,
                    ^(bool uiSuccess, NSDictionary *info, const std::string &) {
                        __typeof__(self) s = weakSelf;
                        if (!s) return;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (uiSuccess && info) {
                                NSString *pref = info[@"preferred_username"];
                                NSString *email = info[@"email"];
                                NSString *name = pref ? pref : (email ? [email componentsSeparatedByString:@"@"][0] : nil);
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
            self.storeView = nil;
            self.catalogView = nil;
            self.rootView.accountName = OPNAuthSessionDisplayName(self.currentSession);
            self.rootView.accountStatus = OPNDisplayTier(self.currentSession.membershipTier);
            self.rootView.remainingPlayTime = @"--";
            self.currentRemainingPlayTimeAvailable = NO;
            self.rootView.gameCountText = @"";
            [self refreshAccountAvatar];
            [self refreshAccountMenu];
            [self refreshAccountSummary];
            [self refreshStreamRegions];
            NSString *initialSectionName = OpnControllerModeEnabled() ? @"Interface" : nil;
            OPNSettingsView *settings = [[OPNSettingsView alloc] initWithFrame:bounds selectedSectionName:initialSectionName];
            settings.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            __weak __typeof__(self) weakSelf = self;
            settings.onBackRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                if (OpnControllerModeEnabled()) {
                    [strongSelf showControllerHomePage];
                } else {
                    [strongSelf transitionToScreen:AuthScreen::Catalog];
                }
            };
            settings.onPreviousPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:-1];
            };
            settings.onNextPageRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf switchControllerPageBy:1];
            };
            settings.onCheckForUpdatesRequested = ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf checkForApplicationUpdates];
            };
            self.settingsView = settings;
            [self.contentContainer addSubview:settings];
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
    __weak __typeof__(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *, NSError *error) {
        if (error || !data) return;
        NSImage *image = [[NSImage alloc] initWithData:data];
        if (!image) return;
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
    for (const AuthSession &session : AuthService::Shared().LoadSavedSessions()) {
        std::string identifier = OPNAuthSessionIdentifier(session);
        if (identifier.empty()) continue;
        NSString *identifierString = [NSString stringWithUTF8String:identifier.c_str()];
        NSString *label = OPNAuthSessionDisplayName(session);
        [items addObject:@{@"identifier": identifierString, @"label": label}];
    }
    self.rootView.accountMenuItems = items;
    std::string currentIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    self.rootView.currentAccountIdentifier = currentIdentifier.empty()
        ? @""
        : [NSString stringWithUTF8String:currentIdentifier.c_str()];
    [self rebuildDesktopAccountSwitcher];
    [self updateDesktopAccountSwitcher];
}

- (void)transitionToCatalogAfterProviderSelectionForSession:(const OPN::AuthSession &)session {
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
        [strongSelf transitionToScreen:AuthScreen::Catalog];
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
        [self transitionToCatalogAfterProviderSelectionForSession:selected];
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
            [strongSelf transitionToCatalogAfterProviderSelectionForSession:fresh];
            return;
        }

        AuthSession fallback = AuthService::Shared().LoadSavedSession();
        if (fallback.isAuthenticated && fallback.IsAccessTokenValid()) {
            strongSelf.currentSession = fallback;
            [strongSelf transitionToCatalogAfterProviderSelectionForSession:fallback];
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
    if (!self.catalogView || self.featuredGamesRefreshInFlight) return;

    std::string accountIdentifier = OPNAuthSessionIdentifier(self.currentSession);
    if (self.hasCachedFeaturedGames && self.cachedFeaturedGamesAccountIdentifier == accountIdentifier) {
        [self.catalogView setFeaturedGames:self.cachedFeaturedGames];
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

            if (success) {
                FeaturedGamesResult featured = OPNFeaturedGamesFromPanels(panels);
                if (!featured.games.empty()) {
                    OPN::LogInfo(@"[AppDelegate] featured games resolved from marquee count=%lu", (unsigned long)featured.games.size());
                    strongSelf.featuredGamesRefreshInFlight = NO;
                    strongSelf.cachedFeaturedGames = featured.games;
                    strongSelf.cachedFeaturedGamesAccountIdentifier = accountIdentifier;
                    strongSelf.hasCachedFeaturedGames = YES;
                    if (strongSelf.catalogView && strongSelf.currentScreen == AuthScreen::Catalog) {
                        [strongSelf.catalogView setFeaturedGames:featured.games];
                    }
                    return;
                }
                OPN::LogInfo(@"[AppDelegate] Marquee panel contained no featured games; falling back to main panel");
            } else {
                OPN::LogError(@"[AppDelegate] Marquee featured games fetch failed: %s", error.c_str());
            }

            GameService::Shared().FetchMainPanels(
                [weakSelf, accountIdentifier, canRetry](bool mainSuccess, const std::vector<PanelResult> &mainPanels, const std::string &mainError) {
                    __typeof__(self) fallbackSelf = weakSelf;
                    if (!fallbackSelf) return;
                    fallbackSelf.featuredGamesRefreshInFlight = NO;
                    if (accountIdentifier != OPNAuthSessionIdentifier(fallbackSelf.currentSession)) return;

                    if (!mainSuccess && canRetry && mainError.find("401") != std::string::npos) {
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

                    if (!mainSuccess) {
                        OPN::LogError(@"[AppDelegate] Main-panel featured games fetch failed: %s", mainError.c_str());
                        return;
                    }

                    FeaturedGamesResult featured = OPNFeaturedGamesFromPanels(mainPanels);
                    OPN::LogInfo(@"[AppDelegate] featured games resolved from main count=%lu explicit=%d", (unsigned long)featured.games.size(), featured.usedExplicitFeaturedSection);
                    fallbackSelf.cachedFeaturedGames = featured.games;
                    fallbackSelf.cachedFeaturedGamesAccountIdentifier = accountIdentifier;
                    fallbackSelf.hasCachedFeaturedGames = !featured.games.empty();
                    if (fallbackSelf.catalogView && fallbackSelf.currentScreen == AuthScreen::Catalog) {
                        [fallbackSelf.catalogView setFeaturedGames:featured.games];
                    }
                });
                return;
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
                        [retrySelf transitionToScreen:AuthScreen::Catalog];
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
                [strongSelf transitionToScreen:AuthScreen::Catalog];
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
