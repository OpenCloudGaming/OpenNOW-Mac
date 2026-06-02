#import <Cocoa/Cocoa.h>
#include <functional>
#include <vector>
#include "../common/OPNGameTypes.h"

@interface OPNStoreView : NSView

@property (nonatomic, copy) void (^onSelectGame)(const OPN::GameInfo &game, int variantIndex);
@property (nonatomic, copy) void (^onBuyGame)(const OPN::GameInfo &game, int variantIndex, NSString *purchaseURL);
@property (nonatomic, copy) void (^onBackRequested)(void);
@property (nonatomic, copy) void (^onPreviousPageRequested)(void);
@property (nonatomic, copy) void (^onNextPageRequested)(void);
@property (nonatomic, assign) BOOL controllerInputSuspended;
@property (nonatomic, readonly) BOOL hasContent;

- (instancetype)initWithFrame:(NSRect)frame;
- (void)setLoading:(BOOL)loading;
- (void)setError:(NSString *)message;
- (void)setLibraryGames:(const std::vector<OPN::GameInfo> &)games;
- (void)setFeaturedGames:(const std::vector<OPN::GameInfo> &)games;
- (void)setPanels:(const std::vector<OPN::PanelResult> &)panels;

@end
