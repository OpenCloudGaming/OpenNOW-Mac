#import <Cocoa/Cocoa.h>
#import <Cocoa/Cocoa.h>

@class OPNSessionReportPayload;

NS_ASSUME_NONNULL_BEGIN

@interface OPNStreamViewController : NSViewController

- (instancetype)initWithGameTitle:(NSString *)title
                             appId:(NSString *)appId
                          apiToken:(NSString *)token
                     accountLinked:(BOOL)accountLinked
                      selectedStore:(NSString *)selectedStore;

- (instancetype)initWithGameTitle:(NSString *)title
                             appId:(NSString *)appId
                          apiToken:(NSString *)token
                     accountLinked:(BOOL)accountLinked
                     selectedStore:(NSString *)selectedStore
                   resumeSessionId:(NSString *)resumeSessionId
                       resumeServer:(NSString *)resumeServer;

- (void)setInitialViewFrame:(NSRect)frame;
- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited;
- (void)startStreamIfNeeded;
- (void)setStreamInputSuppressed:(BOOL)suppressed;

@property(nonatomic, copy) void (^onStreamEnd)
    (BOOL success, NSString *errorMessage, OPNSessionReportPayload *report);
@property(nonatomic, copy) void (^onDashboardToggleRequested)(void);

- (void)requestQuitGameConfirmation;
- (void)shutdownForApplicationTermination;

@end

NS_ASSUME_NONNULL_END
