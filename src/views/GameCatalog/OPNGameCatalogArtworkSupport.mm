#import "OPNGameCatalogPrivate.h"

NSString *OPNStoreDisplayLabel(NSString *value) {
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
NSString *OPNStoreDisplayString(const std::string &value, NSString *fallback) {
    NSString *display = OPNStoreDisplayLabel(OPNStoreString(value, @""));
    return display.length > 0 ? display : (fallback ?: @"");
}

NSString *OPNStoreIconAssetName(NSString *name) {
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

static NSOperationQueue *OPNStoreIconLoaderQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.opennow.store-icon-loader";
        queue.maxConcurrentOperationCount = 2;
        queue.qualityOfService = NSQualityOfServiceUtility;
    });
    return queue;
}

NSArray<NSString *> *OPNStoreIconCandidatePaths(NSString *assetName) {
    NSString *safeAssetName = assetName.length > 0 ? assetName : @"default";
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:safeAssetName ofType:@"svg" inDirectory:@"store-icons"];
    if (bundlePath.length > 0) [paths addObject:bundlePath];
    NSString *relativePath = [NSString stringWithFormat:@"assets/store-icons/%@.svg", safeAssetName];
    [paths addObject:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:relativePath]];
    [paths addObject:[@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:relativePath]];
    return paths;
}

void OPNReadStoreIconDataAtPath(NSString *path, void (^completion)(NSData *data)) {
    if (!completion) return;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_io_t channel = dispatch_io_create_with_path(DISPATCH_IO_STREAM, path.fileSystemRepresentation, O_RDONLY, 0, queue, ^(int error) { (void)error; });
    if (!channel) {
        completion(nil);
        return;
    }
    NSMutableData *result = [NSMutableData data];
    dispatch_io_read(channel, 0, SIZE_MAX, queue, ^(bool done, dispatch_data_t data, int error) {
        if (data && error == 0) {
            dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
                (void)region;
                (void)offset;
                [result appendBytes:buffer length:size];
                return true;
            });
        }
        if (!done) return;
        dispatch_io_close(channel, 0);
        completion(error == 0 && result.length > 0 ? [result copy] : nil);
    });
}

void OPNLoadStoreIconDataFromPaths(NSArray<NSString *> *paths, NSUInteger index, void (^completion)(NSData *data)) {
    if (index >= paths.count) {
        completion(nil);
        return;
    }
    OPNReadStoreIconDataAtPath(paths[index], ^(NSData *data) {
        if (data.length > 0) {
            completion(data);
            return;
        }
        OPNLoadStoreIconDataFromPaths(paths, index + 1, completion);
    });
}

NSImage *OPNStoreIconPlaceholderImage(NSString *name) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *assetName = OPNStoreIconAssetName(name);
    NSImage *cached = cache[assetName];
    if (cached) return cached;

    NSDictionary<NSString *, NSString *> *labels = @{
        @"steam": @"ST",
        @"epic": @"EP",
        @"ubisoft": @"UB",
        @"battlenet": @"BN",
        @"xbox": @"XB",
        @"ea": @"EA",
        @"gog": @"GOG",
        @"default": @"CL",
    };
    NSDictionary<NSString *, NSColor *> *fills = @{
        @"steam": OpnColor(0x1B2838, 1.0),
        @"epic": OpnColor(0x202020, 1.0),
        @"ubisoft": OpnColor(0x3D61FF, 1.0),
        @"battlenet": OpnColor(0x149BFF, 1.0),
        @"xbox": OpnColor(0x107C10, 1.0),
        @"ea": OpnColor(0xFF4747, 1.0),
        @"gog": OpnColor(0x6D3DF5, 1.0),
        @"default": OpnColor(OPN::kBrandGreen, 1.0),
    };

    NSSize size = NSMakeSize(64.0, 64.0);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    NSRect bounds = NSMakeRect(0.0, 0.0, size.width, size.height);
    [(fills[assetName] ?: fills[@"default"]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14.0 yRadius:14.0] fill];
    NSString *label = labels[assetName] ?: labels[@"default"];
    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:label.length > 2 ? 18.0 : 23.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    NSSize labelSize = [label sizeWithAttributes:attributes];
    [label drawAtPoint:NSMakePoint(floor((size.width - labelSize.width) * 0.5), floor((size.height - labelSize.height) * 0.5) - 1.0) withAttributes:attributes];
    [image unlockFocus];
    cache[assetName] = image;
    return image;
}

NSMutableDictionary<NSString *, NSImage *> *OPNStoreIconImageCache(void) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

NSImage *OPNCachedStoreIconImage(NSString *name) {
    return OPNStoreIconImageCache()[OPNStoreIconAssetName(name)];
}

NSImage *OPNStoreGreyscaleIconImage(NSImage *image) {
    NSImage *templateImage = image ? [image copy] : nil;
    [templateImage setTemplate:YES];
    return templateImage;
}

void OPNLoadStoreIconImage(NSString *name, void (^completion)(NSImage *image)) {
    NSString *assetName = OPNStoreIconAssetName(name);
    NSImage *cached = OPNCachedStoreIconImage(name);
    if (cached) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
        return;
    }
    NSArray<NSString *> *paths = OPNStoreIconCandidatePaths(assetName);
    [OPNStoreIconLoaderQueue() addOperationWithBlock:^{
        OPNLoadStoreIconDataFromPaths(paths, 0, ^(NSData *data) {
            NSImage *image = data.length > 0 ? [[NSImage alloc] initWithData:data] : nil;
            if (!image && ![assetName isEqualToString:@"default"]) {
                OPNLoadStoreIconDataFromPaths(OPNStoreIconCandidatePaths(@"default"), 0, ^(NSData *defaultData) {
                    NSImage *defaultImage = defaultData.length > 0 ? [[NSImage alloc] initWithData:defaultData] : nil;
                    if (defaultImage) [defaultImage setTemplate:NO];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (defaultImage) OPNStoreIconImageCache()[assetName] = defaultImage;
                        if (completion) completion(defaultImage);
                    });
                });
                return;
            }
            if (image) [image setTemplate:NO];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (image) OPNStoreIconImageCache()[assetName] = image;
                if (completion) completion(image);
            });
        });
    }];
}

NSImage *OPNStoreFallbackArtworkImage(void) {
    return OpnFallbackHeroArtworkImage();
}

NSString *OPNStorePrimaryStoreName(const OPN::GameInfo &game) {
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

NSArray<NSString *> *OPNStoreVariantStoreNames(const OPN::GameInfo &game) {
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

bool OPNStoreStringEqualsCaseInsensitive(const std::string &lhs, const std::string &rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); i++) {
        if (std::tolower((unsigned char)lhs[i]) != std::tolower((unsigned char)rhs[i])) return false;
    }
    return true;
}

BOOL OPNStoreIsNumericString(const std::string &value) {
    return !value.empty() && value.find_first_not_of("0123456789") == std::string::npos;
}

void OPNStoreAppendUniqueURL(NSMutableArray<NSString *> *urls, NSString *urlString) {
    NSString *trimmed = [urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [urls containsObject:trimmed]) return;
    [urls addObject:trimmed];
}

void OPNStoreAppendImageType(NSMutableArray<NSString *> *urls, const OPN::GameInfo &game, const char *type) {
    auto it = game.imageUrlsByType.find(type);
    if (it == game.imageUrlsByType.end()) return;
    for (const std::string &url : it->second) {
        OPNStoreAppendUniqueURL(urls, OPNStoreString(url, @""));
    }
}

NSString *OPNStoreSteamArtworkURLForGame(const OPN::GameInfo &game) {
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

NSArray<NSString *> *OPNStoreImageCandidatesForGame(const OPN::GameInfo &game, BOOL prominent) {
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

NSArray<NSString *> *OPNStoreLogoCandidatesForGame(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSArray<NSString *> *preferredTypes = @[@"GAME_LOGO", @"LOGO", @"TITLE_LOGO"];
    for (NSString *type in preferredTypes) {
        OPNStoreAppendImageType(urls, game, type.UTF8String);
    }
    return urls;
}

NSCache<NSString *, NSImage *> *OPNStoreLogoCropCache(void) {
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 120;
        cache.totalCostLimit = 32 * 1024 * 1024;
    });
    return cache;
}

NSImage *OPNStoreVisibleLogoImage(NSImage *image) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return image;
    NSString *cacheKey = [NSString stringWithFormat:@"%p:%.0fx%.0f", (__bridge void *)image, image.size.width, image.size.height];
    NSImage *cached = [OPNStoreLogoCropCache() objectForKey:cacheKey];
    if (cached) return cached;
    NSRect proposedRect = NSMakeRect(0.0, 0.0, image.size.width, image.size.height);
    CGImageRef source = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!source) return image;

    NSInteger width = (NSInteger)CGImageGetWidth(source);
    NSInteger height = (NSInteger)CGImageGetHeight(source);
    if (width <= 0 || height <= 0) return image;
    const size_t bytesPerPixel = 4;
    const size_t bytesPerRow = (size_t)width * bytesPerPixel;
    std::vector<unsigned char> pixels((size_t)height * bytesPerRow, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(pixels.data(), (size_t)width, (size_t)height, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!context) return image;
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), source);
    CGContextRelease(context);

    NSInteger minX = width;
    NSInteger minY = height;
    NSInteger maxX = -1;
    NSInteger maxY = -1;
    for (NSInteger y = 0; y < height; y++) {
        for (NSInteger x = 0; x < width; x++) {
            size_t offset = (size_t)y * bytesPerRow + (size_t)x * bytesPerPixel;
            if (pixels[offset + 3] <= 10) continue;
            minX = MIN(minX, x);
            minY = MIN(minY, y);
            maxX = MAX(maxX, x);
            maxY = MAX(maxY, y);
        }
    }
    if (maxX < minX || maxY < minY) return image;

    NSInteger padding = MAX((NSInteger)8, (NSInteger)ceil(MAX(maxX - minX + 1, maxY - minY + 1) * 0.04));
    minX = MAX((NSInteger)0, minX - padding);
    minY = MAX((NSInteger)0, minY - padding);
    maxX = MIN(width - 1, maxX + padding);
    maxY = MIN(height - 1, maxY + padding);

    NSInteger cropWidth = maxX - minX + 1;
    NSInteger cropHeight = maxY - minY + 1;
    if (cropWidth <= 0 || cropHeight <= 0) return image;
    if (cropWidth >= width * 0.92 && cropHeight >= height * 0.92) return image;

    CGImageRef cropped = CGImageCreateWithImageInRect(source, CGRectMake((CGFloat)minX, (CGFloat)minY, (CGFloat)cropWidth, (CGFloat)cropHeight));
    if (!cropped) return image;
    NSImage *croppedImage = [[NSImage alloc] initWithCGImage:cropped size:NSMakeSize((CGFloat)cropWidth, (CGFloat)cropHeight)];
    CGImageRelease(cropped);
    NSImage *result = croppedImage ?: image;
    [OPNStoreLogoCropCache() setObject:result forKey:cacheKey cost:(NSUInteger)MAX((NSInteger)1, cropWidth * cropHeight * 4)];
    return result;
}

NSRect OPNStoreHeroVisibleArtworkRectForImage(NSImage *image, NSRect bounds) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return bounds;
    return bounds;
}

NSRect OPNStoreHeroLogoFrameForImage(NSImage *image, NSRect bounds, NSImage *artworkImage) {
    NSRect artworkRect = OPNStoreHeroVisibleArtworkRectForImage(artworkImage, bounds);
    CGFloat horizontalInset = MIN(OPNStoreHeroContentInsetForWidth(NSWidth(bounds)), MAX(24.0, NSWidth(artworkRect) * 0.08));
    CGFloat maxWidth = MIN(kStoreHeroLogoMaxWidth, MAX(120.0, NSWidth(artworkRect) - horizontalInset * 2.0));
    CGFloat maxHeight = MIN(kStoreHeroLogoMaxHeight, NSHeight(artworkRect) * 0.44);
    CGFloat width = maxWidth;
    CGFloat height = maxHeight;
    if (image.size.width > 0.0 && image.size.height > 0.0) {
        CGFloat aspect = image.size.width / image.size.height;
        if (maxWidth / MAX(1.0, maxHeight) > aspect) {
            height = maxHeight;
            width = floor(height * aspect);
        } else {
            width = maxWidth;
            height = floor(width / aspect);
        }
    }
    CGFloat x = NSMinX(artworkRect) + horizontalInset;
    CGFloat y = NSMinY(artworkRect) + floor((NSHeight(artworkRect) - height) * 0.5);
    return NSMakeRect(x, y, width, height);
}

NSRect OPNStoreHeroLogoFallbackFrame(NSRect bounds, NSImage *artworkImage) {
    NSRect artworkRect = OPNStoreHeroVisibleArtworkRectForImage(artworkImage, bounds);
    CGFloat horizontalInset = MIN(OPNStoreHeroContentInsetForWidth(NSWidth(bounds)), MAX(24.0, NSWidth(artworkRect) * 0.08));
    CGFloat width = MIN(kStoreHeroLogoMaxWidth, MAX(160.0, NSWidth(artworkRect) - horizontalInset * 2.0));
    CGFloat height = MIN(108.0, MAX(56.0, NSHeight(artworkRect) * 0.22));
    CGFloat x = NSMinX(artworkRect) + horizontalInset;
    CGFloat y = NSMinY(artworkRect) + floor((NSHeight(artworkRect) - height) * 0.5);
    return NSMakeRect(x, y, width, height);
}

void OPNStoreHeroBringLogoToFront(NSView *container, NSTextField *titleFallback, NSImageView *logoView) {
    if (!container) return;
    if (titleFallback.superview == container) [container addSubview:titleFallback positioned:NSWindowAbove relativeTo:nil];
    if (logoView.superview == container) [container addSubview:logoView positioned:NSWindowAbove relativeTo:nil];
}

void OPNStoreConfigureHeroLogoImageView(NSImageView *logoView, CGFloat zPosition) {
    logoView.imageScaling = NSImageScaleProportionallyDown;
    logoView.imageAlignment = NSImageAlignLeft;
    logoView.wantsLayer = YES;
    logoView.layer.zPosition = zPosition;
    logoView.layer.shadowColor = OpnColor(OPN::kBlack, 0.90).CGColor;
    logoView.layer.shadowOpacity = 1.0;
    logoView.layer.shadowRadius = 18.0;
    logoView.layer.shadowOffset = CGSizeMake(0.0, -2.0);
}

BOOL OPNStoreHeroImageHasVisibleContent(NSImage *image) {
    if (!image || image.size.width <= 0.0 || image.size.height <= 0.0) return NO;
    if (image.size.width < 900.0 || image.size.height < 300.0) return NO;
    if (image.size.width / MAX(1.0, image.size.height) < 1.65) return NO;
    NSRect proposedRect = NSMakeRect(0.0, 0.0, image.size.width, image.size.height);
    CGImageRef source = [image CGImageForProposedRect:&proposedRect context:nil hints:nil];
    if (!source) return YES;

    static const size_t sampleWidth = 24;
    static const size_t sampleHeight = 24;
    static const size_t bytesPerPixel = 4;
    static const size_t bytesPerRow = sampleWidth * bytesPerPixel;
    std::vector<unsigned char> pixels(sampleHeight * bytesPerRow, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef context = CGBitmapContextCreate(pixels.data(), sampleWidth, sampleHeight, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGColorSpaceRelease(colorSpace);
    if (!context) return YES;
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, sampleWidth, sampleHeight), source);
    CGContextRelease(context);

    NSUInteger visiblePixels = 0;
    NSUInteger opaquePixels = 0;
    for (size_t offset = 0; offset + 3 < pixels.size(); offset += bytesPerPixel) {
        CGFloat alpha = pixels[offset + 3];
        if (alpha > 24.0) visiblePixels++;
        if (alpha > 180.0) opaquePixels++;
    }
    NSUInteger totalPixels = sampleWidth * sampleHeight;
    return visiblePixels >= totalPixels / 3 && opaquePixels >= totalPixels / 5;
}

NSString *OPNStorePrimaryGenre(const OPN::GameInfo &game) {
    if (!game.genres.empty()) return OPNStoreDisplayString(game.genres.front(), @"Cloud Game");
    if (!game.playType.empty()) return OPNStoreDisplayString(game.playType, @"Cloud Game");
    return @"Cloud Game";
}

NSString *OPNStoreFeatureSummary(const OPN::GameInfo &game) {
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
