#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <functional>
#include <cstdint>

NS_ASSUME_NONNULL_BEGIN

#ifndef OPN_SENTRY_OBJC_DECLARATIONS
#define OPN_SENTRY_OBJC_DECLARATIONS
@interface OPNSentryTransaction : NSObject
- (void)setStatus:(BOOL)success;
- (void)finish;
@end

@interface OPNSentry : NSObject
+ (void)logInfoMessage:(NSString *)message;
+ (void)logErrorMessage:(NSString *)message;
+ (nullable OPNSentryTransaction *)startTransactionWithName:(NSString *)name operation:(NSString *)operation makeCurrent:(BOOL)makeCurrent;
+ (nullable OPNSentryTransaction *)traceHTTPRequest:(NSMutableURLRequest *)request name:(NSString *)name;
+ (BOOL)recordCounterMetricWithKey:(NSString *)key value:(int64_t)value attributes:(nullable NSDictionary<NSString *, id> *)attributes;
+ (BOOL)recordGaugeMetricWithKey:(NSString *)key value:(double)value unit:(nullable NSString *)unit attributes:(nullable NSDictionary<NSString *, id> *)attributes;
+ (BOOL)recordDistributionMetricWithKey:(NSString *)key value:(double)value unit:(nullable NSString *)unit attributes:(nullable NSDictionary<NSString *, id> *)attributes;
@end
#endif

#ifndef OPN_SENTRY_LOG_MACROS
#define OPN_SENTRY_LOG_MACROS
#define OPNLogInfo(...) [OPNSentry logInfoMessage:[NSString stringWithFormat:__VA_ARGS__]]
#define OPNLogError(...) [OPNSentry logErrorMessage:[NSString stringWithFormat:__VA_ARGS__]]
#endif

#ifndef OPN_SENTRY_METRIC_HELPERS
#define OPN_SENTRY_METRIC_HELPERS
static inline NSString *OPNSentryMetricKey(const char *value) {
    if (!value || value[0] == '\0') return @"";
    return [NSString stringWithUTF8String:value] ?: @"";
}

static inline bool OPNRecordSentryCounterMetric(const char *key, int64_t value, NSDictionary<NSString *, id> * _Nullable attributes) {
    return [OPNSentry recordCounterMetricWithKey:OPNSentryMetricKey(key) value:value attributes:attributes] ? true : false;
}

static inline bool OPNRecordSentryGaugeMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> * _Nullable attributes) {
    return [OPNSentry recordGaugeMetricWithKey:OPNSentryMetricKey(key) value:value unit:OPNSentryMetricKey(unit) attributes:attributes] ? true : false;
}

static inline bool OPNRecordSentryDistributionMetric(const char *key, double value, const char *unit, NSDictionary<NSString *, id> * _Nullable attributes) {
    return [OPNSentry recordDistributionMetricWithKey:OPNSentryMetricKey(key) value:value unit:OPNSentryMetricKey(unit) attributes:attributes] ? true : false;
}
#endif

NS_ASSUME_NONNULL_END

namespace OPN {

struct StreamSettings {
    std::string resolution = "1920x1080";
    int fps = 60;
    std::string codec = "H264";
    std::string colorQuality = "8bit_420";
    int maxBitrateMbps = 50;
    int prefilterMode = 0;
    int prefilterSharpness = 0;
    int prefilterDenoise = 0;
    int prefilterModel = 0;
    bool enableCloudGsync = false;
    bool enableL4S = false;
    bool enableReflex = true;
    bool lowLatencyMode = false;
    bool enableHdr = false;
    std::string microphoneMode = "disabled";
    std::string microphoneDeviceId;
    int microphonePushToTalkKeyCode = 9;
    int microphonePushToTalkModifierMask = 0;
    double gameVolume = 1.0;
    double microphoneVolume = 1.0;
    std::string keyboardLayout = "us";
    std::string gameLanguage = "en_US";
    bool accountLinked = true;
    std::string selectedStore;
    std::string networkTestSessionId;
    std::string networkType = "Unknown";
    int networkLatencyMs = -1;
    uint32_t remoteControllersBitmap = 0;
    uint32_t supportedHidDevices = 0;
    std::vector<std::string> availableSupportedControllers;
};

struct IceServer {
    std::vector<std::string> urls;
    std::string username;
    std::string credential;
};

struct MediaConnectionInfo {
    std::string ip;
    int port = 0;
};

struct NegotiatedStreamProfile {
    std::string resolution;
    int fps = 0;
    std::string codec;
    std::string colorQuality;
    int bitDepth = -1;
    int chromaFormat = -1;
    int prefilterMode = -1;
    int prefilterSharpness = -1;
    int prefilterDenoise = -1;
    int prefilterModel = -1;
};

struct SessionAdMediaFile {
    std::string mediaFileUrl;
    std::string encodingProfile;
};

struct SessionAdInfo {
    std::string adId;
    int adState = -1;
    std::string adUrl;
    std::string mediaUrl;
    std::vector<SessionAdMediaFile> adMediaFiles;
    std::string clickThroughUrl;
    int adLengthInSeconds = 0;
    int durationMs = 0;
    std::string title;
    std::string description;
};

struct SessionAdState {
    bool isAdsRequired = false;
    bool sessionAdsRequired = false;
    bool isQueuePaused = false;
    bool serverSentEmptyAds = false;
    int gracePeriodSeconds = 0;
    std::string message;
    std::vector<SessionAdInfo> sessionAds;
};

enum class SessionProgressState {
    Unknown = 0,
    Connecting,
    InQueue,
    PreviousSessionCleanup,
    WaitingForStorage,
    SettingUp,
};

struct SessionInfo {
    std::string sessionId;
    int status = 0;
    int queuePosition = 0;
    int seatSetupStep = 0;
    SessionProgressState progressState = SessionProgressState::Unknown;
    std::string zone;
    std::string streamingBaseUrl;
    std::string serverIp;
    std::string signalingServer;
    std::string signalingUrl;
    std::string gpuType;
    std::vector<IceServer> iceServers;
    MediaConnectionInfo mediaConnectionInfo;
    NegotiatedStreamProfile negotiatedStreamProfile;
    SessionAdState adState;
    double remainingPlaytimeHours = 0;
    bool remainingPlaytimeAvailable = false;
    bool remainingPlaytimeUnlimited = false;
    std::string clientId;
    std::string deviceId;
};

struct ActiveSessionEntry {
    std::string sessionId;
    int appId = 0;
    int status = 0;
    std::string serverIp;
    std::string gpuType;
    std::string streamingBaseUrl;
    std::string signalingUrl;
};

struct IceCandidatePayload {
    std::string candidate;
    std::string sdpMid;
    int sdpMLineIndex = 0;
    std::string usernameFragment;
};

struct SendAnswerRequest {
    std::string sdp;
    std::string nvstSdp;
};

using SessionCreateCallback = std::function<void(bool success, const SessionInfo &info, const std::string &error)>;
using SessionPollCallback = std::function<void(bool success, const SessionInfo &info, const std::string &error)>;

}
