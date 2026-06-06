#import <Cocoa/Cocoa.h>
#include "common/OPNSessionHealthReport.h"

NS_ASSUME_NONNULL_BEGIN

@interface OPNSessionReportView : NSView
@property (nonatomic, copy) void (^onDone)(void);
- (instancetype)initWithFrame:(NSRect)frame report:(const OPN::SessionHealthReport &)report;
@end

NS_ASSUME_NONNULL_END
