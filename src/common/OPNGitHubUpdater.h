#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface OPNGitHubRelease : NSObject
@property (nonatomic, copy, readonly) NSString *version;
@property (nonatomic, copy, readonly) NSString *tagName;
@property (nonatomic, copy, readonly) NSString *releaseNotes;
@property (nonatomic, copy, readonly) NSString *releaseURL;
@property (nonatomic, copy, readonly) NSString *assetName;
@property (nonatomic, copy, readonly) NSString *assetDownloadURL;
- (instancetype)initWithVersion:(NSString *)version
                        tagName:(NSString *)tagName
                   releaseNotes:(NSString *)releaseNotes
                     releaseURL:(NSString *)releaseURL
                      assetName:(NSString *)assetName
                assetDownloadURL:(NSString *)assetDownloadURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef void (^OPNGitHubUpdateCheckCompletion)(OPNGitHubRelease *_Nullable release, NSError *_Nullable error);
typedef void (^OPNGitHubUpdateInstallCompletion)(BOOL launchedInstaller, NSError *_Nullable error);

@interface OPNGitHubUpdater : NSObject
@property (nonatomic, copy, readonly) NSString *currentVersion;
- (instancetype)initWithOwner:(NSString *)owner repository:(NSString *)repository NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)checkForUpdateWithCompletion:(OPNGitHubUpdateCheckCompletion)completion;
- (void)installRelease:(OPNGitHubRelease *)release completion:(OPNGitHubUpdateInstallCompletion)completion;
@end

NS_ASSUME_NONNULL_END
