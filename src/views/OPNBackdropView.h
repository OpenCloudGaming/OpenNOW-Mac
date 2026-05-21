#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, OPNBackdropMode) {
    OPNBackdropModeAuth = 0,
    OPNBackdropModeHome = 1,
    OPNBackdropModeStore = 2,
    OPNBackdropModeLibrary = 3,
    OPNBackdropModeSettings = 4,
};

@interface OPNBackdropView : NSView

@property (nonatomic, assign) OPNBackdropMode mode;
@property (nonatomic, copy) NSString *accountName;
@property (nonatomic, copy) NSString *accountStatus;
@property (nonatomic, strong) NSImage *accountAvatarImage;
@property (nonatomic, copy) NSString *remainingPlayTime;
@property (nonatomic, copy) NSString *gameCountText;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *accountMenuItems;
@property (nonatomic, copy) NSString *currentAccountIdentifier;
@property (nonatomic, copy) void (^onHomeSelected)(void);
@property (nonatomic, copy) void (^onStoreSelected)(void);
@property (nonatomic, copy) void (^onLibrarySelected)(void);
@property (nonatomic, copy) void (^onSearchSelected)(void);
@property (nonatomic, copy) void (^onSettingsSelected)(void);
@property (nonatomic, copy) void (^onAccountSelected)(NSString *accountIdentifier);
@property (nonatomic, copy) void (^onAddAccountSelected)(void);
@property (nonatomic, copy) void (^onSignOutSelected)(void);
@property (nonatomic, copy) void (^onExitSelected)(void);

@end
