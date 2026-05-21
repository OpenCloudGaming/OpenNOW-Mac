#import <Cocoa/Cocoa.h>

@interface OPNSettingsView : NSView

@property (nonatomic, copy) void (^onBackRequested)(void);
@property (nonatomic, copy) void (^onPreviousPageRequested)(void);
@property (nonatomic, copy) void (^onNextPageRequested)(void);

- (instancetype)initWithFrame:(NSRect)frame;
- (instancetype)initWithFrame:(NSRect)frame selectedSectionName:(NSString *)selectedSectionName;

@end
