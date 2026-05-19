#include "OPNSentry.h"

#import <Foundation/Foundation.h>
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <string>

#if defined(OPN_HAVE_SENTRY) && OPN_HAVE_SENTRY
#include <sentry.h>
#define OPN_SENTRY_ENABLED 1
#else
#define OPN_SENTRY_ENABLED 0
#endif

namespace OPN {

namespace {

static bool OPNEnvironmentFlagEnabled(const char *name) {
    const char *value = std::getenv(name);
    return value && value[0] == '1' && value[1] == '\0';
}

static NSString *OPNFormattedLogMessage(NSString *format, va_list arguments) {
    if (format.length == 0) return @"";
    return [[NSString alloc] initWithFormat:format arguments:arguments] ?: @"";
}

static const char *OPNLogMessageUtf8(NSString *message) {
    const char *utf8 = message.UTF8String;
    return utf8 ? utf8 : "";
}

}

#if OPN_SENTRY_ENABLED
namespace {

static constexpr const char *OPNDefaultSentryDsn = "https://26e9dba9cb293d4ca2afceb73dd13b74@o4509317113184256.ingest.us.sentry.io/4511406450868224";
static constexpr const char *OPNSentryLoggerName = "opennow";
static constexpr unsigned int OPNMaxStructuredInfoLogsPerRun = 128;
static bool OPNSentryInitialized = false;
static std::atomic<unsigned int> OPNSentryStructuredInfoLogCount{0};
static std::atomic<bool> OPNSentryStructuredInfoLogsDisabled{false};

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

static NSString *OPNSentryStringByReplacingMatches(NSString *message, NSString *pattern, NSString *replacement) {
    if (message.length == 0) return @"";

    NSError *error = nil;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                  error:&error];
    if (!expression) return message;

    NSRange fullRange = NSMakeRange(0, message.length);
    return [expression stringByReplacingMatchesInString:message
                                                options:0
                                                  range:fullRange
                                           withTemplate:replacement];
}

static NSString *OPNSanitizedSentryMessage(NSString *message) {
    if (message.length == 0) return @"";

    NSString *sanitized = message;
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b", @"[redacted-email]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"\\b(?:\\+?\\d[\\d .()\\-]{7,}\\d)\\b", @"[redacted-phone]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", @"[redacted-ip]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"\\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\\b", @"[redacted-id]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"\\b[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b", @"[redacted-token]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"(?i)(bearer|basic)\\s+[^\\s,;]+", @"$1 [redacted-token]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"(?i)((?:access|refresh|id)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id)([=:]\\s*|\\\"\\s*:\\s*\\\")[^\\s,;\\}\"]+", @"$1$2[redacted-secret]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"/Users/[^/\\s]+", @"/Users/[redacted-user]");
    return sanitized;
}

static NSString *OPNSentryDatabasePath() {
    NSError *error = nil;
    NSURL *cacheURL = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory
                                                           inDomain:NSUserDomainMask
                                                  appropriateForURL:nil
                                                             create:YES
                                                              error:&error];
    if (!cacheURL) {
        OPN::LogError(@"[Sentry] Unable to resolve cache directory: %@", error.localizedDescription ?: @"unknown error");
        return nil;
    }

    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"io.github.opencloudgaming.opennow";
    NSURL *databaseURL = [[cacheURL URLByAppendingPathComponent:bundleIdentifier isDirectory:YES]
        URLByAppendingPathComponent:@"Sentry" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:databaseURL
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&error]) {
        OPN::LogError(@"[Sentry] Unable to create database directory: %@", error.localizedDescription ?: @"unknown error");
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
    return OPNEnvironmentFlagEnabled(name);
}

static bool OPNShouldInitializeSentry() {
    return !OPNSentryEnvironmentFlagEnabled("OPN_DISABLE_SENTRY");
}

static bool OPNUploadInfoLogsAsEvents() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_INFO_EVENTS");
}

static bool OPNUploadStructuredInfoLogs() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_INFO_LOGS");
}

static bool OPNFlushErrorsImmediately() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_FLUSH_ERRORS");
}

static bool OPNShouldSendStructuredInfoLog() {
    if (!OPNUploadStructuredInfoLogs()) return false;
    if (OPNSentryStructuredInfoLogsDisabled.load()) return false;
    unsigned int previousCount = OPNSentryStructuredInfoLogCount.fetch_add(1);
    if (previousCount < OPNMaxStructuredInfoLogsPerRun) return true;
    if (previousCount == OPNMaxStructuredInfoLogsPerRun) {
        std::fprintf(stderr, "[Sentry] structured info log limit reached; local logging continues\n");
    }
    return false;
}

static const char *OPNSentryLogReturnName(log_return_value_t value) {
    switch (value) {
        case SENTRY_LOG_RETURN_SUCCESS: return "success";
        case SENTRY_LOG_RETURN_DISCARD: return "discard";
        case SENTRY_LOG_RETURN_FAILED: return "failed";
        case SENTRY_LOG_RETURN_DISABLED: return "disabled";
    }
    return "unknown";
}

static void OPNCaptureSentryMessage(sentry_level_t level, const char *message) {
    sentry_capture_event(sentry_value_new_message_event(level, OPNSentryLoggerName, message));
}

static void OPNCaptureSentryVerificationMessageIfRequested() {
    if (!OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_VERIFY")) return;
    sentry_capture_event(sentry_value_new_message_event(SENTRY_LEVEL_INFO, OPNSentryLoggerName, "It works!"));
}

}
#endif

bool ShouldLogInfo() {
#if defined(NDEBUG)
    return OPNEnvironmentFlagEnabled("OPN_INFO_LOGS") || OPNEnvironmentFlagEnabled("OPN_DEBUG_LOGS");
#else
    return !OPNEnvironmentFlagEnabled("OPN_DISABLE_INFO_LOGS");
#endif
}

void LogInfo(NSString *format, ...) {
    if (!ShouldLogInfo()) return;

    va_list arguments;
    va_start(arguments, format);
    NSString *message = OPNFormattedLogMessage(format, arguments);
    va_end(arguments);
    const char *utf8Message = OPNLogMessageUtf8(message);

    std::fprintf(stderr, "%s\n", utf8Message);

#if OPN_SENTRY_ENABLED
    if (OPNSentryInitialized) {
        NSString *sentryMessage = OPNSanitizedSentryMessage(message);
        const char *sentryUtf8Message = OPNLogMessageUtf8(sentryMessage);
        if (OPNShouldSendStructuredInfoLog()) {
            log_return_value_t result = sentry_log_info("%s", sentryUtf8Message);
            if (result != SENTRY_LOG_RETURN_SUCCESS) {
                OPNSentryStructuredInfoLogsDisabled.store(true);
                std::fprintf(stderr, "[Sentry] sentry_log_info returned %s; local logging continues\n", OPNSentryLogReturnName(result));
            }
        }
        if (OPNUploadInfoLogsAsEvents()) {
            OPNCaptureSentryMessage(SENTRY_LEVEL_INFO, sentryUtf8Message);
        }
    }
#endif
}

void LogError(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = OPNFormattedLogMessage(format, arguments);
    va_end(arguments);
    const char *utf8Message = OPNLogMessageUtf8(message);

    std::fprintf(stderr, "%s\n", utf8Message);

#if OPN_SENTRY_ENABLED
    if (OPNSentryInitialized) {
        NSString *sentryMessage = OPNSanitizedSentryMessage(message);
        const char *sentryUtf8Message = OPNLogMessageUtf8(sentryMessage);
        log_return_value_t result = sentry_log_error("%s", sentryUtf8Message);
        if (result != SENTRY_LOG_RETURN_SUCCESS) {
            std::fprintf(stderr, "[Sentry] sentry_log_error returned %s\n", OPNSentryLogReturnName(result));
        }
        OPNCaptureSentryMessage(SENTRY_LEVEL_ERROR, sentryUtf8Message);
        if (OPNFlushErrorsImmediately()) {
            sentry_flush(2000);
        }
    }
#endif
}

void InitializeSentry() {
#if OPN_SENTRY_ENABLED
    if (!OPNShouldInitializeSentry()) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sentry_options_t *options = sentry_options_new();
        if (!options) {
            OPN::LogError(@"[Sentry] Unable to allocate Sentry options");
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

        sentry_options_set_debug(options, OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_DEBUG") ? 1 : 0);
        sentry_options_set_enable_logs(options, 1);

        int initResult = sentry_init(options);
        if (initResult != 0) {
            OPN::LogError(@"[Sentry] sentry_init failed with code %d", initResult);
            return;
        }
        OPNSentryInitialized = true;
        OPNCaptureSentryVerificationMessageIfRequested();
        if (OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_VERIFY")) {
            log_return_value_t result = sentry_log_info("%s", "OpenNOW Sentry structured logs are enabled");
            std::fprintf(stderr, "[Sentry] verification log returned %s\n", OPNSentryLogReturnName(result));
            sentry_flush(5000);
        }
    });
#endif
}

void CloseSentry() {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized) return;
    OPNSentryInitialized = false;
    int closeResult = sentry_close();
    if (closeResult != 0) {
        OPN::LogInfo(@"[Sentry] sentry_close dumped %d envelope(s)", closeResult);
    }
#endif
}

}
