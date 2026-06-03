#import "OPNGameCatalogView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>

static const CGFloat kStoreTopInset = 0.0;
static const CGFloat kStoreNavigationClearance = 0.0;
static const CGFloat kStoreHeroHeightRatio = 0.3229;
static const CGFloat kStoreRowHeight = 258.0;
static const CGFloat kStoreCardSpacing = 18.0;
static const CGFloat kStoreTileWidth = 268.0;
static const CGFloat kStoreTileHeight = 151.0;
static const CGFloat kStoreHeroMinContentInset = 30.0;
static const CGFloat kStoreHeroMaxContentInset = 106.0;
static const CGFloat kStoreHeroContentInsetRatio = 0.055;
static const CGFloat kStoreFallbackHeroAspect = 1.0 / kStoreHeroHeightRatio;

@interface OPNStoreDocumentView : NSView
@end

@implementation OPNStoreDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface OPNStoreRailScrollView : NSScrollView
@end

@implementation OPNStoreRailScrollView

- (void)scrollWheel:(NSEvent *)event {
    CGFloat horizontal = std::fabs(event.scrollingDeltaX);
    CGFloat vertical = std::fabs(event.scrollingDeltaY);
    if (vertical > horizontal) {
        NSScrollView *pageScrollView = self.enclosingScrollView;
        if (pageScrollView && pageScrollView != self) {
            [pageScrollView scrollWheel:event];
            return;
        }
    }
    [super scrollWheel:event];
}

@end

static CGFloat OPNStoreHeroContentInsetForWidth(CGFloat width) {
    return MIN(kStoreHeroMaxContentInset, MAX(kStoreHeroMinContentInset, width * kStoreHeroContentInsetRatio));
}

static NSString *OPNStoreString(const std::string &value, NSString *fallback) {
    return value.empty() ? (fallback ?: @"") : [NSString stringWithUTF8String:value.c_str()];
}

static NSString *OPNStoreDisplayLabel(NSString *value) {
    NSString *trimmed = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (trimmed.length == 0) return @"";
    NSDictionary<NSString *, NSString *> *specialLabels = @{
        @"FREE_TO_PLAY": @"Free to Play",
        @"MASSIVELY_MULTIPLAYER_ONLINE": @"MMO",
        @"MASSIVELY_MULTIPLAYER": @"MMO",
        @"KEYBOARD_MOUSE": @"Keyboard + Mouse",
        @"GAMEPAD_PARTIAL": @"Partial Gamepad",
    };
    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    NSString *special = specialLabels[normalized];
    if (special.length > 0) return special;

    NSString *spaced = [[trimmed.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@" "] stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    NSArray<NSString *> *tokens = [spaced componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *acronyms = [NSSet setWithArray:@[@"ai", @"dlc", @"fps", @"hdr", @"mmo", @"moba", @"pve", @"pvp", @"rpg", @"rtx", @"vr"]];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *token in tokens) {
        if (token.length == 0) continue;
        if ([acronyms containsObject:token]) {
            [labels addObject:token.uppercaseString];
            continue;
        }
        NSString *first = [token substringToIndex:1].uppercaseString;
        NSString *rest = token.length > 1 ? [token substringFromIndex:1] : @"";
        [labels addObject:[first stringByAppendingString:rest]];
    }
    return labels.count > 0 ? [labels componentsJoinedByString:@" "] : value;
}

static NSString *OPNStoreDisplayString(const std::string &value, NSString *fallback) {
    NSString *display = OPNStoreDisplayLabel(OPNStoreString(value, @""));
    return display.length > 0 ? display : (fallback ?: @"");
}

static NSString *OPNStoreIconAssetName(NSString *name) {
    NSString *upper = (name ?: @"").uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"steam";
    if ([upper containsString:@"EPIC"] || [upper containsString:@"EGS"]) return @"epic";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"ubisoft";
    if ([upper containsString:@"BATTLE"]) return @"battlenet";
    if ([upper containsString:@"XBOX"] || [upper containsString:@"MICROSOFT"]) return @"xbox";
    if ([upper containsString:@"EA"] || [upper containsString:@"ORIGIN"]) return @"ea";
    if ([upper containsString:@"GOG"]) return @"gog";
    return @"default";
}

static NSString *OPNStoreIconAssetPath(NSString *assetName) {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:assetName ofType:@"svg" inDirectory:@"store-icons"];
    if (bundlePath.length > 0) return bundlePath;
    NSString *relativePath = [NSString stringWithFormat:@"assets/store-icons/%@.svg", assetName ?: @"default"];
    NSString *workingPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:relativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:workingPath]) return workingPath;
    NSString *sourcePath = [@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:relativePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:sourcePath] ? sourcePath : nil;
}

static NSImage *OPNStoreIconImage(NSString *name) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *assetName = OPNStoreIconAssetName(name);
    NSImage *cached = cache[assetName];
    if (cached) return cached;
    NSString *path = OPNStoreIconAssetPath(assetName);
    NSImage *image = path.length > 0 ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!image && ![assetName isEqualToString:@"default"]) {
        path = OPNStoreIconAssetPath(@"default");
        image = path.length > 0 ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    }
    if (!image) return nil;
    [image setTemplate:NO];
    cache[assetName] = image;
    return image;
}

static NSString *OPNStoreLocalAssetPath(NSString *relativePath) {
    NSString *safeRelativePath = relativePath ?: @"";
    NSString *bundlePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:safeRelativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) return bundlePath;
    NSString *workingPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:safeRelativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:workingPath]) return workingPath;
    NSString *sourcePath = [@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:safeRelativePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:sourcePath] ? sourcePath : nil;
}

static NSImage *OPNStoreFallbackArtworkImage(void) {
    static NSImage *fallbackImage;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[
            @"vendor/gfn_vendor_x86_64/files/mall/assets/img/Marquee_Hero_Image_Fallback.webp",
            @"vendor/gfn_vendor_x86_64/files/mall/shared/assets/img/DefaultGameArt-TVBanner.svg",
            @"vendor/gfn_vendor_x86_64/files/mall/assets/img/DefaultGameArt.svg",
        ];
        for (NSString *relativePath in paths) {
            NSString *path = OPNStoreLocalAssetPath(relativePath);
            fallbackImage = path.length > 0 ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
            if (fallbackImage) break;
        }
    });
    return fallbackImage;
}

static NSString *OPNStorePrimaryStoreName(const OPN::GameInfo &game) {
    std::string raw;
    if (!game.variants.empty()) raw = game.variants.front().appStore;
    if (raw.empty() && !game.availableStores.empty()) raw = game.availableStores.front();
    NSString *name = raw.empty() ? @"Cloud" : [NSString stringWithUTF8String:raw.c_str()];
    NSString *upper = name.uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"Steam";
    if ([upper containsString:@"BATTLE"]) return @"Battle.net";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"Ubisoft";
    if ([upper containsString:@"XBOX"]) return @"Xbox";
    if ([upper containsString:@"EPIC"]) return @"Epic";
    if ([upper containsString:@"EA"]) return @"EA";
    return name.capitalizedString;
}

static NSArray<NSString *> *OPNStoreVariantStoreNames(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *stores = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    void (^appendStore)(NSString *) = ^(NSString *rawStore) {
        NSString *store = OPNStoreDisplayLabel(rawStore ?: @"");
        if (store.length == 0) return;
        NSString *key = store.uppercaseString;
        if ([seen containsObject:key]) return;
        [seen addObject:key];
        [stores addObject:store];
    };

    for (const OPN::GameVariant &variant : game.variants) {
        appendStore(OPNStoreString(variant.appStore, @""));
    }
    for (const std::string &store : game.availableStores) {
        appendStore(OPNStoreString(store, @""));
    }
    if (stores.count == 0) [stores addObject:OPNStorePrimaryStoreName(game)];
    return stores;
}

static bool OPNStoreStringEqualsCaseInsensitive(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); i++) {
        if (std::tolower((unsigned char)lhs[i]) != std::tolower((unsigned char)rhs[i])) return false;
    }
    return true;
}

static BOOL OPNStoreIsNumericString(const std::string &value) {
    return !value.empty() && value.find_first_not_of("0123456789") == std::string::npos;
}

static void OPNStoreAppendUniqueURL(NSMutableArray<NSString *> *urls, NSString *urlString) {
    NSString *trimmed = [urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [urls containsObject:trimmed]) return;
    [urls addObject:trimmed];
}

static void OPNStoreAppendImageType(NSMutableArray<NSString *> *urls, const OPN::GameInfo &game, const char *type) {
    auto it = game.imageUrlsByType.find(type);
    if (it == game.imageUrlsByType.end()) return;
    for (const std::string &url : it->second) {
        OPNStoreAppendUniqueURL(urls, OPNStoreString(url, @""));
    }
}

static NSString *OPNStoreSteamArtworkURLForGame(const OPN::GameInfo &game) {
    std::string appId;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreIsNumericString(variant.id)) {
            NSString *store = OPNStoreString(variant.appStore, @"");
            if ([store.uppercaseString containsString:@"STEAM"]) {
                appId = variant.id;
                break;
            }
        }
    }
    if (appId.empty() && OPNStoreIsNumericString(game.launchAppId)) appId = game.launchAppId;
    if (appId.empty()) return nil;
    return [NSString stringWithFormat:@"https://cdn.cloudflare.steamstatic.com/steam/apps/%s/header.jpg", appId.c_str()];
}

static NSArray<NSString *> *OPNStoreImageCandidatesForGame(const OPN::GameInfo &game, BOOL prominent) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSArray<NSString *> *preferredTypes = prominent
        ? @[@"MARQUEE_HERO_IMAGE", @"HERO_IMAGE", @"TV_BANNER", @"FEATURE_IMAGE", @"KEY_ART", @"KEY_IMAGE", @"GAME_BOX_ART"]
        : @[@"TV_BANNER", @"HERO_IMAGE", @"KEY_IMAGE", @"KEY_ART", @"GAME_BOX_ART", @"FEATURE_IMAGE"];
    for (NSString *type in preferredTypes) {
        OPNStoreAppendImageType(urls, game, type.UTF8String);
    }
    OPNStoreAppendUniqueURL(urls, OPNStoreString(game.heroImageUrl, @""));
    OPNStoreAppendUniqueURL(urls, OPNStoreString(game.imageUrl, @""));
    for (const std::string &screenshot : game.screenshotUrls) {
        OPNStoreAppendUniqueURL(urls, OPNStoreString(screenshot, @""));
        if (!prominent) break;
    }
    OPNStoreAppendUniqueURL(urls, OPNStoreSteamArtworkURLForGame(game));
    return urls;
}

static NSString *OPNStorePrimaryGenre(const OPN::GameInfo &game) {
    if (!game.genres.empty()) return OPNStoreDisplayString(game.genres.front(), @"Cloud Game");
    if (!game.playType.empty()) return OPNStoreDisplayString(game.playType, @"Cloud Game");
    return @"Cloud Game";
}

static NSString *OPNStoreFeatureSummary(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (game.maxOnlinePlayers > 1) [parts addObject:[NSString stringWithFormat:@"%d online", game.maxOnlinePlayers]];
    if (game.maxLocalPlayers > 1) [parts addObject:[NSString stringWithFormat:@"%d local", game.maxLocalPlayers]];
    for (const std::string &feature : game.featureLabels) {
        NSString *label = OPNStoreDisplayString(feature, @"");
        if (label.length > 0) [parts addObject:label];
        if (parts.count >= 2) break;
    }
    if (parts.count == 0 && !game.supportedControls.empty()) {
        NSString *control = OPNStoreDisplayString(game.supportedControls.front(), @"");
        if (control.length > 0) [parts addObject:control];
    }
    return parts.count > 0 ? [parts componentsJoinedByString:@" · "] : @"Ready to stream";
}

static bool OPNStoreGameMatchesLibraryGame(const OPN::GameInfo &storeGame, const OPN::GameInfo &libraryGame) {
    if (!storeGame.uuid.empty() && storeGame.uuid == libraryGame.uuid) return true;
    if (!storeGame.id.empty() && storeGame.id == libraryGame.id) return true;
    if (!storeGame.launchAppId.empty() && storeGame.launchAppId == libraryGame.launchAppId) return true;
    if (!storeGame.title.empty() && OPNStoreStringEqualsCaseInsensitive(storeGame.title, libraryGame.title)) return true;
    return false;
}

static bool OPNStoreVariantMatchesMetadata(const OPN::GameVariant &target, const OPN::GameVariant &source) {
    if (!target.id.empty() && !source.id.empty() && target.id == source.id) return true;
    if (!target.appStore.empty() && !source.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(target.appStore, source.appStore)) return true;
    return false;
}

static bool OPNStoreContainsStoreName(const std::vector<std::string> &stores, const std::string &store) {
    for (const std::string &entry : stores) {
        if (OPNStoreStringEqualsCaseInsensitive(entry, store)) return true;
    }
    return false;
}

static bool OPNStoreMergeGameStoreMetadata(OPN::GameInfo &target, const OPN::GameInfo &source) {
    bool changed = false;
    if (target.launchAppId.empty() && !source.launchAppId.empty()) {
        target.launchAppId = source.launchAppId;
        changed = true;
    }
    for (const std::string &store : source.availableStores) {
        if (!store.empty() && !OPNStoreContainsStoreName(target.availableStores, store)) {
            target.availableStores.push_back(store);
            changed = true;
        }
    }
    for (const OPN::GameVariant &sourceVariant : source.variants) {
        if (sourceVariant.appStore.empty()) continue;
        bool merged = false;
        for (OPN::GameVariant &targetVariant : target.variants) {
            if (!OPNStoreVariantMatchesMetadata(targetVariant, sourceVariant)) continue;
            if (targetVariant.id.empty() && !sourceVariant.id.empty()) {
                targetVariant.id = sourceVariant.id;
                changed = true;
            }
            if (targetVariant.appStore.empty()) {
                targetVariant.appStore = sourceVariant.appStore;
                changed = true;
            }
            if (targetVariant.storeUrl.empty() && !sourceVariant.storeUrl.empty()) {
                targetVariant.storeUrl = sourceVariant.storeUrl;
                changed = true;
            }
            if (targetVariant.serviceStatus.empty() && !sourceVariant.serviceStatus.empty()) {
                targetVariant.serviceStatus = sourceVariant.serviceStatus;
                changed = true;
            }
            if (!targetVariant.librarySelected && sourceVariant.librarySelected) {
                targetVariant.librarySelected = true;
                changed = true;
            }
            if (!targetVariant.inLibrary && sourceVariant.inLibrary) {
                targetVariant.inLibrary = true;
                changed = true;
            }
            merged = true;
            break;
        }
        if (!merged && !sourceVariant.storeUrl.empty()) {
            target.variants.push_back(sourceVariant);
            if (!OPNStoreContainsStoreName(target.availableStores, sourceVariant.appStore)) {
                target.availableStores.push_back(sourceVariant.appStore);
            }
            changed = true;
        }
    }
    return changed;
}

static void OPNStoreAppendFingerprintField(std::string &fingerprint, const std::string &value) {
    fingerprint.append(std::to_string(value.size()));
    fingerprint.push_back(':');
    fingerprint.append(value);
    fingerprint.push_back('|');
}

static std::string OPNStorePanelsFingerprint(const std::vector<OPN::PanelResult> &panels) {
    std::string fingerprint;
    fingerprint.reserve(panels.size() * 64);
    for (const OPN::PanelResult &panel : panels) {
        OPNStoreAppendFingerprintField(fingerprint, panel.id);
        OPNStoreAppendFingerprintField(fingerprint, panel.title);
        for (const OPN::PanelSection &section : panel.sections) {
            OPNStoreAppendFingerprintField(fingerprint, section.id);
            OPNStoreAppendFingerprintField(fingerprint, section.title);
            for (const OPN::GameInfo &game : section.games) {
                OPNStoreAppendFingerprintField(fingerprint, game.id);
                OPNStoreAppendFingerprintField(fingerprint, game.title);
                OPNStoreAppendFingerprintField(fingerprint, game.imageUrl);
                OPNStoreAppendFingerprintField(fingerprint, game.heroImageUrl);
                fingerprint.append(game.isInLibrary ? "1" : "0");
                fingerprint.push_back('|');
                for (const OPN::GameVariant &variant : game.variants) {
                    OPNStoreAppendFingerprintField(fingerprint, variant.id);
                    OPNStoreAppendFingerprintField(fingerprint, variant.appStore);
                    OPNStoreAppendFingerprintField(fingerprint, variant.storeUrl);
                    OPNStoreAppendFingerprintField(fingerprint, variant.serviceStatus);
                    fingerprint.append(variant.inLibrary ? "1" : "0");
                    fingerprint.append(variant.librarySelected ? "1" : "0");
                    fingerprint.push_back('|');
                }
            }
        }
    }
    return fingerprint;
}

static bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game);
static OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game);

static std::vector<OPN::PanelResult> OPNCatalogPanelsForGames(const std::vector<OPN::GameInfo> &sourceGames) {
    std::vector<OPN::PanelResult> panels;
    OPN::PanelResult panel;
    panel.id = "catalog";
    panel.title = "Library";
    panel.__typename = "CatalogPanel";

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    OPN::PanelSection currentSection;
    currentSection.id = "catalog-section-1";
    currentSection.title = "Library";
    currentSection.__typename = "CatalogSection";

    NSInteger sectionIndex = 1;
    for (const OPN::GameInfo &game : sourceGames) {
        if (!OPNCatalogGameHasAccessibleVariants(game)) continue;
        OPN::GameInfo catalogGame = OPNCatalogGameWithAccessibleVariants(game);
        NSString *identity = OpnGameIdentityForHero(catalogGame);
        if (identity.length > 0 && [seen containsObject:identity]) continue;
        if (identity.length > 0) [seen addObject:identity];

        if (currentSection.games.size() >= 24) {
            panel.sections.push_back(currentSection);
            sectionIndex++;
            currentSection = OPN::PanelSection();
            currentSection.id = "catalog-section-" + std::to_string((long)sectionIndex);
            currentSection.title = "Library";
            currentSection.__typename = "CatalogSection";
        }
        currentSection.games.push_back(catalogGame);
    }

    if (!currentSection.games.empty()) panel.sections.push_back(currentSection);
    if (!panel.sections.empty()) panels.push_back(panel);
    return panels;
}

static bool OPNStoreVariantIsLibrarySelected(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary ||
           variant.serviceStatus == "MANUAL" ||
           variant.serviceStatus == "PLATFORM_SYNC" ||
           variant.serviceStatus == "IN_LIBRARY";
}

static bool OPNCatalogGameHasAccessibleVariants(const OPN::GameInfo &game) {
    if (game.isInLibrary) return true;
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsLibrarySelected(variant)) return true;
    }
    return game.variants.empty();
}

static OPN::GameInfo OPNCatalogGameWithAccessibleVariants(const OPN::GameInfo &game) {
    OPN::GameInfo catalogGame = game;
    catalogGame.isInLibrary = true;
    std::vector<OPN::GameVariant> variants;
    for (OPN::GameVariant variant : game.variants) {
        if (!OPNStoreVariantIsLibrarySelected(variant)) continue;
        variant.inLibrary = true;
        variants.push_back(variant);
    }
    if (!variants.empty()) catalogGame.variants = variants;
    return catalogGame;
}

static int OPNStoreSelectedLibraryVariantIndex(const OPN::GameInfo &libraryGame) {
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (libraryGame.variants[i].librarySelected) return (int)i;
    }
    for (size_t i = 0; i < libraryGame.variants.size(); i++) {
        if (OPNStoreVariantIsLibrarySelected(libraryGame.variants[i])) return (int)i;
    }
    return libraryGame.variants.empty() ? -1 : 0;
}

static bool OPNStoreVariantIsOwned(const OPN::GameVariant &variant) {
    return OPNStoreVariantIsLibrarySelected(variant);
}

static bool OPNStoreVariantIsNotOwned(const OPN::GameVariant &variant) {
    return !OPNStoreVariantIsOwned(variant);
}

static const OPN::GameVariant *OPNStoreVariantAtIndex(const OPN::GameInfo &game, int variantIndex) {
    if (variantIndex < 0 || variantIndex >= (int)game.variants.size()) return nullptr;
    return &game.variants[(size_t)variantIndex];
}

static bool OPNStoreGameNeedsPurchase(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *selectedVariant = OPNStoreVariantAtIndex(game, variantIndex);
    if (selectedVariant) return OPNStoreVariantIsNotOwned(*selectedVariant);
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsNotOwned(variant)) return true;
    }
    return false;
}

static NSString *OPNStorePurchaseURLForGame(const OPN::GameInfo &game, int variantIndex) {
    const OPN::GameVariant *selectedVariant = OPNStoreVariantAtIndex(game, variantIndex);
    if (selectedVariant && !selectedVariant->storeUrl.empty()) return OPNStoreString(selectedVariant->storeUrl, @"");
    for (const OPN::GameVariant &variant : game.variants) {
        if (OPNStoreVariantIsNotOwned(variant) && !variant.storeUrl.empty()) return OPNStoreString(variant.storeUrl, @"");
    }
    for (const OPN::GameVariant &variant : game.variants) {
        if (!variant.storeUrl.empty()) return OPNStoreString(variant.storeUrl, @"");
    }
    return @"";
}

static NSString *OPNStorePrimaryActionTitle(const OPN::GameInfo &game, int variantIndex, BOOL prominent) {
    if (OPNStoreGameNeedsPurchase(game, variantIndex)) {
        return @"Buy";
    }
    return prominent ? @"Play Now" : @"PLAY";
}

@interface OPNStoreGameTile : NSView
@property (nonatomic, readonly) OPN::GameInfo game;
@property (nonatomic, assign) int selectedVariantIndex;
@property (nonatomic, assign) NSTimeInterval imageRevealDelay;
@property (nonatomic, copy) void (^onSelect)(void);
@property (nonatomic, copy) void (^onBuy)(NSString *purchaseURL);
- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game prominent:(BOOL)prominent;
- (void)setStoreFocused:(BOOL)focused;
- (void)activate;
@end

@interface OPNStoreGameTile ()
@property (nonatomic, assign) OPN::GameInfo gameData;
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSView *gradientOverlay;
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) CALayer *accentLayer;
@property (nonatomic, strong) CALayer *shineLayer;
@property (nonatomic, strong) NSView *storeBadgeView;
@property (nonatomic, strong) NSImageView *storeIconView;
@property (nonatomic, strong) NSMutableArray<NSImageView *> *storeIconViews;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *metaLabel;
@property (nonatomic, strong) NSTextField *featureLabel;
@property (nonatomic, strong) NSTextField *availabilityLabel;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) BOOL prominent;
@property (nonatomic, assign) BOOL storeFocused;
@property (nonatomic, assign) NSUInteger imageLoadGeneration;
@end

@implementation OPNStoreGameTile

- (void)setSelectedVariantIndex:(int)selectedVariantIndex {
    _selectedVariantIndex = selectedVariantIndex;
    NSInteger storeCount = MAX((NSInteger)_gameData.availableStores.size(), (NSInteger)_gameData.variants.size());
    BOOL needsPurchase = OPNStoreGameNeedsPurchase(_gameData, _selectedVariantIndex);
    self.availabilityLabel.stringValue = needsPurchase
        ? @"Not owned"
        : (storeCount > 1 ? [NSString stringWithFormat:@"%ld stores", (long)storeCount] : @"Cloud ready");
    self.playButton.title = OPNStorePrimaryActionTitle(_gameData, _selectedVariantIndex, self.prominent);
}

- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game prominent:(BOOL)prominent {
    self = [super initWithFrame:frame];
    if (self) {
        _gameData = game;
        _prominent = prominent;
        _selectedVariantIndex = game.variants.empty() ? -1 : 0;
        self.wantsLayer = YES;
        self.layer.cornerRadius = prominent ? 28.0 : 18.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = OpnColor(0x070A0C, 0.92).CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = OpnColor(0xFFFFFF, prominent ? 0.18 : 0.12).CGColor;

        _imageView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageView.wantsLayer = YES;
        _imageView.layer.backgroundColor = OpnColor(0x11161A).CGColor;
        [self addSubview:_imageView];

        _gradientOverlay = [[NSView alloc] initWithFrame:self.bounds];
        _gradientOverlay.wantsLayer = YES;
        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.colors = @[(id)OpnColor(OPN::kBlack, prominent ? 0.08 : 0.02).CGColor,
                                  (id)OpnColor(OPN::kBlack, prominent ? 0.18 : 0.12).CGColor,
                                  (id)OpnColor(OPN::kBlack, prominent ? 0.88 : 0.82).CGColor];
        _gradientLayer.locations = @[@0.0, @0.52, @1.0];
        _gradientLayer.startPoint = CGPointMake(0.5, 0.0);
        _gradientLayer.endPoint = CGPointMake(0.5, 1.0);
        _gradientOverlay.layer = _gradientLayer;
        [self addSubview:_gradientOverlay];

        _shineLayer = [CALayer layer];
        _shineLayer.backgroundColor = OpnColor(OPN::kBrandGreen, prominent ? 0.16 : 0.10).CGColor;
        _shineLayer.opacity = prominent ? 0.88 : 0.52;
        [self.layer addSublayer:_shineLayer];

        _accentLayer = [CALayer layer];
        _accentLayer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.96).CGColor;
        [self.layer addSublayer:_accentLayer];

        CGFloat titleSize = prominent ? 31.0 : 15.0;
        _storeBadgeView = [[NSView alloc] initWithFrame:NSZeroRect];
        _storeBadgeView.wantsLayer = YES;
        _storeBadgeView.layer.backgroundColor = NSColor.clearColor.CGColor;
        [self addSubview:_storeBadgeView];

        _storeIconViews = [NSMutableArray array];
        NSArray<NSString *> *variantStores = OPNStoreVariantStoreNames(game);
        _storeIconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _storeIconView.imageScaling = NSImageScaleProportionallyDown;
        _storeIconView.image = OPNStoreIconImage(variantStores.firstObject ?: OPNStorePrimaryStoreName(game));
        _storeIconView.toolTip = variantStores.firstObject ?: OPNStorePrimaryStoreName(game);
        _storeIconView.wantsLayer = YES;
        _storeIconView.layer.backgroundColor = OpnColor(0x030506, 0.72).CGColor;
        _storeIconView.layer.borderWidth = 1.0;
        _storeIconView.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
        [_storeBadgeView addSubview:_storeIconView];
        [_storeIconViews addObject:_storeIconView];

        for (NSUInteger index = 1; index < MIN((NSUInteger)4, variantStores.count); index++) {
            NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
            iconView.imageScaling = NSImageScaleProportionallyDown;
            iconView.image = OPNStoreIconImage(variantStores[index]);
            iconView.toolTip = variantStores[index];
            iconView.wantsLayer = YES;
            iconView.layer.backgroundColor = OpnColor(0x030506, 0.72).CGColor;
            iconView.layer.borderWidth = 1.0;
            iconView.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
            [_storeBadgeView addSubview:iconView];
            [_storeIconViews addObject:iconView];
        }

        NSString *title = game.title.empty() ? @"Untitled" : [NSString stringWithUTF8String:game.title.c_str()];
        _titleLabel = OpnLabel(title, NSZeroRect, titleSize, OpnColor(OPN::kTextPrimary), NSFontWeightBold);
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.maximumNumberOfLines = prominent ? 2 : 1;
        [self addSubview:_titleLabel];

        _metaLabel = OpnLabel(OPNStorePrimaryGenre(game), NSZeroRect, prominent ? 13.0 : 11.5, OpnColor(0xDBDEE5, 0.86), NSFontWeightSemibold);
        _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_metaLabel];

        _featureLabel = OpnLabel(OPNStoreFeatureSummary(game), NSZeroRect, prominent ? 13.0 : 11.0, OpnColor(0xB9BDC7, 0.82), NSFontWeightMedium);
        _featureLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _featureLabel.maximumNumberOfLines = prominent ? 2 : 1;
        [self addSubview:_featureLabel];

        _availabilityLabel = OpnLabel(@"Cloud ready", NSZeroRect, prominent ? 12.0 : 10.5, OpnColor(OPN::kBrandGreen, 0.96), NSFontWeightBold, NSTextAlignmentRight);
        _availabilityLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_availabilityLabel];

        _playButton = [[NSButton alloc] initWithFrame:NSZeroRect];
        _playButton.title = OPNStorePrimaryActionTitle(game, _selectedVariantIndex, prominent);
        _playButton.bordered = NO;
        _playButton.font = [NSFont systemFontOfSize:prominent ? 14.0 : 11.0 weight:NSFontWeightBlack];
        _playButton.contentTintColor = OpnColor(OPN::kAccentOn);
        _playButton.wantsLayer = YES;
        _playButton.layer.backgroundColor = OpnColor(OPN::kBrandGreen, 0.98).CGColor;
        _playButton.layer.shadowColor = OpnColor(OPN::kBrandGreen).CGColor;
        _playButton.layer.shadowOpacity = prominent ? 0.42 : 0.0;
        _playButton.layer.shadowRadius = prominent ? 24.0 : 0.0;
        _playButton.layer.shadowOffset = CGSizeZero;
        _playButton.hidden = !prominent;
        _playButton.target = self;
        _playButton.action = @selector(selectPressed);
        [self addSubview:_playButton];

        self.selectedVariantIndex = _selectedVariantIndex;
        [self loadImage];
        [self updateTrackingAreas];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (OPN::GameInfo)game { return _gameData; }

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    NSView *hitView = [super hitTest:point];
    if (!hitView) return nil;
    if (hitView == self.playButton || [hitView isDescendantOf:self.playButton]) return hitView;
    return self;
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    self.imageView.frame = self.bounds;
    self.gradientOverlay.frame = self.bounds;
    self.gradientLayer.frame = self.gradientOverlay.bounds;
    self.shineLayer.frame = NSMakeRect(width * 0.10, height - 5.0, width * 0.80, 5.0);
    self.shineLayer.cornerRadius = 2.5;
    self.accentLayer.frame = self.prominent ? NSMakeRect(0.0, 0.0, 5.0, height) : NSMakeRect(0.0, 0.0, width, 3.0);
    if (self.prominent) {
        CGFloat iconSize = 34.0;
        CGFloat iconGap = 8.0;
        CGFloat badgeWidth = self.storeIconViews.count * iconSize + MAX((NSUInteger)0, self.storeIconViews.count - 1) * iconGap;
        self.storeBadgeView.frame = NSMakeRect(30.0, 28.0, badgeWidth, 34.0);
        for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
            NSImageView *iconView = self.storeIconViews[index];
            iconView.frame = NSMakeRect(index * (iconSize + iconGap), 0.0, iconSize, iconSize);
            iconView.layer.cornerRadius = iconSize * 0.5;
        }
        self.availabilityLabel.frame = NSMakeRect(width - 188.0, 34.0, 150.0, 20.0);
        self.metaLabel.frame = NSMakeRect(30.0, height - 150.0, width - 220.0, 20.0);
        self.titleLabel.frame = NSMakeRect(30.0, height - 126.0, width - 220.0, 74.0);
        self.featureLabel.frame = NSMakeRect(30.0, height - 49.0, width - 210.0, 21.0);
        self.playButton.frame = NSMakeRect(width - 152.0, height - 70.0, 112.0, 42.0);
        self.playButton.layer.cornerRadius = 21.0;
    } else {
        CGFloat iconSize = 28.0;
        CGFloat iconGap = 6.0;
        CGFloat badgeWidth = self.storeIconViews.count * iconSize + MAX((NSUInteger)0, self.storeIconViews.count - 1) * iconGap;
        self.storeBadgeView.frame = NSMakeRect(12.0, 12.0, badgeWidth, 28.0);
        for (NSUInteger index = 0; index < self.storeIconViews.count; index++) {
            NSImageView *iconView = self.storeIconViews[index];
            iconView.frame = NSMakeRect(index * (iconSize + iconGap), 0.0, iconSize, iconSize);
            iconView.layer.cornerRadius = iconSize * 0.5;
        }
        self.availabilityLabel.frame = NSZeroRect;
        self.metaLabel.frame = NSZeroRect;
        self.titleLabel.frame = NSZeroRect;
        self.featureLabel.frame = NSZeroRect;
        self.playButton.frame = NSMakeRect(width - 64.0, height - 48.0, 50.0, 28.0);
        self.playButton.layer.cornerRadius = 14.0;
    }
    BOOL showProminentText = self.prominent;
    self.titleLabel.hidden = !showProminentText;
    self.metaLabel.hidden = !showProminentText;
    self.featureLabel.hidden = !showProminentText;
    self.availabilityLabel.hidden = !showProminentText;
}

- (void)setStoreFocused:(BOOL)focused {
    _storeFocused = focused;
    self.alphaValue = 1.0;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.18];
    self.layer.borderWidth = focused ? 2.5 : 1.0;
    self.layer.borderColor = (focused ? OpnColor(OPN::kBrandGreen, 0.98) : OpnColor(0xFFFFFF, self.prominent ? 0.18 : 0.12)).CGColor;
    for (NSImageView *iconView in self.storeIconViews) {
        iconView.layer.borderColor = (focused ? OpnColor(OPN::kBrandGreen, 0.88) : OpnColor(0xFFFFFF, 0.18)).CGColor;
    }
    self.shineLayer.opacity = focused ? 1.0 : (self.prominent ? 0.88 : 0.52);
    self.layer.shadowColor = OpnColor(OPN::kBrandGreen, 1.0).CGColor;
    self.layer.shadowOpacity = focused ? 0.38 : 0.0;
    self.layer.shadowRadius = focused ? 26.0 : 0.0;
    self.layer.shadowOffset = CGSizeZero;
    self.layer.zPosition = focused ? 10.0 : 0.0;
    CATransform3D transform = CATransform3DIdentity;
    if (focused) transform = CATransform3DScale(transform, self.prominent ? 1.020 : 1.055, self.prominent ? 1.020 : 1.055, 1.0);
    self.layer.transform = transform;
    [CATransaction commit];
    self.playButton.hidden = !(self.prominent || focused);
}

- (void)selectPressed {
    if (OPNStoreGameNeedsPurchase(self.gameData, self.selectedVariantIndex)) {
        NSString *purchaseURL = OPNStorePurchaseURLForGame(self.gameData, self.selectedVariantIndex);
        if (self.onBuy) self.onBuy(purchaseURL ?: @"");
        return;
    }
    if (self.onSelect) self.onSelect();
}

- (void)activate {
    [self selectPressed];
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self selectPressed];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (!self.prominent) self.playButton.hidden = NO;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.42).CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.prominent && !self.storeFocused) self.playButton.hidden = YES;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(0xFFFFFF, self.prominent ? 0.18 : 0.12).CGColor;
}

- (void)resetMouseTrackingIfOutside {
    if (self.prominent || self.storeFocused) return;
    NSWindow *window = self.window;
    if (!window) return;
    NSPoint screenPoint = [NSEvent mouseLocation];
    NSPoint windowPoint = [window convertPointFromScreen:screenPoint];
    NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
    if (!NSPointInRect(localPoint, self.bounds)) {
        self.playButton.hidden = YES;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.12).CGColor;
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea && [self.trackingAreas containsObject:self.trackingArea]) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)loadImage {
    self.imageLoadGeneration++;
    NSArray<NSString *> *candidates = OPNStoreImageCandidatesForGame(_gameData, self.prominent);
    if (candidates.count == 0) {
        self.imageView.image = OPNStoreFallbackArtworkImage();
        return;
    }
    [self loadImageFromCandidates:candidates index:0];
}

- (void)loadImageFromCandidates:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index {
    NSUInteger generation = self.imageLoadGeneration;
    if (index >= urlStrings.count) {
        if (!self.imageView.image) self.imageView.image = OPNStoreFallbackArtworkImage();
        return;
    }
    NSString *urlString = urlStrings[index];
    if (urlString.length == 0) {
        [self loadImageFromCandidates:urlStrings index:index + 1];
        return;
    }

    __weak __typeof__(self) weakSelf = self;
    CGFloat scale = self.window.screen.backingScaleFactor > 0.0 ? self.window.screen.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
    CGFloat maxPixelDimension = MAX(NSWidth(self.bounds), NSHeight(self.bounds)) * MAX(1.0, scale) * (self.prominent ? 1.6 : 1.25);
    OpnLoadImageForURL(urlString, maxPixelDimension, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.imageLoadGeneration) return;
        if (!image) {
            [strongSelf loadImageFromCandidates:urlStrings index:index + 1];
            return;
        }
        NSTimeInterval revealDelay = strongSelf.imageView.image ? 0.0 : strongSelf.imageRevealDelay;
        strongSelf.imageView.alphaValue = 0.0;
        strongSelf.imageView.image = image;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(revealDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __typeof__(self) revealSelf = weakSelf;
            if (!revealSelf || generation != revealSelf.imageLoadGeneration) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                revealSelf.imageView.animator.alphaValue = 1.0;
            } completionHandler:nil];
        });
    });
}

@end

@interface OPNGameCatalogView ()
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, assign) std::vector<OPN::PanelResult> panels;
@property (nonatomic, assign) std::vector<OPN::GameInfo> libraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<OPNStoreGameTile *> *> *rowCards;
@property (nonatomic, strong) NSMutableArray<OpnImageLoadToken *> *heroImageLoadTokens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *heroAspectByIdentity;
@property (nonatomic, strong) NSTimer *heroRotationTimer;
@property (nonatomic, strong) NSMutableArray<NSView *> *desktopFeaturedHeroViews;
@property (nonatomic, assign) NSRect desktopFeaturedHeroFrame;
@property (nonatomic, assign) NSInteger currentHeroIndex;
@property (nonatomic, assign) NSInteger focusedRowIndex;
@property (nonatomic, assign) NSInteger focusedColumnIndex;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) BOOL renderStoreScheduled;
@property (nonatomic, assign) std::string panelsFingerprint;
- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)addDesktopHeroStageForGame:(const OPN::GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height;
- (void)cancelHeroImageLoads;
- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token;
- (CGFloat)heroAspectForGame:(const OPN::GameInfo &)game;
- (void)updateDesktopFeaturedHeroOnly;
- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width;
- (void)scheduleRenderStore;
- (BOOL)mergeKnownStoreMetadataIntoPanels;
- (void)refreshLibrarySelections;
- (void)updateFocusedTiles;
- (void)updateHeroTileOnly;
@end

@implementation OPNGameCatalogView

using namespace OPN;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        _rowCards = [NSMutableArray array];
        _heroImageLoadTokens = [NSMutableArray array];
        _heroAspectByIdentity = [NSMutableDictionary dictionary];
        _desktopFeaturedHeroViews = [NSMutableArray array];
        _desktopFeaturedHeroFrame = NSZeroRect;
        _focusedRowIndex = 0;
        _focusedColumnIndex = 0;
        _scrollView = [[NSScrollView alloc] initWithFrame:self.bounds];
        _scrollView.drawsBackground = NO;
        _scrollView.borderType = NSNoBorder;
        _scrollView.hasVerticalScroller = YES;
        _scrollView.hasHorizontalScroller = NO;
        _scrollView.autohidesScrollers = YES;
        _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_scrollView];

        _documentView = [[OPNStoreDocumentView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
        _documentView.wantsLayer = YES;
        _scrollView.documentView = _documentView;

        _statusLabel = OpnLabel(@"", NSZeroRect, 15.0, OpnColor(kTextMuted), NSFontWeightMedium, NSTextAlignmentCenter);
        [self addSubview:_statusLabel];

        _loadingView = [[OPNLoadingView alloc] initWithFrame:self.bounds message:@"Loading games..."];
        _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _loadingView.hidden = YES;
        [self addSubview:_loadingView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(interfacePreferencesChanged:)
                                                     name:OPNInterfacePreferencesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(storeScrollViewBoundsDidChange:)
                                                     name:NSViewBoundsDidChangeNotification
                                                   object:_scrollView.contentView];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)hasContent { return self.rowCards.count > 0 || self.desktopFeaturedHeroViews.count > 0; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.heroRotationTimer invalidate];
    [self cancelHeroImageLoads];
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self renderStore];
}

- (void)setLoading:(BOOL)loading {
    BOOL showBlockingLoader = loading && !self.hasContent;
    self.loadingView.hidden = !showBlockingLoader;
    self.statusLabel.stringValue = @"";
    if (showBlockingLoader) {
        [self.loadingView startAnimating];
    } else {
        [self.loadingView stopAnimating];
    }
}

- (void)setError:(NSString *)message {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    [self setLoading:NO];
    self.statusLabel.stringValue = message ?: @"";
}

- (void)setGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    std::vector<PanelResult> catalogPanels = OPNCatalogPanelsForGames(games);
    NSInteger gameCount = 0;
    for (const PanelResult &panel : catalogPanels) {
        for (const PanelSection &section : panel.sections) {
            gameCount += (NSInteger)section.games.size();
        }
    }
    if (self.onGameCountChanged) self.onGameCountChanged(gameCount);
    [self setPanels:catalogPanels];
}

- (void)setCatalogBrowseResult:(const OPN::CatalogBrowseResult &)result {
    [self setGames:result.games];
    if (self.onGameCountChanged) {
        NSInteger count = result.totalCount > 0 ? result.totalCount : (NSInteger)result.games.size();
        self.onGameCountChanged(count);
    }
}

- (void)setActiveSessionAppIds:(const std::vector<int> &)appIds {
    (void)appIds;
}

- (void)setUserName:(NSString *)name {
    (void)name;
}

- (void)setPanels:(const std::vector<OPN::PanelResult> &)panels {
    std::string fingerprint = OPNStorePanelsFingerprint(panels);
    if (self.hasContent && fingerprint == self.panelsFingerprint) {
        _panels = panels;
        [self mergeKnownStoreMetadataIntoPanels];
        [self refreshLibrarySelections];
        return;
    }
    _panels = panels;
    self.panelsFingerprint = fingerprint;
    [self mergeKnownStoreMetadataIntoPanels];
    self.currentHeroIndex = 0;
    [self configureHeroRotationTimer];
    [self renderStore];
}

- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games {
    _featuredGames = games;
    self.currentHeroIndex = 0;
    [self configureHeroRotationTimer];
    [self renderStore];
}

- (void)setLibraryGames:(const std::vector<OPN::GameInfo> &)games {
    _libraryGames = games;
    [self mergeKnownStoreMetadataIntoPanels];
    if (self.rowCards.count > 0 || self.desktopFeaturedHeroViews.count > 0) {
        [self refreshLibrarySelections];
    } else if (!_panels.empty()) {
        [self renderStore];
    }
}

- (BOOL)mergeKnownStoreMetadataIntoPanels {
    if (_panels.empty() || _libraryGames.empty()) return NO;
    BOOL changed = NO;
    for (PanelResult &panel : _panels) {
        for (PanelSection &section : panel.sections) {
            for (GameInfo &storeGame : section.games) {
                for (const GameInfo &knownGame : _libraryGames) {
                    if (!OPNStoreGameMatchesLibraryGame(storeGame, knownGame)) continue;
                    if (OPNStoreMergeGameStoreMetadata(storeGame, knownGame)) changed = YES;
                }
            }
        }
    }
    return changed;
}

- (int)selectedVariantIndexForStoreGame:(const GameInfo &)storeGame {
    for (const GameInfo &libraryGame : _libraryGames) {
        if (!OPNStoreGameMatchesLibraryGame(storeGame, libraryGame)) continue;
        int libraryVariantIndex = OPNStoreSelectedLibraryVariantIndex(libraryGame);
        if (libraryVariantIndex < 0 || libraryVariantIndex >= (int)libraryGame.variants.size()) return storeGame.variants.empty() ? -1 : 0;

        const GameVariant &libraryVariant = libraryGame.variants[(size_t)libraryVariantIndex];
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.id.empty() && storeVariant.id == libraryVariant.id) return (int)i;
        }
        for (size_t i = 0; i < storeGame.variants.size(); i++) {
            const GameVariant &storeVariant = storeGame.variants[i];
            if (!libraryVariant.appStore.empty() && OPNStoreStringEqualsCaseInsensitive(storeVariant.appStore, libraryVariant.appStore)) return (int)i;
        }
    }
    return storeGame.variants.empty() ? -1 : 0;
}

- (NSInteger)heroCandidateCount {
    return MIN((NSInteger)6, (NSInteger)_featuredGames.size());
}

- (const GameInfo *)currentHeroGame {
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount <= 0) return nullptr;
    NSInteger target = ((self.currentHeroIndex % candidateCount) + candidateCount) % candidateCount;
    return &_featuredGames[(size_t)target];
}

- (void)configureHeroRotationTimer {
    [self.heroRotationTimer invalidate];
    self.heroRotationTimer = nil;
    if ([self heroCandidateCount] < 2) return;

    self.heroRotationTimer = [NSTimer scheduledTimerWithTimeInterval:7.0
                                                              target:self
                                                            selector:@selector(heroRotationTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)heroRotationTimerFired:(NSTimer *)timer {
    (void)timer;
    NSInteger candidateCount = [self heroCandidateCount];
    if (candidateCount < 2) return;
    self.currentHeroIndex = (self.currentHeroIndex + 1) % candidateCount;
    [self updateHeroTileOnly];
}

- (void)layout {
    [super layout];
    CGFloat navClearance = kStoreNavigationClearance;
    self.scrollView.frame = NSMakeRect(0.0, navClearance, NSWidth(self.bounds), MAX(0.0, NSHeight(self.bounds) - navClearance));
    self.loadingView.frame = self.bounds;
    self.statusLabel.frame = NSMakeRect(0, NSHeight(self.bounds) * 0.5, NSWidth(self.bounds), 26.0);
    if (std::fabs(self.lastLayoutWidth - NSWidth(self.bounds)) > 1.0) {
        self.lastLayoutWidth = NSWidth(self.bounds);
        [self scheduleRenderStore];
    }
}

- (void)scheduleRenderStore {
    if (self.renderStoreScheduled) return;
    self.renderStoreScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderStoreScheduled = NO;
        [self renderStore];
    });
}

- (void)cancelHeroImageLoads {
    for (OpnImageLoadToken *token in self.heroImageLoadTokens) [token cancel];
    [self.heroImageLoadTokens removeAllObjects];
}

- (void)trackHeroImageLoadToken:(OpnImageLoadToken *)token {
    if (!token) return;
    [self.heroImageLoadTokens addObject:token];
    if (self.heroImageLoadTokens.count > 12) [self.heroImageLoadTokens removeObjectsInRange:NSMakeRange(0, self.heroImageLoadTokens.count - 8)];
}

- (CGFloat)heroAspectForGame:(const GameInfo &)game {
    NSNumber *aspect = self.heroAspectByIdentity[OpnGameIdentityForHero(game)];
    return aspect.doubleValue > 0.0 ? aspect.doubleValue : kStoreFallbackHeroAspect;
}

- (void)refreshLibrarySelections {
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *card in row) {
            card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:card.game];
        }
    }
    [self updateFocusedTiles];
}

- (void)renderStore {
    [self cancelHeroImageLoads];
    for (NSView *view in [self.documentView.subviews copy]) {
        [view removeFromSuperview];
    }
    [self.rowCards removeAllObjects];
    [self.desktopFeaturedHeroViews removeAllObjects];
    self.desktopFeaturedHeroFrame = NSZeroRect;

    CGFloat viewportWidth = MAX(1.0, NSWidth(self.bounds));
    CGFloat width = MAX(980.0, viewportWidth);
    CGFloat contentX = OPNStoreHeroContentInsetForWidth(width);
    CGFloat contentWidth = MAX(680.0, width - contentX * 2.0);
    CGFloat y = kStoreTopInset;

    const GameInfo *heroGame = [self currentHeroGame];

    CGFloat heroHeight = 0.0;
    if (heroGame) {
        CGFloat heroAspect = [self heroAspectForGame:*heroGame];
        heroHeight = floor(viewportWidth / MAX(0.1, heroAspect));
        [self addDesktopHeroStageForGame:*heroGame y:y contentX:0.0 width:viewportWidth height:heroHeight];
    }

    CGFloat rowY = heroGame ? y + heroHeight + 48.0 : y;
    NSInteger renderedRows = 0;
    for (const PanelResult &panel : _panels) {
        for (const PanelSection &section : panel.sections) {
            if (section.games.empty()) continue;
            [self addSection:section index:renderedRows y:rowY contentX:contentX width:width];
            rowY += kStoreRowHeight;
            renderedRows++;
        }
    }

    if (renderedRows == 0 && !self.loadingView.hidden) {
        self.statusLabel.stringValue = @"";
    } else if (renderedRows == 0) {
        self.statusLabel.stringValue = @"";
        [self addEmptyStoreStateWithY:rowY contentX:contentX width:contentWidth];
        rowY += 260.0;
    } else {
        self.statusLabel.stringValue = @"";
    }

    CGFloat documentHeight = MAX(NSHeight(self.bounds), rowY + 88.0);
    self.documentView.frame = NSMakeRect(0, 0, width, documentHeight);
    [self updateFocusedTiles];
}

- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width {
    NSView *emptyPanel = [[NSView alloc] initWithFrame:NSMakeRect(contentX, y, width, 220.0)];
    emptyPanel.wantsLayer = YES;
    emptyPanel.layer.cornerRadius = 28.0;
    emptyPanel.layer.backgroundColor = OpnColor(0xFFFFFF, 0.045).CGColor;
    emptyPanel.layer.borderWidth = 1.0;
    emptyPanel.layer.borderColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    [self.documentView addSubview:emptyPanel];

    NSTextField *eyebrow = OpnLabel(@"SIGNAL LOST", NSMakeRect(0.0, 54.0, width, 18.0), 12.0, OpnColor(kBrandGreen), NSFontWeightBlack, NSTextAlignmentCenter);
    [emptyPanel addSubview:eyebrow];
    NSTextField *title = OpnLabel(@"No games found", NSMakeRect(0.0, 78.0, width, 34.0), 27.0, OpnColor(kTextPrimary), NSFontWeightBold, NSTextAlignmentCenter);
    [emptyPanel addSubview:title];
    NSTextField *subtitle = OpnLabel(@"The catalog returned no games. Try again after the service refreshes.", NSMakeRect(0.0, 120.0, width, 22.0), 13.0, OpnColor(kTextSecondary), NSFontWeightMedium, NSTextAlignmentCenter);
    [emptyPanel addSubview:subtitle];
}

- (void)addDesktopHeroStageForGame:(const GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height {
    self.desktopFeaturedHeroFrame = NSMakeRect(contentX, y, width, height);

    OPNHeroArtworkView *artwork = [[OPNHeroArtworkView alloc] initWithFrame:self.desktopFeaturedHeroFrame];
    artwork.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.documentView addSubview:artwork];
    [self loadFeaturedHeroImageForView:artwork gameIdentity:OpnGameIdentityForHero(game) candidates:OpnHeroImageCandidatesForGame(game) index:0];
    [self.desktopFeaturedHeroViews addObject:artwork];
}

- (void)loadFeaturedHeroImageForView:(OPNHeroArtworkView *)view gameIdentity:(NSString *)gameIdentity candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view) return;
    if (index >= candidates.count) {
        view.image = OpnFallbackHeroArtworkImage();
        return;
    }
    NSString *urlString = candidates[index];
    if (urlString.length == 0) {
        [self loadFeaturedHeroImageForView:view gameIdentity:gameIdentity candidates:candidates index:index + 1];
        return;
    }

    __weak OPNHeroArtworkView *weakView = view;
    __weak __typeof__(self) weakSelf = self;
    OpnImageLoadToken *token = OpnLoadImageForURLCancellable(urlString, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        __typeof__(self) strongSelf = weakSelf;
        OPNHeroArtworkView *strongView = weakView;
        if (!strongView.superview) return;
        if (!image) {
            [strongSelf loadFeaturedHeroImageForView:strongView gameIdentity:gameIdentity candidates:candidates index:index + 1];
            return;
        }
        if (image.size.width > 0.0 && image.size.height > 0.0 && gameIdentity.length > 0) {
            CGFloat aspect = image.size.width / image.size.height;
            NSNumber *previousAspect = strongSelf.heroAspectByIdentity[gameIdentity];
            strongSelf.heroAspectByIdentity[gameIdentity] = @(aspect);
            const GameInfo *currentHero = [strongSelf currentHeroGame];
            BOOL currentHeroMatches = currentHero && [OpnGameIdentityForHero(*currentHero) isEqualToString:gameIdentity];
            if (currentHeroMatches && (!previousAspect || std::fabs(previousAspect.doubleValue - aspect) > 0.01)) {
                [strongSelf scheduleRenderStore];
                return;
            }
        }
        strongView.image = image;
    });
    [self trackHeroImageLoadToken:token];
}

- (void)updateHeroTileOnly {
    [self updateDesktopFeaturedHeroOnly];
}

- (void)updateDesktopFeaturedHeroOnly {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || self.desktopFeaturedHeroViews.count == 0 || NSIsEmptyRect(self.desktopFeaturedHeroFrame)) {
        [self renderStore];
        return;
    }

    NSArray<NSView *> *oldViews = [self.desktopFeaturedHeroViews copy];
    [self.desktopFeaturedHeroViews removeAllObjects];
    NSRect frame = self.desktopFeaturedHeroFrame;
    [self addDesktopHeroStageForGame:*heroGame y:NSMinY(frame) contentX:NSMinX(frame) width:NSWidth(frame) height:NSHeight(frame)];
    for (NSView *newView in self.desktopFeaturedHeroViews) newView.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        for (NSView *oldView in oldViews) oldView.animator.alphaValue = 0.0;
        for (NSView *newView in self.desktopFeaturedHeroViews) newView.animator.alphaValue = 1.0;
    } completionHandler:^{
        for (NSView *oldView in oldViews) [oldView removeFromSuperview];
    }];
}

- (void)addSection:(const PanelSection &)section index:(NSInteger)sectionIndex y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width {
    CGFloat rightInset = contentX;
    CGFloat availableWidth = MAX(320.0, width - contentX - rightInset);
    NSString *sectionTitle = section.title.empty() ? @"Featured" : [NSString stringWithUTF8String:section.title.c_str()];

    NSView *rowGlow = [[NSView alloc] initWithFrame:NSMakeRect(contentX - 18.0, y + 36.0, availableWidth + 36.0, kStoreTileHeight + 44.0)];
    rowGlow.wantsLayer = YES;
    rowGlow.layer.cornerRadius = 24.0;
    rowGlow.layer.backgroundColor = OpnColor(0xFFFFFF, 0.032).CGColor;
    rowGlow.layer.borderWidth = 1.0;
    rowGlow.layer.borderColor = OpnColor(0xFFFFFF, 0.055).CGColor;
    [self.documentView addSubview:rowGlow];

    NSTextField *indexLabel = OpnLabel([NSString stringWithFormat:@"%02ld", (long)sectionIndex + 1], NSMakeRect(contentX, y + 5.0, 42.0, 18.0), 11.0, OpnColor(kBrandGreen), NSFontWeightBlack);
    [self.documentView addSubview:indexLabel];
    NSTextField *label = OpnLabel(sectionTitle, NSMakeRect(contentX + 42.0, y, availableWidth - 142.0, 30.0), 23.0, OpnColor(kTextPrimary), NSFontWeightBold);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.documentView addSubview:label];
    NSString *hintText = [NSString stringWithFormat:@"%ld games", (long)section.games.size()];
    NSTextField *railHint = OpnLabel(hintText, NSMakeRect(contentX + availableWidth - 110.0, y + 6.0, 110.0, 18.0), 12.0, OpnColor(kTextMuted), NSFontWeightSemibold, NSTextAlignmentRight);
    [self.documentView addSubview:railHint];

    OPNStoreRailScrollView *rowScroll = [[OPNStoreRailScrollView alloc] initWithFrame:NSMakeRect(contentX, y + 48.0, availableWidth, kStoreTileHeight + 30.0)];
    rowScroll.drawsBackground = NO;
    rowScroll.borderType = NSNoBorder;
    rowScroll.hasHorizontalScroller = YES;
    rowScroll.hasVerticalScroller = NO;
    rowScroll.autohidesScrollers = YES;
    [self.documentView addSubview:rowScroll];

    OPNStoreDocumentView *rowDocument = [[OPNStoreDocumentView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(rowScroll.frame), kStoreTileHeight + 30.0)];
    rowDocument.wantsLayer = YES;
    rowScroll.documentView = rowDocument;

    NSMutableArray<OPNStoreGameTile *> *cards = [NSMutableArray array];
    CGFloat x = 0.0;
    NSInteger column = 0;
    NSInteger maxCards = 24;
    for (const GameInfo &game : section.games) {
        BOOL focused = NO;
        CGFloat cardWidth = focused ? kStoreTileWidth + 28.0 : kStoreTileWidth;
        CGFloat cardHeight = focused ? kStoreTileHeight + 16.0 : kStoreTileHeight;
        CGFloat cardY = focused ? 0.0 : 10.0;
        OPNStoreGameTile *card = [[OPNStoreGameTile alloc] initWithFrame:NSMakeRect(x, cardY, cardWidth, cardHeight) game:game prominent:NO];
        card.imageRevealDelay = MIN(0.42, 0.035 * column + 0.025 * sectionIndex);
        card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:game];
        [card setStoreFocused:focused];
        __weak __typeof__(self) weakSelf = self;
        __weak OPNStoreGameTile *weakCard = card;
        card.onSelect = ^{
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onSelectGame) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onSelectGame(strongCard.game, variantIndex);
        };
        card.onBuy = ^(NSString *purchaseURL) {
            __typeof__(self) strongSelf = weakSelf;
            OPNStoreGameTile *strongCard = weakCard;
            if (!strongSelf || !strongCard || !strongSelf.onBuyGame) return;
            int variantIndex = strongCard.selectedVariantIndex >= 0 ? strongCard.selectedVariantIndex : 0;
            strongSelf.onBuyGame(strongCard.game, variantIndex, purchaseURL ?: @"");
        };
        [rowDocument addSubview:card];
        [cards addObject:card];
        x += cardWidth + kStoreCardSpacing;
        column++;
        if (column >= maxCards) break;
    }
    rowDocument.frame = NSMakeRect(0, 0, MAX(x + 24.0, NSWidth(rowScroll.frame)), kStoreTileHeight + 30.0);
    [self.rowCards addObject:cards];
}

- (void)updateFocusedTiles {
    if (self.rowCards.count == 0) return;
    self.focusedRowIndex = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex));
    NSMutableArray<OPNStoreGameTile *> *focusedRow = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (focusedRow.count == 0) return;
    self.focusedColumnIndex = MAX(0, MIN((NSInteger)focusedRow.count - 1, self.focusedColumnIndex));
    for (NSUInteger rowIndex = 0; rowIndex < self.rowCards.count; rowIndex++) {
        NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[rowIndex];
        for (NSUInteger columnIndex = 0; columnIndex < row.count; columnIndex++) {
            [row[columnIndex] setStoreFocused:(NSInteger)rowIndex == self.focusedRowIndex && (NSInteger)columnIndex == self.focusedColumnIndex];
        }
    }
}

- (void)scrollFocusedTileIntoView {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    OPNStoreGameTile *tile = row[(NSUInteger)self.focusedColumnIndex];
    NSRect tileInDocument = [tile convertRect:tile.bounds toView:self.documentView];
    [self.documentView scrollRectToVisible:NSInsetRect(tileInDocument, -28.0, -46.0)];
    [tile scrollRectToVisible:NSInsetRect(tile.bounds, -24.0, -12.0)];
}

- (void)moveGamepadFocusByRows:(NSInteger)rowDelta columns:(NSInteger)columnDelta {
    if (self.rowCards.count == 0) return;
    NSInteger nextRow = MAX(0, MIN((NSInteger)self.rowCards.count - 1, self.focusedRowIndex + rowDelta));
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)nextRow];
    if (row.count == 0) return;
    NSInteger nextColumn = self.focusedColumnIndex + columnDelta;
    if (nextRow != self.focusedRowIndex && columnDelta == 0) nextColumn = MIN(nextColumn, (NSInteger)row.count - 1);
    nextColumn = MAX(0, MIN((NSInteger)row.count - 1, nextColumn));
    if (nextRow == self.focusedRowIndex && nextColumn == self.focusedColumnIndex) return;
    self.focusedRowIndex = nextRow;
    self.focusedColumnIndex = nextColumn;
    [self updateFocusedTiles];
    [self scrollFocusedTileIntoView];
}

- (void)moveGamepadFocusBy:(NSInteger)delta {
    [self moveGamepadFocusByRows:0 columns:delta];
}

- (void)activateGamepadFocus {
    if (self.focusedRowIndex < 0 || self.focusedRowIndex >= (NSInteger)self.rowCards.count) return;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (self.focusedColumnIndex < 0 || self.focusedColumnIndex >= (NSInteger)row.count) return;
    [row[(NSUInteger)self.focusedColumnIndex] activate];
}

- (void)storeScrollViewBoundsDidChange:(NSNotification *)notification {
    if (notification.object != self.scrollView.contentView) return;
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *tile in row) {
            [tile resetMouseTrackingIfOutside];
        }
    }
}

@end
