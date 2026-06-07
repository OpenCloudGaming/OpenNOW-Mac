#pragma once

#import <Foundation/Foundation.h>

namespace OPN {

class SentryTransaction final {
public:
    SentryTransaction() noexcept;
    SentryTransaction(const char *name, const char *operation) noexcept;
    ~SentryTransaction();

    SentryTransaction(const SentryTransaction &) = delete;
    SentryTransaction &operator=(const SentryTransaction &) = delete;
    SentryTransaction(SentryTransaction &&other) noexcept;
    SentryTransaction &operator=(SentryTransaction &&other) noexcept;

    bool IsActive() const noexcept;
    void SetStatus(bool success) noexcept;
    void Finish() noexcept;

private:
    void *m_transaction;
    void *m_previousTransaction;
};

void InitializeSentry();
void CloseSentry();
bool ShouldLogInfo();
void LogInfo(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void LogError(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
void CaptureExternalLogLine(NSString *line);
void AddSentryTraceHeaders(NSMutableURLRequest *request);

}
