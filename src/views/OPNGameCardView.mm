#import "OPNGameCardView.h"
#import "../common/OPNColorTokens.h"
#import "../common/OPNCoreAnimationCoordinator.h"
#import "../common/OPNUIHelpers.h"
#include <QuartzCore/QuartzCore.h>
#include "common/OPNSentry.h"

static const CGFloat gCardWidth = 220.0;
static const CGFloat gControllerCardWidth = 164.0;
static const CGFloat gImageHeight = gCardWidth * 9.0 / 16.0;
static const CGFloat gInfoHeight = 0.0;
static unsigned OPNControllerAccentSoftRGB(void) {
    return OpnBlendRGB(OPN::kBrandGreen, 0xFFFFFF, 0.42);
}

static unsigned OPNControllerAccentBlackRGB(CGFloat blackMix) {
    return OpnBlendRGB(OPN::kBrandGreen, 0x000000, blackMix);
}
static CGFloat OPNScaledCardWidth(void) {
    if (OpnControllerModeEnabled()) return gControllerCardWidth;
    return gCardWidth;
}

static CGFloat OPNScaledCardHeight(void) {
    if (OpnControllerModeEnabled()) return gControllerCardWidth;
    return gImageHeight;
}

static NSString *OPNStorePrettyName(NSString *name) {
    NSString *upper = name.uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"Steam";
    if ([upper containsString:@"EPIC"] || [upper containsString:@"EGS"]) return @"Epic";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"Ubisoft";
    if ([upper containsString:@"BATTLE"]) return @"Battle.net";
    if ([upper containsString:@"XBOX"] || [upper containsString:@"MICROSOFT"]) return @"Xbox";
    if ([upper containsString:@"EA"]) return @"EA";
    if ([upper containsString:@"ORIGIN"]) return @"EA";
    if ([upper containsString:@"GOG"]) return @"GOG";
    return name.capitalizedString;
}

static NSString *OPNStoreIconAssetName(NSString *name) {
    NSString *upper = name.uppercaseString;
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

    NSString *relativePath = [NSString stringWithFormat:@"assets/store-icons/%@.svg", assetName];
    NSString *workingPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:relativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:workingPath]) return workingPath;

    NSString *sourcePath = [@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:relativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sourcePath]) return sourcePath;

    return nil;
}

static NSImage *OPNStoreIconImage(NSString *name) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSString *assetName = OPNStoreIconAssetName(name ?: @"");
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

static NSImage *OPNGreyscaleStoreIconImage(NSString *name) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSString *assetName = OPNStoreIconAssetName(name ?: @"");
    NSImage *cached = cache[assetName];
    if (cached) return cached;

    NSImage *source = OPNStoreIconImage(name);
    if (!source) return nil;
    NSImage *templateImage = [source copy];
    [templateImage setTemplate:YES];
    cache[assetName] = templateImage;
    return templateImage;
}

static NSString *OPNStoreIconGlyph(NSString *name) {
    NSString *upper = name.uppercaseString;
    if ([upper containsString:@"STEAM"]) return @"●";
    if ([upper containsString:@"UBISOFT"] || [upper containsString:@"UPLAY"]) return @"◎";
    if ([upper containsString:@"BATTLE"]) return @"✦";
    if ([upper containsString:@"XBOX"] || [upper containsString:@"MICROSOFT"]) return @"X";
    if ([upper containsString:@"EPIC"] || [upper containsString:@"EGS"]) return @"E";
    if ([upper containsString:@"EA"] || [upper containsString:@"ORIGIN"]) return @"EA";
    if ([upper containsString:@"GOG"]) return @"G";
    return name.length > 0 ? [name substringToIndex:1].uppercaseString : @"?";
}

static NSColor *OPNStoreIconColor(NSString *name, BOOL selected) {
    (void)name;
    CGFloat alpha = selected ? 0.96 : 0.76;
    return OpnColor(0xF4F5F7, alpha);
}

static NSFont *OPNStoreIconFont(NSString *glyph) {
    return glyph.length > 1
        ? [NSFont systemFontOfSize:8.0 weight:NSFontWeightBlack]
        : [NSFont systemFontOfSize:13.0 weight:NSFontWeightBlack];
}

static BOOL OPNIsNumericString(const std::string &value) {
    return !value.empty() && value.find_first_not_of("0123456789") == std::string::npos;
}

static NSString *OPNSteamArtworkURLForGame(const OPN::GameInfo &game) {
    std::string appId;
    for (const auto &variant : game.variants) {
        NSString *store = [NSString stringWithUTF8String:variant.appStore.c_str()];
        if ([store.uppercaseString containsString:@"STEAM"] && OPNIsNumericString(variant.id)) {
            appId = variant.id;
            break;
        }
    }
    if (appId.empty() && OPNIsNumericString(game.launchAppId)) appId = game.launchAppId;
    if (appId.empty()) return nil;
    return [NSString stringWithFormat:@"https://cdn.cloudflare.steamstatic.com/steam/apps/%s/header.jpg", appId.c_str()];
}

static std::string OPNGameCardImageSignature(const OPN::GameInfo &game) {
    std::string signature = game.heroImageUrl + "\n" + game.imageUrl + "\n" + game.launchAppId;
    for (const char *type : {"KEY_ART", "KEY_IMAGE"}) {
        auto it = game.imageUrlsByType.find(type);
        if (it == game.imageUrlsByType.end()) continue;
        for (const std::string &value : it->second) {
            signature += "\n";
            signature += value;
        }
    }
    return signature;
}

typedef void (^OPNGameCardImageCompletion)(NSImage *image);

static void OPNGameCardLoadImageForURL(NSString *urlString, OPNGameCardImageCompletion completion) {
    OpnLoadImageForURL(urlString, 720.0, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        (void)resolvedURL;
        (void)data;
        completion(image);
    });
}

@interface OPNGameCardView () <CALayerDelegate>
@property (nonatomic, assign) OPN::GameInfo gameData;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSTextField *controllerStoreLabel;
@property (nonatomic, strong) NSTextField *controllerTitleLabel;
@property (nonatomic, strong) NSView *storeChipsContainer;
@property (nonatomic, strong) NSView *currentStoreLogoContainer;
@property (nonatomic, strong) NSImageView *currentStoreLogoView;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) CALayer *reflectionLayer;
@property (nonatomic, strong) NSMutableArray<NSButton *> *storeChipButtons;
@property (nonatomic, assign) NSUInteger imageLoadGeneration;
- (void)loadImageFromCandidates:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index generation:(NSUInteger)generation;
- (void)applyFocusStyle;
- (void)updateCurrentStoreLogo;
@end

@implementation OPNGameCardView

using namespace OPN;

+ (NSSize)cardSize { return NSMakeSize(OPNScaledCardWidth(), OPNScaledCardHeight()); }
+ (CGFloat)imageHeight { return OPNScaledCardHeight(); }
+ (CGFloat)infoHeight { return gInfoHeight; }

- (OPN::GameInfo)game { return _gameData; }

- (instancetype)initWithFrame:(NSRect)frame game:(const OPN::GameInfo &)game {
    self = [super initWithFrame:frame];
    if (self) {
        _gameData = game;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 20.0;
        self.layer.masksToBounds = NO;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.13).CGColor;
        self.layer.shadowColor = NSColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.38;
        self.layer.shadowRadius = 20.0;
        self.layer.shadowOffset = CGSizeMake(0.0, 16.0);

        _reflectionLayer = [CALayer layer];
        _reflectionLayer.backgroundColor = OpnColor(OPNControllerAccentSoftRGB(), 0.28).CGColor;
        _reflectionLayer.cornerRadius = 18.0;
        _reflectionLayer.opacity = 0.0;
        _reflectionLayer.shadowColor = OpnColor(OPNControllerAccentSoftRGB()).CGColor;
        _reflectionLayer.shadowOpacity = 0.68;
        _reflectionLayer.shadowRadius = 24.0;
        _reflectionLayer.shadowOffset = CGSizeZero;
        [self.layer addSublayer:_reflectionLayer];

        _contentView = [[NSView alloc] initWithFrame:self.bounds];
        _contentView.wantsLayer = YES;
        _contentView.layer.cornerRadius = 20.0;
        _contentView.layer.masksToBounds = YES;
        _contentView.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.88), 0.84).CGColor;
        [self addSubview:_contentView];

        _imageView = [[NSImageView alloc] initWithFrame:self.bounds];
        _imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _imageView.wantsLayer = YES;
        _imageView.layer.backgroundColor = OpnColor(OPNControllerAccentBlackRGB(0.90)).CGColor;
        [_contentView addSubview:_imageView];

        _currentStoreLogoContainer = [[NSView alloc] initWithFrame:NSZeroRect];
        _currentStoreLogoContainer.wantsLayer = YES;
        _currentStoreLogoContainer.layer.cornerRadius = 9.0;
        _currentStoreLogoContainer.layer.backgroundColor = OpnColor(0x05070A, 0.62).CGColor;
        _currentStoreLogoContainer.layer.borderWidth = 1.0;
        _currentStoreLogoContainer.layer.borderColor = OpnColor(0xFFFFFF, 0.15).CGColor;
        [_contentView addSubview:_currentStoreLogoContainer];

        _currentStoreLogoView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _currentStoreLogoView.imageScaling = NSImageScaleProportionallyDown;
        _currentStoreLogoView.contentTintColor = OpnColor(0xD7D8DC, 0.88);
        [_currentStoreLogoContainer addSubview:_currentStoreLogoView];

        _controllerStoreLabel = OpnLabel(@"", NSZeroRect, 13.0, OpnColor(0xFFFFFF, 0.88), NSFontWeightMedium);
        _controllerStoreLabel.hidden = !OpnControllerModeEnabled();
        [_contentView addSubview:_controllerStoreLabel];

        _controllerTitleLabel = OpnLabel(@"", NSZeroRect, 15.0, OpnColor(0xFFFFFF), NSFontWeightBold);
        _controllerTitleLabel.hidden = !OpnControllerModeEnabled();
        _controllerTitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _controllerTitleLabel.maximumNumberOfLines = 2;
        [_contentView addSubview:_controllerTitleLabel];

        _playButton = [[NSButton alloc] initWithFrame:
            NSMakeRect((NSWidth(self.bounds) - 76) / 2, NSHeight(self.bounds) - 52, 76, 34)];
        _playButton.title = @"PLAY";
        _playButton.bordered = NO;
        _playButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
        _playButton.contentTintColor = OpnColor(OPNControllerAccentBlackRGB(0.88));
        _playButton.wantsLayer = YES;
        _playButton.layer.cornerRadius = 17;
        _playButton.layer.backgroundColor = OpnColor(OPNControllerAccentSoftRGB(), 0.94).CGColor;
        _playButton.layer.shadowColor = OpnColor(OPNControllerAccentSoftRGB()).CGColor;
        _playButton.layer.shadowOpacity = 0.18;
        _playButton.layer.shadowRadius = 14;
        _playButton.layer.shadowOffset = CGSizeZero;
        _playButton.hidden = YES;
        _playButton.target = self;
        _playButton.action = @selector(playClicked);
        [self addSubview:_playButton];

        _storeChipButtons = [NSMutableArray array];

        _selectedVariantIndex = -1;
        int idx = 0;
        for (auto &v : game.variants) {
            if (v.librarySelected || v.inLibrary) {
                _selectedVariantIndex = idx;
                break;
            }
            idx++;
        }
        if (_selectedVariantIndex < 0 && !game.variants.empty()) {
            _selectedVariantIndex = 0;
        }

        _storeChipsContainer = [[NSView alloc] initWithFrame:
            NSMakeRect(16, NSHeight(self.bounds) - 37, NSWidth(self.bounds) - 32, 24)];
        [_contentView addSubview:_storeChipsContainer];
        [self buildStoreChips];
        [self updateControllerLabels];
        [self updateCurrentStoreLogo];

        [self loadImage];

        _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
            owner:self userInfo:nil];
        [self addTrackingArea:_trackingArea];
    }
    return self;
}

- (void)setControllerFocused:(BOOL)controllerFocused {
    if (_controllerFocused == controllerFocused) return;
    _controllerFocused = controllerFocused;
    [self applyFocusStyle];
}

- (void)applyFocusStyle {
    BOOL selected = self.controllerFocused;
    NSColor *accentColor = OpnColor(OPNControllerAccentSoftRGB());
    self.playButton.hidden = OpnControllerModeEnabled() || !selected;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.22];
    [CATransaction setAnimationTimingFunction:[OPNCoreAnimationCoordinator appleQuinticTimingFunction]];
    self.layer.zPosition = selected ? 20.0 : 0.0;
    self.layer.borderColor = selected ? OpnColor(OPN::kBrandGreen, 0.98).CGColor : OpnColor(0xFFFFFF, 0.13).CGColor;
    self.layer.borderWidth = selected ? 3.0 : 1.0;
    self.playButton.layer.shadowOpacity = selected ? 0.58 : 0.18;
    self.playButton.layer.shadowRadius = selected ? 22.0 : 14.0;
    [CATransaction commit];

    CGFloat prominence = selected ? 1.0 : 0.0;
    [[OPNCoreAnimationCoordinator sharedCoordinator] animateFocusForCardLayer:self.layer
                                                                    glowLayer:self.reflectionLayer
                                                                      focused:selected
                                                                   prominence:prominence
                                                                   accentColor:accentColor];
}

- (void)updateControllerLabels {
    NSString *store = @"";
    if (_selectedVariantIndex >= 0 && _selectedVariantIndex < (int)_gameData.variants.size()) {
        store = OPNStorePrettyName([NSString stringWithUTF8String:_gameData.variants[(size_t)_selectedVariantIndex].appStore.c_str()]);
    } else if (!_gameData.availableStores.empty()) {
        store = OPNStorePrettyName([NSString stringWithUTF8String:_gameData.availableStores.front().c_str()]);
    }
    self.controllerStoreLabel.stringValue = store;
    self.controllerTitleLabel.stringValue = _gameData.title.empty() ? @"Untitled" : [NSString stringWithUTF8String:_gameData.title.c_str()];
}

- (BOOL)isFlipped { return YES; }

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);
    CGFloat shortestSide = MAX(1.0, MIN(width, height));
    CGFloat cornerRadius = shortestSide * (20.0 / 180.0);
    self.contentView.frame = self.bounds;
    self.contentView.layer.cornerRadius = cornerRadius;
    self.imageView.frame = self.bounds;
    if (OpnControllerModeEnabled()) {
        self.controllerStoreLabel.hidden = YES;
        self.controllerTitleLabel.hidden = YES;
        self.controllerStoreLabel.frame = NSZeroRect;
        self.controllerTitleLabel.frame = NSZeroRect;
    } else {
        self.controllerStoreLabel.hidden = YES;
        self.controllerTitleLabel.hidden = YES;
    }
    CGFloat playWidth = width * (76.0 / 180.0);
    CGFloat playHeight = height * (34.0 / 180.0);
    self.playButton.frame = NSMakeRect((width - playWidth) / 2.0, MAX(0.0, height - height * (52.0 / 180.0)), playWidth, playHeight);
    self.storeChipsContainer.frame = NSMakeRect(width * (16.0 / 180.0), MAX(0.0, height - height * (37.0 / 180.0)), MAX(1.0, width - width * (32.0 / 180.0)), height * (24.0 / 180.0));
    CGFloat logoContainerSize = MAX(24.0, floor(width * (30.0 / 164.0)));
    CGFloat logoMargin = MAX(8.0, floor(width * (9.0 / 164.0)));
    self.currentStoreLogoContainer.frame = NSMakeRect(width - logoMargin - logoContainerSize,
                                                      height - logoMargin - logoContainerSize,
                                                      logoContainerSize,
                                                      logoContainerSize);
    self.currentStoreLogoContainer.layer.cornerRadius = logoContainerSize * 0.30;
    CGFloat logoInset = logoContainerSize * 0.20;
    self.currentStoreLogoView.frame = NSInsetRect(self.currentStoreLogoContainer.bounds, logoInset, logoInset);
    self.reflectionLayer.frame = NSMakeRect(width * (16.0 / 180.0), height - height * (10.0 / 180.0), MAX(1.0, width - width * (32.0 / 180.0)), height * (18.0 / 180.0));
    CGPathRef shadowPath = OpnCreateRoundedRectPath(self.bounds, cornerRadius, cornerRadius);
    self.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);
}

- (void)updateCurrentStoreLogo {
    NSString *store = @"";
    if (_selectedVariantIndex >= 0 && _selectedVariantIndex < (int)_gameData.variants.size()) {
        store = [NSString stringWithUTF8String:_gameData.variants[(size_t)_selectedVariantIndex].appStore.c_str()];
    } else if (!_gameData.availableStores.empty()) {
        store = [NSString stringWithUTF8String:_gameData.availableStores.front().c_str()];
    }

    NSImage *icon = OPNGreyscaleStoreIconImage(store);
    self.currentStoreLogoView.image = icon;
    self.currentStoreLogoContainer.hidden = icon == nil || store.length == 0;
    self.currentStoreLogoContainer.toolTip = store.length > 0 ? OPNStorePrettyName(store) : @"";
}

- (void)playClicked {
    if (self.onPlay) self.onPlay();
}

- (void)updateGame:(const OPN::GameInfo &)game {
    int selectedVariant = _selectedVariantIndex;
    const std::string previousImageSignature = OPNGameCardImageSignature(_gameData);
    const std::string nextImageSignature = OPNGameCardImageSignature(game);
    _gameData = game;
    if (selectedVariant >= 0 && selectedVariant < (int)_gameData.variants.size()) {
        _selectedVariantIndex = selectedVariant;
    } else {
        _selectedVariantIndex = _gameData.variants.empty() ? -1 : 0;
    }
    [self buildStoreChips];
    [self updateControllerLabels];
    [self updateCurrentStoreLogo];
    if (previousImageSignature != nextImageSignature) {
        self.imageView.image = nil;
        [self loadImage];
    }
}

- (void)buildStoreChips {
    for (NSView *v in _storeChipsContainer.subviews) { [v removeFromSuperview]; }
    [_storeChipButtons removeAllObjects];
    self.storeChipsContainer.hidden = OpnControllerModeEnabled() || _gameData.variants.size() <= 1;
    if (self.storeChipsContainer.hidden) return;
    if (_gameData.variants.empty()) return;

    if (_gameData.variants.size() <= 1) return;

    CGFloat x = 0;
    NSInteger maxChips = 4;
    NSInteger count = 0;
    int idx = 0;
    for (auto &v : _gameData.variants) {
        if (count >= maxChips) break;
        NSString *name = [NSString stringWithUTF8String:v.appStore.c_str()];
        if (!name || name.length == 0) { idx++; continue; }
        NSString *glyph = OPNStoreIconGlyph(name);
        BOOL selected = idx == _selectedVariantIndex;
        NSImage *iconImage = OPNStoreIconImage(name);

        NSButton *chip = [[NSButton alloc] initWithFrame:NSMakeRect(x, 0, 28, 24)];
        if (iconImage) {
            chip.title = @"";
            chip.image = iconImage;
            chip.imagePosition = NSImageOnly;
            chip.imageScaling = NSImageScaleProportionallyDown;
        } else {
            chip.attributedTitle = [[NSAttributedString alloc] initWithString:glyph
                                                                    attributes:@{
                NSFontAttributeName: OPNStoreIconFont(glyph),
                NSForegroundColorAttributeName: OPNStoreIconColor(name, selected),
            }];
        }
        chip.bordered = NO;
        chip.wantsLayer = YES;
        chip.layer.cornerRadius = 8;
        chip.target = self;
        chip.action = @selector(chipClicked:);
        chip.tag = idx;
        chip.toolTip = OPNStorePrettyName(name ?: @"");

        if (selected) {
            chip.layer.backgroundColor = OpnColor(0x05070A, 0.62).CGColor;
            chip.layer.borderWidth = 1.0;
            chip.layer.borderColor = OpnColor(0xFFFFFF, 0.34).CGColor;
        } else {
            chip.layer.backgroundColor = OpnColor(0x05070A, 0.34).CGColor;
            chip.layer.borderColor = OpnColor(0xFFFFFF, 0.16).CGColor;
            chip.layer.borderWidth = 1;
        }

        [_storeChipsContainer addSubview:chip];
        [_storeChipButtons addObject:chip];
        x += 32;
        count++;
        idx++;
    }
}

- (void)chipClicked:(NSButton *)sender {
    [self selectVariantAtIndex:(int)sender.tag];
}

- (void)selectVariantAtIndex:(int)index {
    if (index < 0 || index >= (int)_gameData.variants.size()) return;
    _selectedVariantIndex = index;
    [self buildStoreChips];
    [self updateControllerLabels];
    [self updateCurrentStoreLogo];
}

- (void)loadImage {
    NSMutableArray<NSString *> *urlStrings = [NSMutableArray array];
    const OPN::GameInfo &gameData = _gameData;
    auto appendRawImagesForType = [&](const char *type) {
        auto it = gameData.imageUrlsByType.find(type);
        if (it == gameData.imageUrlsByType.end()) return;
        for (const std::string &value : it->second) {
            if (value.empty()) continue;
            NSString *candidate = [NSString stringWithUTF8String:value.c_str()];
            if (candidate.length > 0 && ![urlStrings containsObject:candidate]) [urlStrings addObject:candidate];
        }
    };
    if (OpnControllerModeEnabled()) {
        appendRawImagesForType("KEY_ART");
        appendRawImagesForType("KEY_IMAGE");
    }
    NSString *primaryUrl = self.gameData.imageUrl.empty() ? nil : [NSString stringWithUTF8String:self.gameData.imageUrl.c_str()];
    NSString *heroUrl = self.gameData.heroImageUrl.empty() ? nil : [NSString stringWithUTF8String:self.gameData.heroImageUrl.c_str()];
    NSString *steamUrl = OPNSteamArtworkURLForGame(self.gameData);
    for (NSString *candidate in @[heroUrl ?: @"", primaryUrl ?: @"", steamUrl ?: @""]) {
        if (candidate.length > 0 && ![urlStrings containsObject:candidate]) {
            [urlStrings addObject:candidate];
        }
    }
    NSString *title = self.gameData.title.empty() ? @"<untitled>" : [NSString stringWithUTF8String:self.gameData.title.c_str()];
    NSString *gameId = self.gameData.id.empty() ? @"" : [NSString stringWithUTF8String:self.gameData.id.c_str()];
    OPN::LogInfo(@"[GameCard] image candidates title=%@ id=%@ hero=%d primary=%d steam=%d total=%lu", title, gameId, heroUrl.length > 0, primaryUrl.length > 0, steamUrl.length > 0, (unsigned long)urlStrings.count);
    if (urlStrings.count == 0) {
        OPN::LogInfo(@"[GameCard] no image candidates title=%@ id=%@ variants=%lu", title, gameId, (unsigned long)self.gameData.variants.size());
        return;
    }

    NSUInteger generation = ++self.imageLoadGeneration;
    [self loadImageFromCandidates:urlStrings index:0 generation:generation];
}

- (void)loadImageFromCandidates:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index generation:(NSUInteger)generation {
    if (generation != self.imageLoadGeneration) return;
    if (index >= urlStrings.count) {
        NSString *title = self.gameData.title.empty() ? @"<untitled>" : [NSString stringWithUTF8String:self.gameData.title.c_str()];
        OPN::LogError(@"[GameCard] all image candidates failed title=%@", title);
        return;
    }

    NSString *urlStr = urlStrings[index];
    NSString *title = self.gameData.title.empty() ? @"<untitled>" : [NSString stringWithUTF8String:self.gameData.title.c_str()];
    __weak __typeof__(self) weakSelf = self;
    OPN::LogInfo(@"[GameCard] image request start title=%@ index=%lu/%lu url=%@", title, (unsigned long)index + 1, (unsigned long)urlStrings.count, urlStr);
    OPNGameCardLoadImageForURL(urlStr, ^(NSImage *image) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.imageLoadGeneration != generation) return;
        if (!image) {
            OPN::LogError(@"[GameCard] image candidate failed title=%@ index=%lu url=%@", title, (unsigned long)index + 1, urlStr);
            [strongSelf loadImageFromCandidates:urlStrings index:index + 1 generation:generation];
            return;
        }
        OPN::LogInfo(@"[GameCard] image loaded title=%@ size=%.0fx%.0f url=%@", title, image.size.width, image.size.height, urlStr);
        strongSelf.imageView.image = image;
    });
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    if (OpnControllerModeEnabled()) return;
    if (!self.controllerFocused) {
        self.playButton.hidden = NO;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.28).CGColor;
    }
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    if (OpnControllerModeEnabled()) return;
    if (!self.controllerFocused) {
        self.playButton.hidden = YES;
        self.layer.borderColor = OpnColor(0xFFFFFF, 0.10).CGColor;
    }
}

- (void)updateTrackingAreas {
    if (self.trackingArea && [self.trackingAreas containsObject:self.trackingArea]) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
        owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

@end
