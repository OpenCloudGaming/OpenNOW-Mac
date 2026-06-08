#include "OPNSentry.h"

#import <Foundation/Foundation.h>
@import Sentry;
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

namespace OPN {

namespace {

static constexpr const char *OPNDefaultSentryDsn = "https://26e9dba9cb293d4ca2afceb73dd13b74@o4509317113184256.ingest.us.sentry.io/4511406450868224";
static constexpr double OPNDefaultSentryTracesSampleRate = 1.0;
static constexpr float OPNDefaultSentryProfileSessionSampleRate = 1.0F;
static bool OPNSentryInitialized = false;
static thread_local void *OPNCurrentSentryTransaction = nullptr;
static std::atomic<bool> OPNSentryMetricWarningReported{false};
static NSUncaughtExceptionHandler *OPNPreviousUncaughtExceptionHandler = nullptr;
static std::terminate_handler OPNPreviousTerminateHandler = nullptr;

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

static NSString *OPNInfoString(NSString *key, NSString *fallback) {
    id value = NSBundle.mainBundle.infoDictionary[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
    return fallback;
}

static NSString *OPNSentryReleaseName() {
    NSString *name = OPNInfoString(@"CFBundleName", @"OpenNOW");
    NSString *version = OPNInfoString(@"CFBundleShortVersionString", @"0.0.0");
    NSString *build = OPNInfoString(@"CFBundleVersion", nil);
    return build.length > 0
        ? [NSString stringWithFormat:@"%@@%@+%@", name, version, build]
        : [NSString stringWithFormat:@"%@@%@", name, version];
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
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"(?i)((?:access|refresh|id)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id)([=:]\\s*|\\\"\\s*:\\s*\\\")[^\\s,;\\}\\\"]+", @"$1$2[redacted-secret]");
    sanitized = OPNSentryStringByReplacingMatches(sanitized, @"/Users/[^/\\s]+", @"/Users/[redacted-user]");
    return sanitized;
}

static bool OPNSentryEnvironmentFlagEnabled(const char *name) {
    return OPNEnvironmentFlagEnabled(name);
}

static double OPNClampedSentrySampleRate(const char *environmentName, double fallback) {
    const char *value = std::getenv(environmentName);
    if (!value || value[0] == '\0') return fallback;

    errno = 0;
    char *end = nullptr;
    double sampleRate = std::strtod(value, &end);
    if (errno != 0 || end == value || (end && end[0] != '\0') || !std::isfinite(sampleRate) || sampleRate < 0.0 || sampleRate > 1.0) {
        OPN::LogError(@"[Sentry] Invalid %s='%s'; using %.2f", environmentName, value, fallback);
        return fallback;
    }
    return sampleRate;
}

static double OPNSentryTraceSampleRate() {
    return OPNClampedSentrySampleRate("OPN_SENTRY_TRACES_SAMPLE_RATE", OPNDefaultSentryTracesSampleRate);
}

static float OPNSentryProfileSessionSampleRate() {
    return static_cast<float>(OPNClampedSentrySampleRate("OPN_SENTRY_PROFILE_SESSION_SAMPLE_RATE", OPNDefaultSentryProfileSessionSampleRate));
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

static id<SentrySpan> OPNTransactionFromOpaque(void *transaction) {
    return (__bridge id<SentrySpan>)transaction;
}

static void OPNCaptureSentryMessage(SentryLevel level, NSString *message) {
    SentryEvent *event = [[SentryEvent alloc] initWithLevel:level];
    event.message = [[SentryMessage alloc] initWithFormatted:message ?: @""];
    [SentrySDK captureEvent:event];
}

static void OPNSendSentryErrorLog(NSString *message) {
    if (!OPNSentryInitialized) return;
    OPNCaptureSentryMessage(kSentryLevelError, message ?: @"");
    if (OPNFlushErrorsImmediately()) {
        [SentrySDK flush:2.0];
    }
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
    OPNCaptureSentryMessage(kSentryLevelInfo, @"It works!");
    [SentrySDK flush:5.0];
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

static std::string OPNUtf8String(NSString *value) {
    if (value.length == 0) return std::string();
    const char *utf8 = value.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
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

static void OPNAddSentryTraceHeaders(id<SentrySpan> span, NSMutableURLRequest *request) {
    if (!span || !request) return;

    SentryTraceHeader *traceHeader = [span toTraceHeader];
    NSString *traceHeaderValue = [traceHeader value];
    if (traceHeaderValue.length > 0 && [request valueForHTTPHeaderField:@"sentry-trace"].length == 0) {
        [request setValue:traceHeaderValue forHTTPHeaderField:@"sentry-trace"];
    }

    NSString *baggage = [span baggageHttpHeader];
    if (baggage.length > 0 && [request valueForHTTPHeaderField:@"baggage"].length == 0) {
        [request setValue:baggage forHTTPHeaderField:@"baggage"];
    }
}

}

SentryTransaction::SentryTransaction() noexcept
    : m_transaction(nullptr),
      m_previousTransaction(nullptr) {}

SentryTransaction::SentryTransaction(const char *name, const char *operation) noexcept
    : SentryTransaction(name, operation, true) {}

SentryTransaction::SentryTransaction(const char *name, const char *operation, bool makeCurrent) noexcept
    : m_transaction(nullptr),
      m_previousTransaction(nullptr) {
    if (!OPNSentryInitialized) return;

    NSString *transactionName = name && name[0] != '\0' ? [NSString stringWithUTF8String:name] : @"OpenNOW operation";
    NSString *transactionOperation = operation && operation[0] != '\0' ? [NSString stringWithUTF8String:operation] : @"task";
    id<SentrySpan> transaction = [SentrySDK startTransactionWithName:transactionName
                                                           operation:transactionOperation
                                                         bindToScope:makeCurrent ? YES : NO];
    if (!transaction) return;

    m_transaction = (__bridge_retained void *)transaction;
    if (makeCurrent) {
        m_previousTransaction = OPNCurrentSentryTransaction;
        OPNCurrentSentryTransaction = m_transaction;
    }
}

SentryTransaction::~SentryTransaction() {
    Finish();
}

SentryTransaction::SentryTransaction(SentryTransaction &&other) noexcept
    : m_transaction(std::exchange(other.m_transaction, nullptr)),
      m_previousTransaction(std::exchange(other.m_previousTransaction, nullptr)) {
    if (OPNCurrentSentryTransaction == other.m_transaction) {
        OPNCurrentSentryTransaction = m_transaction;
    }
}

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
    id<SentrySpan> transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction) return;
    transaction.status = success ? kSentrySpanStatusOk : kSentrySpanStatusInternalError;
}

void SentryTransaction::SetTag(const char *key, const char *value) noexcept {
    id<SentrySpan> transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction || !key || key[0] == '\0' || !value) return;
    [transaction setTagValue:[NSString stringWithUTF8String:value] forKey:[NSString stringWithUTF8String:key]];
}

void SentryTransaction::SetData(const char *key, const char *value) noexcept {
    id<SentrySpan> transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction || !key || key[0] == '\0' || !value) return;
    [transaction setDataValue:[NSString stringWithUTF8String:value] forKey:[NSString stringWithUTF8String:key]];
}

void SentryTransaction::AddTraceHeaders(NSMutableURLRequest *request) const noexcept {
    OPNAddSentryTraceHeaders(OPNTransactionFromOpaque(m_transaction), request);
}

void SentryTransaction::Finish() noexcept {
    id<SentrySpan> transaction = OPNTransactionFromOpaque(m_transaction);
    if (!transaction) return;
    if (OPNCurrentSentryTransaction == m_transaction) {
        OPNCurrentSentryTransaction = m_previousTransaction;
    }
    void *retainedTransaction = m_transaction;
    m_transaction = nullptr;
    m_previousTransaction = nullptr;
    [transaction finish];
    CFBridgingRelease(retainedTransaction);
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

    if (OPNSentryInitialized && OPNUploadInfoLogsAsEvents()) {
        OPNCaptureSentryMessage(kSentryLevelInfo, OPNSanitizedSentryMessage(message));
    }
}

void LogError(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = OPNFormattedLogMessage(format, arguments);
    va_end(arguments);
    const char *utf8Message = OPNLogMessageUtf8(message);

    std::fprintf(stderr, "%s\n", utf8Message);

    if (OPNSentryInitialized) {
        OPNSendSentryErrorLog(OPNSanitizedSentryMessage(message));
    }
}

void CaptureExternalLogLine(NSString *line) {
    if (line.length == 0 || !OPNSentryInitialized) return;

    NSString *sentryMessage = OPNSanitizedSentryMessage(line);
    if (OPNExternalLogLineLooksLikeError(sentryMessage)) {
        OPNSendSentryErrorLog(sentryMessage);
    } else if (OPNUploadInfoLogsAsEvents()) {
        OPNCaptureSentryMessage(kSentryLevelInfo, sentryMessage);
    }
}

void AddSentryTraceHeaders(NSMutableURLRequest *request) {
    if (!request || !OPNSentryInitialized || !OPNCurrentSentryTransaction) return;
    OPNAddSentryTraceHeaders(OPNTransactionFromOpaque(OPNCurrentSentryTransaction), request);
}

bool RecordSentryCounterMetric(const char *key, int64_t value, NSDictionary<NSString *, id> *attributes) {
    (void)key;
    (void)value;
    (void)attributes;
    if (!OPNSentryMetricWarningReported.exchange(true)) {
        std::fprintf(stderr, "[Sentry] Metrics API is not enabled in the Cocoa SDK bridge; event and profile telemetry continue.\n");
    }
    return false;
}

bool RecordSentryGaugeMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> *attributes) {
    (void)key;
    (void)value;
    (void)unit;
    (void)attributes;
    if (!OPNSentryMetricWarningReported.exchange(true)) {
        std::fprintf(stderr, "[Sentry] Metrics API is not enabled in the Cocoa SDK bridge; event and profile telemetry continue.\n");
    }
    return false;
}

bool RecordSentryDistributionMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> *attributes) {
    (void)key;
    (void)value;
    (void)unit;
    (void)attributes;
    if (!OPNSentryMetricWarningReported.exchange(true)) {
        std::fprintf(stderr, "[Sentry] Metrics API is not enabled in the Cocoa SDK bridge; event and profile telemetry continue.\n");
    }
    return false;
}

void InitializeSentry() {
    if (!OPNShouldInitializeSentry()) return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const double traceSampleRate = OPNSentryTraceSampleRate();
        const float profileSessionSampleRate = OPNSentryProfileSessionSampleRate();
        [SentrySDK startWithConfigureOptions:^(SentryOptions *options) {
            options.dsn = [NSString stringWithUTF8String:OPNDefaultSentryDsn];
            options.releaseName = OPNSentryReleaseName();
            options.debug = OPNSentryEnvironmentFlagEnabled("OPN_SENTRY_DEBUG") ? YES : NO;
            options.enableLogs = YES;
            options.tracesSampleRate = @(traceSampleRate);
            options.configureProfiling = ^(SentryProfileOptions *profileOptions) {
                profileOptions.lifecycle = SentryProfileLifecycleTrace;
                profileOptions.sessionSampleRate = profileSessionSampleRate;
            };
        }];

        OPNSentryInitialized = true;
        OPNInstallUnhandledExceptionHandlers();
        OPNCaptureSentryVerificationMessageIfRequested();
    });
}

void CloseSentry() {
    if (!OPNSentryInitialized) return;
    OPNSentryInitialized = false;
    [SentrySDK close];
}

}
