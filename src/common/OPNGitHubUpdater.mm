#import "OPNGitHubUpdater.h"
#include "OPNSentry.h"

static NSString *const OPNGitHubUpdaterErrorDomain = @"OpenNOW.GitHubUpdater";

typedef NS_ENUM(NSInteger, OPNGitHubUpdaterErrorCode) {
    OPNGitHubUpdaterErrorInvalidResponse = 1,
    OPNGitHubUpdaterErrorNoReleaseAsset = 2,
    OPNGitHubUpdaterErrorNotBundledApp = 3,
    OPNGitHubUpdaterErrorDownloadFailed = 4,
    OPNGitHubUpdaterErrorExtractionFailed = 5,
    OPNGitHubUpdaterErrorValidationFailed = 6,
    OPNGitHubUpdaterErrorInstallerLaunchFailed = 7,
};

@implementation OPNGitHubRelease

- (instancetype)initWithVersion:(NSString *)version
                        tagName:(NSString *)tagName
                   releaseNotes:(NSString *)releaseNotes
                     releaseURL:(NSString *)releaseURL
                      assetName:(NSString *)assetName
                assetDownloadURL:(NSString *)assetDownloadURL {
    self = [super init];
    if (self) {
        _version = [version copy];
        _tagName = [tagName copy];
        _releaseNotes = [releaseNotes copy];
        _releaseURL = [releaseURL copy];
        _assetName = [assetName copy];
        _assetDownloadURL = [assetDownloadURL copy];
    }
    return self;
}

@end

@interface OPNGitHubUpdater ()
@property (nonatomic, copy) NSString *owner;
@property (nonatomic, copy) NSString *repository;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation OPNGitHubUpdater

- (instancetype)initWithOwner:(NSString *)owner repository:(NSString *)repository {
    self = [super init];
    if (self) {
        _owner = [owner copy];
        _repository = [repository copy];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 600.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (NSString *)currentVersion {
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    return version.length > 0 ? version : @"0.0.0";
}

- (void)checkForUpdateWithCompletion:(OPNGitHubUpdateCheckCompletion)completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest", self.owner, self.repository]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"OpenNOW-Updater" forHTTPHeaderField:@"User-Agent"];
    auto trace = OPN::TraceSentryHTTPRequest(request, "GitHub update check");

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        OPN::SentryTransactionFinishGuard traceGuard(trace);
        if (error) {
            [self completeUpdateCheck:completion release:nil error:error];
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (!http || http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
            [self completeUpdateCheck:completion release:nil error:[self errorWithCode:OPNGitHubUpdaterErrorInvalidResponse description:@"GitHub did not return a valid release response."]];
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:NSDictionary.class]) {
            [self completeUpdateCheck:completion release:nil error:jsonError ?: [self errorWithCode:OPNGitHubUpdaterErrorInvalidResponse description:@"GitHub release metadata was not valid JSON."]];
            return;
        }

        OPNGitHubRelease *release = [self releaseFromJSON:(NSDictionary *)json error:&jsonError];
        if (!release) {
            [self completeUpdateCheck:completion release:nil error:jsonError];
            return;
        }
        if ([self compareVersion:release.version toVersion:self.currentVersion] <= 0) {
            traceGuard.SetSuccess(true);
            [self completeUpdateCheck:completion release:nil error:nil];
            return;
        }
        traceGuard.SetSuccess(true);
        [self completeUpdateCheck:completion release:release error:nil];
    }];
    [task resume];
}

- (void)installRelease:(OPNGitHubRelease *)release completion:(OPNGitHubUpdateInstallCompletion)completion {
    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    if (![bundleURL.pathExtension.lowercaseString isEqualToString:@"app"]) {
        [self completeInstall:completion launched:NO error:[self errorWithCode:OPNGitHubUpdaterErrorNotBundledApp description:@"Updates can only be installed from the packaged OpenNOW.app bundle."]];
        return;
    }

    NSURL *downloadURL = [NSURL URLWithString:release.assetDownloadURL];
    if (!downloadURL) {
        [self completeInstall:completion launched:NO error:[self errorWithCode:OPNGitHubUpdaterErrorInvalidResponse description:@"The release asset download URL is invalid."]];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:downloadURL];
    auto trace = OPN::TraceSentryHTTPRequest(request, "GitHub update download");
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        OPN::SentryTransactionFinishGuard traceGuard(trace);
        if (error || !location) {
            [self completeInstall:completion launched:NO error:error ?: [self errorWithCode:OPNGitHubUpdaterErrorDownloadFailed description:@"The update archive could not be downloaded."]];
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (!http || http.statusCode < 200 || http.statusCode >= 300) {
            [self completeInstall:completion launched:NO error:[self errorWithCode:OPNGitHubUpdaterErrorDownloadFailed description:@"GitHub did not return the update archive."]];
            return;
        }
        traceGuard.SetSuccess(true);
        [self stageAndLaunchInstallerForDownloadedArchive:location release:release currentBundleURL:bundleURL completion:completion];
    }];
    [task resume];
}

- (void)stageAndLaunchInstallerForDownloadedArchive:(NSURL *)archiveURL
                                            release:(OPNGitHubRelease *)release
                                   currentBundleURL:(NSURL *)currentBundleURL
                                         completion:(OPNGitHubUpdateInstallCompletion)completion {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *stagingURL = [[fileManager temporaryDirectory] URLByAppendingPathComponent:[[NSUUID UUID] UUIDString] isDirectory:YES];
    NSURL *archiveCopyURL = [stagingURL URLByAppendingPathComponent:release.assetName isDirectory:NO];
    NSURL *extractURL = [stagingURL URLByAppendingPathComponent:@"extracted" isDirectory:YES];
    NSError *fileError = nil;
    if (![fileManager createDirectoryAtURL:extractURL withIntermediateDirectories:YES attributes:nil error:&fileError] ||
        ![fileManager copyItemAtURL:archiveURL toURL:archiveCopyURL error:&fileError]) {
        [self completeInstall:completion launched:NO error:fileError];
        return;
    }

    NSTask *extractTask = [[NSTask alloc] init];
    extractTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
    extractTask.arguments = @[@"-x", @"-k", archiveCopyURL.path, extractURL.path];
    NSError *extractError = nil;
    if (![extractTask launchAndReturnError:&extractError]) {
        [self completeInstall:completion launched:NO error:extractError];
        return;
    }
    [extractTask waitUntilExit];
    if (extractTask.terminationStatus != 0) {
        [self completeInstall:completion launched:NO error:[self errorWithCode:OPNGitHubUpdaterErrorExtractionFailed description:@"The update archive could not be extracted."]];
        return;
    }

    NSURL *newBundleURL = [self findAppBundleInDirectory:extractURL];
    NSError *validationError = nil;
    if (![self validateCandidateBundle:newBundleURL expectedVersion:release.version currentBundleURL:currentBundleURL error:&validationError]) {
        [self completeInstall:completion launched:NO error:validationError];
        return;
    }

    NSURL *scriptURL = [stagingURL URLByAppendingPathComponent:@"install-opennow-update.sh" isDirectory:NO];
    NSString *backupPath = [[currentBundleURL.path stringByDeletingLastPathComponent] stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.previous", currentBundleURL.lastPathComponent]];
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/sh\n"
         "set -eu\n"
         "parent_pid='%d'\n"
         "target=%@\n"
         "source=%@\n"
         "backup=%@\n"
         "staging=%@\n"
         "while kill -0 \"$parent_pid\" >/dev/null 2>&1; do sleep 0.2; done\n"
         "rm -rf \"$backup\"\n"
         "if [ -d \"$target\" ]; then mv \"$target\" \"$backup\"; fi\n"
         "if mv \"$source\" \"$target\"; then\n"
         "  /usr/bin/xattr -dr com.apple.quarantine \"$target\" >/dev/null 2>&1 || true\n"
         "  /usr/bin/open \"$target\"\n"
         "  rm -rf \"$backup\" \"$staging\"\n"
         "else\n"
         "  if [ -d \"$backup\" ] && [ ! -d \"$target\" ]; then mv \"$backup\" \"$target\"; fi\n"
         "  /usr/bin/open \"$target\" >/dev/null 2>&1 || true\n"
         "  exit 1\n"
         "fi\n",
        getpid(), [self shellQuotedString:currentBundleURL.path], [self shellQuotedString:newBundleURL.path], [self shellQuotedString:backupPath], [self shellQuotedString:stagingURL.path]];
    if (![script writeToURL:scriptURL atomically:YES encoding:NSUTF8StringEncoding error:&fileError] ||
        ![fileManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:scriptURL.path error:&fileError]) {
        [self completeInstall:completion launched:NO error:fileError];
        return;
    }

    NSTask *installerTask = [[NSTask alloc] init];
    installerTask.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    installerTask.arguments = @[scriptURL.path];
    NSError *launchError = nil;
    BOOL launched = [installerTask launchAndReturnError:&launchError];
    [self completeInstall:completion launched:launched error:launched ? nil : (launchError ?: [self errorWithCode:OPNGitHubUpdaterErrorInstallerLaunchFailed description:@"The update installer could not be launched."] )];
}

- (OPNGitHubRelease *)releaseFromJSON:(NSDictionary *)json error:(NSError **)error {
    NSString *tagName = [json[@"tag_name"] isKindOfClass:NSString.class] ? json[@"tag_name"] : @"";
    NSString *version = [self normalizedVersion:tagName];
    NSString *releaseNotes = [json[@"body"] isKindOfClass:NSString.class] ? json[@"body"] : @"";
    NSString *releaseURL = [json[@"html_url"] isKindOfClass:NSString.class] ? json[@"html_url"] : @"";
    NSArray *assets = [json[@"assets"] isKindOfClass:NSArray.class] ? json[@"assets"] : @[];
    NSDictionary *selectedAsset = nil;
    for (id asset in assets) {
        if (![asset isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"";
        if ([name hasPrefix:@"OpenNOW-"] && [name hasSuffix:@"-macOS.zip"]) {
            selectedAsset = asset;
            break;
        }
    }
    if (!selectedAsset) {
        for (id asset in assets) {
            if (![asset isKindOfClass:NSDictionary.class]) continue;
            NSString *name = [asset[@"name"] isKindOfClass:NSString.class] ? asset[@"name"] : @"";
            if ([name.lowercaseString hasSuffix:@".zip"] && [name.lowercaseString containsString:@"macos"]) {
                selectedAsset = asset;
                break;
            }
        }
    }
    NSString *assetName = [selectedAsset[@"name"] isKindOfClass:NSString.class] ? selectedAsset[@"name"] : @"";
    NSString *assetURL = [selectedAsset[@"browser_download_url"] isKindOfClass:NSString.class] ? selectedAsset[@"browser_download_url"] : @"";
    if (version.length == 0 || assetURL.length == 0) {
        if (error) *error = [self errorWithCode:OPNGitHubUpdaterErrorNoReleaseAsset description:@"The latest GitHub release does not include an OpenNOW macOS zip asset."];
        return nil;
    }
    return [[OPNGitHubRelease alloc] initWithVersion:version tagName:tagName releaseNotes:releaseNotes releaseURL:releaseURL assetName:assetName assetDownloadURL:assetURL];
}

- (NSURL *)findAppBundleInDirectory:(NSURL *)directoryURL {
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager enumeratorAtURL:directoryURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in enumerator) {
        if ([url.pathExtension.lowercaseString isEqualToString:@"app"]) return url;
    }
    return nil;
}

- (BOOL)validateCandidateBundle:(NSURL *)candidateURL expectedVersion:(NSString *)expectedVersion currentBundleURL:(NSURL *)currentBundleURL error:(NSError **)error {
    if (!candidateURL) {
        if (error) *error = [self errorWithCode:OPNGitHubUpdaterErrorValidationFailed description:@"The update archive did not contain an app bundle."];
        return NO;
    }
    NSBundle *candidateBundle = [NSBundle bundleWithURL:candidateURL];
    NSString *candidateIdentifier = candidateBundle.bundleIdentifier;
    NSString *currentIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *candidateVersion = candidateBundle.infoDictionary[@"CFBundleShortVersionString"];
    NSString *candidateExecutable = candidateBundle.infoDictionary[@"CFBundleExecutable"];
    NSString *executablePath = candidateExecutable.length > 0 ? [[candidateURL URLByAppendingPathComponent:@"Contents/MacOS" isDirectory:YES] URLByAppendingPathComponent:candidateExecutable].path : nil;
    BOOL executableExists = executablePath.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:executablePath];
    if (![candidateIdentifier isEqualToString:currentIdentifier] || !executableExists || [self compareVersion:candidateVersion toVersion:expectedVersion] != 0 || [self compareVersion:candidateVersion toVersion:self.currentVersion] <= 0) {
        if (error) *error = [self errorWithCode:OPNGitHubUpdaterErrorValidationFailed description:@"The downloaded app bundle did not match OpenNOW or did not contain the expected newer version."];
        return NO;
    }
    if (![self verifyCodeSignatureForBundle:candidateURL]) {
        if (error) *error = [self errorWithCode:OPNGitHubUpdaterErrorValidationFailed description:@"The downloaded app bundle did not pass macOS code-signature verification."];
        return NO;
    }
    NSString *currentParent = currentBundleURL.URLByDeletingLastPathComponent.path;
    if (currentParent.length == 0 || ![NSFileManager.defaultManager isWritableFileAtPath:currentParent]) {
        if (error) *error = [self errorWithCode:OPNGitHubUpdaterErrorValidationFailed description:@"OpenNOW does not have permission to replace the current app bundle. Move it to a writable folder and try again."];
        return NO;
    }
    return YES;
}

- (BOOL)verifyCodeSignatureForBundle:(NSURL *)bundleURL {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/codesign"];
    task.arguments = @[@"--verify", @"--deep", @"--strict", bundleURL.path];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

- (NSString *)normalizedVersion:(NSString *)version {
    NSString *trimmed = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed.lowercaseString hasPrefix:@"v"]) return [trimmed substringFromIndex:1];
    return trimmed;
}

- (NSInteger)compareVersion:(NSString *)left toVersion:(NSString *)right {
    NSArray<NSString *> *leftParts = [[self normalizedVersion:left] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".-_"]];
    NSArray<NSString *> *rightParts = [[self normalizedVersion:right] componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@".-_"]];
    NSUInteger count = MAX(leftParts.count, rightParts.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSString *leftPart = i < leftParts.count ? leftParts[i] : @"0";
        NSString *rightPart = i < rightParts.count ? rightParts[i] : @"0";
        NSScanner *leftScanner = [NSScanner scannerWithString:leftPart];
        NSScanner *rightScanner = [NSScanner scannerWithString:rightPart];
        long long leftNumber = 0;
        long long rightNumber = 0;
        BOOL leftNumeric = [leftScanner scanLongLong:&leftNumber] && leftScanner.isAtEnd;
        BOOL rightNumeric = [rightScanner scanLongLong:&rightNumber] && rightScanner.isAtEnd;
        if (leftNumeric && rightNumeric) {
            if (leftNumber < rightNumber) return -1;
            if (leftNumber > rightNumber) return 1;
        } else {
            NSComparisonResult result = [leftPart compare:rightPart options:NSCaseInsensitiveSearch | NSNumericSearch];
            if (result == NSOrderedAscending) return -1;
            if (result == NSOrderedDescending) return 1;
        }
    }
    return 0;
}

- (NSString *)shellQuotedString:(NSString *)value {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSError *)errorWithCode:(OPNGitHubUpdaterErrorCode)code description:(NSString *)description {
    return [NSError errorWithDomain:OPNGitHubUpdaterErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

- (void)completeUpdateCheck:(OPNGitHubUpdateCheckCompletion)completion release:(OPNGitHubRelease *)release error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(release, error);
    });
}

- (void)completeInstall:(OPNGitHubUpdateInstallCompletion)completion launched:(BOOL)launched error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(launched, error);
    });
}

@end
