#include "OPNStreamTypes.h"
#include "common/OPNSessionHealthReport.h"
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface OPNStreamViewController : NSViewController

- (instancetype)initWithGameTitle:(const std::string &)title
                             appId:(const std::string &)appId
                          apiToken:(const std::string &)token
                     accountLinked:(bool)accountLinked
                      selectedStore:(const std::string &)selectedStore;

- (instancetype)initWithGameTitle:(const std::string &)title
                             appId:(const std::string &)appId
                          apiToken:(const std::string &)token
                     accountLinked:(bool)accountLinked
                     selectedStore:(const std::string &)selectedStore
                   resumeSessionId:(const std::string &)resumeSessionId
                       resumeServer:(const std::string &)resumeServer;

- (void)setInitialViewFrame:(NSRect)frame;
- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited;
- (void)startStreamIfNeeded;
- (void)setStreamInputSuppressed:(BOOL)suppressed;

@property(nonatomic, copy) void (^onStreamEnd)
    (BOOL success, const std::string &errorMessage, const OPN::SessionHealthReport &report);
@property(nonatomic, copy) void (^onDashboardToggleRequested)(void);

- (void)requestQuitGameConfirmation;
- (void)shutdownForApplicationTermination;

@end

NS_ASSUME_NONNULL_END
