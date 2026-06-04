#pragma once

#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include "OPNGameTypes.h"

NSColor *OpnColor(unsigned rgb, CGFloat alpha = 1.0);
unsigned OpnBlendRGB(unsigned rgb, unsigned target, CGFloat amount);

extern NSString *const OPNInterfacePreferencesDidChangeNotification;

typedef NS_ENUM(NSInteger, OPNAppIconTheme) {
    OPNAppIconThemeBlack = 0,
    OPNAppIconThemeGreen = 1,
    OPNAppIconThemeBlue = 2,
};

BOOL OpnAutoFullScreenEnabled(void);
void OpnSetAutoFullScreenEnabled(BOOL enabled);
OPNAppIconTheme OpnAppIconThemePreference(void);
void OpnSetAppIconThemePreference(OPNAppIconTheme theme);
CGFloat OpnBackgroundTintStrength(void);

NSDictionary<NSAttributedStringKey, id> *OpnTextStyle(CGFloat size, NSColor *color,
                                                        NSFontWeight weight = NSFontWeightRegular);

NSTextField *OpnLabel(NSString *text, NSRect frame, CGFloat size, NSColor *color,
                       NSFontWeight weight = NSFontWeightRegular,
                       NSTextAlignment alignment = NSTextAlignmentLeft);

NSButton *OpnButton(NSString *title, NSRect frame, NSColor *background, NSColor *textColor,
                     bool bordered = false, NSColor *borderColor = nil);

NSTextField *OpnTextField(NSRect frame, NSString *placeholder, bool isSecure = false);

NSProgressIndicator *OpnSpinner(NSRect frame);

void OpnDisableFocusHighlights(NSView *view);
CGPathRef OpnCreateRoundedRectPath(NSRect rect, CGFloat xRadius, CGFloat yRadius) CF_RETURNS_RETAINED;
CGPathRef OpnCreateEllipsePath(NSRect rect) CF_RETURNS_RETAINED;

typedef void (^OpnImageLoadCompletion)(NSImage *image, NSString *resolvedURL, NSData *data);

@interface OPNHeroArtworkView : NSView
@property (nonatomic, strong) NSImage *image;
@end

@interface OpnImageLoadToken : NSObject
@property (nonatomic, assign, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

void OpnLoadImageForURL(NSString *urlString, CGFloat maxPixelDimension, OpnImageLoadCompletion completion);
void OpnLoadImageFromCandidates(NSArray<NSString *> *candidates,
                                 CGFloat maxPixelDimension,
                                 OpnImageLoadCompletion completion);
NSImage *OpnCachedImageForURL(NSString *urlString, CGFloat maxPixelDimension);
NSImage *OpnCachedImageFromCandidates(NSArray<NSString *> *candidates, CGFloat maxPixelDimension, NSString **resolvedURL);
OpnImageLoadToken *OpnLoadImageForURLCancellable(NSString *urlString,
                                                 CGFloat maxPixelDimension,
                                                 OpnImageLoadCompletion completion);
OpnImageLoadToken *OpnLoadImageFromCandidatesCancellable(NSArray<NSString *> *candidates,
                                                          CGFloat maxPixelDimension,
                                                          OpnImageLoadCompletion completion);

NSString *OpnGameIdentityForHero(const OPN::GameInfo &game);
NSArray<NSString *> *OpnHeroImageCandidatesForGame(const OPN::GameInfo &game);
NSImage *OpnFallbackHeroArtworkImage(void);
