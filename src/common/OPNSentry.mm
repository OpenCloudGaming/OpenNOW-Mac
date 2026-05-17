#include "OPNSentry.h"

#import <Foundation/Foundation.h>
#include <cstdlib>
#include <string>

#if defined(OPN_HAVE_SENTRY) && OPN_HAVE_SENTRY
#include <sentry.h>
#define OPN_SENTRY_ENABLED 1
#else
#define OPN_SENTRY_ENABLED 0
#endif

namespace OPN {

#if OPN_SENTRY_ENABLED
namespace {

static constexpr const char *OPNDefaultSentryDsn = "https://47a6752be389eabd7ed3b088ca89c0b3@o4509317113184256.ingest.us.sentry.io/4511406320320512";
static constexpr const char *OPNSentryLoggerName = "opennow";
static bool OPNSentryInitialized = false;

static NSString *OPNInfoString(NSString *key, NSString *fallback) {
    id value = NSBundle.mainBundle.infoDictionary[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return fallback;
}

static std::string OPNUtf8String(NSString *value) {
    if (value.length == 0) return std::string();
    const char *utf8 = value.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

static std::string OPNSentryReleaseName() {
    NSString *name = OPNInfoString(@"CFBundleName", @"OpenNOW");
    NSString *version = OPNInfoString(@"CFBundleShortVersionString", @"0.0.0");
    NSString *build = OPNInfoString(@"CFBundleVersion", nil);
    NSString *release = build.length > 0
        ? [NSString stringWithFormat:@"%@@%@+%@", name, version, build]
        : [NSString stringWithFormat:@"%@@%@", name, version];
    return OPNUtf8String(release);
}

static NSString *OPNSentryDatabasePath() {
    NSError *error = nil;
    NSURL *cacheURL = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory
                                                           inDomain:NSUserDomainMask
                                                  appropriateForURL:nil
                                                             create:YES
                                                              error:&error];
    if (!cacheURL) {
        NSLog(@"[Sentry] Unable to resolve cache directory: %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"io.github.opencloudgaming.opennow";
    NSURL *databaseURL = [[cacheURL URLByAppendingPathComponent:bundleIdentifier isDirectory:YES]
        URLByAppendingPathComponent:@"Sentry" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:databaseURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&error]) {
        NSLog(@"[Sentry] Unable to create database directory: %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }
    return databaseURL.path;
}

static NSString *OPNSentryInstallPrefix() {
#ifdef OPN_SENTRY_INSTALL_PREFIX
    return [NSString stringWithUTF8String:OPN_SENTRY_INSTALL_PREFIX];
#else
    return nil;
#endif
}

static NSString *OPNSentryExecutableDirectory() {
    NSString *path = NSBundle.mainBundle.executableURL.path;
    return path.length > 0 ? path.stringByDeletingLastPathComponent : nil;
}

static NSString *OPNSentryHandlerPath() {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *executableDirectory = OPNSentryExecutableDirectory();
    if (executableDirectory.length > 0) {
        [candidates addObject:[executableDirectory stringByAppendingPathComponent:@"crashpad_handler"]];
    }
    NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
    if (frameworksPath.length > 0) {
        [candidates addObject:[frameworksPath stringByAppendingPathComponent:@"crashpad_handler"]];
    }
    NSString *installPrefix = OPNSentryInstallPrefix();
    if (installPrefix.length > 0) {
        [candidates addObject:[[installPrefix stringByAppendingPathComponent:@"bin"] stringByAppendingPathComponent:@"crashpad_handler"]];
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *path in candidates) {
        BOOL isDirectory = NO;
        if ([fileManager fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory && [fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static bool OPNSentryEnvironmentFlagEnabled(const char *name) {
    const char *value = std::getenv(name);
    return value && value[0] == '1' && value[1] == '\0';
}

static void OPNCaptureSentryVerificationMessageIfRequested() {
    if (!OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_VERIFY")) return;
    sentry_capture_event(sentry_value_new_message_event(SENTRY_LEVEL_INFO, OPNSentryLoggerName, "It works!"));
}

}
#endif

void InitializeSentry() {
#if OPN_SENTRY_ENABLED
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sentry_options_t *options = sentry_options_new();
        if (!options) {
            NSLog(@"[Sentry] Unable to allocate Sentry options");
            return;
        }

        const char *configuredDsn = sentry_options_get_dsn(options);
        if (!configuredDsn || configuredDsn[0] == '\0') {
            sentry_options_set_dsn(options, OPNDefaultSentryDsn);
        }

        NSString *databasePath = OPNSentryDatabasePath();
        if (databasePath.length > 0) {
            sentry_options_set_database_path(options, databasePath.fileSystemRepresentation);
        }

        NSString *handlerPath = OPNSentryHandlerPath();
        if (handlerPath.length > 0) {
            sentry_options_set_handler_path(options, handlerPath.fileSystemRepresentation);
        }

        std::string releaseName = OPNSentryReleaseName();
        if (!releaseName.empty()) {
            sentry_options_set_release(options, releaseName.c_str());
        }

        int initResult = sentry_init(options);
        if (initResult != 0) {
            NSLog(@"[Sentry] sentry_init failed with code %d", initResult);
            return;
        }
        OPNSentryInitialized = true;
        OPNCaptureSentryVerificationMessageIfRequested();
    });
#endif
}

void CloseSentry() {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized) return;
    OPNSentryInitialized = false;
    int closeResult = sentry_close();
    if (closeResult != 0) {
        NSLog(@"[Sentry] sentry_close dumped %d envelope(s)", closeResult);
    }
#endif
}

}
