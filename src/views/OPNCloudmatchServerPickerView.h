#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface OPNCloudmatchServerOption : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *url;
@property (nonatomic, assign, readonly) NSInteger latencyMs;
@property (nonatomic, assign, readonly, getter=isAutomatic) BOOL automatic;
@property (nonatomic, copy, readonly) NSString *latencyText;
@property (nonatomic, copy, readonly) NSString *detailText;

- (instancetype)initWithName:(NSString *)name
                         url:(NSString *)url
                   latencyMs:(NSInteger)latencyMs
                    automatic:(BOOL)automatic NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface OPNCloudmatchServerPickerView : NSView

@property (nonatomic, copy, nullable) void (^onConfirm)(OPNCloudmatchServerOption *option);
@property (nonatomic, copy, nullable) void (^onCancel)(void);
@property (nonatomic, copy, nullable) void (^onRefresh)(void);

- (instancetype)initWithFrame:(NSRect)frame gameTitle:(NSString *)gameTitle NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frame NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)setOptions:(NSArray<OPNCloudmatchServerOption *> *)options
 selectedRegionUrl:(NSString *)selectedRegionUrl
        refreshing:(BOOL)refreshing;
- (void)setRefreshing:(BOOL)refreshing;
- (void)setStatusMessage:(NSString *)statusMessage isError:(BOOL)isError;

@end

NS_ASSUME_NONNULL_END
