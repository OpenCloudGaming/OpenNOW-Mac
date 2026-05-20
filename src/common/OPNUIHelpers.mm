#import "OPNUIHelpers.h"
#import "OPNColorTokens.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#include <cmath>

NSString *const OPNInterfacePreferencesDidChangeNotification = @"OpenNOW.InterfacePreferencesDidChange";

static NSString *const OPNAutoFullScreenDefaultsKey = @"OpenNOW.Interface.AutoFullScreen";
static NSString *const OPNControllerModeDefaultsKey = @"OpenNOW.Interface.ControllerMode";
static const CGFloat OPNBackgroundTintStrength = 0.85;

static dispatch_queue_t OpnImageLoaderQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.opennow.image-loader", DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

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

static NSMutableDictionary<NSString *, NSMutableArray<OpnImageLoadCompletion> *> *OpnPendingImageCompletions(void) {
    static NSMutableDictionary<NSString *, NSMutableArray<OpnImageLoadCompletion> *> *pendingCompletions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pendingCompletions = [NSMutableDictionary dictionary];
    });
    return pendingCompletions;
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
    NSMutableDictionary<NSString *, NSMutableArray<OpnImageLoadCompletion> *> *pendingCompletions = OpnPendingImageCompletions();
    NSArray<OpnImageLoadCompletion> *completions = nil;
    @synchronized (pendingCompletions) {
        if (image) {
            NSUInteger cost = MAX((NSUInteger)1, (NSUInteger)(image.size.width * image.size.height * 4.0));
            [OpnDecodedImageCache() setObject:image forKey:cacheKey cost:cost];
        }
        if (data.length > 0) [OpnImageDataMemoryCache() setObject:data forKey:cacheKey cost:data.length];
        completions = [pendingCompletions[cacheKey] copy];
        [pendingCompletions removeObjectForKey:cacheKey];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (OpnImageLoadCompletion completion in completions) completion(image, urlString, data);
    });
}

static int OPNClampedColorByte(NSInteger value) {
    return (int)MAX(0, MIN(value, 255));
}

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

BOOL OpnControllerModeEnabled(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:OPNControllerModeDefaultsKey];
    return stored ? [NSUserDefaults.standardUserDefaults boolForKey:OPNControllerModeDefaultsKey] : YES;
}

void OpnSetControllerModeEnabled(BOOL enabled) {
    if (enabled == OpnControllerModeEnabled()) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:OPNControllerModeDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [NSNotificationCenter.defaultCenter postNotificationName:OPNInterfacePreferencesDidChangeNotification object:nil];
}

CGFloat OpnBackgroundTintStrength(void) {
    return OPNBackgroundTintStrength;
}

static void OPNAppendLittleEndianUInt16(NSMutableData *data, uint16_t value) {
    uint16_t little = CFSwapInt16HostToLittle(value);
    [data appendBytes:&little length:sizeof(little)];
}

static void OPNAppendLittleEndianUInt32(NSMutableData *data, uint32_t value) {
    uint32_t little = CFSwapInt32HostToLittle(value);
    [data appendBytes:&little length:sizeof(little)];
}

static NSData *OPNConsoleToneWAVData(OPNConsoleTone tone) {
    static NSMutableDictionary<NSNumber *, NSData *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSMutableDictionary dictionary];
    });

    NSNumber *key = @(tone);
    NSData *cached = cache[key];
    if (cached) return cached;

    const uint32_t sampleRate = 44100;
    double duration = 0.070;
    double primaryFrequency = 660.0;
    double secondaryFrequency = 990.0;
    double volume = 0.22;
    switch (tone) {
        case OPNConsoleToneMove:
            duration = 0.052;
            primaryFrequency = 720.0;
            secondaryFrequency = 1080.0;
            volume = 0.17;
            break;
        case OPNConsoleToneSelect:
            duration = 0.105;
            primaryFrequency = 620.0;
            secondaryFrequency = 1240.0;
            volume = 0.23;
            break;
        case OPNConsoleToneChange:
            duration = 0.090;
            primaryFrequency = 880.0;
            secondaryFrequency = 1320.0;
            volume = 0.20;
            break;
        case OPNConsoleToneBack:
            duration = 0.080;
            primaryFrequency = 440.0;
            secondaryFrequency = 330.0;
            volume = 0.18;
            break;
    }

    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint32_t frameCount = (uint32_t)std::round(duration * sampleRate);
    const uint32_t dataByteCount = frameCount * channels * (bitsPerSample / 8);
    NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataByteCount];

    [data appendBytes:"RIFF" length:4];
    OPNAppendLittleEndianUInt32(data, 36 + dataByteCount);
    [data appendBytes:"WAVE" length:4];
    [data appendBytes:"fmt " length:4];
    OPNAppendLittleEndianUInt32(data, 16);
    OPNAppendLittleEndianUInt16(data, 1);
    OPNAppendLittleEndianUInt16(data, channels);
    OPNAppendLittleEndianUInt32(data, sampleRate);
    OPNAppendLittleEndianUInt32(data, sampleRate * channels * (bitsPerSample / 8));
    OPNAppendLittleEndianUInt16(data, channels * (bitsPerSample / 8));
    OPNAppendLittleEndianUInt16(data, bitsPerSample);
    [data appendBytes:"data" length:4];
    OPNAppendLittleEndianUInt32(data, dataByteCount);

    for (uint32_t frame = 0; frame < frameCount; frame++) {
        double t = (double)frame / (double)sampleRate;
        double progress = (double)frame / (double)MAX(1u, frameCount - 1);
        double attack = MIN(1.0, progress / 0.10);
        double release = MIN(1.0, (1.0 - progress) / 0.42);
        double envelope = attack * release;
        double bend = 1.0 + (tone == OPNConsoleToneBack ? -0.18 : 0.10) * (1.0 - progress);
        double sample = sin(2.0 * M_PI * primaryFrequency * bend * t) * 0.68;
        sample += sin(2.0 * M_PI * secondaryFrequency * t) * 0.24;
        sample += sin(2.0 * M_PI * primaryFrequency * 2.0 * t) * 0.08;
        int16_t pcm = (int16_t)std::round(MAX(-1.0, MIN(1.0, sample * envelope * volume)) * 32767.0);
        OPNAppendLittleEndianUInt16(data, (uint16_t)pcm);
    }

    NSData *immutableData = [data copy];
    cache[key] = immutableData;
    return immutableData;
}

void OpnPlayConsoleTone(OPNConsoleTone tone) {
    static NSMutableArray<AVAudioPlayer *> *activePlayers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activePlayers = [NSMutableArray array];
    });

    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:OPNConsoleToneWAVData(tone) error:&error];
    if (!player || error) return;
    player.volume = 0.85;
    [player prepareToPlay];
    [activePlayers addObject:player];
    [player play];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((player.duration + 0.25) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [activePlayers removeObject:player];
    });
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

void OpnLoadImageForURL(NSString *urlString, CGFloat maxPixelDimension, OpnImageLoadCompletion completion) {
    if (!completion) return;
    NSString *normalizedURL = [[urlString ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
    if (normalizedURL.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, nil); });
        return;
    }

    NSString *cacheKey = OpnImageCacheKey(normalizedURL, maxPixelDimension);
    NSImage *cachedImage = [OpnDecodedImageCache() objectForKey:cacheKey];
    if (cachedImage) {
        NSData *cachedData = [OpnImageDataMemoryCache() objectForKey:cacheKey];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cachedImage, normalizedURL, cachedData); });
        return;
    }

    NSMutableDictionary<NSString *, NSMutableArray<OpnImageLoadCompletion> *> *pendingCompletions = OpnPendingImageCompletions();
    @synchronized (pendingCompletions) {
        NSMutableArray<OpnImageLoadCompletion> *existing = pendingCompletions[cacheKey];
        if (existing) {
            [existing addObject:[completion copy]];
            return;
        }
        pendingCompletions[cacheKey] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    dispatch_async(OpnImageLoaderQueue(), ^{
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

        [[OpnImageLoaderSession() dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || data.length == 0 || (http && http.statusCode >= 400)) {
                OpnCompleteImageRequest(cacheKey, normalizedURL, nil, nil);
                return;
            }
            dispatch_async(OpnImageLoaderQueue(), ^{
                NSImage *image = OpnDecodedImageFromData(data, maxPixelDimension);
                if (image) [data writeToFile:OpnImageDataPath(normalizedURL) options:NSDataWritingAtomic error:nil];
                OpnCompleteImageRequest(cacheKey, normalizedURL, image, image ? data : nil);
            });
        }] resume];
    });
}

static void OpnLoadImageCandidateAtIndex(NSArray<NSString *> *candidates,
                                         NSUInteger index,
                                         CGFloat maxPixelDimension,
                                         OpnImageLoadCompletion completion) {
    if (!completion) return;
    if (index >= candidates.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, nil); });
        return;
    }
    NSString *candidate = candidates[index];
    OpnLoadImageForURL(candidate, maxPixelDimension, ^(NSImage *image, NSString *resolvedURL, NSData *data) {
        if (image) {
            completion(image, resolvedURL, data);
            return;
        }
        OpnLoadImageCandidateAtIndex(candidates, index + 1, maxPixelDimension, completion);
    });
}

void OpnLoadImageFromCandidates(NSArray<NSString *> *candidates,
                                CGFloat maxPixelDimension,
                                OpnImageLoadCompletion completion) {
    OpnLoadImageCandidateAtIndex(candidates, 0, maxPixelDimension, completion);
}
