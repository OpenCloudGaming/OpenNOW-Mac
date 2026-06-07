#pragma once

#import <Foundation/Foundation.h>
#include <cstdint>
#include <memory>

namespace OPN {

class SentryTransaction final {
public:
    SentryTransaction() noexcept;
    SentryTransaction(const char *name, const char *operation) noexcept;
    SentryTransaction(const char *name, const char *operation, bool makeCurrent) noexcept;
    ~SentryTransaction();

    SentryTransaction(const SentryTransaction &) = delete;
    SentryTransaction &operator=(const SentryTransaction &) = delete;
    SentryTransaction(SentryTransaction &&other) noexcept;
    SentryTransaction &operator=(SentryTransaction &&other) noexcept;

    bool IsActive() const noexcept;
    void SetStatus(bool success) noexcept;
    void SetTag(const char *key, const char *value) noexcept;
    void SetData(const char *key, const char *value) noexcept;
    void AddTraceHeaders(NSMutableURLRequest *request) const noexcept;
    void Finish() noexcept;

private:
    void *m_transaction;
    void *m_previousTransaction;
};

using SentryTransactionPtr = std::shared_ptr<SentryTransaction>;

class SentryTransactionFinishGuard final {
public:
    explicit SentryTransactionFinishGuard(SentryTransactionPtr transaction) noexcept;
    ~SentryTransactionFinishGuard();

    SentryTransactionFinishGuard(const SentryTransactionFinishGuard &) = delete;
    SentryTransactionFinishGuard &operator=(const SentryTransactionFinishGuard &) = delete;

    void SetSuccess(bool success) noexcept;
    void Finish(bool success) noexcept;

private:
    SentryTransactionPtr m_transaction;
    bool m_success;
};

SentryTransactionPtr StartSentryTransaction(const char *name, const char *operation);
SentryTransactionPtr TraceSentryHTTPRequest(NSMutableURLRequest *request, const char *name);

void InitializeSentry();
void CloseSentry();
bool ShouldLogInfo();
void LogInfo(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void LogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void CaptureExternalLogLine(NSString *line);
void AddSentryTraceHeaders(NSMutableURLRequest *request);
bool RecordSentryCounterMetric(const char *key, int64_t value, NSDictionary<NSString *, id> *attributes = nil);
bool RecordSentryGaugeMetric(const char *key, double value, const char *unit = nullptr, NSDictionary<NSString *, id> *attributes = nil);
bool RecordSentryDistributionMetric(const char *key, double value, const char *unit = nullptr, NSDictionary<NSString *, id> *attributes = nil);

}
