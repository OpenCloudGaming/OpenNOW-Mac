#import "OPNUIHelpers.h"
#import "OPNColorTokens.h"
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#include <cmath>

NSString *const OPNInterfacePreferencesDidChangeNotification = @"OpenNOW.InterfacePreferencesDidChange";

static NSString *const OPNAutoFullScreenDefaultsKey = @"OpenNOW.Interface.AutoFullScreen";
static const CGFloat OPNBackgroundTintStrength = 0.85;

static NSOperationQueue *OpnImageLoaderOperationQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.opennow.image-loader";
        queue.maxConcurrentOperationCount = 4;
        queue.qualityOfService = NSQualityOfServiceUtility;
    });
    return queue;
}

@interface OpnImageLoadToken ()
- (void)opnSetOperation:(NSOperation *)operation;
- (void)opnSetTask:(NSURLSessionDataTask *)task;
- (void)opnAddChildToken:(OpnImageLoadToken *)token;
@end

@implementation OpnImageLoadToken {
    NSLock *_lock;
    BOOL _cancelled;
    NSOperation *_operation;
    NSURLSessionDataTask *_task;
    NSMutableArray<OpnImageLoadToken *> *_children;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _children = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isCancelled {
    [_lock lock];
    BOOL cancelled = _cancelled;
    [_lock unlock];
    return cancelled;
}

- (void)cancel {
    NSArray<OpnImageLoadToken *> *children = nil;
    NSOperation *operation = nil;
    NSURLSessionDataTask *task = nil;
    [_lock lock];
    if (!_cancelled) {
        _cancelled = YES;
        operation = _operation;
        task = _task;
        children = [_children copy];
        [_children removeAllObjects];
    }
    [_lock unlock];
    [operation cancel];
    [task cancel];
    for (OpnImageLoadToken *child in children) [child cancel];
}

- (void)opnSetOperation:(NSOperation *)operation {
    BOOL cancelNow = NO;
    [_lock lock];
    _operation = operation;
    cancelNow = _cancelled;
    [_lock unlock];
    if (cancelNow) [operation cancel];
}

- (void)opnSetTask:(NSURLSessionDataTask *)task {
    BOOL cancelNow = NO;
    [_lock lock];
    _task = task;
    cancelNow = _cancelled;
    [_lock unlock];
    if (cancelNow) [task cancel];
}

- (void)opnAddChildToken:(OpnImageLoadToken *)token {
    if (!token) return;
    BOOL cancelNow = NO;
    [_lock lock];
    cancelNow = _cancelled;
    if (!cancelNow) [_children addObject:token];
    [_lock unlock];
    if (cancelNow) [token cancel];
}

@end

@interface OpnPendingImageCompletion : NSObject
@property (nonatomic, strong) OpnImageLoadToken *token;
@property (nonatomic, copy) OpnImageLoadCompletion completion;
@end

@implementation OpnPendingImageCompletion
@end

static NSURLSession *OpnImageLoaderSession(void) {
    static NSURLSession *session;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.HTTPMaximumConnectionsPerHost = 6;
        configuration.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.URLCache = [NSURLCache sharedURLCache];
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static NSCache<NSString *, NSImage *> *OpnDecodedImageCache(void) {
    static NSCache<NSString *, NSImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 260;
        cache.totalCostLimit = 128 * 1024 * 1024;
    });
    return cache;
}

static NSCache<NSString *, NSData *> *OpnImageDataMemoryCache(void) {
    static NSCache<NSString *, NSData *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 260;
        cache.totalCostLimit = 96 * 1024 * 1024;
    });
    return cache;
}

static NSMutableDictionary<NSString *, NSMutableArray<OpnPendingImageCompletion *> *> *OpnPendingImageCompletions(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<OpnPendingImageCompletion *> *> *pendingCompletions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pendingCompletions = [NSMutableDictionary dictionary];
    });
    return pendingCompletions;
}

static NSMutableDictionary<NSString *, NSDate *> *OpnImageFailureCache(void) {
    static NSMutableDictionary<NSString *, NSDate *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

static BOOL OpnImageFailureCacheContainsFreshEntry(NSString *urlString) {
    if (urlString.length == 0) return NO;
    NSMutableDictionary<NSString *, NSDate *> *cache = OpnImageFailureCache();
    @synchronized (cache) {
        NSDate *expiresAt = cache[urlString];
        if (!expiresAt) return NO;
        if ([expiresAt timeIntervalSinceNow] > 0.0) return YES;
        [cache removeObjectForKey:urlString];
        return NO;
    }
}

static void OpnImageFailureCacheSetFailed(NSString *urlString) {
    if (urlString.length == 0) return;
    NSMutableDictionary<NSString *, NSDate *> *cache = OpnImageFailureCache();
    @synchronized (cache) {
        cache[urlString] = [NSDate dateWithTimeIntervalSinceNow:10.0 * 60.0];
    }
}

static void OpnImageFailureCacheClear(NSString *urlString) {
    if (urlString.length == 0) return;
    NSMutableDictionary<NSString *, NSDate *> *cache = OpnImageFailureCache();
    @synchronized (cache) {
        [cache removeObjectForKey:urlString];
    }
}

static NSString *OpnSHA256String(NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
    return hash;
}

static NSString *OpnImageLoaderDirectory(void) {
    static NSString *directory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
        NSURL *baseURL = urls.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
        directory = [[baseURL URLByAppendingPathComponent:@"OpenNOW/ImageLoader" isDirectory:YES].path copy];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return directory;
}

static NSString *OpnImageDataPath(NSString *urlString) {
    return [OpnImageLoaderDirectory() stringByAppendingPathComponent:[OpnSHA256String(urlString) stringByAppendingPathExtension:@"img"]];
}

static NSInteger OpnImageCachePixelBucket(CGFloat maxPixelDimension) {
    CGFloat clamped = MAX(64.0, MIN(maxPixelDimension > 0.0 ? maxPixelDimension : 1024.0, 4096.0));
    return (NSInteger)(ceil(clamped / 128.0) * 128.0);
}

static NSString *OpnImageCacheKey(NSString *urlString, CGFloat maxPixelDimension) {
    return [NSString stringWithFormat:@"%@|%ld", urlString ?: @"", (long)OpnImageCachePixelBucket(maxPixelDimension)];
}

static NSImage *OpnDecodedImageFromData(NSData *data, CGFloat maxPixelDimension) {
    if (data.length == 0) return nil;
    NSInteger pixelLimit = OpnImageCachePixelBucket(maxPixelDimension);
    NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)sourceOptions);
    if (!source) return nil;

    NSDictionary *thumbnailOptions = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(pixelLimit),
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbnailOptions);
    CFRelease(source);
    if (!thumbnail) return [[NSImage alloc] initWithData:data];

    NSSize size = NSMakeSize((CGFloat)CGImageGetWidth(thumbnail), (CGFloat)CGImageGetHeight(thumbnail));
    NSImage *image = [[NSImage alloc] initWithCGImage:thumbnail size:size];
    CGImageRelease(thumbnail);
    return image;
}

static void OpnCompleteImageRequest(NSString *cacheKey, NSString *urlString, NSImage *image, NSData *data) {
    NSMutableDictionary<NSString *, NSMutableArray<OpnPendingImageCompletion *> *> *pendingCompletions = OpnPendingImageCompletions();
    NSArray<OpnPendingImageCompletion *> *completions = nil;
    @synchronized (pendingCompletions) {
        if (image) {
            NSUInteger cost = MAX((NSUInteger)1, (NSUInteger)(image.size.width * image.size.height * 4.0));
            [OpnDecodedImageCache() setObject:image forKey:cacheKey cost:cost];
            OpnImageFailureCacheClear(urlString);
        } else {
            OpnImageFailureCacheSetFailed(urlString);
        }
        if (data.length > 0) [OpnImageDataMemoryCache() setObject:data forKey:cacheKey cost:data.length];
        completions = [pendingCompletions[cacheKey] copy];
        [pendingCompletions removeObjectForKey:cacheKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (OpnPendingImageCompletion *entry in completions) {
            if (!entry.token.isCancelled && entry.completion) entry.completion(image, urlString, data);
        }
    });
}

static int OPNClampedColorByte(NSInteger value) {
    return (int)MAX(0, MIN(value, 255));
}

static NSString *OpnStringFromStdString(const std::string &value, NSString *fallback) {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [NSString stringWithUTF8String:value.c_str()];
    return string.length > 0 ? string : (fallback ?: @"");
}

static NSString *OpnHeroLocalAssetPath(NSString *relativePath) {
    NSString *safeRelativePath = relativePath ?: @"";
    NSString *bundlePath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:safeRelativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) return bundlePath;
    NSString *workingPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:safeRelativePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:workingPath]) return workingPath;
    NSString *sourcePath = [@"/Volumes/Projects/OpenNOW-Mac" stringByAppendingPathComponent:safeRelativePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:sourcePath] ? sourcePath : nil;
}

static void OpnAppendUniqueHeroURL(NSMutableArray<NSString *> *urls, NSString *urlString) {
    NSString *trimmed = [urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0 || [urls containsObject:trimmed]) return;
    [urls addObject:trimmed];
}

static void OpnAppendHeroImageType(NSMutableArray<NSString *> *urls, const OPN::GameInfo &game, const char *type) {
    auto it = game.imageUrlsByType.find(type);
    if (it == game.imageUrlsByType.end()) return;
    for (const std::string &url : it->second) {
        OpnAppendUniqueHeroURL(urls, OpnStringFromStdString(url, @""));
    }
}

@implementation OPNHeroArtworkView

- (BOOL)isFlipped { return YES; }

- (void)setImage:(NSImage *)image {
    _image = image;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [OpnColor(0x030506, 1.0) setFill];
    NSRectFill(self.bounds);
    if (!self.image || self.image.size.width <= 0.0 || self.image.size.height <= 0.0) return;

    CGFloat imageAspect = self.image.size.width / self.image.size.height;
    CGFloat viewAspect = MAX(1.0, NSWidth(self.bounds)) / MAX(1.0, NSHeight(self.bounds));
    NSRect target = self.bounds;
    if (imageAspect > viewAspect) {
        target.size.height = floor(NSWidth(self.bounds) / imageAspect);
        target.origin.y = floor((NSHeight(self.bounds) - NSHeight(target)) * 0.5);
    } else if (imageAspect < viewAspect) {
        target.size.width = floor(NSHeight(self.bounds) * imageAspect);
        target.origin.x = floor((NSWidth(self.bounds) - NSWidth(target)) * 0.5);
    }

    [self.image drawInRect:target fromRect:NSMakeRect(0.0, 0.0, self.image.size.width, self.image.size.height) operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}

@end

unsigned OpnBlendRGB(unsigned rgb, unsigned target, CGFloat amount) {
    amount = MAX(0.0, MIN(amount, 1.0));
    int r = (int)std::round(((rgb >> 16) & 0xFF) * (1.0 - amount) + ((target >> 16) & 0xFF) * amount);
    int g = (int)std::round(((rgb >> 8) & 0xFF) * (1.0 - amount) + ((target >> 8) & 0xFF) * amount);
    int b = (int)std::round((rgb & 0xFF) * (1.0 - amount) + (target & 0xFF) * amount);
    return ((unsigned)OPNClampedColorByte(r) << 16) | ((unsigned)OPNClampedColorByte(g) << 8) | (unsigned)OPNClampedColorByte(b);
}

BOOL OpnAutoFullScreenEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:OPNAutoFullScreenDefaultsKey];
}

void OpnSetAutoFullScreenEnabled(BOOL enabled) {
    if (enabled == OpnAutoFullScreenEnabled()) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:OPNAutoFullScreenDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:OPNInterfacePreferencesDidChangeNotification object:nil];
}

CGFloat OpnBackgroundTintStrength(void) {
    return OPNBackgroundTintStrength;
}

static unsigned OpnResolvedInterfaceColor(unsigned rgb) {
    switch (rgb) {
        case OPN::kBrandGreen: return OPN::kBrandGreen;
        case OPN::kBrandGreenHover: return OPN::kBrandGreenHover;
        case OPN::kBrandGreenPress: return OPN::kBrandGreenPress;
        case OPN::kAccentOn: return OPN::kAccentOn;
        default: break;
    }
    return rgb;
}

NSColor *OpnColor(unsigned rgb, CGFloat alpha) {
    rgb = OpnResolvedInterfaceColor(rgb);
    return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:alpha];
}

NSDictionary<NSAttributedStringKey, id> *OpnTextStyle(CGFloat size, NSColor *color,
                                                       NSFontWeight weight) {
    return @{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
    };
}

NSTextField *OpnLabel(NSString *text, NSRect frame, CGFloat size, NSColor *color,
                       NSFontWeight weight, NSTextAlignment alignment) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    label.stringValue = text;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.alignment = alignment;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

NSButton *OpnButton(NSString *title, NSRect frame, NSColor *background, NSColor *textColor,
                     bool bordered, NSColor *borderColor) {
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    button.title = title;
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.focusRingType = NSFocusRingTypeNone;
    button.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];
    button.contentTintColor = textColor;
    button.wantsLayer = YES;
    button.layer.backgroundColor = background.CGColor;
    button.layer.cornerRadius = 10.0;
    if (bordered) {
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = (borderColor ? borderColor : OpnColor(OPN::kBrandGreen)).CGColor;
    }
    return button;
}

NSTextField *OpnTextField(NSRect frame, NSString *placeholder, bool isSecure) {
    NSTextField *field = isSecure
        ? [[NSSecureTextField alloc] initWithFrame:frame]
        : [[NSTextField alloc] initWithFrame:frame];
    field.placeholderString = placeholder;
    field.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    field.textColor = OpnColor(OPN::kTextPrimary);
    field.backgroundColor = OpnColor(OPN::kInputBackground);
    field.bordered = YES;
    field.focusRingType = NSFocusRingTypeExterior;
    field.bezelStyle = NSTextFieldRoundedBezel;
    return field;
}

NSProgressIndicator *OpnSpinner(NSRect frame) {
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:frame];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = NSControlSizeRegular;
    spinner.displayedWhenStopped = NO;
    return spinner;
}

void OpnDisableFocusHighlights(NSView *view) {
    if (!view) return;
    view.focusRingType = NSFocusRingTypeNone;
    for (NSView *subview in view.subviews) {
        OpnDisableFocusHighlights(subview);
    }
}

CGPathRef OpnCreateRoundedRectPath(NSRect rect, CGFloat xRadius, CGFloat yRadius) {
    return CGPathCreateWithRoundedRect(NSRectToCGRect(rect), xRadius, yRadius, nullptr);
}

CGPathRef OpnCreateEllipsePath(NSRect rect) {
    return CGPathCreateWithEllipseInRect(NSRectToCGRect(rect), nullptr);
}

OpnImageLoadToken *OpnLoadImageForURLCancellable(NSString *urlString, CGFloat maxPixelDimension, OpnImageLoadCompletion completion) {
    OpnImageLoadToken *token = [[OpnImageLoadToken alloc] init];
    if (!completion) return token;
    NSString *normalizedURL = [[urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
    if (normalizedURL.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!token.isCancelled) completion(nil, nil, nil); });
        return token;
    }

    NSString *cacheKey = OpnImageCacheKey(normalizedURL, maxPixelDimension);
    NSImage *cachedImage = [OpnDecodedImageCache() objectForKey:cacheKey];
    if (cachedImage) {
        NSData *cachedData = [OpnImageDataMemoryCache() objectForKey:cacheKey];
        dispatch_async(dispatch_get_main_queue(), ^{ if (!token.isCancelled) completion(cachedImage, normalizedURL, cachedData); });
        return token;
    }

    if (OpnImageFailureCacheContainsFreshEntry(normalizedURL)) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!token.isCancelled) completion(nil, normalizedURL, nil); });
        return token;
    }

    OpnPendingImageCompletion *pendingEntry = [[OpnPendingImageCompletion alloc] init];
    pendingEntry.token = token;
    pendingEntry.completion = [completion copy];

    NSMutableDictionary<NSString *, NSMutableArray<OpnPendingImageCompletion *> *> *pendingCompletions = OpnPendingImageCompletions();
    @synchronized (pendingCompletions) {
        NSMutableArray<OpnPendingImageCompletion *> *existing = pendingCompletions[cacheKey];
        if (existing) {
            [existing addObject:pendingEntry];
            return token;
        }
        pendingCompletions[cacheKey] = [NSMutableArray arrayWithObject:pendingEntry];
    }

    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSData *cachedData = [NSData dataWithContentsOfFile:OpnImageDataPath(normalizedURL)];
        if (cachedData.length > 0) {
            NSImage *image = OpnDecodedImageFromData(cachedData, maxPixelDimension);
            if (image) {
                OpnCompleteImageRequest(cacheKey, normalizedURL, image, cachedData);
                return;
            }
        }

        NSURL *url = [NSURL URLWithString:normalizedURL];
        if (!url) {
            OpnCompleteImageRequest(cacheKey, normalizedURL, nil, nil);
            return;
        }

        NSURLSessionDataTask *task = [OpnImageLoaderSession() dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || data.length == 0 || (http && http.statusCode >= 400)) {
                OpnCompleteImageRequest(cacheKey, normalizedURL, nil, nil);
                return;
            }
            NSBlockOperation *decodeOperation = [NSBlockOperation blockOperationWithBlock:^{
                NSImage *image = OpnDecodedImageFromData(data, maxPixelDimension);
                if (image) [data writeToFile:OpnImageDataPath(normalizedURL) options:NSDataWritingAtomic error:nil];
                OpnCompleteImageRequest(cacheKey, normalizedURL, image, image ? data : nil);
            }];
            [OpnImageLoaderOperationQueue() addOperation:decodeOperation];
        }];
        [task resume];
    }];
    [OpnImageLoaderOperationQueue() addOperation:operation];
    return token;
}

void OpnLoadImageForURL(NSString *urlString, CGFloat maxPixelDimension, OpnImageLoadCompletion completion) {
    (void)OpnLoadImageForURLCancellable(urlString, maxPixelDimension, completion);
}

static void OpnLoadImageCandidateAtIndex(NSArray<NSString *> *candidates,
                                         NSUInteger index,
                                         CGFloat maxPixelDimension,
                                         OpnImageLoadCompletion completion,
                                         OpnImageLoadToken *parentToken) {
    if (!completion) return;
    if (parentToken.isCancelled) return;
    if (index >= candidates.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (!parentToken.isCancelled) completion(nil, nil, nil); });
        return;
    }
    NSString *candidate = candidates[index];
    OpnImageLoadToken *childToken = OpnLoadImageForURLCancellable(candidate, maxPixelDimension, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        if (parentToken.isCancelled) return;
        if (image) {
            completion(image, resolvedURL, data);
            return;
        }
        OpnLoadImageCandidateAtIndex(candidates, index + 1, maxPixelDimension, completion, parentToken);
    });
    [parentToken opnAddChildToken:childToken];
}

void OpnLoadImageFromCandidates(NSArray<NSString *> *candidates,
                                CGFloat maxPixelDimension,
                                OpnImageLoadCompletion completion) {
    (void)OpnLoadImageFromCandidatesCancellable(candidates, maxPixelDimension, completion);
}

OpnImageLoadToken *OpnLoadImageFromCandidatesCancellable(NSArray<NSString *> *candidates,
                                                         CGFloat maxPixelDimension,
                                                         OpnImageLoadCompletion completion) {
    OpnImageLoadToken *token = [[OpnImageLoadToken alloc] init];
    OpnLoadImageCandidateAtIndex(candidates, 0, maxPixelDimension, completion, token);
    return token;
}

NSString *OpnGameIdentityForHero(const OPN::GameInfo &game) {
    if (!game.id.empty()) return OpnStringFromStdString(game.id, @"");
    if (!game.uuid.empty()) return OpnStringFromStdString(game.uuid, @"");
    if (!game.launchAppId.empty()) return OpnStringFromStdString(game.launchAppId, @"");
    return OpnStringFromStdString(game.title, @"");
}

NSArray<NSString *> *OpnHeroImageCandidatesForGame(const OPN::GameInfo &game) {
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    NSArray<NSString *> *preferredTypes = @[
        @"MARQUEE_HERO_IMAGE",
        @"HERO_IMAGE",
        @"TV_BANNER",
        @"FEATURE_IMAGE",
        @"KEY_ART",
        @"KEY_IMAGE",
        @"GAME_BOX_ART",
    ];
    for (NSString *type in preferredTypes) {
        OpnAppendHeroImageType(urls, game, type.UTF8String);
    }
    OpnAppendUniqueHeroURL(urls, OpnStringFromStdString(game.heroImageUrl, @""));
    OpnAppendUniqueHeroURL(urls, OpnStringFromStdString(game.imageUrl, @""));
    for (const std::string &screenshot : game.screenshotUrls) {
        OpnAppendUniqueHeroURL(urls, OpnStringFromStdString(screenshot, @""));
    }
    return urls;
}

NSImage *OpnFallbackHeroArtworkImage(void) {
    static NSImage *fallbackImage;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *paths = @[
            @"vendor/gfn_vendor_x86_64/files/mall/assets/img/Marquee_Hero_Image_Fallback.webp",
            @"vendor/gfn_vendor_x86_64/files/mall/shared/assets/img/DefaultGameArt-TVBanner.svg",
            @"vendor/gfn_vendor_x86_64/files/mall/assets/img/DefaultGameArt.svg",
        ];
        for (NSString *relativePath in paths) {
            NSString *path = OpnHeroLocalAssetPath(relativePath);
            fallbackImage = path.length > 0 ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
            if (fallbackImage) break;
        }
    });
    return fallbackImage;
}
