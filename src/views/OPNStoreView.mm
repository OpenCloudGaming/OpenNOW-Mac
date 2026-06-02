#import "OPNStoreView.h"
#import "OPNLoadingView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNUIHelpers.h"
#import <GameController/GameController.h>
#include <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cctype>
#include <cmath>

static const CGFloat kStoreTopInset = 170.0;
static const CGFloat kStoreNavigationClearance = 0.0;
static const CGFloat kControllerStoreNavigationClearance = 0.0;
static const CGFloat kStoreHeroTopOffset = 0.0;
static const CGFloat kStoreHeroHeightRatio = 0.3229;
static const CGFloat kStoreRowHeight = 258.0;
static const CGFloat kStoreCardSpacing = 18.0;
static const CGFloat kStoreTileWidth = 268.0;
static const CGFloat kStoreTileHeight = 151.0;
static const CGFloat kStoreHeroMinContentInset = 30.0;
static const CGFloat kStoreHeroMaxContentInset = 106.0;
static const CGFloat kStoreHeroContentInsetRatio = 0.055;
static const CGFloat kControllerStoreHeroTop = 30.0;
static const CGFloat kControllerStoreRailHeight = 276.0;

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

static CGFloat OPNStoreHeroHeightForSize(CGFloat width, CGFloat height) {
    CGFloat viewportHeroHeight = MIN(520.0, MAX(250.0, MAX(1.0, height) * 0.32));
    return floor(MIN(viewportHeroHeight, MAX(1.0, width) * kStoreHeroHeightRatio));
}

@interface OPNStoreAmbientView : NSView
@property (nonatomic, assign) CGFloat intensity;
@end

@implementation OPNStoreAmbientView

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _intensity = 1.0;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSIsEmptyRect(bounds)) return;

    NSGradient *base = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x020405, 1.0), 0.0,
        OpnColor(0x07120D, 1.0), 0.34,
        OpnColor(0x11141A, 1.0), 0.62,
        OpnColor(0x030405, 1.0), 1.0,
        nil];
    [base drawInRect:bounds angle:-38.0];

    NSGradient *greenBloom = [[NSGradient alloc] initWithColors:@[
        OpnColor(OPN::kBrandGreen, 0.24 * self.intensity),
        OpnColor(OPN::kBrandGreen, 0.06 * self.intensity),
        OpnColor(OPN::kBrandGreen, 0.0)
    ]];
    [greenBloom drawFromCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.20, NSMinY(bounds) + 188.0)
                        radius:12.0
                      toCenter:NSMakePoint(NSMinX(bounds) + NSWidth(bounds) * 0.24, NSMinY(bounds) + 230.0)
                        radius:620.0
                       options:0];

    NSGradient *violetBloom = [[NSGradient alloc] initWithColors:@[
        OpnColor(0x4D7CFF, 0.14 * self.intensity),
        OpnColor(0x4D7CFF, 0.035 * self.intensity),
        OpnColor(0x4D7CFF, 0.0)
    ]];
    [violetBloom drawFromCenter:NSMakePoint(NSMaxX(bounds) - NSWidth(bounds) * 0.17, NSMinY(bounds) + 160.0)
                         radius:10.0
                       toCenter:NSMakePoint(NSMaxX(bounds) - NSWidth(bounds) * 0.24, NSMinY(bounds) + 240.0)
                         radius:560.0
                        options:0];

    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRect:bounds];
    [clip addClip];
    [OpnColor(0xFFFFFF, 0.028 * self.intensity) setStroke];
    for (CGFloat x = -NSHeight(bounds); x < NSWidth(bounds) + NSHeight(bounds); x += 58.0) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, 0.0)];
        [line lineToPoint:NSMakePoint(x + NSHeight(bounds) * 0.78, NSHeight(bounds))];
        line.lineWidth = 1.0;
        [line stroke];
    }
    [NSGraphicsContext restoreGraphicsState];

    NSGradient *vignette = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x000000, 0.0), 0.0,
        OpnColor(0x000000, 0.72), 1.0,
        nil];
    [vignette drawInRect:bounds angle:-90.0];
}

@end

@interface OPNStoreHeroBackgroundView : NSView
@property (nonatomic, strong) NSImage *image;
@property (nonatomic, assign) CGFloat cornerRadius;
@end

@implementation OPNStoreHeroBackgroundView

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _cornerRadius = 20.0;
    }
    return self;
}

- (void)setImage:(NSImage *)image {
    _image = image;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (NSIsEmptyRect(bounds)) return;

    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:self.cornerRadius yRadius:self.cornerRadius];
    [NSGraphicsContext saveGraphicsState];
    [clipPath addClip];

    NSGradient *fallback = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x0A1115), 0.0,
        OpnColor(0x152020), 0.48,
        OpnColor(0x07090C), 1.0,
        nil];
    [fallback drawInRect:bounds angle:0.0];

    if (self.image && self.image.size.width > 0.0 && self.image.size.height > 0.0) {
        CGFloat imageAspect = self.image.size.width / self.image.size.height;
        CGFloat boundsAspect = NSWidth(bounds) / MAX(1.0, NSHeight(bounds));
        NSRect sourceRect = NSMakeRect(0.0, 0.0, self.image.size.width, self.image.size.height);
        if (imageAspect > boundsAspect) {
            CGFloat sourceWidth = self.image.size.height * boundsAspect;
            sourceRect.origin.x = floor((self.image.size.width - sourceWidth) * 0.5);
            sourceRect.size.width = sourceWidth;
        } else {
            CGFloat sourceHeight = self.image.size.width / boundsAspect;
            sourceRect.origin.y = floor((self.image.size.height - sourceHeight) * 0.5);
            sourceRect.size.height = sourceHeight;
        }
        [self.image drawInRect:bounds fromRect:sourceRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    }

    NSGradient *leftScrim = [[NSGradient alloc] initWithColorsAndLocations:
        OpnColor(0x000000, 0.86), 0.0,
        OpnColor(0x000000, 0.58), 0.34,
        OpnColor(0x000000, 0.12), 0.70,
        OpnColor(0x000000, 0.0), 1.0,
        nil];
    [leftScrim drawInRect:bounds angle:0.0];

    NSGradient *bottomScrim = [[NSGradient alloc] initWithColors:@[
        OpnColor(0x000000, 0.0),
        OpnColor(0x000000, 0.40)
    ]];
    [bottomScrim drawInRect:bounds angle:-90.0];

    [NSGraphicsContext restoreGraphicsState];
}

@end

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

static NSArray<NSString *> *OPNStoreLogoCandidatesForGame(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    OPNStoreAppendImageType(urls, game, "GAME_LOGO");
    OPNStoreAppendImageType(urls, game, "LOGO");
    OPNStoreAppendImageType(urls, game, "TITLE_LOGO");
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

static uint16_t OPNStoreGamepadButtons(void) {
    NSArray<GCController *> *controllers = [GCController controllers];
    if (controllers.count == 0) return 0;
    GCExtendedGamepad *pad = controllers.firstObject.extendedGamepad;
    if (!pad) return 0;
    uint16_t buttons = 0;
    if (pad.buttonA.value > 0.5) buttons |= 1u << 0;
    if (pad.buttonB.value > 0.5) buttons |= 1u << 1;
    if (pad.dpad.up.value > 0.5 || pad.leftThumbstick.yAxis.value > 0.65) buttons |= 1u << 2;
    if (pad.dpad.down.value > 0.5 || pad.leftThumbstick.yAxis.value < -0.65) buttons |= 1u << 3;
    if (pad.dpad.left.value > 0.5 || pad.leftThumbstick.xAxis.value < -0.65) buttons |= 1u << 4;
    if (pad.dpad.right.value > 0.5 || pad.leftThumbstick.xAxis.value > 0.65) buttons |= 1u << 5;
    if (pad.leftShoulder.value > 0.5) buttons |= 1u << 6;
    if (pad.rightShoulder.value > 0.5) buttons |= 1u << 7;
    return buttons;
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

static BOOL OPNStoreGamepadNavigationActive(NSView *view) {
    NSWindow *window = view.window;
    if (!window || window.contentViewController != nil) return NO;
    return window.contentView == view || [view isDescendantOf:window.contentView];
}

static bool OPNStoreVariantIsLibrarySelected(const OPN::GameVariant &variant) {
    return variant.librarySelected || variant.inLibrary ||
           variant.serviceStatus == "MANUAL" ||
           variant.serviceStatus == "PLATFORM_SYNC" ||
           variant.serviceStatus == "IN_LIBRARY";
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
    return variant.inLibrary || variant.librarySelected;
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
        self.availabilityLabel.frame = NSMakeRect(width - 92.0, 18.0, 76.0, 15.0);
        self.metaLabel.frame = NSMakeRect(14.0, height - 59.0, width - 28.0, 17.0);
        self.titleLabel.frame = NSMakeRect(14.0, height - 37.0, width - 28.0, 20.0);
        self.featureLabel.frame = NSMakeRect(14.0, height - 78.0, width - 28.0, 16.0);
        self.playButton.frame = NSMakeRect(width - 64.0, height - 48.0, 50.0, 28.0);
        self.playButton.layer.cornerRadius = 14.0;
    }
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
    self.featureLabel.hidden = !self.prominent && !focused;
}

- (void)selectPressed {
    if (OPNStoreGameNeedsPurchase(self.gameData, self.selectedVariantIndex)) {
        NSString *purchaseURL = OPNStorePurchaseURLForGame(self.gameData, self.selectedVariantIndex);
        if (self.onBuy) self.onBuy(purchaseURL ?: @"");
        return;
    }
    if (self.onSelect) self.onSelect();
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self selectPressed];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    if (!self.prominent) self.playButton.hidden = NO;
    if (!self.prominent) self.featureLabel.hidden = NO;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(OPN::kBrandGreen, 0.42).CGColor;
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    if (!self.prominent && !self.storeFocused) self.playButton.hidden = YES;
    if (!self.prominent && !self.storeFocused) self.featureLabel.hidden = YES;
    if (!self.storeFocused) self.layer.borderColor = OpnColor(0xFFFFFF, self.prominent ? 0.18 : 0.12).CGColor;
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

@interface OPNStoreView ()
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) OPNStoreDocumentView *documentView;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, assign) std::vector<OPN::PanelResult> panels;
@property (nonatomic, assign) std::vector<OPN::GameInfo> libraryGames;
@property (nonatomic, assign) std::vector<OPN::GameInfo> featuredGames;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<OPNStoreGameTile *> *> *rowCards;
@property (nonatomic, strong) NSTimer *heroRotationTimer;
@property (nonatomic, strong) NSTimer *gamepadNavigationTimer;
@property (nonatomic, strong) OPNStoreGameTile *heroTile;
@property (nonatomic, strong) NSMutableArray<NSView *> *controllerFeaturedHeroViews;
@property (nonatomic, strong) NSMutableArray<NSView *> *desktopFeaturedHeroViews;
@property (nonatomic, assign) NSRect controllerFeaturedHeroFrame;
@property (nonatomic, assign) NSRect desktopFeaturedHeroFrame;
@property (nonatomic, assign) NSInteger currentHeroIndex;
@property (nonatomic, assign) NSInteger focusedRowIndex;
@property (nonatomic, assign) NSInteger focusedColumnIndex;
@property (nonatomic, assign) uint16_t previousGamepadButtons;
@property (nonatomic, assign) CFTimeInterval lastGamepadMoveTime;
@property (nonatomic, assign) CGFloat lastLayoutWidth;
@property (nonatomic, assign) BOOL renderStoreScheduled;
@property (nonatomic, assign) std::string panelsFingerprint;
@property (nonatomic, assign) OPN::GameInfo controllerFeaturedHeroGame;
@property (nonatomic, assign) int controllerFeaturedHeroVariantIndex;
- (void)startGamepadNavigationIfNeeded;
- (void)stopGamepadNavigation;
- (void)controllerDidConnect:(NSNotification *)notification;
- (void)controllerDidDisconnect:(NSNotification *)notification;
- (OPNStoreGameTile *)configuredHeroGameTile:(const OPN::GameInfo &)game frame:(NSRect)frame;
- (void)addControllerFeaturedHeroForGame:(const OPN::GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount;
- (void)updateControllerFeaturedHeroOnly;
- (void)loadControllerFeaturedHeroImageForView:(OPNStoreHeroBackgroundView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)loadControllerFeaturedHeroLogoForView:(NSImageView *)view titleFallback:(NSTextField *)titleFallback candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index;
- (void)controllerFeaturedHeroLaunchClicked:(id)sender;
- (void)addDesktopHeroStageForGame:(const OPN::GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height;
- (void)updateDesktopFeaturedHeroOnly;
- (NSView *)storeChipWithTitle:(NSString *)title frame:(NSRect)frame highlighted:(BOOL)highlighted;
- (NSView *)storeIconStripForGame:(const OPN::GameInfo &)game frame:(NSRect)frame;
- (void)addEmptyStoreStateWithY:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width;
- (void)scheduleRenderStore;
- (BOOL)mergeKnownStoreMetadataIntoPanels;
- (void)refreshLibrarySelections;
- (void)updateFocusedTiles;
- (void)updateHeroTileOnly;
- (void)installGamepadValueHandlers;
- (void)requestControllerBackToHome;
@end

@implementation OPNStoreView

using namespace OPN;

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        _rowCards = [NSMutableArray array];
        _controllerFeaturedHeroViews = [NSMutableArray array];
        _desktopFeaturedHeroViews = [NSMutableArray array];
        _controllerFeaturedHeroFrame = NSZeroRect;
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

        _loadingView = [[OPNLoadingView alloc] initWithFrame:self.bounds message:@"Loading Store..."];
        _loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _loadingView.hidden = YES;
        [self addSubview:_loadingView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(interfacePreferencesChanged:)
                                                     name:OPNInterfacePreferencesDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidConnect:)
                                                     name:GCControllerDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(controllerDidDisconnect:)
                                                     name:GCControllerDidDisconnectNotification
                                                   object:nil];
        [self startGamepadNavigationIfNeeded];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)hasContent { return self.heroTile != nil || self.rowCards.count > 0 || self.controllerFeaturedHeroViews.count > 0; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.heroRotationTimer invalidate];
    [self stopGamepadNavigation];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self startGamepadNavigationIfNeeded];
    } else {
        [self stopGamepadNavigation];
    }
}

- (void)interfacePreferencesChanged:(NSNotification *)notification {
    (void)notification;
    [self renderStore];
    [self startGamepadNavigationIfNeeded];
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
    if (self.rowCards.count > 0 || self.heroTile) {
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
    CGFloat navClearance = OpnControllerModeEnabled() ? kControllerStoreNavigationClearance : kStoreNavigationClearance;
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

- (void)refreshLibrarySelections {
    if (self.heroTile) {
        self.heroTile.selectedVariantIndex = [self selectedVariantIndexForStoreGame:self.heroTile.game];
    }
    for (NSMutableArray<OPNStoreGameTile *> *row in self.rowCards) {
        for (OPNStoreGameTile *card in row) {
            card.selectedVariantIndex = [self selectedVariantIndexForStoreGame:card.game];
        }
    }
    [self updateFocusedTiles];
}

- (void)renderStore {
    self.heroTile = nil;
    for (NSView *view in [self.documentView.subviews copy]) {
        [view removeFromSuperview];
    }
    [self.rowCards removeAllObjects];
    [self.controllerFeaturedHeroViews removeAllObjects];
    [self.desktopFeaturedHeroViews removeAllObjects];
    self.controllerFeaturedHeroFrame = NSZeroRect;
    self.desktopFeaturedHeroFrame = NSZeroRect;

    if (OpnControllerModeEnabled()) {
        [self renderControllerStore];
        return;
    }

    CGFloat width = MAX(980.0, NSWidth(self.bounds));
    CGFloat contentX = OPNStoreHeroContentInsetForWidth(width);
    CGFloat contentWidth = MAX(680.0, width - contentX * 2.0);
    CGFloat y = kStoreTopInset;

    OPNStoreAmbientView *ambient = [[OPNStoreAmbientView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, MAX(NSHeight(self.bounds), 1800.0))];
    [self.documentView addSubview:ambient];

    const GameInfo *heroGame = [self currentHeroGame];

    CGFloat heroHeight = 0.0;
    if (heroGame) {
        heroHeight = OPNStoreHeroHeightForSize(contentWidth, NSHeight(self.bounds));
        [self addDesktopHeroStageForGame:*heroGame y:y + kStoreHeroTopOffset contentX:contentX width:contentWidth height:heroHeight];
    }

    CGFloat rowY = heroGame ? y + kStoreHeroTopOffset + heroHeight + 62.0 : y;
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
    ambient.frame = NSMakeRect(0.0, 0.0, width, documentHeight);
    self.documentView.frame = NSMakeRect(0, 0, width, documentHeight);
}

- (NSView *)storeChipWithTitle:(NSString *)title frame:(NSRect)frame highlighted:(BOOL)highlighted {
    NSView *chip = [[NSView alloc] initWithFrame:frame];
    chip.wantsLayer = YES;
    chip.layer.cornerRadius = NSHeight(frame) * 0.5;
    chip.layer.backgroundColor = (highlighted ? OpnColor(kBrandGreen, 0.18) : OpnColor(0xFFFFFF, 0.075)).CGColor;
    chip.layer.borderWidth = 1.0;
    chip.layer.borderColor = (highlighted ? OpnColor(kBrandGreen, 0.54) : OpnColor(0xFFFFFF, 0.11)).CGColor;

    NSTextField *label = OpnLabel(title ?: @"", NSMakeRect(12.0, 5.0, NSWidth(frame) - 24.0, NSHeight(frame) - 8.0), 11.0, highlighted ? OpnColor(kBrandGreen, 0.98) : OpnColor(kTextSecondary), NSFontWeightBold, NSTextAlignmentCenter);
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [chip addSubview:label];
    return chip;
}

- (NSView *)storeIconStripForGame:(const GameInfo &)game frame:(NSRect)frame {
    NSView *strip = [[NSView alloc] initWithFrame:frame];
    NSArray<NSString *> *stores = OPNStoreVariantStoreNames(game);
    NSUInteger iconCount = MIN((NSUInteger)4, stores.count);
    if (iconCount == 0) return strip;

    CGFloat iconSize = MIN(NSHeight(frame), 36.0);
    CGFloat iconGap = MAX(6.0, iconSize * 0.22);
    for (NSUInteger index = 0; index < iconCount; index++) {
        NSString *store = stores[index];
        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(index * (iconSize + iconGap), 0.0, iconSize, iconSize)];
        iconView.imageScaling = NSImageScaleProportionallyDown;
        iconView.image = OPNStoreIconImage(store);
        iconView.toolTip = store;
        iconView.wantsLayer = YES;
        iconView.layer.cornerRadius = iconSize * 0.5;
        iconView.layer.backgroundColor = OpnColor(0x030506, 0.72).CGColor;
        iconView.layer.borderWidth = 1.0;
        iconView.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
        [strip addSubview:iconView];
    }
    return strip;
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
    NSTextField *title = OpnLabel(@"No Store collections found", NSMakeRect(0.0, 78.0, width, 34.0), 27.0, OpnColor(kTextPrimary), NSFontWeightBold, NSTextAlignmentCenter);
    [emptyPanel addSubview:title];
    NSTextField *subtitle = OpnLabel(@"The cloud storefront returned empty panels. Try again after the catalog service refreshes.", NSMakeRect(0.0, 120.0, width, 22.0), 13.0, OpnColor(kTextSecondary), NSFontWeightMedium, NSTextAlignmentCenter);
    [emptyPanel addSubview:subtitle];
}

- (void)addDesktopHeroStageForGame:(const GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height {
    self.controllerFeaturedHeroGame = game;
    self.controllerFeaturedHeroVariantIndex = [self selectedVariantIndexForStoreGame:game];
    self.desktopFeaturedHeroFrame = NSMakeRect(contentX, y, width, height);

    OPNStoreDocumentView *stage = [[OPNStoreDocumentView alloc] initWithFrame:self.desktopFeaturedHeroFrame];
    stage.wantsLayer = YES;
    stage.layer.backgroundColor = OpnColor(0x030506, 0.98).CGColor;
    stage.layer.cornerRadius = 34.0;
    stage.layer.borderWidth = 2.0;
    stage.layer.borderColor = OpnColor(0x203040, 0.92).CGColor;
    stage.layer.shadowColor = OpnColor(0x000000, 1.0).CGColor;
    stage.layer.shadowOpacity = 0.48;
    stage.layer.shadowRadius = 34.0;
    stage.layer.shadowOffset = CGSizeMake(0.0, 22.0);
    [self.documentView addSubview:stage];

    OPNStoreHeroBackgroundView *artwork = [[OPNStoreHeroBackgroundView alloc] initWithFrame:stage.bounds];
    artwork.cornerRadius = 34.0;
    artwork.wantsLayer = YES;
    artwork.layer.cornerRadius = 34.0;
    artwork.layer.masksToBounds = YES;
    [stage addSubview:artwork];
    [self loadControllerFeaturedHeroImageForView:artwork candidates:OPNStoreImageCandidatesForGame(game, YES) index:0];

    CAGradientLayer *artScrim = [CAGradientLayer layer];
    artScrim.frame = artwork.bounds;
    artScrim.colors = @[(id)OpnColor(0x020403, 0.92).CGColor,
                        (id)OpnColor(0x020403, 0.42).CGColor,
                        (id)OpnColor(0x020403, 0.04).CGColor];
    artScrim.locations = @[@0.0, @0.34, @1.0];
    artScrim.startPoint = CGPointMake(0.0, 0.5);
    artScrim.endPoint = CGPointMake(1.0, 0.5);
    [artwork.layer addSublayer:artScrim];

    CGFloat textWidth = MIN(520.0, MAX(320.0, width * 0.35));

    NSString *titleText = game.title.empty() ? @"Untitled" : [NSString stringWithUTF8String:game.title.c_str()];
    NSTextField *title = OpnLabel(titleText, NSMakeRect(68.0, height * 0.30, textWidth, 76.0), 36.0, OpnColor(kTextPrimary), NSFontWeightBlack);
    title.lineBreakMode = NSLineBreakByWordWrapping;
    title.maximumNumberOfLines = 2;
    title.wantsLayer = YES;
    title.layer.shadowColor = NSColor.blackColor.CGColor;
    title.layer.shadowOpacity = 0.62;
    title.layer.shadowRadius = 10.0;
    title.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [stage addSubview:title];

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(68.0, height * 0.25, textWidth, MIN(120.0, MAX(78.0, height * 0.26)))];
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.wantsLayer = YES;
    logoView.layer.opacity = 0.0;
    logoView.layer.shadowColor = NSColor.blackColor.CGColor;
    logoView.layer.shadowOpacity = 0.58;
    logoView.layer.shadowRadius = 10.0;
    logoView.layer.shadowOffset = CGSizeMake(0.0, 4.0);
    [stage addSubview:logoView];
    [self loadControllerFeaturedHeroLogoForView:logoView titleFallback:title candidates:OPNStoreLogoCandidatesForGame(game) index:0];

    NSString *metaText = [NSString stringWithFormat:@"%@ / %@", OPNStorePrimaryStoreName(game), OPNStorePrimaryGenre(game)];
    NSTextField *meta = OpnLabel(metaText, NSMakeRect(68.0, height * 0.57, textWidth, 24.0), 16.0, OpnColor(0xFFFFFF, 0.86), NSFontWeightBold);
    meta.lineBreakMode = NSLineBreakByTruncatingTail;
    [stage addSubview:meta];

    NSButton *launchButton = [[NSButton alloc] initWithFrame:NSMakeRect(68.0, height * 0.68, 138.0, 44.0)];
    int selectedVariantIndex = [self selectedVariantIndexForStoreGame:game];
    launchButton.title = OPNStoreGameNeedsPurchase(game, selectedVariantIndex)
        ? @"Buy"
        : @"Play";
    launchButton.bordered = NO;
    launchButton.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBlack];
    launchButton.contentTintColor = OpnColor(kAccentOn);
    launchButton.wantsLayer = YES;
    launchButton.layer.cornerRadius = 23.0;
    launchButton.layer.backgroundColor = OpnColor(kBrandGreen, 0.98).CGColor;
    launchButton.layer.shadowColor = OpnColor(kBrandGreen).CGColor;
    launchButton.layer.shadowOpacity = 0.32;
    launchButton.layer.shadowRadius = 22.0;
    launchButton.layer.shadowOffset = CGSizeZero;
    launchButton.target = self;
    launchButton.action = @selector(controllerFeaturedHeroLaunchClicked:);
    [stage addSubview:launchButton];

    NSString *storeName = OPNStorePrimaryStoreName(game);
    NSButton *storeButton = [[NSButton alloc] initWithFrame:NSMakeRect(224.0, height * 0.68, 126.0, 44.0)];
    storeButton.title = storeName.length > 0 ? storeName : @"Store";
    storeButton.bordered = NO;
    storeButton.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightBold];
    storeButton.contentTintColor = OpnColor(kTextPrimary, 0.88);
    storeButton.wantsLayer = YES;
    storeButton.layer.cornerRadius = 22.0;
    storeButton.layer.backgroundColor = OpnColor(0xFFFFFF, 0.075).CGColor;
    storeButton.layer.borderWidth = 1.0;
    storeButton.layer.borderColor = OpnColor(0xFFFFFF, 0.18).CGColor;
    storeButton.target = self;
    storeButton.action = @selector(controllerFeaturedHeroLaunchClicked:);
    [stage addSubview:storeButton];
    [self.desktopFeaturedHeroViews addObject:stage];

    NSInteger dotCount = [self heroCandidateCount];
    if (dotCount > 1) {
        CGFloat activeDotWidth = 32.0;
        CGFloat inactiveDotWidth = 16.0;
        CGFloat dotHeight = 6.0;
        CGFloat dotSpacing = 28.0;
        CGFloat dotRailWidth = (dotCount - 1) * dotSpacing + activeDotWidth;
        CGFloat dotX = contentX + floor((width - dotRailWidth) * 0.5);
        CGFloat dotY = y + height + 20.0;
        NSInteger activeIndex = ((self.currentHeroIndex % dotCount) + dotCount) % dotCount;
        for (NSInteger index = 0; index < dotCount; index++) {
            BOOL active = index == activeIndex;
            CGFloat pillWidth = active ? activeDotWidth : inactiveDotWidth;
            CGFloat pillX = dotX + index * dotSpacing + (active ? 0.0 : floor((activeDotWidth - inactiveDotWidth) * 0.5));
            NSView *pill = [[NSView alloc] initWithFrame:NSMakeRect(pillX, dotY, pillWidth, dotHeight)];
            pill.wantsLayer = YES;
            pill.layer.cornerRadius = dotHeight * 0.5;
            pill.layer.backgroundColor = (active ? OpnColor(OPN::kBrandGreen, 0.95) : OpnColor(0xFFFFFF, 0.20)).CGColor;
            [self.documentView addSubview:pill];
            [self.desktopFeaturedHeroViews addObject:pill];
        }
    }
}

- (void)renderControllerStore {
    CGFloat width = MAX(1040.0, NSWidth(self.bounds));
    CGFloat contentX = OPNStoreHeroContentInsetForWidth(width);
    CGFloat contentWidth = MAX(640.0, width - contentX * 2.0);
    CGFloat laneX = contentX;
    CGFloat y = kControllerStoreHeroTop;

    OPNStoreAmbientView *ambient = [[OPNStoreAmbientView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, MAX(NSHeight(self.bounds), 1600.0))];
    ambient.intensity = 0.78;
    [self.documentView addSubview:ambient];

    NSView *ambientPanel = [[NSView alloc] initWithFrame:NSMakeRect(contentX - 28.0, 28.0, contentWidth + 56.0, 618.0)];
    ambientPanel.wantsLayer = YES;
    CAGradientLayer *ambientGradient = [CAGradientLayer layer];
    ambientGradient.colors = @[(id)OpnColor(0x071116, 0.92).CGColor,
                               (id)OpnColor(0x111018, 0.62).CGColor,
                               (id)OpnColor(0x030507, 0.0).CGColor];
    ambientGradient.startPoint = CGPointMake(0.0, 0.0);
    ambientGradient.endPoint = CGPointMake(1.0, 1.0);
    ambientGradient.frame = ambientPanel.bounds;
    ambientPanel.layer = ambientGradient;
    ambientPanel.layer.cornerRadius = 38.0;
    [self.documentView addSubview:ambientPanel];

    const GameInfo *heroGame = [self currentHeroGame];
    NSInteger renderedRows = 0;
    if (heroGame) {
        CGFloat availableHeroWidth = MAX(1.0, contentWidth);
        CGFloat heroWidth = availableHeroWidth;
        CGFloat heroHeight = OPNStoreHeroHeightForSize(heroWidth, NSHeight(self.bounds));
        CGFloat heroX = contentX + floor((availableHeroWidth - heroWidth) * 0.5);
        NSInteger heroDotCount = MIN((NSInteger)6, MAX((NSInteger)1, [self heroCandidateCount]));
        NSInteger heroDotIndex = ((self.currentHeroIndex % heroDotCount) + heroDotCount) % heroDotCount;
        [self addControllerFeaturedHeroForGame:*heroGame
                                         frame:NSMakeRect(heroX, y - 12.0, heroWidth, heroHeight)
                                   activeIndex:heroDotIndex
                                    totalCount:heroDotCount];
        y += heroHeight + 74.0;
    }

    for (const PanelResult &panel : _panels) {
        for (const PanelSection &section : panel.sections) {
            if (section.games.empty()) continue;
            [self addSection:section index:renderedRows y:y contentX:laneX width:width];
            y += kControllerStoreRailHeight;
            renderedRows++;
        }
    }

    if (renderedRows == 0 && !self.loadingView.hidden) {
        self.statusLabel.stringValue = @"";
    } else if (renderedRows == 0) {
        self.statusLabel.stringValue = @"No Store collections found.";
    } else {
        self.statusLabel.stringValue = @"";
    }

    CGFloat documentHeight = MAX(NSHeight(self.bounds), y + 80.0);
    ambient.frame = NSMakeRect(0.0, 0.0, width, documentHeight);
    ambientPanel.frame = NSMakeRect(contentX - 28.0, 28.0, contentWidth + 56.0, MAX(618.0, documentHeight - 72.0));
    ambientGradient.frame = ambientPanel.bounds;
    self.documentView.frame = NSMakeRect(0, 0, width, documentHeight);
    [self updateFocusedTiles];
}

- (void)addControllerFeaturedHeroForGame:(const GameInfo &)game frame:(NSRect)frame activeIndex:(NSInteger)activeIndex totalCount:(NSInteger)totalCount {
    self.controllerFeaturedHeroGame = game;
    self.controllerFeaturedHeroVariantIndex = [self selectedVariantIndexForStoreGame:game];
    self.controllerFeaturedHeroFrame = frame;

    CGFloat heroHeight = MAX(1.0, NSHeight(frame));
    CGFloat heroScale = MIN(heroHeight / 270.0, 2.0);
    CGFloat cornerRadius = heroHeight * (18.0 / 270.0);
    CGFloat leftInset = 68.0 * heroScale;
    CGFloat logoWidth = 340.0 * heroScale;
    CGFloat logoHeight = 84.0 * heroScale;
    CGFloat buttonHeight = 42.0 * heroScale * 0.68;
    CGFloat buttonWidth = 152.0 * heroScale * 0.68;
    CGFloat buttonY = NSMinY(frame) + heroHeight * (198.0 / 270.0);

    NSView *heroShadow = [[NSView alloc] initWithFrame:frame];
    heroShadow.wantsLayer = YES;
    heroShadow.layer.cornerRadius = cornerRadius;
    heroShadow.layer.masksToBounds = NO;
    heroShadow.layer.backgroundColor = NSColor.clearColor.CGColor;
    heroShadow.layer.shadowColor = NSColor.blackColor.CGColor;
    heroShadow.layer.shadowOpacity = 0.58;
    heroShadow.layer.shadowRadius = heroHeight * (30.0 / 270.0);
    heroShadow.layer.shadowOffset = CGSizeMake(0.0, heroHeight * (16.0 / 270.0));
    CGPathRef heroShadowPath = OpnCreateRoundedRectPath(heroShadow.bounds, cornerRadius, cornerRadius);
    heroShadow.layer.shadowPath = heroShadowPath;
    CGPathRelease(heroShadowPath);
    [self.documentView addSubview:heroShadow];
    [self.controllerFeaturedHeroViews addObject:heroShadow];

    OPNStoreHeroBackgroundView *hero = [[OPNStoreHeroBackgroundView alloc] initWithFrame:frame];
    hero.cornerRadius = cornerRadius;
    hero.wantsLayer = YES;
    hero.layer.cornerRadius = cornerRadius;
    hero.layer.masksToBounds = YES;
    hero.layer.borderWidth = heroHeight * (1.0 / 270.0);
    hero.layer.borderColor = OpnColor(0xFFFFFF, 0.14).CGColor;
    [self.documentView addSubview:hero];
    [self.controllerFeaturedHeroViews addObject:hero];
    [self loadControllerFeaturedHeroImageForView:hero candidates:OPNStoreImageCandidatesForGame(game, YES) index:0];

    NSString *titleText = OPNStoreString(game.title, @"Untitled");
    NSTextField *title = OpnLabel(titleText, NSMakeRect(NSMinX(frame) + leftInset, NSMinY(frame) + heroHeight * (88.0 / 270.0), logoWidth, 42.0 * heroScale), 30.0 * heroScale, OpnColor(kTextPrimary), NSFontWeightBlack);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.wantsLayer = YES;
    title.layer.shadowColor = NSColor.blackColor.CGColor;
    title.layer.shadowOpacity = 0.62;
    title.layer.shadowRadius = 10.0;
    title.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    [self.documentView addSubview:title];
    [self.controllerFeaturedHeroViews addObject:title];

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(NSMinX(frame) + leftInset, NSMinY(frame) + heroHeight * (70.0 / 270.0), logoWidth, logoHeight)];
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.wantsLayer = YES;
    logoView.layer.opacity = 0.0;
    logoView.layer.shadowColor = NSColor.blackColor.CGColor;
    logoView.layer.shadowOpacity = 0.58;
    logoView.layer.shadowRadius = heroHeight * (10.0 / 270.0);
    logoView.layer.shadowOffset = CGSizeMake(0.0, heroHeight * (4.0 / 270.0));
    [self.documentView addSubview:logoView];
    [self.controllerFeaturedHeroViews addObject:logoView];
    [self loadControllerFeaturedHeroLogoForView:logoView titleFallback:title candidates:OPNStoreLogoCandidatesForGame(game) index:0];

    NSString *store = OPNStorePrimaryStoreName(game);
    NSString *metaText = [NSString stringWithFormat:@"%@  /  %@", store, OPNStorePrimaryGenre(game)];
    NSTextField *meta = OpnLabel(metaText, NSMakeRect(NSMinX(frame) + leftInset, NSMinY(frame) + heroHeight * (152.0 / 270.0), logoWidth, 20.0 * heroScale), 14.0 * heroScale, OpnColor(0xFFFFFF, 0.82), NSFontWeightSemibold);
    meta.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.documentView addSubview:meta];
    [self.controllerFeaturedHeroViews addObject:meta];

    NSString *primaryTitle = OPNStoreGameNeedsPurchase(game, self.controllerFeaturedHeroVariantIndex)
        ? @"Buy"
        : @"▶  Play Now";
    NSButton *primary = OpnButton(primaryTitle, NSMakeRect(NSMinX(frame) + leftInset, buttonY, buttonWidth, buttonHeight), OpnColor(0x45F27C, 0.98), OpnColor(0x051008));
    primary.font = [NSFont systemFontOfSize:14.5 * heroScale * 0.68 weight:NSFontWeightBold];
    primary.layer.cornerRadius = buttonHeight * 0.24;
    primary.layer.shadowColor = OpnColor(0x45F27C).CGColor;
    primary.layer.shadowOpacity = 0.42;
    primary.layer.shadowRadius = buttonHeight * 0.38;
    primary.layer.shadowOffset = CGSizeZero;
    primary.target = self;
    primary.action = @selector(controllerFeaturedHeroLaunchClicked:);
    [self.documentView addSubview:primary];
    [self.controllerFeaturedHeroViews addObject:primary];

    NSUInteger storeIconCount = MIN((NSUInteger)4, OPNStoreVariantStoreNames(game).count);
    CGFloat storeIconSize = MIN(buttonHeight, 36.0);
    CGFloat storeIconGap = MAX(6.0, storeIconSize * 0.22);
    CGFloat storeIconWidth = storeIconCount * storeIconSize + MAX((NSUInteger)0, storeIconCount - 1) * storeIconGap;
    NSView *storeIcons = [self storeIconStripForGame:game frame:NSMakeRect(NSMaxX(primary.frame) + 14.0 * heroScale * 0.68, NSMinY(primary.frame), storeIconWidth, buttonHeight)];
    [self.documentView addSubview:storeIcons];
    [self.controllerFeaturedHeroViews addObject:storeIcons];

    CGFloat dotSpacing = 24.0 * heroScale;
    CGFloat activeDotWidth = 22.0 * heroScale;
    CGFloat inactiveDotWidth = 14.0 * heroScale;
    CGFloat dotHeight = 5.0 * heroScale;
    CGFloat dotWidth = totalCount > 0 ? (totalCount - 1) * dotSpacing + activeDotWidth : 0.0;
    CGFloat dotX = NSMidX(frame) - dotWidth * 0.5;
    CGFloat dotY = NSMaxY(frame) + heroHeight * (14.0 / 270.0);
    for (NSInteger index = 0; index < totalCount; index++) {
        BOOL active = index == activeIndex;
        NSRect dotRect = active ? NSMakeRect(dotX + index * dotSpacing, dotY, activeDotWidth, dotHeight) : NSMakeRect(dotX + index * dotSpacing + (activeDotWidth - inactiveDotWidth) * 0.5, dotY, inactiveDotWidth, dotHeight);
        NSView *dot = [[NSView alloc] initWithFrame:dotRect];
        dot.wantsLayer = YES;
        dot.layer.cornerRadius = dotHeight * 0.5;
        dot.layer.backgroundColor = (active ? OpnColor(OPN::kBrandGreen, 0.95) : OpnColor(0xFFFFFF, 0.18)).CGColor;
        [self.documentView addSubview:dot];
        [self.controllerFeaturedHeroViews addObject:dot];
    }
}

- (void)loadControllerFeaturedHeroImageForView:(OPNStoreHeroBackgroundView *)view candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view) return;
    if (index >= candidates.count) {
        view.image = OPNStoreFallbackArtworkImage();
        return;
    }
    NSString *urlString = candidates[index];
    if (urlString.length == 0) {
        [self loadControllerFeaturedHeroImageForView:view candidates:candidates index:index + 1];
        return;
    }

    __weak OPNStoreHeroBackgroundView *weakView = view;
    OpnLoadImageForURL(urlString, 1600.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        OPNStoreHeroBackgroundView *strongView = weakView;
        if (!strongView.superview) return;
        if (!image) {
            [self loadControllerFeaturedHeroImageForView:strongView candidates:candidates index:index + 1];
            return;
        }
        strongView.image = image;
    });
}

- (void)loadControllerFeaturedHeroLogoForView:(NSImageView *)view titleFallback:(NSTextField *)titleFallback candidates:(NSArray<NSString *> *)candidates index:(NSUInteger)index {
    if (!view || index >= candidates.count) return;
    NSString *urlString = candidates[index];
    if (urlString.length == 0) {
        [self loadControllerFeaturedHeroLogoForView:view titleFallback:titleFallback candidates:candidates index:index + 1];
        return;
    }

    __weak NSImageView *weakView = view;
    __weak NSTextField *weakTitleFallback = titleFallback;
    OpnLoadImageForURL(urlString, 900.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        NSImageView *strongView = weakView;
        if (!strongView.superview) return;
        if (!image) {
            [self loadControllerFeaturedHeroLogoForView:strongView titleFallback:weakTitleFallback candidates:candidates index:index + 1];
            return;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        strongView.image = image;
        strongView.layer.opacity = 1.0;
        weakTitleFallback.layer.opacity = 0.0;
        [CATransaction commit];
    });
}

- (void)controllerFeaturedHeroLaunchClicked:(id)sender {
    (void)sender;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    OPN::GameInfo featuredGame = self.controllerFeaturedHeroGame;
    int variantIndex = self.controllerFeaturedHeroVariantIndex >= 0 ? self.controllerFeaturedHeroVariantIndex : 0;
    if (OPNStoreGameNeedsPurchase(featuredGame, variantIndex)) {
        NSString *purchaseURL = OPNStorePurchaseURLForGame(featuredGame, variantIndex);
        if (self.onBuyGame) self.onBuyGame(featuredGame, variantIndex, purchaseURL ?: @"");
        return;
    }
    if (!self.onSelectGame) return;
    self.onSelectGame(featuredGame, variantIndex);
}

- (void)updateControllerFeaturedHeroOnly {
    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || NSEqualRects(self.controllerFeaturedHeroFrame, NSZeroRect)) {
        [self renderStore];
        return;
    }

    NSRect frame = self.controllerFeaturedHeroFrame;
    for (NSView *view in [self.controllerFeaturedHeroViews copy]) {
        [view removeFromSuperview];
    }
    [self.controllerFeaturedHeroViews removeAllObjects];

    NSInteger heroDotCount = MIN((NSInteger)6, MAX((NSInteger)1, [self heroCandidateCount]));
    NSInteger heroDotIndex = ((self.currentHeroIndex % heroDotCount) + heroDotCount) % heroDotCount;
    [self addControllerFeaturedHeroForGame:*heroGame frame:frame activeIndex:heroDotIndex totalCount:heroDotCount];
    [self updateFocusedTiles];
}

- (void)addHeroGame:(const GameInfo &)game y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width height:(CGFloat)height {
    NSRect heroRect = NSMakeRect(contentX, y, width, height);
    OPNStoreGameTile *hero = [self configuredHeroGameTile:game frame:heroRect];
    [self.documentView addSubview:hero];
    self.heroTile = hero;
    if (OpnControllerModeEnabled()) [self.rowCards addObject:[NSMutableArray arrayWithObject:hero]];
}

- (OPNStoreGameTile *)configuredHeroGameTile:(const GameInfo &)game frame:(NSRect)frame {
    OPNStoreGameTile *hero = [[OPNStoreGameTile alloc] initWithFrame:frame game:game prominent:YES];
    hero.imageRevealDelay = 0.04;
    hero.selectedVariantIndex = [self selectedVariantIndexForStoreGame:game];
    __weak __typeof__(self) weakSelf = self;
    __weak OPNStoreGameTile *weakHero = hero;
    hero.onSelect = ^{
        __typeof__(self) strongSelf = weakSelf;
        OPNStoreGameTile *strongHero = weakHero;
        if (!strongSelf || !strongHero || !strongSelf.onSelectGame) return;
        strongSelf.onSelectGame(strongHero.game, strongHero.selectedVariantIndex);
    };
    hero.onBuy = ^(NSString *purchaseURL) {
        __typeof__(self) strongSelf = weakSelf;
        OPNStoreGameTile *strongHero = weakHero;
        if (!strongSelf || !strongHero || !strongSelf.onBuyGame) return;
        int variantIndex = strongHero.selectedVariantIndex >= 0 ? strongHero.selectedVariantIndex : 0;
        strongSelf.onBuyGame(strongHero.game, variantIndex, purchaseURL ?: @"");
    };
    return hero;
}

- (void)updateHeroTileOnly {
    if (OpnControllerModeEnabled()) {
        [self updateControllerFeaturedHeroOnly];
        return;
    }

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

- (void)updateLegacyHeroTileOnly {

    const GameInfo *heroGame = [self currentHeroGame];
    if (!heroGame || !self.heroTile || self.heroTile.superview != self.documentView) {
        [self renderStore];
        return;
    }

    NSRect heroFrame = self.heroTile.frame;
    OPNStoreGameTile *oldHero = self.heroTile;
    OPNStoreGameTile *newHero = [self configuredHeroGameTile:*heroGame frame:heroFrame];
    [self.documentView replaceSubview:oldHero with:newHero];
    self.heroTile = newHero;

    if (OpnControllerModeEnabled() && self.rowCards.count > 0) {
        self.rowCards[0] = [NSMutableArray arrayWithObject:newHero];
        [self updateFocusedTiles];
    }
}

- (void)addSection:(const PanelSection &)section index:(NSInteger)sectionIndex y:(CGFloat)y contentX:(CGFloat)contentX width:(CGFloat)width {
    CGFloat rightInset = OpnControllerModeEnabled() ? OPNStoreHeroContentInsetForWidth(width) : contentX;
    CGFloat availableWidth = MAX(320.0, width - contentX - rightInset);
    NSString *sectionTitle = section.title.empty() ? @"Featured" : [NSString stringWithUTF8String:section.title.c_str()];

    NSView *rowGlow = [[NSView alloc] initWithFrame:NSMakeRect(contentX - 18.0, y + 36.0, availableWidth + 36.0, kStoreTileHeight + 44.0)];
    rowGlow.wantsLayer = YES;
    rowGlow.layer.cornerRadius = 24.0;
    rowGlow.layer.backgroundColor = OpnColor(0xFFFFFF, OpnControllerModeEnabled() ? 0.026 : 0.032).CGColor;
    rowGlow.layer.borderWidth = 1.0;
    rowGlow.layer.borderColor = OpnColor(0xFFFFFF, 0.055).CGColor;
    [self.documentView addSubview:rowGlow];

    NSTextField *indexLabel = OpnLabel([NSString stringWithFormat:@"%02ld", (long)sectionIndex + 1], NSMakeRect(contentX, y + 5.0, 42.0, 18.0), 11.0, OpnColor(kBrandGreen), NSFontWeightBlack);
    [self.documentView addSubview:indexLabel];
    NSTextField *label = OpnLabel(sectionTitle, NSMakeRect(contentX + 42.0, y, availableWidth - 142.0, 30.0), OpnControllerModeEnabled() ? 20.0 : 23.0, OpnColor(kTextPrimary), NSFontWeightBold);
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
    NSInteger maxCards = OpnControllerModeEnabled() ? 18 : 24;
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

- (void)normalizeFocusedPosition {
    if (self.rowCards.count == 0) {
        self.focusedRowIndex = 0;
        self.focusedColumnIndex = 0;
        return;
    }
    self.focusedRowIndex = MAX(0, MIN(self.focusedRowIndex, (NSInteger)self.rowCards.count - 1));
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (row.count == 0) {
        self.focusedColumnIndex = 0;
        return;
    }
    self.focusedColumnIndex = MAX(0, MIN(self.focusedColumnIndex, (NSInteger)row.count - 1));
}

- (OPNStoreGameTile *)focusedTile {
    [self normalizeFocusedPosition];
    if (self.rowCards.count == 0) return nil;
    NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[(NSUInteger)self.focusedRowIndex];
    if (row.count == 0 || self.focusedColumnIndex >= (NSInteger)row.count) return nil;
    return row[(NSUInteger)self.focusedColumnIndex];
}

- (void)updateFocusedTiles {
    [self normalizeFocusedPosition];
    BOOL controllerMode = OpnControllerModeEnabled();
    for (NSUInteger rowIndex = 0; rowIndex < self.rowCards.count; rowIndex++) {
        NSMutableArray<OPNStoreGameTile *> *row = self.rowCards[rowIndex];
        for (NSUInteger columnIndex = 0; columnIndex < row.count; columnIndex++) {
            BOOL focused = controllerMode && (NSInteger)rowIndex == self.focusedRowIndex && (NSInteger)columnIndex == self.focusedColumnIndex;
            [row[columnIndex] setStoreFocused:focused];
        }
    }
}

- (void)scrollFocusedTileIntoView {
    OPNStoreGameTile *tile = [self focusedTile];
    if (!tile) return;
    NSScrollView *railScroll = tile.enclosingScrollView;
    if ([railScroll isKindOfClass:OPNStoreRailScrollView.class]) {
        NSClipView *clipView = railScroll.contentView;
        CGFloat targetX = NSMidX(tile.frame) - NSWidth(clipView.bounds) * 0.5;
        targetX = MAX(0.0, MIN(targetX, MAX(0.0, NSWidth(railScroll.documentView.frame) - NSWidth(clipView.bounds))));
        [clipView scrollToPoint:NSMakePoint(targetX, 0.0)];
        [railScroll reflectScrolledClipView:clipView];
        [self.documentView scrollRectToVisible:NSInsetRect(railScroll.frame, -20.0, -24.0)];
        [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
        return;
    }
    [self.documentView scrollRectToVisible:NSInsetRect(tile.frame, -28.0, -28.0)];
    [self.scrollView reflectScrolledClipView:self.scrollView.contentView];
}

- (void)focusRow:(NSInteger)row column:(NSInteger)column scrollIntoView:(BOOL)scrollIntoView {
    if (self.rowCards.count == 0) return;
    NSInteger previousRow = self.focusedRowIndex;
    NSInteger previousColumn = self.focusedColumnIndex;
    self.focusedRowIndex = row;
    self.focusedColumnIndex = column;
    [self normalizeFocusedPosition];
    [self updateFocusedTiles];
    if (scrollIntoView) [self scrollFocusedTileIntoView];
    if (OpnControllerModeEnabled() && (previousRow != self.focusedRowIndex || previousColumn != self.focusedColumnIndex)) {
        OpnPlayConsoleTone(OPNConsoleToneMove);
    }
}

- (void)moveFocusByRows:(NSInteger)rows columns:(NSInteger)columns {
    if (!OpnControllerModeEnabled()) return;
    [self focusRow:self.focusedRowIndex + rows column:self.focusedColumnIndex + columns scrollIntoView:YES];
}

- (void)launchFocusedGame {
    OPNStoreGameTile *tile = [self focusedTile];
    if (!tile) return;
    if (OpnControllerModeEnabled()) OpnPlayConsoleTone(OPNConsoleToneSelect);
    int variantIndex = tile.selectedVariantIndex >= 0 ? tile.selectedVariantIndex : 0;
    if (OPNStoreGameNeedsPurchase(tile.game, variantIndex)) {
        NSString *purchaseURL = OPNStorePurchaseURLForGame(tile.game, variantIndex);
        if (self.onBuyGame) self.onBuyGame(tile.game, variantIndex, purchaseURL ?: @"");
        return;
    }
    if (self.onSelectGame) self.onSelectGame(tile.game, variantIndex);
}

- (void)requestControllerBackToHome {
    if (!self.onBackRequested) return;
    OpnPlayConsoleTone(OPNConsoleToneBack);
    self.onBackRequested();
}

- (void)keyDown:(NSEvent *)event {
    if (!OpnControllerModeEnabled()) {
        [super keyDown:event];
        return;
    }
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    switch (event.keyCode) {
        case 123: [self moveFocusByRows:0 columns:-1]; return;
        case 124: [self moveFocusByRows:0 columns:1]; return;
        case 125: [self moveFocusByRows:1 columns:0]; return;
        case 126: [self moveFocusByRows:-1 columns:0]; return;
        case 36:
        case 49:
            [self launchFocusedGame];
            return;
        case 53:
            [self requestControllerBackToHome];
            return;
        default:
            break;
    }
    if ([chars isEqualToString:@"b"] || [chars isEqualToString:@"h"]) {
        [self requestControllerBackToHome];
        return;
    }
    if ([chars isEqualToString:@"["]) {
        if (self.onPreviousPageRequested) self.onPreviousPageRequested();
        return;
    }
    if ([chars isEqualToString:@"]"]) {
        if (self.onNextPageRequested) self.onNextPageRequested();
        return;
    }
    [super keyDown:event];
}

- (void)startGamepadNavigationIfNeeded {
    if (self.controllerInputSuspended || !OpnControllerModeEnabled() || self.gamepadNavigationTimer || [GCController controllers].count == 0 || !OPNStoreGamepadNavigationActive(self)) return;
    [self installGamepadValueHandlers];
    self.gamepadNavigationTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                                   target:self
                                                                 selector:@selector(pollGamepadNavigation)
                                                                 userInfo:nil
                                                                  repeats:YES];
}

- (void)installGamepadValueHandlers {
    __weak __typeof__(self) weakSelf = self;
    for (GCController *controller in [GCController controllers]) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (!gamepad) continue;
        gamepad.valueChangedHandler = ^(GCExtendedGamepad *, GCControllerElement *) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || !OPNStoreGamepadNavigationActive(strongSelf)) return;
                [strongSelf pollGamepadNavigation];
            });
        };
    }
}

- (void)stopGamepadNavigation {
    [self.gamepadNavigationTimer invalidate];
    self.gamepadNavigationTimer = nil;
    self.previousGamepadButtons = 0;
}

- (void)controllerDidConnect:(NSNotification *)notification {
    (void)notification;
    [self startGamepadNavigationIfNeeded];
}

- (void)controllerDidDisconnect:(NSNotification *)notification {
    (void)notification;
    if ([GCController controllers].count == 0) {
        [self stopGamepadNavigation];
        return;
    }
    self.previousGamepadButtons = 0;
}

- (void)pollGamepadNavigation {
    if (self.controllerInputSuspended) {
        self.previousGamepadButtons = OPNStoreGamepadButtons();
        return;
    }
    if (!OpnControllerModeEnabled() || [GCController controllers].count == 0 || !OPNStoreGamepadNavigationActive(self)) {
        [self stopGamepadNavigation];
        return;
    }
    [self.window makeFirstResponder:self];
    uint16_t buttons = OPNStoreGamepadButtons();
    uint16_t pressed = buttons & (uint16_t)~self.previousGamepadButtons;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL repeatMove = (now - self.lastGamepadMoveTime) > 0.22;
    uint16_t moves = buttons & ((1u << 2) | (1u << 3) | (1u << 4) | (1u << 5));
    if (moves && repeatMove) {
        pressed |= moves;
        self.lastGamepadMoveTime = now;
    }
    if (pressed & (1u << 0)) [self launchFocusedGame];
    if (pressed & (1u << 1)) {
        [self requestControllerBackToHome];
        self.previousGamepadButtons = buttons;
        return;
    }
    if (pressed & (1u << 6)) {
        if (self.onPreviousPageRequested) self.onPreviousPageRequested();
        self.previousGamepadButtons = buttons;
        return;
    }
    if (pressed & (1u << 7)) {
        if (self.onNextPageRequested) self.onNextPageRequested();
        self.previousGamepadButtons = buttons;
        return;
    }
    if (pressed & (1u << 2)) [self moveFocusByRows:-1 columns:0];
    if (pressed & (1u << 3)) [self moveFocusByRows:1 columns:0];
    if (pressed & (1u << 4)) [self moveFocusByRows:0 columns:-1];
    if (pressed & (1u << 5)) [self moveFocusByRows:0 columns:1];
    self.previousGamepadButtons = buttons;
}

@end
