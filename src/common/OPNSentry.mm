#include "OPNSentry.h"

#import <Foundation/Foundation.h>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <memory>
#include <string>
#include <utility>

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
static constexpr double OPNDefaultSentryTracesSampleRate = 0.2;
static constexpr const char *OPNSentryLoggerName = "opennow";
static bool OPNSentryInitialized = false;
static thread_local sentry_transaction_t *OPNCurrentSentryTransaction = nullptr;
static std::atomic<bool> OPNSentryStructuredInfoLogFailureReported{false};
static NSUncaughtExceptionHandler *OPNPreviousUncaughtExceptionHandler = nullptr;
static std::terminate_handler OPNPreviousTerminateHandler = nullptr;

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

static double OPNSentryTraceSampleRate() {
    const char *value = std::getenv("OPN_SENTRY_TRACES_SAMPLE_RATE");
    if (!value || value[0] == '\0') return OPNDefaultSentryTracesSampleRate;

    errno = 0;
    char *end = nullptr;
    double sampleRate = std::strtod(value, &end);
    if (errno != 0 || end == value || (end && end[0] != '\0') || !std::isfinite(sampleRate) || sampleRate < 0.0 || sampleRate > 1.0) {
        OPN::LogError(@"[Sentry] Invalid OPN_SENTRY_TRACES_SAMPLE_RATE='%s'; using %.2f", value, OPNDefaultSentryTracesSampleRate);
        return OPNDefaultSentryTracesSampleRate;
    }
    return sampleRate;
}

static bool OPNShouldInitializeSentry() {
    return !OPNSentryEnvironmentFlagEnabled("OPN_DISABLE_SENTRY");
}

static bool OPNUploadInfoLogsAsEvents() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_INFO_EVENTS");
}

static bool OPNFlushErrorsImmediately() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_FLUSH_ERRORS");
}

static bool OPNShouldSendStructuredInfoLog() {
    return OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_INFO_LOGS");
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

static const char *OPNSentryMetricResultName(sentry_metrics_result_t value) {
    switch (value) {
        case SENTRY_METRICS_RESULT_SUCCESS: return "success";
        case SENTRY_METRICS_RESULT_DISCARD: return "discard";
        case SENTRY_METRICS_RESULT_FAILED: return "failed";
        case SENTRY_METRICS_RESULT_DISABLED: return "disabled";
    }
    return "unknown";
}

static sentry_value_t OPNSentryMetricAttributeValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        const char *stringValue = [(NSString *)value UTF8String];
        return sentry_value_new_attribute(sentry_value_new_string(stringValue ? stringValue : ""), nullptr);
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
            return sentry_value_new_attribute(sentry_value_new_bool(number.boolValue ? 1 : 0), nullptr);
        }
        return sentry_value_new_attribute(sentry_value_new_double(number.doubleValue), nullptr);
    }

    NSString *description = [value description];
    const char *stringValue = description.UTF8String;
    return sentry_value_new_attribute(sentry_value_new_string(stringValue ? stringValue : ""), nullptr);
}

static sentry_value_t OPNSentryMetricAttributes(NSDictionary<NSString *, id> *attributes) {
    if (attributes.count == 0) return sentry_value_new_null();

    sentry_value_t sentryAttributes = sentry_value_new_object();
    for (NSString *key in attributes) {
        if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
        id value = attributes[key];
        if (!value || value == NSNull.null) continue;

        const char *utf8Key = key.UTF8String;
        if (!utf8Key || utf8Key[0] == '\0') continue;
        sentry_value_set_by_key(sentryAttributes, utf8Key, OPNSentryMetricAttributeValue(value));
    }

    return sentryAttributes;
}

static bool OPNHandleSentryMetricResult(sentry_metrics_result_t result, const char *key) {
    if (result == SENTRY_METRICS_RESULT_SUCCESS) return true;
    if (result == SENTRY_METRICS_RESULT_FAILED) {
        std::fprintf(stderr, "[Sentry] metric '%s' failed to enqueue\n", key ? key : "");
    }
    return false;
}

static void OPNRecordSentryErrorLogMetric(const char *source) {
    if (!OPNSentryInitialized) return;
    NSDictionary<NSString *, id> *attributes = @{
        @"source": source && source[0] != '\0' ? [NSString stringWithUTF8String:source] : @"local",
    };
    OPNHandleSentryMetricResult(sentry_metrics_count("opennow.logs.error.count", 1, OPNSentryMetricAttributes(attributes)), "opennow.logs.error.count");
}

static void OPNCaptureSentryMessage(sentry_level_t level, const char *message) {
    sentry_capture_event(sentry_value_new_message_event(level, OPNSentryLoggerName, message));
}

static void OPNSendStructuredInfoLog(const char *message) {
    if (!OPNSentryInitialized || !OPNShouldSendStructuredInfoLog()) return;
    log_return_value_t result = sentry_log_info("%s", message);
    if (result != SENTRY_LOG_RETURN_SUCCESS && !OPNSentryStructuredInfoLogFailureReported.exchange(true)) {
        std::fprintf(stderr, "[Sentry] sentry_log_info returned %s; local logging continues\n", OPNSentryLogReturnName(result));
    }
}

static void OPNSendStructuredErrorLog(const char *message) {
    if (!OPNSentryInitialized) return;
    log_return_value_t result = sentry_log_error("%s", message);
    if (result != SENTRY_LOG_RETURN_SUCCESS) {
        std::fprintf(stderr, "[Sentry] sentry_log_error returned %s\n", OPNSentryLogReturnName(result));
    }
    OPNCaptureSentryMessage(SENTRY_LEVEL_ERROR, message);
    if (OPNFlushErrorsImmediately()) {
        sentry_flush(2000);
    }
}

static BOOL OPNExternalLogLineLooksLikeError(NSString *line) {
    if (line.length == 0) return NO;
    NSString *lowercaseLine = line.lowercaseString;
    return [lowercaseLine containsString:@"error"] ||
        [lowercaseLine containsString:@"exception"] ||
        [lowercaseLine containsString:@"failed"] ||
        [lowercaseLine containsString:@"failure"] ||
        [lowercaseLine containsString:@"crash"] ||
        [lowercaseLine containsString:@"fatal"];
}

static void OPNReportUncaughtNSException(NSException *exception) {
    NSString *reason = exception.reason ?: @"unknown reason";
    NSString *name = exception.name ?: @"NSException";
    NSArray<NSString *> *symbols = exception.callStackSymbols ?: @[];
    NSString *stack = symbols.count > 0 ? [symbols componentsJoinedByString:@"\n"] : @"";
    OPN::LogError(@"[Sentry] Uncaught Objective-C exception %@: %@\n%@", name, reason, stack);
    if (OPNPreviousUncaughtExceptionHandler) {
        OPNPreviousUncaughtExceptionHandler(exception);
    }
}

static void OPNReportTerminate() {
    std::exception_ptr currentException = std::current_exception();
    if (currentException) {
        try {
            std::rethrow_exception(currentException);
        } catch (const std::exception &exception) {
            OPN::LogError(@"[Sentry] Unhandled C++ exception: %s", exception.what());
        } catch (...) {
            OPN::LogError(@"[Sentry] Unhandled non-standard C++ exception");
        }
    } else {
        OPN::LogError(@"[Sentry] std::terminate called without an active exception");
    }

    if (OPNPreviousTerminateHandler) {
        OPNPreviousTerminateHandler();
    }
    std::abort();
}

static void OPNInstallUnhandledExceptionHandlers() {
    OPNPreviousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(OPNReportUncaughtNSException);
    OPNPreviousTerminateHandler = std::set_terminate(OPNReportTerminate);
}

static void OPNCaptureSentryVerificationMessageIfRequested() {
    if (!OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_VERIFY")) return;
    sentry_capture_event(sentry_value_new_message_event(SENTRY_LEVEL_INFO, OPNSentryLoggerName, "It works!"));
}

static void OPNCaptureSentryVerificationMetricsIfRequested() {
    if (!OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_VERIFY")) return;

    NSDictionary<NSString *, id> *requestAttributes = @{
        @"endpoint": @"/api/users",
        @"method": @"POST",
    };
    sentry_metrics_result_t counterResult = sentry_metrics_count("button_click", 1, sentry_value_new_null());
    sentry_metrics_result_t gaugeResult = sentry_metrics_gauge("queue_depth", 42.0, nullptr, sentry_value_new_null());
    sentry_metrics_result_t distributionResult = sentry_metrics_distribution("response_time", 187.5, SENTRY_UNIT_MILLISECOND, sentry_value_new_null());
    sentry_metrics_result_t requestCounterResult = sentry_metrics_count("network.request.count", 1, OPNSentryMetricAttributes(requestAttributes));

    std::fprintf(stderr,
        "[Sentry] verification metrics returned counter=%s gauge=%s distribution=%s request_counter=%s\n",
        OPNSentryMetricResultName(counterResult),
        OPNSentryMetricResultName(gaugeResult),
        OPNSentryMetricResultName(distributionResult),
        OPNSentryMetricResultName(requestCounterResult));
}

static sentry_transaction_t *OPNTransactionFromOpaque(void *transaction) {
    return static_cast<sentry_transaction_t *>(transaction);
}

static NSString *OPNSanitizedURLForTrace(NSURL *url) {
    if (!url) return @"";
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url.host ?: @"";
    components.user = nil;
    components.password = nil;
    components.query = nil;
    components.fragment = nil;
    return components.string ?: url.host ?: @"";
}

static std::string OPNHTTPTransactionName(NSMutableURLRequest *request, const char *fallbackName) {
    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod.uppercaseString : @"GET";
    NSURL *url = request.URL;
    NSString *host = url.host.length > 0 ? url.host : @"unknown-host";
    NSString *path = url.path.length > 0 ? url.path : @"/";
    NSString *name = [NSString stringWithFormat:@"HTTP %@ %@%@", method, host, path];
    if (name.length == 0 && fallbackName && fallbackName[0] != '\0') name = [NSString stringWithUTF8String:fallbackName];
    return OPNUtf8String(name);
}

static void OPNAddSentryTraceHeader(const char *key, const char *value, void *userdata) {
    if (!key || !value || !userdata) return;
    NSMutableURLRequest *request = (__bridge NSMutableURLRequest *)userdata;
    NSString *headerName = [NSString stringWithUTF8String:key];
    NSString *headerValue = [NSString stringWithUTF8String:value];
    if (headerName.length == 0 || headerValue.length == 0) return;
    if ([request valueForHTTPHeaderField:headerName].length == 0) {
        [request setValue:headerValue forHTTPHeaderField:headerName];
    }
}

}
#endif

SentryTransaction::SentryTransaction() noexcept
    : m_transaction(nullptr),
      m_previousTransaction(nullptr) {}

SentryTransaction::SentryTransaction(const char *name, const char *operation) noexcept
    : SentryTransaction(name, operation, true) {}

SentryTransaction::SentryTransaction(const char *name, const char *operation, bool makeCurrent) noexcept
    : m_transaction(nullptr),
      m_previousTransaction(nullptr) {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized) return;

    const char *transactionName = name && name[0] != '\0' ? name : "OpenNOW operation";
    const char *transactionOperation = operation && operation[0] != '\0' ? operation : "task";
    sentry_transaction_context_t *context = sentry_transaction_context_new(transactionName, transactionOperation);
    if (!context) return;

    sentry_transaction_t *transaction = sentry_transaction_start(context, sentry_value_new_null());
    if (!transaction) return;

    m_transaction = transaction;
    if (makeCurrent) {
        m_previousTransaction = OPNCurrentSentryTransaction;
        OPNCurrentSentryTransaction = transaction;
        sentry_set_transaction_object(transaction);
    }
#else
    (void)name;
    (void)operation;
    (void)makeCurrent;
#endif
}

SentryTransaction::~SentryTransaction() {
    Finish();
}

SentryTransaction::SentryTransaction(SentryTransaction &&other) noexcept
    : m_transaction(std::exchange(other.m_transaction, nullptr)),
      m_previousTransaction(std::exchange(other.m_previousTransaction, nullptr)) {}

SentryTransaction &SentryTransaction::operator=(SentryTransaction &&other) noexcept {
    if (this == &other) return *this;
    Finish();
    m_transaction = std::exchange(other.m_transaction, nullptr);
    m_previousTransaction = std::exchange(other.m_previousTransaction, nullptr);
    return *this;
}

bool SentryTransaction::IsActive() const noexcept {
    return m_transaction != nullptr;
}

void SentryTransaction::SetStatus(bool success) noexcept {
#if OPN_SENTRY_ENABLED
    sentry_transaction_t *transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction) return;
    sentry_transaction_set_status(transaction, success ? SENTRY_SPAN_STATUS_OK : SENTRY_SPAN_STATUS_INTERNAL_ERROR);
#else
    (void)success;
#endif
}

void SentryTransaction::SetTag(const char *key, const char *value) noexcept {
#if OPN_SENTRY_ENABLED
    sentry_transaction_t *transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction || !key || key[0] == '\0' || !value) return;
    sentry_transaction_set_tag(transaction, key, value);
#else
    (void)key;
    (void)value;
#endif
}

void SentryTransaction::SetData(const char *key, const char *value) noexcept {
#if OPN_SENTRY_ENABLED
    sentry_transaction_t *transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction || !key || key[0] == '\0' || !value) return;
    sentry_transaction_set_data(transaction, key, sentry_value_new_string(value));
#else
    (void)key;
    (void)value;
#endif
}

void SentryTransaction::AddTraceHeaders(NSMutableURLRequest *request) const noexcept {
#if OPN_SENTRY_ENABLED
    sentry_transaction_t *transaction = OPNTransactionFromOpaque(m_transaction);
    if (!request || !transaction) return;
    sentry_transaction_iter_headers(transaction, OPNAddSentryTraceHeader, (__bridge void *)request);
#else
    (void)request;
#endif
}

void SentryTransaction::Finish() noexcept {
#if OPN_SENTRY_ENABLED
    sentry_transaction_t *transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction) return;
    if (OPNCurrentSentryTransaction == transaction) {
        OPNCurrentSentryTransaction = OPNTransactionFromOpaque(m_previousTransaction);
    }
    m_transaction = nullptr;
    m_previousTransaction = nullptr;
    sentry_transaction_finish(transaction);
#endif
}

SentryTransactionFinishGuard::SentryTransactionFinishGuard(SentryTransactionPtr transaction) noexcept
    : m_transaction(std::move(transaction)),
      m_success(false) {}

SentryTransactionFinishGuard::~SentryTransactionFinishGuard() {
    Finish(m_success);
}

void SentryTransactionFinishGuard::SetSuccess(bool success) noexcept {
    m_success = success;
}

void SentryTransactionFinishGuard::Finish(bool success) noexcept {
    if (!m_transaction) return;
    m_transaction->SetStatus(success);
    m_transaction->Finish();
    m_transaction.reset();
}

SentryTransactionPtr StartSentryTransaction(const char *name, const char *operation) {
    auto transaction = std::make_shared<SentryTransaction>(name, operation, true);
    return transaction->IsActive() ? transaction : nullptr;
}

SentryTransactionPtr TraceSentryHTTPRequest(NSMutableURLRequest *request, const char *name) {
    if (!request) return nullptr;
#if OPN_SENTRY_ENABLED
    std::string transactionName = OPNHTTPTransactionName(request, name);
    auto transaction = std::make_shared<SentryTransaction>(transactionName.c_str(), "http.client", false);
    if (!transaction->IsActive()) return nullptr;
    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod.uppercaseString : @"GET";
    NSString *url = OPNSanitizedURLForTrace(request.URL);
    transaction->SetTag("http.method", method.UTF8String ?: "GET");
    if (request.URL.host.length > 0) transaction->SetTag("server.address", request.URL.host.UTF8String ?: "");
    if (url.length > 0) transaction->SetData("url.full", url.UTF8String ?: "");
    transaction->AddTraceHeaders(request);
    AddSentryTraceHeaders(request);
    return transaction;
#else
    (void)name;
    return nullptr;
#endif
}

bool ShouldLogInfo() {
    return !OPNEnvironmentFlagEnabled("OPN_DISABLE_INFO_LOGS");
}

void LogInfo(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = OPNFormattedLogMessage(format, arguments);
    va_end(arguments);
    const char *utf8Message = OPNLogMessageUtf8(message);

    if (ShouldLogInfo()) {
        std::fprintf(stderr, "%s\n", utf8Message);
    }

#if OPN_SENTRY_ENABLED
    if (OPNSentryInitialized) {
        NSString *sentryMessage = OPNSanitizedSentryMessage(message);
        const char *sentryUtf8Message = OPNLogMessageUtf8(sentryMessage);
        OPNSendStructuredInfoLog(sentryUtf8Message);
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
        OPNSendStructuredErrorLog(sentryUtf8Message);
        OPNRecordSentryErrorLogMetric("local");
    }
#endif
}

void CaptureExternalLogLine(NSString *line) {
    if (line.length == 0) return;

#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized) return;
    NSString *sentryMessage = OPNSanitizedSentryMessage(line);
    const char *sentryUtf8Message = OPNLogMessageUtf8(sentryMessage);
    if (OPNExternalLogLineLooksLikeError(sentryMessage)) {
        OPNSendStructuredErrorLog(sentryUtf8Message);
        OPNRecordSentryErrorLogMetric("external");
    } else {
        OPNSendStructuredInfoLog(sentryUtf8Message);
    }
#else
    (void)line;
#endif
}

void AddSentryTraceHeaders(NSMutableURLRequest *request) {
#if OPN_SENTRY_ENABLED
    if (!request || !OPNSentryInitialized || !OPNCurrentSentryTransaction) return;
    sentry_transaction_iter_headers(OPNCurrentSentryTransaction, OPNAddSentryTraceHeader, (__bridge void *)request);
#else
    (void)request;
#endif
}

bool RecordSentryCounterMetric(const char *key, int64_t value, NSDictionary<NSString *, id> *attributes) {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized || !key || key[0] == '\0') return false;
    return OPNHandleSentryMetricResult(sentry_metrics_count(key, value, OPNSentryMetricAttributes(attributes)), key);
#else
    (void)key;
    (void)value;
    (void)attributes;
    return false;
#endif
}

bool RecordSentryGaugeMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> *attributes) {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized || !key || key[0] == '\0' || !std::isfinite(value)) return false;
    return OPNHandleSentryMetricResult(sentry_metrics_gauge(key, value, unit, OPNSentryMetricAttributes(attributes)), key);
#else
    (void)key;
    (void)value;
    (void)unit;
    (void)attributes;
    return false;
#endif
}

bool RecordSentryDistributionMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> *attributes) {
#if OPN_SENTRY_ENABLED
    if (!OPNSentryInitialized || !key || key[0] == '\0' || !std::isfinite(value)) return false;
    return OPNHandleSentryMetricResult(sentry_metrics_distribution(key, value, unit, OPNSentryMetricAttributes(attributes)), key);
#else
    (void)key;
    (void)value;
    (void)unit;
    (void)attributes;
    return false;
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
        sentry_options_set_enable_metrics(options, OPNSentryEnvironmentFlagEnabled("OPN_DISABLE_SENTRY_METRICS") ? 0 : 1);
        sentry_options_set_traces_sample_rate(options, OPNSentryTraceSampleRate());
        sentry_options_set_propagate_traceparent(options, 1);

        int initResult = sentry_init(options);
        if (initResult != 0) {
            OPN::LogError(@"[Sentry] sentry_init failed with code %d", initResult);
            return;
        }
        OPNSentryInitialized = true;
        OPNInstallUnhandledExceptionHandlers();
        OPNHandleSentryMetricResult(sentry_metrics_count("opennow.app.lifecycle.count", 1, OPNSentryMetricAttributes(@{@"phase": @"start"})), "opennow.app.lifecycle.count");
        OPNCaptureSentryVerificationMessageIfRequested();
        OPNCaptureSentryVerificationMetricsIfRequested();
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
    OPNHandleSentryMetricResult(sentry_metrics_count("opennow.app.lifecycle.count", 1, OPNSentryMetricAttributes(@{@"phase": @"close"})), "opennow.app.lifecycle.count");
    OPNSentryInitialized = false;
    int closeResult = sentry_close();
    if (closeResult != 0) {
        OPN::LogInfo(@"[Sentry] sentry_close dumped %d envelope(s)", closeResult);
    }
#endif
}

}
