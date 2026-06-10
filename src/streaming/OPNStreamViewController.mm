#import "OPNStreamViewController.h"
#include "OPNStreamPreferences.h"
#include "OPNSessionManager.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/signpost.h>

@class OPNSessionReportPayload;
@class OPNStreamRecordingManager;

@interface OPNStreamStatsSnapshot : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) double latencyMs;
@property(nonatomic, readonly) double jitterMs;
@property(nonatomic, readonly) double inboundBitrateMbps;
@property(nonatomic, readonly) double packetLossPercent;
@property(nonatomic, readonly) double decodeTimeMs;
@property(nonatomic, readonly) double renderFps;
@property(nonatomic, readonly) unsigned long long framesReceived;
@property(nonatomic, readonly) unsigned long long framesDropped;
@property(nonatomic, readonly) long long packetsLost;
@property(nonatomic, readonly) NSInteger fps;
@property(nonatomic, readonly) NSString *resolution;
@property(nonatomic, readonly) NSString *codec;
@property(nonatomic, readonly) NSString *videoEnhancementActiveTier;
@property(nonatomic, readonly) NSString *videoEnhancementConfiguredTier;
@property(nonatomic, readonly) NSString *videoEnhancementSourceResolution;
@property(nonatomic, readonly) NSString *videoEnhancementDrawableResolution;
@property(nonatomic, readonly) NSString *videoEnhancementFallbackReason;
@property(nonatomic, readonly) NSString *videoEnhancementDiagnostics;
@property(nonatomic, readonly) double videoEnhancementFrameTimeMs;
@property(nonatomic, readonly) unsigned long long videoEnhancementDroppedFrames;
@end

@interface OPNStreamSessionHandle : NSObject
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly, getter=isInputReady) BOOL inputReady;
@property(nonatomic, readonly) void *rawSession;
+ (BOOL)isBackendAvailable;
+ (NSUInteger)maxGamepadControllers;
+ (NSString *)iceUfragFromOfferSdp:(NSString *)offerSdp;
- (instancetype)init;
- (void)stop;
- (void)setNativeWindow:(void *)nativeWindow;
- (void)setMaxBitrateMbps:(NSInteger)mbps;
- (void)addRemoteIceCandidatePayload:(NSDictionary *)payload;
- (OPNStreamStatsSnapshot *)latestStatsSnapshot;
@end

typedef void (^OPNStreamViewVoidHandler)(void);
typedef void (^OPNStreamViewSidebarVisibilityHandler)(BOOL visible);

@interface OPNStreamView : NSView
- (void)setMicrophoneMode:(NSString *)mode pushToTalkKeyCode:(uint16_t)keyCode modifierMask:(uint16_t)modifierMask;
- (void)setStreamActive:(BOOL)active;
- (void)setMaxBitrateMbps:(NSInteger)mbps;
- (BOOL)toggleMicrophoneEnabledShortcut;
- (BOOL)toggleRecordingShortcut;
- (void)toggleSidebarHUD;
- (void)setRecordingGameTitle:(NSString *)gameTitle;
- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited;
- (void)startRemainingPlaytimeCountdown;
- (void)stopRecordingIfNeeded;
- (void)setSuppressInputWhenWindowInactive:(BOOL)suppress;
- (void)setStreamInputSuppressed:(BOOL)suppressed;
- (void)setDirectMouseInputEnabled:(BOOL)enabled;
- (void)attachToPipeline:(void *)pipeline;
- (void)detachFromPipeline;
- (void)handleKeyEvent:(NSEvent *)event;
- (void)handleMouseEvent:(NSEvent *)event;
- (NSView *)nativeVideoView;
- (void)setVideoAspectRatio:(CGFloat)aspectRatio;
- (void)setVideoUpscalingMode:(NSInteger)mode sharpness:(NSInteger)sharpness denoise:(NSInteger)denoise streamWidth:(NSInteger)streamWidth streamHeight:(NSInteger)streamHeight;
- (void)takeFocus;
- (void)releasePointerLock;
- (BOOL)isSidebarHUDVisible;
- (void)clearStreamCallbacks;
@property (nonatomic, readonly) OPNStreamRecordingManager *recordingManager;
@property (nonatomic, copy) OPNStreamViewVoidHandler onUserActivity;
@property (nonatomic, copy) OPNStreamViewVoidHandler onDashboardToggleRequested;
@property (nonatomic, copy) OPNStreamViewSidebarVisibilityHandler onSidebarHUDVisibilityChanged;
@end

@interface OPNLoadingView : NSView
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSArray<NSString *> *steps;
@property (nonatomic, assign) NSInteger currentStepIndex;
@property (nonatomic, assign) NSInteger queuePosition;
@property (nonatomic, strong, readonly) NSTextField *messageLabel;
@property (nonatomic, copy) void (^adPlaybackEventHandler)(NSString *adId, NSString *action, NSInteger watchedTimeInMs, NSInteger pausedTimeInMs, NSString *cancelReason);
- (instancetype)initWithFrame:(NSRect)frame message:(NSString *)message;
- (void)setSteps:(NSArray<NSString *> *)steps currentStepIndex:(NSInteger)currentStepIndex;
- (void)advanceToStep:(NSInteger)stepIndex message:(NSString *)message;
- (void)updateQueuePosition:(NSInteger)queuePosition;
- (void)updateAdPresentationWithVisible:(BOOL)visible chipText:(NSString *)chipText title:(NSString *)title message:(NSString *)message adId:(NSString *)adId mediaUrl:(NSString *)mediaUrl durationMs:(NSInteger)durationMs;
- (void)clearAdPresentation;
- (void)startAnimating;
- (void)stopAnimating;
@end

@interface OPNSessionHealthReportBuilder : NSObject
- (void)resetWithGameTitle:(NSString *)gameTitle appId:(NSString *)appId backend:(NSString *)backend now:(double)now;
- (void)markPhase:(NSString *)phase now:(double)now;
- (void)setRequestedResolution:(NSString *)resolution fps:(NSInteger)fps codec:(NSString *)codec bitrateMbps:(NSInteger)bitrateMbps;
- (void)setFinalResolution:(NSString *)resolution fps:(NSInteger)fps codec:(NSString *)codec bitrateMbps:(NSInteger)bitrateMbps;
- (void)setNetworkStreamingBaseUrl:(NSString *)streamingBaseUrl networkType:(NSString *)networkType latencyMs:(NSInteger)latencyMs measuredBandwidthMbps:(double)measuredBandwidthMbps packetLossPercent:(double)packetLossPercent jitterMs:(NSInteger)jitterMs usedAutomaticRegion:(BOOL)usedAutomaticRegion region:(NSString *)region;
- (void)setSessionZone:(NSString *)zone gpuType:(NSString *)gpuType negotiatedResolution:(NSString *)negotiatedResolution negotiatedFps:(NSInteger)negotiatedFps negotiatedCodec:(NSString *)negotiatedCodec;
- (void)markConnected:(double)now;
- (void)recordEventWithTitle:(NSString *)title detail:(NSString *)detail now:(double)now;
- (void)addStatsSnapshot:(OPNStreamStatsSnapshot *)snapshot;
- (OPNSessionReportPayload *)finalizeWithSuccess:(BOOL)success terminalError:(NSString *)terminalError now:(double)now;
@end

@interface OPNDiscordPresence : NSObject
+ (void)updatePlayingWithGameTitle:(NSString *)gameTitle resolution:(NSString *)resolution fps:(NSInteger)fps bitrateMbps:(NSInteger)bitrateMbps codec:(NSString *)codec;
@end

@interface OPNLogCapture : NSObject
+ (void)appendEvent:(NSString *)message;
+ (void)copyCapturedLogToClipboard:(NSString *)reason;
@end

@interface OPNSentryTransactionBridge : NSObject
+ (instancetype)transactionWithName:(NSString *)name operation:(NSString *)operation;
- (void)setTag:(NSString *)key value:(NSString *)value;
- (void)setData:(NSString *)key value:(NSString *)value;
- (void)setStatus:(BOOL)success;
- (void)finish;
@end
#include <algorithm>
#include <cmath>
#include <vector>
#include <cctype>

namespace OPN {
class IStreamSession;
void OPNSetSessionManagerAccessToken(const std::string &token);
void OPNSetSessionManagerStreamingBaseUrl(const std::string &url);
void OPNReportSessionAd(const SessionInfo &session,
                        const std::string &adId,
                        const std::string &action,
                        int watchedTimeInMs,
                        int pausedTimeInMs,
                        const std::string &cancelReason,
                        std::function<void(bool, const SessionInfo &, const std::string &)> completion);
void OPNPollSession(const std::string &sessionId,
                    const std::string &serverIp,
                    SessionPollCallback completion);
void OPNStopSession(const std::string &sessionId,
                    const std::string &serverIp,
                    std::function<void(bool, const std::string &)> completion);
void OPNClaimSession(const std::string &sessionId,
                     const std::string &serverIp,
                     const std::string &appId,
                     const StreamSettings &settings,
                     bool recoveryMode,
                     SessionCreateCallback completion);
void OPNGetActiveSessions(std::function<void(bool, const std::vector<ActiveSessionEntry> &, const std::string &)> completion);
void OPNCreateSession(const std::string &appId,
                      const std::string &internalTitle,
                      const StreamSettings &settings,
                      SessionCreateCallback completion);
}

void OPNClearStreamSessionCallbacks(OPN::IStreamSession *session);
void OPNConfigureStreamViewSessionCallbacks(OPN::IStreamSession *session,
                                            OPNStreamView *streamView,
                                            OPNStreamRecordingManager *recordingManager);
void OPNSendStreamSessionMouseMove(OPN::IStreamSession *session, int16_t dx, int16_t dy);

typedef void (^OPNStreamSessionAnswerHandler)(NSString *sdp, NSString *nvstSdp);
typedef void (^OPNStreamSessionLocalIceCandidateHandler)(NSDictionary *candidate);
typedef void (^OPNStreamSessionStateHandler)(BOOL connected, NSString *errorMessage);

void OPNInjectManualStreamSessionIceCandidate(OPN::IStreamSession *session,
                                              const OPN::SessionInfo &sessionInfo,
                                              NSString *offerSdp,
                                              NSString *serverIceUfrag);
void OPNStartStreamSession(OPN::IStreamSession *session,
                           const OPN::SessionInfo &sessionInfo,
                           NSString *offerSdp,
                           const OPN::StreamSettings &settings,
                           OPNStreamSessionAnswerHandler answerHandler,
                           OPNStreamSessionLocalIceCandidateHandler localIceCandidateHandler,
                           OPNStreamSessionStateHandler stateHandler);

@interface OPNWebSocketSignalingClient : NSObject
- (instancetype)initWithSignalingServer:(NSString *)signalingServer sessionId:(NSString *)sessionId signalingUrl:(NSString *)signalingUrl;
@property(nonatomic, copy, nullable) void (^onOffer)(NSString *sdp);
@property(nonatomic, copy, nullable) void (^onIceCandidate)(NSDictionary *candidate);
@property(nonatomic, copy, nullable) void (^onClosed)(BOOL clean, NSString *reason);
- (void)setPeerResolution:(NSString *)resolution;
- (void)connect:(void (^)(BOOL success, NSString *error))completion;
- (void)disconnect;
- (void)sendAnswerSdp:(NSString *)sdp nvstSdp:(NSString *)nvstSdp;
- (void)sendIceCandidate:(NSDictionary *)candidate;
@end

@interface OPNLocale : NSObject
+ (NSString *)currentGFNLocale;
@end

@interface OPNGFNError : NSObject
+ (NSString *)userFacingMessageForErrorMessage:(NSString *)errorMessage gameTitle:(NSString *)gameTitle;
+ (NSString *)userFacingMessageForErrorMessage:(NSString *)errorMessage gameTitle:(NSString *)gameTitle sessionWasConnected:(BOOL)sessionWasConnected;
@end

static constexpr NSInteger OPNMaxAutomaticRecoveryAttempts = 2;
static constexpr NSTimeInterval OPNStableRecoveryResetInterval = 15.0;
static constexpr NSTimeInterval OPNSignalingRemoteIceGraceInterval = 5.0;
static constexpr NSTimeInterval OPNStreamIdleDeviceInputInterval = 4.0 * 60.0;
static constexpr NSTimeInterval OPNStreamIdleDeviceInputReturnDelay = 0.25;
static constexpr NSTimeInterval OPNStreamInactivityTimeoutInterval = 10.0 * 60.0;
static constexpr NSTimeInterval OPNStreamInactivityCheckInterval = 5.0;
static constexpr NSTimeInterval OPNStreamQualityGuardrailCooldownInterval = 30.0;
static constexpr NSTimeInterval OPNStreamPlaytimeRefreshInterval = 10.0;
static constexpr int16_t OPNStreamIdleDeviceInputPulsePixels = 8;
static constexpr NSInteger OPNStreamQualityDegradedSampleThreshold = 3;
static constexpr int OPNStreamMinimumGuardrailBitrateMbps = 15;

static bool OPNStreamSessionReadyStatus(int status) {
    return status == 2 || status == 3;
}

static bool OPNStreamSessionLimitExceededError(const std::string &error) {
    return error.find("SESSION_LIMIT") != std::string::npos || error.find("\"statusCode\":11") != std::string::npos;
}

static bool OPNStreamSessionAuthenticationError(const std::string &error) {
    return error.find("HTTP 401") != std::string::npos ||
        error.find("HTTP 403") != std::string::npos ||
        error.find("AUTH_FAILURE") != std::string::npos ||
        error.find("auth_failure") != std::string::npos ||
        error.find("No access token") != std::string::npos;
}

static std::string OPNStreamQueueProgressMessage(int queuePosition) {
    if (queuePosition > 2) return std::to_string(queuePosition - 1) + " gamers ahead of you.";
    if (queuePosition == 2) return "1 gamer ahead of you.";
    if (queuePosition == 1) return "You're next in queue.";
    return "Waiting in queue...";
}

static std::string OPNStreamProgressMessageForSession(const OPN::SessionInfo &session) {
    if (session.adState.isAdsRequired) {
        if (!session.adState.message.empty()) return session.adState.message;
        return session.adState.isQueuePaused ? "Launch paused for ads." : "Watch the ad to continue.";
    }
    if (session.status == 6 || session.progressState == OPN::SessionProgressState::PreviousSessionCleanup) {
        return "Previous session is ending. Waiting for GeForce NOW to finish cleanup...";
    }
    switch (session.progressState) {
        case OPN::SessionProgressState::WaitingForStorage: return "Waiting for cloud storage to be ready...";
        case OPN::SessionProgressState::InQueue: return OPNStreamQueueProgressMessage(session.queuePosition);
        case OPN::SessionProgressState::Connecting: return "Connecting to GeForce NOW...";
        case OPN::SessionProgressState::SettingUp: return "Setting up cloud rig...";
        case OPN::SessionProgressState::Unknown: break;
        case OPN::SessionProgressState::PreviousSessionCleanup: break;
    }
    if (session.queuePosition > 0) return OPNStreamQueueProgressMessage(session.queuePosition);
    return "Waiting for cloud session...";
}

static void OPNStreamDispatchLaunchCompletion(const OPN::SessionCreateCallback &completion,
                                              bool success,
                                              const OPN::SessionInfo &session,
                                              const std::string &error) {
    if (!completion) return;
    OPN::SessionCreateCallback completionCopy = completion;
    OPN::SessionInfo sessionCopy = session;
    std::string errorCopy = error;
    dispatch_async(dispatch_get_main_queue(), ^{
        completionCopy(success, sessionCopy, errorCopy);
    });
}

static void OPNStreamReportLaunchProgress(const std::function<void(const std::string &, const OPN::SessionInfo &)> &progress,
                                          const OPN::SessionInfo &session) {
    if (!progress) return;
    auto progressCopy = progress;
    std::string message = OPNStreamProgressMessageForSession(session);
    OPN::SessionInfo sessionCopy = session;
    dispatch_async(dispatch_get_main_queue(), ^{
        progressCopy(message, sessionCopy);
    });
}

static void OPNStreamReportLaunchProgress(const std::function<void(const std::string &, const OPN::SessionInfo &)> &progress,
                                          const std::string &message) {
    if (!progress) return;
    auto progressCopy = progress;
    std::string messageCopy = message;
    dispatch_async(dispatch_get_main_queue(), ^{
        progressCopy(messageCopy, OPN::SessionInfo{});
    });
}

static void OPNStreamPollSessionReady(std::string sessionId,
                                      std::string serverIp,
                                      std::function<void(const std::string &, const OPN::SessionInfo &)> progress,
                                      OPN::SessionCreateCallback completion) {
    auto retries = std::make_shared<int>(0);
    auto pollBlock = std::make_shared<std::function<void()>>();
    *pollBlock = [=] {
        if (*retries >= 60) {
            OPNStreamDispatchLaunchCompletion(completion, false, OPN::SessionInfo{}, "Session poll timeout");
            return;
        }
        (*retries)++;
        OPN::OPNPollSession(sessionId, serverIp, [=](bool ok, const OPN::SessionInfo &info, const std::string &) {
            if (ok && OPNStreamSessionReadyStatus(info.status) && !info.serverIp.empty()) {
                OPNStreamReportLaunchProgress(progress, info);
                OPNStreamDispatchLaunchCompletion(completion, true, info, "");
                return;
            }
            if (ok) OPNStreamReportLaunchProgress(progress, info);
            if (ok && info.status > 3 && info.status != 6) {
                OPNStreamDispatchLaunchCompletion(completion, false, OPN::SessionInfo{}, "Session in terminal error state");
                return;
            }
            uint64_t delayNs = *retries <= 12 ? 300 * NSEC_PER_MSEC : (*retries <= 20 ? 500 * NSEC_PER_MSEC : NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
                if (*pollBlock) (*pollBlock)();
            });
        });
    };
    (*pollBlock)();
}

static bool OPNStreamTryUseExistingSession(const std::vector<OPN::ActiveSessionEntry> &sessions,
                                           const std::string &appId,
                                           std::function<void(const std::string &, const OPN::SessionInfo &)> progress,
                                           OPN::SessionCreateCallback completion) {
    int appIdNum = atoi(appId.c_str());
    for (const auto &session : sessions) {
        if (session.appId == appIdNum && OPNStreamSessionReadyStatus(session.status) && !session.serverIp.empty()) {
            OPNStreamPollSessionReady(session.sessionId, session.serverIp, progress, completion);
            return true;
        }
    }
    for (const auto &session : sessions) {
        if (OPNStreamSessionReadyStatus(session.status) && !session.sessionId.empty() && !session.serverIp.empty()) {
            OPNStreamPollSessionReady(session.sessionId, session.serverIp, progress, completion);
            return true;
        }
    }
    for (const auto &session : sessions) {
        if (session.status == 1 && !session.sessionId.empty() && !session.serverIp.empty()) {
            OPNStreamPollSessionReady(session.sessionId, session.serverIp, progress, completion);
            return true;
        }
    }
    return false;
}

static void OPNStreamCreateOrReuseSession(const std::string &appId,
                                          const std::string &gameTitle,
                                          const OPN::StreamSettings &settings,
                                          std::function<void(const std::string &, const OPN::SessionInfo &)> progress,
                                          OPN::SessionCreateCallback completion) {
    OPN::OPNGetActiveSessions([=](bool ok, const std::vector<OPN::ActiveSessionEntry> &sessions, const std::string &error) {
        if (ok && OPNStreamTryUseExistingSession(sessions, appId, progress, completion)) return;
        if (!ok && OPNStreamSessionAuthenticationError(error)) {
            OPNStreamDispatchLaunchCompletion(completion, false, OPN::SessionInfo{}, error);
            return;
        }
        OPN::OPNCreateSession(appId, gameTitle, settings, [=](bool success, const OPN::SessionInfo &info, const std::string &createError) {
            if (!success) {
                OPNStreamDispatchLaunchCompletion(completion, false, OPN::SessionInfo{}, createError);
                return;
            }
            OPNStreamReportLaunchProgress(progress, info);
            if (OPNStreamSessionReadyStatus(info.status) && !info.serverIp.empty()) {
                OPNStreamDispatchLaunchCompletion(completion, true, info, "");
                return;
            }
            OPNStreamPollSessionReady(info.sessionId, info.serverIp, progress, completion);
        });
    });
}

@interface OPNQuitGameOverlayView : NSView
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic, copy) void (^onQuit)(void);
@end

@interface OPNShortcutLegendView : NSView
@end

@interface OPNStatsOverlayView : NSView
- (NSSize)preferredSizeForMaxWidth:(CGFloat)maxWidth;
- (void)updateLatencyMs:(NSInteger)latencyMs
            bitrateMbps:(double)bitrateMbps
            packetsLost:(int64_t)packetsLost
             resolution:(NSString *)resolution
                    fps:(NSInteger)fps
              renderFps:(double)renderFps
                  codec:(NSString *)codec
            enhancement:(NSString *)enhancement
        framesDropped:(uint64_t)framesDropped;
@end

@interface OPNStreamViewController ()
@property (nonatomic, strong) OPNStreamView *streamView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) OPNLoadingView *loadingView;
@property (nonatomic, strong) OPNQuitGameOverlayView *quitOverlay;
@property (nonatomic, strong) OPNStatsOverlayView *statsOverlay;
@property (nonatomic, strong) OPNShortcutLegendView *shortcutLegendOverlay;
@property (nonatomic, strong) NSTimer *statsRefreshTimer;
@property (nonatomic, strong) NSTimer *playtimeRefreshTimer;
@property (nonatomic, strong) NSTimer *inactivityTimer;
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, copy) NSString *appId;
@property (nonatomic, copy) NSString *apiToken;
@property (nonatomic, copy) NSString *selectedStore;
@property (nonatomic, copy) NSString *resumeSessionId;
@property (nonatomic, copy) NSString *resumeServer;
@property (nonatomic, assign) BOOL accountLinked;
@property (nonatomic, assign) BOOL resumeExistingSession;
@property (nonatomic, assign) BOOL streamStarted;
@property (nonatomic, assign) BOOL launchSignpostActive;
@property (nonatomic, assign) CFTimeInterval launchStartTime;
@property (nonatomic, assign) os_signpost_id_t launchSignpostId;
- (void)finishLaunchMeasurementWithSuccess:(BOOL)success reason:(NSString *)reason;
- (NSString *)launchStatusMessageForStep:(NSInteger)stepIndex baseMessage:(NSString *)baseMessage;
- (void)resetQualityGuardrailsForBitrate:(int)bitrateMbps;
- (void)evaluateQualityGuardrailsWithStats:(OPNStreamStatsSnapshot *)stats;
- (void)showQualityGuardrailToastWithTitle:(NSString *)title detail:(NSString *)detail warning:(BOOL)warning;
- (void)recordStreamUserActivity;
- (void)startInactivityTimer;
- (void)stopInactivityTimer;
- (void)startPlaytimeRefreshTimer;
- (void)stopPlaytimeRefreshTimer;
- (void)refreshDisplayedPlaytimeFromSessionPoll;
- (void)refreshPlaytimeTimerFired:(NSTimer *)timer;
- (void)checkInactivityTimer:(NSTimer *)timer;
- (void)toggleIdleDeviceInputMode;
- (void)showAntiAFKNoticeEnabled:(BOOL)enabled;
- (void)sendRandomIdleDeviceInputIfNeededAtTime:(CFTimeInterval)now;
- (void)endStreamFromInactivityTimeout;
- (void)connectWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                        settings:(const OPN::StreamSettings &)settings
                launchGeneration:(NSUInteger)launchGeneration;
- (void)beginSessionAllocationWithSettings:(const OPN::StreamSettings &)settings
                             streamProfile:(const OPN::StreamPreferenceProfile &)streamProfile
                          streamingBaseUrl:(const std::string &)streamingBaseUrl
                          launchGeneration:(NSUInteger)launchGeneration
                          recoveringLaunch:(BOOL)recoveringLaunch;
- (void)refreshStreamViewLayoutForCurrentContainer;
- (void)configureStreamViewSessionCallbacks;
- (void)clearCurrentSessionCallbacks;
@end

static os_log_t OPNStreamPerformanceLog() {
    static os_log_t log = os_log_create("com.opennow.stream", "performance");
    return log;
}

static NSString *OPNStringFromStdString(const std::string &value, NSString *fallback = @"") {
    if (value.empty()) return fallback ?: @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: (fallback ?: @"");
}

static std::string OPNStdStringFromNSString(NSString *value) {
    return value.UTF8String ?: "";
}

static std::string OPNUserFacingGFNErrorMessage(const std::string &errorMessage,
                                                const std::string &gameTitle,
                                                BOOL sessionWasConnected = NO) {
    NSString *message = OPNStringFromStdString(errorMessage, @"");
    NSString *title = OPNStringFromStdString(gameTitle, @"");
    NSString *mapped = [OPNGFNError userFacingMessageForErrorMessage:message
                                                           gameTitle:title
                                                 sessionWasConnected:sessionWasConnected];
    return OPNStdStringFromNSString(mapped);
}

static std::string OPNUserFacingGFNErrorMessageForTitle(const std::string &errorMessage,
                                                        NSString *gameTitle,
                                                        BOOL sessionWasConnected = NO) {
    return OPNUserFacingGFNErrorMessage(errorMessage, OPNStdStringFromNSString(gameTitle), sessionWasConnected);
}

static BOOL OPNShouldReportTerminalStreamFailure(NSString *message) {
    if (message.length == 0) return YES;
    if ([message isEqualToString:@"Session ended due to inactivity."]) return NO;
    if ([message isEqualToString:@"Microphone permission denied"]) return NO;
    // AUTH_FAILURE_STATUS from NVIDIA (e.g. 4192C0FF) maps to "Your NVIDIA session expired".
    // This is an expected user-side condition (expired token); suppress Sentry noise.
    if ([message containsString:@"NVIDIA session expired"]) return NO;
    return YES;
}

static NSString *OPNBoundedStreamFailureMessage(NSString *message) {
    if (message.length <= 700) return message;
    return [[message substringToIndex:700] stringByAppendingString:@"..."];
}

static NSDictionary<NSString *, id> *OPNStreamMetricAttributes(NSString *outcome,
                                                                BOOL recovering,
                                                                NSString *backend,
                                                                NSString *codec,
                                                                NSString *resolution,
                                                                int fps) {
    return @{
        @"outcome": outcome.length > 0 ? outcome : @"unknown",
        @"recovery": @(recovering),
        @"backend": backend.length > 0 ? backend : @"unknown",
        @"codec": codec.length > 0 ? codec : @"unknown",
        @"resolution": resolution.length > 0 ? resolution : @"unknown",
        @"fps": @(fps),
    };
}

static NSString *OPNStreamFailureReportMessage(NSString *message) {
    if (message.length == 0) return @"Stream failed";
    NSRange jsonRange = [message rangeOfString:@"{"];
    if (jsonRange.location == NSNotFound) return OPNBoundedStreamFailureMessage(message);

    NSString *prefix = [[message substringToIndex:jsonRange.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *jsonText = [message substringFromIndex:jsonRange.location];
    NSData *jsonData = [jsonText dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return OPNBoundedStreamFailureMessage(message);

    NSDictionary *requestStatus = [json[@"requestStatus"] isKindOfClass:[NSDictionary class]] ? json[@"requestStatus"] : nil;
    NSNumber *statusCode = [requestStatus[@"statusCode"] isKindOfClass:[NSNumber class]] ? requestStatus[@"statusCode"] : nil;
    NSString *statusDescription = [requestStatus[@"statusDescription"] isKindOfClass:[NSString class]] ? requestStatus[@"statusDescription"] : nil;
    NSString *requestId = [requestStatus[@"requestId"] isKindOfClass:[NSString class]] ? requestStatus[@"requestId"] : nil;
    NSString *serverId = [requestStatus[@"serverId"] isKindOfClass:[NSString class]] ? requestStatus[@"serverId"] : nil;
    NSArray *otherSessions = [json[@"otherUserSessions"] isKindOfClass:[NSArray class]] ? json[@"otherUserSessions"] : nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (prefix.length > 0) [parts addObject:prefix];
    if (statusCode) [parts addObject:[NSString stringWithFormat:@"statusCode=%ld", (long)statusCode.integerValue]];
    if (statusDescription.length > 0) [parts addObject:[NSString stringWithFormat:@"description=%@", statusDescription]];
    if (serverId.length > 0) [parts addObject:[NSString stringWithFormat:@"serverId=%@", serverId]];
    if (requestId.length > 0) [parts addObject:[NSString stringWithFormat:@"requestId=%@", requestId]];
    if (otherSessions) [parts addObject:[NSString stringWithFormat:@"otherSessions=%lu", (unsigned long)otherSessions.count]];
    return parts.count > 0 ? [parts componentsJoinedByString:@" "] : OPNBoundedStreamFailureMessage(message);
}

struct OPNDisplayStreamProfile {
    int displayWidth = 1920;
    int displayHeight = 1080;
    int streamWidth = 1920;
    int streamHeight = 1080;
    std::string resolution = "1920x1080";
};

static NSSize CurrentDisplayPixelSize(NSWindow *window) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (!screen) {
        return NSMakeSize(1920.0, 1080.0);
    }

    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    if ([screenNumber isKindOfClass:[NSNumber class]]) {
        CGDirectDisplayID displayId = (CGDirectDisplayID)screenNumber.unsignedIntValue;
        size_t pixelWidth = CGDisplayPixelsWide(displayId);
        size_t pixelHeight = CGDisplayPixelsHigh(displayId);
        if (pixelWidth > 0 && pixelHeight > 0) {
            return NSMakeSize((CGFloat)pixelWidth, (CGFloat)pixelHeight);
        }
    }

    CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
    return NSMakeSize(NSWidth(screen.frame) * scale, NSHeight(screen.frame) * scale);
}

static OPNDisplayStreamProfile ResolveDisplayStreamProfile(NSWindow *window) {
    NSSize displayPixels = CurrentDisplayPixelSize(window);
    int displayWidth = std::max(640, (int)std::llround(displayPixels.width));
    int displayHeight = std::max(360, (int)std::llround(displayPixels.height));
    displayWidth -= displayWidth % 2;
    displayHeight -= displayHeight % 2;

    OPNDisplayStreamProfile profile;
    profile.displayWidth = displayWidth;
    profile.displayHeight = displayHeight;
    profile.streamWidth = displayWidth;
    profile.streamHeight = displayHeight;
    profile.resolution = std::to_string(displayWidth) + "x" + std::to_string(displayHeight);
    return profile;
}

static OPN::StreamResolutionOption OPNPowerSaverResolution(const OPN::StreamPreferenceProfile &profile) {
    double aspect = profile.AspectRatio();
    if (aspect <= 0.1 || !std::isfinite(aspect)) aspect = 16.0 / 9.0;

    int width = std::min(profile.resolution.width, 1280);
    int height = (int)std::llround((double)width / aspect);
    if (height > 800) {
        height = 800;
        width = (int)std::llround((double)height * aspect);
    }
    width = std::max(640, width - (width % 2));
    height = std::max(360, height - (height % 2));
    return {width, height};
}

static OPN::StreamResolutionOption OPNEffectiveStreamResolution(const OPN::StreamPreferenceProfile &profile,
                                                                 const OPNDisplayStreamProfile &displayProfile) {
    if (profile.enablePowerSaver) return OPNPowerSaverResolution(profile);

    const bool usingDefaultResolutionProfile = profile.aspectIndex == 1 && profile.resolutionIndex == 2;
    if (usingDefaultResolutionProfile && displayProfile.streamWidth > 0 && displayProfile.streamHeight > 0) {
        return {displayProfile.streamWidth, displayProfile.streamHeight};
    }
    return profile.resolution;
}

static double OPNAspectRatioForResolution(const OPN::StreamResolutionOption &resolution, double fallbackAspectRatio) {
    if (resolution.width <= 0 || resolution.height <= 0) return fallbackAspectRatio;
    double aspect = (double)resolution.width / (double)resolution.height;
    return std::isfinite(aspect) && aspect > 0.1 ? aspect : fallbackAspectRatio;
}

static int OPNEffectiveMaxBitrateMbps(const OPN::StreamPreferenceProfile &profile) {
    if (profile.enablePowerSaver) return std::min(profile.maxBitrateMbps, 15);
    return profile.maxBitrateMbps;
}

static BOOL OPNNetworkPreflightWarning(const OPN::StreamNetworkPreflightResult &preflight,
                                       int requestedMaxBitrateMbps,
                                       int effectiveMaxBitrateMbps,
                                       NSString **messageOut) {
    NSMutableArray<NSString *> *issues = [NSMutableArray array];
    BOOL hasMeasuredCondition = NO;
    if (preflight.latencyMs >= 150) {
        [issues addObject:[NSString stringWithFormat:@"Latency is very high (%d ms).", preflight.latencyMs]];
        hasMeasuredCondition = YES;
    } else if (preflight.latencyMs >= 80) {
        [issues addObject:[NSString stringWithFormat:@"Latency is elevated (%d ms).", preflight.latencyMs]];
        hasMeasuredCondition = YES;
    }
    if (preflight.measuredBandwidthMbps > 0.0 && preflight.measuredBandwidthMbps < requestedMaxBitrateMbps) {
        [issues addObject:[NSString stringWithFormat:@"Measured bandwidth is %.0f Mbps.", preflight.measuredBandwidthMbps]];
        hasMeasuredCondition = YES;
    }
    if (preflight.packetLossPercent >= 2.0) {
        [issues addObject:[NSString stringWithFormat:@"Packet loss is %.1f%%.", preflight.packetLossPercent]];
        hasMeasuredCondition = YES;
    }
    if (preflight.jitterMs >= 30) {
        [issues addObject:[NSString stringWithFormat:@"Jitter is %d ms.", preflight.jitterMs]];
        hasMeasuredCondition = YES;
    }
    if (effectiveMaxBitrateMbps > 0 && requestedMaxBitrateMbps > effectiveMaxBitrateMbps) {
        [issues addObject:[NSString stringWithFormat:@"OpenNOW lowered the stream bitrate from %d Mbps to %d Mbps for this route.", requestedMaxBitrateMbps, effectiveMaxBitrateMbps]];
        hasMeasuredCondition = YES;
    }
    if (preflight.serverReportedWarning && !preflight.warningMessage.empty()) {
        [issues addObject:OPNStringFromStdString(preflight.warningMessage, @"The network test reported a warning.")];
        hasMeasuredCondition = YES;
    }
    if (!preflight.continueRecommended && hasMeasuredCondition) {
        [issues addObject:@"The network test recommends cancelling this launch."];
    }
    if (issues.count == 0) return NO;

    NSString *networkType = preflight.networkType.empty() ? @"Unknown" : OPNStringFromStdString(preflight.networkType, @"Unknown");
    NSString *route = preflight.usedAutomaticRegion ? @"Automatic region" : @"Selected region";
    NSString *details = [issues componentsJoinedByString:@" "];
    if (messageOut) {
        *messageOut = [NSString stringWithFormat:@"%@ reported poor network conditions on %@ (%@). You can continue anyway, but the stream may stutter, drop quality, or disconnect.", route, networkType, details];
    }
    return YES;
}

static std::string OPNEffectiveStreamCodec(const OPN::StreamPreferenceProfile &profile,
                                              const OPN::StreamResolutionOption &resolution,
                                              const OPN::StreamDeviceCapabilities &capabilities) {
    return OPN::ResolveStreamCodecForCapabilities(profile, resolution, capabilities, [OPNStreamSessionHandle isBackendAvailable]);
}

static bool OPNStreamCodecSelectionIsExplicit(const OPN::StreamPreferenceProfile &profile) {
    std::string codec = profile.codec.value;
    std::transform(codec.begin(), codec.end(), codec.begin(), [](unsigned char value) {
        return (char)std::toupper(value);
    });
    return !codec.empty() && codec != "AUTO";
}

static uint32_t OPNConnectedControllerBitmap() {
    NSArray<GCController *> *controllers = GCController.controllers;
    uint32_t bitmap = 0;
    NSUInteger count = MIN([OPNStreamSessionHandle maxGamepadControllers], controllers.count);
    for (NSUInteger i = 0; i < count; i++) {
        if (!controllers[i].extendedGamepad) continue;
        bitmap |= (uint32_t)(1u << i);
        bitmap |= (uint32_t)(1u << (i + 8));
    }
    return bitmap;
}

static std::vector<std::string> OPNAvailableSupportedControllers() {
    return {};
}

static OPN::StreamSettings OPNSettingsWithNegotiatedProfile(OPN::StreamSettings settings, const OPN::SessionInfo &sessionInfo) {
    const OPN::NegotiatedStreamProfile &profile = sessionInfo.negotiatedStreamProfile;
    if (!profile.resolution.empty()) settings.resolution = profile.resolution;
    if (profile.fps > 0) settings.fps = profile.fps;
    if (!profile.codec.empty()) settings.codec = profile.codec;
    if (!profile.colorQuality.empty()) settings.colorQuality = profile.colorQuality;
    if (profile.prefilterMode >= 0) settings.prefilterMode = profile.prefilterMode;
    if (profile.prefilterSharpness >= 0) settings.prefilterSharpness = profile.prefilterSharpness;
    if (profile.prefilterDenoise >= 0) settings.prefilterDenoise = profile.prefilterDenoise;
    if (profile.prefilterModel >= 0) settings.prefilterModel = profile.prefilterModel;
    return settings;
}

static BOOL OPNIsCommandQEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"q"];
}

static BOOL OPNIsCommandNEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"n"];
}

static BOOL OPNIsCommandMEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"m"];
}

static BOOL OPNIsCommandGEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"g"];
}

static BOOL OPNIsCommandREvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"r"];
}

static BOOL OPNIsCommandHEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"h"];
}

static BOOL OPNIsCommandLEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"l"];
}

static BOOL OPNIsCommandKEvent(NSEvent *event) {
    if (!event || event.type != NSEventTypeKeyDown) return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    return (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"k"];
}

static std::string OPNLowercaseCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return value;
}

static BOOL OPNStreamErrorIsRecoverable(const std::string &error) {
    if (error.empty()) return NO;
    std::string lower = OPNLowercaseCopy(error);
    if (lower.find("invalid game id") != std::string::npos) return NO;
    if (lower.find("terminal error state") != std::string::npos) return NO;
    if (lower.find("401") != std::string::npos || lower.find("unauthorized") != std::string::npos) return NO;

    return lower.find("connection") != std::string::npos ||
           lower.find("webrtc") != std::string::npos ||
           lower.find("ice") != std::string::npos ||
           lower.find("signaling") != std::string::npos ||
           lower.find("timeout") != std::string::npos ||
           lower.find("stream connection lost") != std::string::npos;
}

static BOOL OPNResumeErrorShouldCreateFreshSession(const std::string &error) {
    return error.find("STALE_ACTIVE_SESSION") != std::string::npos ||
           error.find("Claim HTTP 400") != std::string::npos ||
           error.find("\"statusCode\":0") != std::string::npos ||
           error.find("8A8C0000") != std::string::npos;
}

static NSTimeInterval OPNRecoveryDelayForAttempt(NSInteger attempt) {
    static const NSTimeInterval delays[] = {0.0, 3.0};
    if (attempt <= 0) return delays[0];
    NSInteger index = MIN(attempt - 1, (NSInteger)(sizeof(delays) / sizeof(delays[0])) - 1);
    return delays[index];
}

static NSColor *OPNQuitColor(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}

static NSTextField *OPNQuitLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color, NSTextAlignment alignment) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.alignment = alignment;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    return label;
}

static void OPNStyleQuitButton(NSButton *button, NSColor *background, NSColor *textColor) {
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 10.0;
    button.layer.backgroundColor = background.CGColor;
    button.attributedTitle = [[NSAttributedString alloc] initWithString:button.title attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: textColor,
    }];
}

@implementation OPNQuitGameOverlayView {
    NSRect _cardFrame;
    NSTextField *_brandLabel;
    NSTextField *_eyebrowLabel;
    NSTextField *_titleLabel;
    NSTextField *_messageLabel;
    NSButton *_cancelButton;
    NSButton *_quitButton;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        _brandLabel = OPNQuitLabel(@"OpenNOW", 13.0, NSFontWeightSemibold,
                                   OPNQuitColor(0.72, 0.74, 0.78, 1.0), NSTextAlignmentLeft);
        _eyebrowLabel = OPNQuitLabel(@"Command-Q", 12.0, NSFontWeightMedium,
                                     OPNQuitColor(0.48, 0.50, 0.56, 1.0), NSTextAlignmentLeft);
        _titleLabel = OPNQuitLabel(@"End stream?", 24.0, NSFontWeightSemibold,
                                   OPNQuitColor(0.96, 0.96, 0.98, 1.0), NSTextAlignmentLeft);
        _messageLabel = OPNQuitLabel(@"Your stream will close and you will return to the library. Unsaved in-game progress may be lost.",
                                     13.0, NSFontWeightRegular,
                                     OPNQuitColor(0.66, 0.68, 0.73, 1.0), NSTextAlignmentLeft);
        _messageLabel.maximumNumberOfLines = 2;

        _cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelPressed:)];
        OPNStyleQuitButton(_cancelButton,
                           OPNQuitColor(0.20, 0.21, 0.24, 0.95),
                           OPNQuitColor(0.88, 0.89, 0.92, 1.0));
        _cancelButton.layer.borderWidth = 1.0;
        _cancelButton.layer.borderColor = OPNQuitColor(1.0, 1.0, 1.0, 0.10).CGColor;

        _quitButton = [NSButton buttonWithTitle:@"End Stream" target:self action:@selector(quitPressed:)];
        OPNStyleQuitButton(_quitButton,
                           OPNQuitColor(0.00, 0.48, 1.0, 1.0),
                           [NSColor whiteColor]);
        _quitButton.layer.shadowColor = OPNQuitColor(0.0, 0.0, 0.0, 1.0).CGColor;
        _quitButton.layer.shadowOpacity = 0.20;
        _quitButton.layer.shadowRadius = 12.0;
        _quitButton.layer.shadowOffset = CGSizeMake(0, -3);

        [self addSubview:_brandLabel];
        [self addSubview:_eyebrowLabel];
        [self addSubview:_titleLabel];
        [self addSubview:_messageLabel];
        [self addSubview:_cancelButton];
        [self addSubview:_quitButton];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
}

- (void)layout {
    [super layout];
    CGFloat cardW = MIN(460.0, MAX(320.0, NSWidth(self.bounds) - 80.0));
    CGFloat cardH = 236.0;
    _cardFrame = NSMakeRect(floor((NSWidth(self.bounds) - cardW) / 2.0),
                            floor((NSHeight(self.bounds) - cardH) / 2.0),
                            cardW,
                            cardH);
    CGFloat x = NSMinX(_cardFrame);
    CGFloat top = NSMaxY(_cardFrame);
    CGFloat padding = 28.0;
    _brandLabel.frame = NSMakeRect(x + padding, top - 43.0, 140.0, 18.0);
    _eyebrowLabel.frame = NSMakeRect(NSMaxX(_cardFrame) - padding - 82.0, top - 43.0, 82.0, 18.0);
    _titleLabel.frame = NSMakeRect(x + padding, top - 88.0, cardW - padding * 2.0, 30.0);
    _messageLabel.frame = NSMakeRect(x + padding, top - 134.0, cardW - padding * 2.0, 42.0);

    CGFloat buttonW = 124.0;
    CGFloat buttonY = NSMinY(_cardFrame) + 26.0;
    _quitButton.frame = NSMakeRect(NSMaxX(_cardFrame) - padding - buttonW, buttonY, buttonW, 42.0);
    _cancelButton.frame = NSMakeRect(NSMinX(_quitButton.frame) - 12.0 - buttonW, buttonY, buttonW, 42.0);
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.52] setFill];
    NSRectFill(self.bounds);

    NSGradient *veil = [[NSGradient alloc] initWithStartingColor:OPNQuitColor(0.12, 0.13, 0.16, 0.58)
                                                    endingColor:OPNQuitColor(0.04, 0.05, 0.06, 0.84)];
    [veil drawInRect:self.bounds angle:90.0];

    NSBezierPath *outer = [NSBezierPath bezierPathWithRoundedRect:_cardFrame xRadius:22.0 yRadius:22.0];
    [OPNQuitColor(1.0, 1.0, 1.0, 0.12) setFill];
    [outer fill];

    NSRect innerRect = NSInsetRect(_cardFrame, 1.0, 1.0);
    NSBezierPath *inner = [NSBezierPath bezierPathWithRoundedRect:innerRect xRadius:21.0 yRadius:21.0];
    NSGradient *card = [[NSGradient alloc] initWithStartingColor:OPNQuitColor(0.15, 0.16, 0.18, 0.96)
                                                    endingColor:OPNQuitColor(0.10, 0.11, 0.13, 0.96)];
    [card drawInBezierPath:inner angle:90.0];

    NSRect divider = NSMakeRect(NSMinX(_cardFrame) + 28.0, NSMinY(_cardFrame) + 78.0,
                                NSWidth(_cardFrame) - 56.0, 1.0);
    [OPNQuitColor(1.0, 1.0, 1.0, 0.08) setFill];
    NSRectFill(divider);
}

- (void)cancelPressed:(id)sender {
    (void)sender;
    if (self.onCancel) self.onCancel();
}

- (void)quitPressed:(id)sender {
    (void)sender;
    if (self.onQuit) self.onQuit();
}

- (void)keyDown:(NSEvent *)event {
    NSString *key = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    BOOL commandQ = (event.modifierFlags & NSEventModifierFlagCommand) && [key isEqualToString:@"q"];
    if (event.keyCode == 53) {
        if (self.onCancel) self.onCancel();
        return;
    }
    if (event.keyCode == 36 || commandQ) {
        if (self.onQuit) self.onQuit();
        return;
    }
    [super keyDown:event];
}

@end

@implementation OPNStatsOverlayView {
    NSTextField *_statsLineLabel;
}

static constexpr CGFloat OPNStatsOverlayMinWidth = 320.0;
static constexpr CGFloat OPNStatsOverlayMaxWidth = 620.0;
static constexpr CGFloat OPNStatsOverlayHorizontalPadding = 8.0;
static constexpr CGFloat OPNStatsOverlayVerticalPadding = 4.0;
static constexpr CGFloat OPNStatsOverlayMinHeight = 22.0;

static NSTextField *OPNStatsText(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color, NSTextAlignment alignment) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text ?: @"";
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.alignment = alignment;
    label.drawsBackground = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSAttributedString *OPNStatsOutlinedLine(NSString *text) {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentLeft;
    style.lineBreakMode = NSLineBreakByCharWrapping;
    return [[NSAttributedString alloc] initWithString:text ?: @""
                                            attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: OPNQuitColor(1.0, 0.86, 0.18, 1.0),
        NSStrokeColorAttributeName: OPNQuitColor(0.0, 0.0, 0.0, 1.0),
        NSStrokeWidthAttributeName: @-2.8,
        NSParagraphStyleAttributeName: style,
    }];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;

        _statsLineLabel = OPNStatsText(@"", 10.0, NSFontWeightMedium, NSColor.clearColor, NSTextAlignmentLeft);
        _statsLineLabel.lineBreakMode = NSLineBreakByCharWrapping;
        _statsLineLabel.maximumNumberOfLines = 0;
        _statsLineLabel.attributedStringValue = OPNStatsOutlinedLine(@"Stats: measuring");
        [self addSubview:_statsLineLabel];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

- (void)layout {
    [super layout];
    _statsLineLabel.frame = NSInsetRect(self.bounds, OPNStatsOverlayHorizontalPadding, OPNStatsOverlayVerticalPadding);
}

- (NSSize)preferredSizeForMaxWidth:(CGFloat)maxWidth {
    CGFloat availableMaxWidth = MAX(1.0, maxWidth - OPNStatsOverlayHorizontalPadding * 2.0);
    NSAttributedString *text = _statsLineLabel.attributedStringValue.length > 0
        ? _statsLineLabel.attributedStringValue
        : OPNStatsOutlinedLine(@"Stats: measuring");
    NSRect textBounds = [text boundingRectWithSize:NSMakeSize(availableMaxWidth, CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
    CGFloat contentWidth = ceil(NSWidth(textBounds));
    CGFloat contentHeight = ceil(NSHeight(textBounds));
    CGFloat width = MIN(maxWidth, MAX(OPNStatsOverlayMinWidth, contentWidth + OPNStatsOverlayHorizontalPadding * 2.0));
    CGFloat height = MAX(OPNStatsOverlayMinHeight, contentHeight + OPNStatsOverlayVerticalPadding * 2.0);
    return NSMakeSize(width, height);
}

- (void)updateLatencyMs:(NSInteger)latencyMs
            bitrateMbps:(double)bitrateMbps
            packetsLost:(int64_t)packetsLost
             resolution:(NSString *)resolution
                    fps:(NSInteger)fps
              renderFps:(double)renderFps
                  codec:(NSString *)codec
            enhancement:(NSString *)enhancement
             framesDropped:(uint64_t)framesDropped {
    NSString *latencyText = latencyMs >= 0 ? [NSString stringWithFormat:@"%ld ms", (long)latencyMs] : @"measuring";
    NSString *bitrateText = bitrateMbps >= 0.0 ? [NSString stringWithFormat:@"%.1f Mbps", bitrateMbps] : @"--";

    NSString *streamText = @"--";
    if (resolution.length > 0 && fps > 0) {
        streamText = [NSString stringWithFormat:@"%@@%ld", resolution, (long)fps];
    } else if (resolution.length > 0) {
        streamText = resolution;
    }
    if (codec.length > 0) {
        streamText = [NSString stringWithFormat:@"%@/%@", streamText, codec];
    }
    NSString *renderText = renderFps >= 0.0 ? [NSString stringWithFormat:@"%.0f fps", renderFps] : @"-- fps";
    NSString *enhancementText = enhancement.length > 0 ? enhancement : @"enh --";
    NSString *dropText = framesDropped > 0 ? [NSString stringWithFormat:@"drop %llu", (unsigned long long)framesDropped] : @"drop 0";
    NSString *lossText = packetsLost > 0 ? [NSString stringWithFormat:@"loss %lld", (long long)packetsLost] : @"loss 0";
    NSString *statsText = [NSString stringWithFormat:@"%@ | %@ | %@ | %@ | %@ | %@ | %@",
                           latencyText,
                           bitrateText,
                           streamText,
                           renderText,
                           enhancementText,
                           dropText,
                           lossText];
    _statsLineLabel.attributedStringValue = OPNStatsOutlinedLine(statsText);
}

@end

static void OPNUpdateLoadingViewAdState(OPNLoadingView *loadingView, const OPN::SessionAdState &adState) {
    if (!adState.isAdsRequired) {
        [loadingView clearAdPresentation];
        return;
    }

    NSString *chipText = adState.isQueuePaused ? @"Queue Paused" : @"Sponsored Break";
    NSString *title = @"Watch to continue";
    NSString *message = @"Your launch will resume automatically after the ad.";
    NSString *adId = @"";
    NSString *mediaUrl = @"";
    NSInteger durationMs = 30000;

    if (!adState.sessionAds.empty()) {
        const OPN::SessionAdInfo &ad = adState.sessionAds.front();
        title = ad.title.empty() ? @"Watch to continue" : [NSString stringWithUTF8String:ad.title.c_str()];
        message = adState.message.empty() ? @"Your launch will resume automatically after the ad." : [NSString stringWithUTF8String:adState.message.c_str()];
        adId = ad.adId.empty() ? @"ad" : [NSString stringWithUTF8String:ad.adId.c_str()];
        mediaUrl = ad.mediaUrl.empty() ? @"" : [NSString stringWithUTF8String:ad.mediaUrl.c_str()];
        durationMs = ad.durationMs > 0 ? ad.durationMs : (ad.adLengthInSeconds > 0 ? ad.adLengthInSeconds * 1000 : 30000);
    } else if (adState.isQueuePaused) {
        title = @"Paused for ads";
        if (!adState.message.empty()) {
            message = [NSString stringWithUTF8String:adState.message.c_str()];
        } else {
            message = adState.gracePeriodSeconds > 0 ? @"Resume before the grace period ends." : @"Resume ads to continue.";
        }
    } else {
        chipText = @"Ad Pending";
        title = @"Waiting for an ad";
        if (!adState.message.empty()) {
            message = [NSString stringWithUTF8String:adState.message.c_str()];
        } else {
            message = adState.serverSentEmptyAds
                ? @"GeForce NOW has not returned one yet. OpenNOW will keep checking."
                : @"GeForce NOW requires an ad before launch can continue.";
        }
    }

    [loadingView updateAdPresentationWithVisible:YES
                                        chipText:chipText ?: @"Sponsored Break"
                                           title:title ?: @"Watch to continue"
                                         message:message ?: @"Your launch will resume automatically after the ad."
                                            adId:adId ?: @""
                                        mediaUrl:mediaUrl ?: @""
                                      durationMs:durationMs];
}

@implementation OPNStreamViewController {
    OPNWebSocketSignalingClient *_signaling;
    OPNStreamSessionHandle *_session;
    NSRect _initialViewFrame;
    id _quitKeyMonitor;
    BOOL _streamEnded;
    BOOL _remoteIceReceived;
    BOOL _connectedOnce;
    BOOL _recovering;
    NSInteger _recoveryAttempt;
    NSUInteger _launchGeneration;
    NSUInteger _stableResetGeneration;
    void *_remoteIceGraceTimer;
    NSString *_webRTCBackendName;
    OPN::SessionInfo _activeSessionInfo;
    BOOL _hasActiveSessionInfo;
    BOOL _remoteStopRequested;
    NSView *_connectedToast;
    id _latencyActivity;
    CFTimeInterval _lastStreamActivityTime;
    CFTimeInterval _lastIdleDeviceInputTime;
    CFTimeInterval _launchFlowStartTime;
    CFTimeInterval _connectedStartTime;
    CFTimeInterval _lastMetricsSampleTime;
    CFTimeInterval _lastQualityGuardrailChangeTime;
    NSInteger _qualityDegradedSampleCount;
    BOOL _qualityWarningShown;
    int _runtimeMaxBitrateMbps;
    BOOL _idleDeviceInputEnabled;
    double _remainingPlaytimeHours;
    BOOL _remainingPlaytimeUnlimited;
    BOOL _remainingPlaytimeAvailable;
    BOOL _playtimeRefreshInFlight;
    BOOL _healthReportStarted;
    OPNSentryTransactionBridge *_streamLaunchTrace;
    OPNSessionHealthReportBuilder *_healthReport;
}

- (instancetype)initWithGameTitle:(NSString *)title
                             appId:(NSString *)appId
                          apiToken:(NSString *)token
                     accountLinked:(BOOL)accountLinked
                      selectedStore:(NSString *)selectedStore {
    return [self initWithGameTitle:title
                             appId:appId
                          apiToken:token
                     accountLinked:accountLinked
                      selectedStore:selectedStore
                   resumeSessionId:@""
                       resumeServer:@""];
}

- (instancetype)initWithGameTitle:(NSString *)title
                             appId:(NSString *)appId
                          apiToken:(NSString *)token
                     accountLinked:(BOOL)accountLinked
                     selectedStore:(NSString *)selectedStore
                   resumeSessionId:(NSString *)resumeSessionId
                       resumeServer:(NSString *)resumeServer {
    self = [super init];
    if (self) {
        _gameTitle = [title copy] ?: @"";
        _appId = [appId copy] ?: @"";
        _apiToken = [token copy] ?: @"";
        _accountLinked = accountLinked;
        _selectedStore = [selectedStore copy] ?: @"";
        _resumeSessionId = [resumeSessionId copy] ?: @"";
        _resumeServer = [resumeServer copy] ?: @"";
        _resumeExistingSession = _resumeSessionId.length > 0 && _resumeServer.length > 0;
        _session = [[OPNStreamSessionHandle alloc] init];
        _webRTCBackendName = @"libwebrtc";
        OPNLogInfo(@"[StreamVC] WebRTC backend selected: libwebrtc");
        _initialViewFrame = NSMakeRect(0, 0, 1, 1);
        _signaling = nil;
        _streamStarted = NO;
        _streamEnded = NO;
        _remoteIceReceived = NO;
        _connectedOnce = NO;
        _recovering = NO;
        _hasActiveSessionInfo = NO;
        _remoteStopRequested = NO;
        _recoveryAttempt = 0;
        _launchGeneration = 0;
        _stableResetGeneration = 0;
        _remoteIceGraceTimer = nullptr;
        _connectedToast = nil;
        _latencyActivity = nil;
        _lastStreamActivityTime = 0;
        _lastIdleDeviceInputTime = 0;
        _launchFlowStartTime = 0;
        _connectedStartTime = 0;
        _lastMetricsSampleTime = 0;
        _lastQualityGuardrailChangeTime = 0;
        _qualityDegradedSampleCount = 0;
        _qualityWarningShown = NO;
        _runtimeMaxBitrateMbps = 0;
        _idleDeviceInputEnabled = NO;
        _remainingPlaytimeHours = 0.0;
        _remainingPlaytimeUnlimited = NO;
        _remainingPlaytimeAvailable = NO;
        _playtimeRefreshInFlight = NO;
        _healthReportStarted = NO;
        _healthReport = [[OPNSessionHealthReportBuilder alloc] init];
    }
    return self;
}

- (void)setRemainingPlaytimeHours:(double)hours unlimited:(BOOL)unlimited {
    _remainingPlaytimeUnlimited = unlimited;
    _remainingPlaytimeAvailable = unlimited || (std::isfinite(hours) && hours >= 0.0);
    _remainingPlaytimeHours = _remainingPlaytimeAvailable && !unlimited ? MAX(0.0, hours) : 0.0;
    if (self.streamView) {
        [self.streamView setRemainingPlaytimeHours:_remainingPlaytimeHours unlimited:_remainingPlaytimeUnlimited];
    }
}

- (void)startStreamIfNeeded {
    if (_streamStarted || _streamEnded) return;
    _streamStarted = YES;
    [self startStreamLaunchFlow];
}

- (void)setInitialViewFrame:(NSRect)frame {
    if (NSWidth(frame) <= 0 || NSHeight(frame) <= 0) return;
    _initialViewFrame = frame;
    if (self.isViewLoaded) {
        self.view.frame = frame;
    }
}

- (void)loadView {
    OPNStreamView *view = [[OPNStreamView alloc] initWithFrame:_initialViewFrame];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = view;
    self.streamView = view;
    __weak __typeof__(self) weakSelf = self;
    view.onUserActivity = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded) return;
        [strongSelf recordStreamUserActivity];
    };
    view.onDashboardToggleRequested = ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded) return;
        if (strongSelf.onDashboardToggleRequested) strongSelf.onDashboardToggleRequested();
    };
    view.onSidebarHUDVisibilityChanged = ^(BOOL visible) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded || !strongSelf->_connectedOnce) return;
        if (visible) {
            [strongSelf refreshDisplayedPlaytimeFromSessionPoll];
            [strongSelf startPlaytimeRefreshTimer];
        } else {
            [strongSelf stopPlaytimeRefreshTimer];
        }
    };
    [self configureStreamViewSessionCallbacks];
    [self.streamView setRecordingGameTitle:_gameTitle.length > 0 ? _gameTitle : @"Stream"];
    if (_remainingPlaytimeAvailable) {
        [self.streamView setRemainingPlaytimeHours:_remainingPlaytimeHours unlimited:_remainingPlaytimeUnlimited];
    }
    OPNLogInfo(@"[StreamVC] loadView called, view=%p", (__bridge void *)view);
}

- (void)clearCurrentSessionCallbacks {
    [self.streamView clearStreamCallbacks];
    OPNClearStreamSessionCallbacks(static_cast<OPN::IStreamSession *>(_session.rawSession));
}

- (void)configureStreamViewSessionCallbacks {
    OPNConfigureStreamViewSessionCallbacks(static_cast<OPN::IStreamSession *>(_session.rawSession), self.streamView, self.streamView.recordingManager);
}

- (void)refreshStreamViewLayoutForCurrentContainer {
    NSView *container = self.view.superview;
    if (container && NSWidth(container.bounds) > 0.0 && NSHeight(container.bounds) > 0.0) {
        self.view.frame = container.bounds;
    }
    self.streamView.frame = self.view.bounds;
    [self.view setNeedsLayout:YES];
    [self.streamView setNeedsLayout:YES];
    [self.view layoutSubtreeIfNeeded];
}

- (void)setStreamInputSuppressed:(BOOL)suppressed {
    [self.streamView setStreamInputSuppressed:suppressed];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    OPNLogInfo(@"[StreamVC] viewDidLoad called");

    NSRect bounds = self.view.bounds;
    OPNLogInfo(@"[StreamVC] view bounds: %@", NSStringFromRect(bounds));

    self.loadingView = [[OPNLoadingView alloc] initWithFrame:[self loadingViewFrame]
                                                     message:@"Starting session..."];
    self.loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.loadingView setSteps:@[@"Check network route",
                                 @"Allocate cloud session",
                                 @"Connect to game server",
                                 @"Receive stream offer",
                                 @"Negotiate WebRTC",
                                 @"Start video pipeline",
                                 @"Connected"]
                   currentStepIndex:-1];
    [self.view addSubview:self.loadingView];
    self.statusLabel = self.loadingView.messageLabel;
    [self configureLoadingViewAdHandler];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (self.view.superview && !NSEqualRects(self.view.frame, self.view.superview.bounds)) {
        [self refreshStreamViewLayoutForCurrentContainer];
    }
    if (self.statsOverlay) {
        self.statsOverlay.frame = [self statsOverlayFrame];
    }
    if (self.shortcutLegendOverlay) {
        self.shortcutLegendOverlay.frame = [self shortcutLegendFrame];
    }
    if (self.loadingView) {
        self.loadingView.frame = [self loadingViewFrame];
    }
}

- (void)viewWillAppear {
    [super viewWillAppear];
    OPNLogInfo(@"[StreamVC] viewWillAppear called");
}

- (void)viewDidAppear {
    [super viewDidAppear];
    OPNLogInfo(@"[StreamVC] viewDidAppear called, streamStarted=%d, streamEnded=%d", _streamStarted, _streamEnded);
    [self installQuitShortcutMonitor];
    if (!_streamStarted && !_streamEnded) {
        OPNLogInfo(@"[StreamVC] Triggering startStreamLaunchFlow");
        [self startStreamIfNeeded];
    }
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self removeQuitShortcutMonitor];
}

- (void)setStatus:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.loadingView) {
            self.loadingView.message = msg;
        }
        if (self.statusLabel) {
            self.statusLabel.stringValue = msg;
        }
    });
}

- (NSRect)loadingViewFrame {
    return self.view.bounds;
}

- (NSString *)launchStatusMessageForStep:(NSInteger)stepIndex baseMessage:(NSString *)baseMessage {
    NSString *safeMessage = baseMessage.length > 0 ? baseMessage : @"Starting session...";
    if (_launchFlowStartTime <= 0.0) return safeMessage;

    CFTimeInterval elapsed = MAX(0.0, CACurrentMediaTime() - _launchFlowStartTime);
    NSString *phase = @"Launch";
    switch (stepIndex) {
        case 0: phase = @"Network"; break;
        case 1: phase = @"Session"; break;
        case 2: phase = @"Server"; break;
        case 3: phase = @"Offer"; break;
        case 4: phase = @"WebRTC"; break;
        case 5: phase = @"Video"; break;
        case 6: phase = @"Ready"; break;
        default: break;
    }

    NSString *retryText = _recovering
        ? [NSString stringWithFormat:@" · retry %ld/%ld", (long)_recoveryAttempt, (long)OPNMaxAutomaticRecoveryAttempts]
        : @"";
    return [NSString stringWithFormat:@"%@ · %@ · %.0fs%@", phase, safeMessage, elapsed, retryText];
}

- (void)setLaunchStep:(NSInteger)stepIndex message:(NSString *)message {
    const char *phase = "Launch";
    switch (stepIndex) {
        case 0: phase = "Network Preflight"; break;
        case 1: phase = "Allocate Session"; break;
        case 2: phase = "Connect Server"; break;
        case 3: phase = "Signaling"; break;
        case 4: phase = "WebRTC"; break;
        case 5: phase = "Video Pipeline"; break;
        case 6: phase = "Connected"; break;
        default: break;
    }
    [_healthReport markPhase:[NSString stringWithUTF8String:phase] ?: @"" now:CACurrentMediaTime()];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *statusMessage = [self launchStatusMessageForStep:stepIndex baseMessage:message];
        if (self.loadingView) {
            if (stepIndex >= self.loadingView.currentStepIndex) {
                [self.loadingView advanceToStep:stepIndex message:statusMessage];
            }
        }
        if (self.statusLabel) {
            self.statusLabel.stringValue = statusMessage;
        }
    });
}

- (void)configureLoadingViewAdHandler {
    if (!self.loadingView) return;
    __weak __typeof__(self) weakSelf = self;
    self.loadingView.adPlaybackEventHandler = ^(NSString *adId, NSString *action, NSInteger watchedTimeInMs, NSInteger pausedTimeInMs, NSString *cancelReason) {
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded || !strongSelf->_hasActiveSessionInfo) return;
        std::string adIdString = adId.length > 0 ? [adId UTF8String] : "";
        std::string actionString = action.length > 0 ? [action UTF8String] : "";
        std::string cancelReasonString = cancelReason.length > 0 ? [cancelReason UTF8String] : "";
        OPN::SessionInfo sessionInfo = strongSelf->_activeSessionInfo;
        OPN::OPNReportSessionAd(sessionInfo,
                                adIdString,
                                actionString,
                                (int)watchedTimeInMs,
                                (int)pausedTimeInMs,
                                cancelReasonString,
                                [weakSelf](bool ok, const OPN::SessionInfo &updatedInfo, const std::string &error) {
            __typeof__(self) callbackSelf = weakSelf;
            if (!callbackSelf || callbackSelf->_streamEnded) return;
            if (!ok) {
                OPNLogError(@"[StreamVC] Ad report failed: %s", error.c_str());
                return;
            }
            OPN::SessionInfo updatedInfoCopy = updatedInfo;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!callbackSelf || callbackSelf->_streamEnded || !callbackSelf.loadingView) return;
                if (!updatedInfoCopy.sessionId.empty()) {
                    callbackSelf->_activeSessionInfo = updatedInfoCopy;
                    callbackSelf->_hasActiveSessionInfo = YES;
                }
                OPNUpdateLoadingViewAdState(callbackSelf.loadingView, updatedInfoCopy.adState);
            });
        });
    };
}

- (void)updateLaunchAdState:(const OPN::SessionInfo &)sessionInfo {
    OPN::SessionInfo sessionInfoCopy = sessionInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.loadingView || self->_streamEnded) return;
        if (!sessionInfoCopy.sessionId.empty()) {
            self->_activeSessionInfo = sessionInfoCopy;
            self->_hasActiveSessionInfo = YES;
        }
        NSInteger visibleQueuePosition = sessionInfoCopy.progressState == OPN::SessionProgressState::InQueue
            ? sessionInfoCopy.queuePosition
            : 0;
        [self.loadingView updateQueuePosition:visibleQueuePosition];
        if (sessionInfoCopy.adState.isAdsRequired) {
            OPNUpdateLoadingViewAdState(self.loadingView, sessionInfoCopy.adState);
        } else {
            [self.loadingView clearAdPresentation];
        }
    });
}

- (void)finishLaunchMeasurementWithSuccess:(BOOL)success reason:(NSString *)reason {
    NSString *safeReason = reason.length > 0 ? reason : @"unknown";
    CFTimeInterval elapsedMs = self.launchSignpostActive ? (CACurrentMediaTime() - self.launchStartTime) * 1000.0 : 0.0;
    if (elapsedMs > 0.0) {
        OPNRecordSentryDistributionMetric("opennow.stream.launch.duration", elapsedMs, "millisecond", @{
            @"outcome": success ? @"success" : @"failure",
            @"reason": safeReason,
            @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
            @"recovery": @(_recovering),
        });
    }
    if (_streamLaunchTrace && ![safeReason isEqualToString:@"stale-resume"]) {
        [_streamLaunchTrace setData:@"reason" value:safeReason];
        [_streamLaunchTrace setStatus:success];
        [_streamLaunchTrace finish];
        _streamLaunchTrace = nil;
    }
    if (!self.launchSignpostActive) return;
    self.launchSignpostActive = NO;
    os_signpost_interval_end(OPNStreamPerformanceLog(),
                             self.launchSignpostId,
                             "StreamLaunch",
                             "success=%{public}s elapsed_ms=%.1f reason=%{public}@",
                             success ? "yes" : "no",
                             elapsedMs,
                             safeReason);
    OPNLogInfo(@"[StreamVC] Stream launch measurement success=%d elapsed=%.1fms reason=%@", success, elapsedMs, safeReason);
}

- (void)installQuitShortcutMonitor {
    if (_quitKeyMonitor) return;
    __weak __typeof__(self) weakSelf = self;
	_quitKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
	                                                            handler:^NSEvent *(NSEvent *event) {
	    __typeof__(self) strongSelf = weakSelf;
	    if (!strongSelf || strongSelf->_streamEnded) return event;
	    if (!strongSelf.view.window || event.window != strongSelf.view.window) return event;
	    if (OPNIsCommandQEvent(event)) {
	        [strongSelf requestQuitGameConfirmation];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandNEvent(event)) {
	        [strongSelf toggleStatsOverlay];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandMEvent(event)) {
	        [strongSelf.streamView toggleMicrophoneEnabledShortcut];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandGEvent(event)) {
	        [strongSelf.streamView toggleSidebarHUD];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandREvent(event)) {
	        [strongSelf.streamView toggleRecordingShortcut];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandHEvent(event)) {
	        [strongSelf toggleShortcutLegendOverlay];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandLEvent(event)) {
	        [strongSelf copyCurrentLogToClipboardFromShortcut];
	        return (NSEvent *)nil;
	    }
	    if (OPNIsCommandKEvent(event)) {
	        [strongSelf toggleIdleDeviceInputMode];
	        return (NSEvent *)nil;
	    }
	    return event;
	}];
}

- (NSRect)statsOverlayFrame {
    CGFloat maxWidth = MIN(OPNStatsOverlayMaxWidth, MAX(1.0, NSWidth(self.view.bounds) - 32.0));
    NSSize size = self.statsOverlay
        ? [self.statsOverlay preferredSizeForMaxWidth:maxWidth]
        : NSMakeSize(MIN(OPNStatsOverlayMinWidth, maxWidth), OPNStatsOverlayMinHeight);
    CGFloat x = MAX(16.0, NSWidth(self.view.bounds) - size.width - 16.0);
    CGFloat y = MAX(8.0, floor(NSHeight(self.view.bounds) - size.height - 8.0));
    return NSMakeRect(x, y, size.width, size.height);
}

- (void)showConnectedToastWithResolution:(NSString *)resolution
                                      fps:(int)fps
                                  bitrate:(int)bitrateMbps
                                    codec:(NSString *)codec {
    [_connectedToast removeFromSuperview];

    CGFloat width = MIN(360.0, MAX(286.0, NSWidth(self.view.bounds) - 36.0));
    NSView *toast = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(self.view.bounds) - width) / 2.0),
                                                             24.0,
                                                             width,
                                                             76.0)];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 18.0;
    toast.layer.backgroundColor = OPNQuitColor(0.05, 0.07, 0.06, 0.86).CGColor;
    toast.layer.borderWidth = 1.0;
    toast.layer.borderColor = OPNQuitColor(0.35, 0.95, 0.56, 0.24).CGColor;
    toast.alphaValue = 0.0;

    NSTextField *title = OPNStatsText(@"Stream Connected", 14.0, NSFontWeightSemibold, OPNQuitColor(0.92, 1.0, 0.94, 1.0), NSTextAlignmentCenter);
    title.frame = NSMakeRect(18.0, 14.0, width - 36.0, 20.0);
    [toast addSubview:title];

    NSString *detail = [NSString stringWithFormat:@"%@ • %@ • %d fps • %d Mbps",
                        _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
                        codec.length > 0 ? codec : @"unknown",
                        fps,
                        bitrateMbps];
    if (resolution.length > 0) {
        detail = [NSString stringWithFormat:@"%@ • %@", detail, resolution];
    }
    NSTextField *subtitle = OPNStatsText(detail, 11.0, NSFontWeightMedium, OPNQuitColor(0.78, 0.84, 0.78, 1.0), NSTextAlignmentCenter);
    subtitle.frame = NSMakeRect(18.0, 40.0, width - 36.0, 18.0);
    [toast addSubview:subtitle];

    _connectedToast = toast;
    [self.view addSubview:toast positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        toast.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self->_connectedToast != toast) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.25;
                toast.animator.alphaValue = 0.0;
            } completionHandler:^{
                if (self->_connectedToast == toast) self->_connectedToast = nil;
                [toast removeFromSuperview];
            }];
        });
    }];
}

- (NSRect)shortcutLegendFrame {
    CGFloat width = MIN(328.0, MAX(276.0, NSWidth(self.view.bounds) - 36.0));
    CGFloat height = 338.0;
    return NSMakeRect(floor(NSWidth(self.view.bounds) - width - 18.0),
                      floor((NSHeight(self.view.bounds) - height) / 2.0),
                      width,
                      height);
}

- (void)showLogCopiedToast {
    [_connectedToast removeFromSuperview];

    CGFloat width = MIN(340.0, MAX(276.0, NSWidth(self.view.bounds) - 36.0));
    NSView *toast = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(self.view.bounds) - width) / 2.0),
                                                             24.0,
                                                             width,
                                                             64.0)];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 16.0;
    toast.layer.backgroundColor = OPNQuitColor(0.05, 0.07, 0.06, 0.88).CGColor;
    toast.layer.borderWidth = 1.0;
    toast.layer.borderColor = OPNQuitColor(0.55, 0.76, 1.0, 0.30).CGColor;
    toast.alphaValue = 0.0;

    NSTextField *title = OPNStatsText(@"Log Copied", 14.0, NSFontWeightSemibold, OPNQuitColor(0.92, 0.96, 1.0, 1.0), NSTextAlignmentCenter);
    title.frame = NSMakeRect(18.0, 11.0, width - 36.0, 20.0);
    [toast addSubview:title];

    NSTextField *subtitle = OPNStatsText(@"Current OpenNOW log is on the clipboard", 11.0, NSFontWeightMedium, OPNQuitColor(0.78, 0.84, 0.88, 1.0), NSTextAlignmentCenter);
    subtitle.frame = NSMakeRect(18.0, 34.0, width - 36.0, 18.0);
    [toast addSubview:subtitle];

    _connectedToast = toast;
    [self.view addSubview:toast positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
        toast.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self->_connectedToast != toast) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                toast.animator.alphaValue = 0.0;
            } completionHandler:^{
                if (self->_connectedToast == toast) self->_connectedToast = nil;
                [toast removeFromSuperview];
            }];
        });
    }];
}

- (void)showAntiAFKNoticeEnabled:(BOOL)enabled {
    [_connectedToast removeFromSuperview];

    CGFloat width = MIN(320.0, MAX(260.0, NSWidth(self.view.bounds) - 36.0));
    NSView *toast = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(self.view.bounds) - width) / 2.0),
                                                             24.0,
                                                             width,
                                                             58.0)];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 16.0;
    toast.layer.backgroundColor = OPNQuitColor(0.05, 0.07, 0.06, 0.88).CGColor;
    toast.layer.borderWidth = 1.0;
    toast.layer.borderColor = (enabled ? OPNQuitColor(0.35, 0.95, 0.56, 0.30) : OPNQuitColor(0.95, 0.68, 0.35, 0.30)).CGColor;
    toast.alphaValue = 0.0;

    NSString *titleText = enabled ? @"Anti-AFK Enabled" : @"Anti-AFK Disabled";
    NSColor *titleColor = enabled ? OPNQuitColor(0.88, 1.0, 0.92, 1.0) : OPNQuitColor(1.0, 0.90, 0.78, 1.0);
    NSTextField *title = OPNStatsText(titleText, 15.0, NSFontWeightSemibold, titleColor, NSTextAlignmentCenter);
    title.frame = NSMakeRect(18.0, 19.0, width - 36.0, 20.0);
    [toast addSubview:title];

    _connectedToast = toast;
    [self.view addSubview:toast positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
        toast.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self->_connectedToast != toast) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                toast.animator.alphaValue = 0.0;
            } completionHandler:^{
                if (self->_connectedToast == toast) self->_connectedToast = nil;
                [toast removeFromSuperview];
            }];
        });
    }];
}

- (void)showQualityGuardrailToastWithTitle:(NSString *)title detail:(NSString *)detail warning:(BOOL)warning {
    [_connectedToast removeFromSuperview];

    CGFloat width = MIN(420.0, MAX(300.0, NSWidth(self.view.bounds) - 36.0));
    CGFloat height = detail.length > 0 ? 78.0 : 58.0;
    NSView *toast = [[NSView alloc] initWithFrame:NSMakeRect(floor((NSWidth(self.view.bounds) - width) / 2.0),
                                                             24.0,
                                                             width,
                                                             height)];
    toast.wantsLayer = YES;
    toast.layer.cornerRadius = 16.0;
    toast.layer.backgroundColor = OPNQuitColor(0.05, 0.07, 0.06, 0.90).CGColor;
    toast.layer.borderWidth = 1.0;
    toast.layer.borderColor = (warning ? OPNQuitColor(1.0, 0.72, 0.34, 0.36) : OPNQuitColor(0.35, 0.95, 0.56, 0.30)).CGColor;
    toast.alphaValue = 0.0;

    NSColor *titleColor = warning ? OPNQuitColor(1.0, 0.91, 0.76, 1.0) : OPNQuitColor(0.88, 1.0, 0.92, 1.0);
    NSTextField *titleLabel = OPNStatsText(title ?: @"Stream quality adjusted", 14.0, NSFontWeightSemibold, titleColor, NSTextAlignmentCenter);
    titleLabel.frame = NSMakeRect(18.0, detail.length > 0 ? 13.0 : 19.0, width - 36.0, 20.0);
    [toast addSubview:titleLabel];

    if (detail.length > 0) {
        NSTextField *detailLabel = OPNStatsText(detail, 11.0, NSFontWeightMedium, OPNQuitColor(0.78, 0.84, 0.78, 1.0), NSTextAlignmentCenter);
        detailLabel.frame = NSMakeRect(18.0, 39.0, width - 36.0, 18.0);
        [toast addSubview:detailLabel];
    }

    _connectedToast = toast;
    [self.view addSubview:toast positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.16;
        toast.animator.alphaValue = 1.0;
    } completionHandler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self->_connectedToast != toast) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
                context.duration = 0.22;
                toast.animator.alphaValue = 0.0;
            } completionHandler:^{
                if (self->_connectedToast == toast) self->_connectedToast = nil;
                [toast removeFromSuperview];
            }];
        });
    }];
}

- (void)resetQualityGuardrailsForBitrate:(int)bitrateMbps {
    _runtimeMaxBitrateMbps = std::max(0, bitrateMbps);
    _qualityDegradedSampleCount = 0;
    _lastQualityGuardrailChangeTime = 0.0;
    _qualityWarningShown = NO;
}

- (void)evaluateQualityGuardrailsWithStats:(OPNStreamStatsSnapshot *)stats {
    if (_streamEnded || !_connectedOnce || _recovering || !stats.available || _runtimeMaxBitrateMbps <= 0) return;

    const double targetFps = stats.fps > 0 ? (double)stats.fps : 60.0;
    const bool highLatency = stats.latencyMs >= 115.0;
    const bool highJitter = stats.jitterMs >= 28.0;
    const bool packetLoss = stats.packetLossPercent >= 1.0;
    const bool droppedFrames = stats.framesReceived > 0 && stats.framesDropped >= 6;
    const bool renderSlow = stats.renderFps > 0.0 && stats.renderFps < targetFps * 0.82;
    const bool decodeSlow = stats.decodeTimeMs >= (1000.0 / targetFps) * 0.95;
    const bool degraded = highLatency || highJitter || packetLoss || droppedFrames || renderSlow || decodeSlow;

    if (!degraded) {
        _qualityDegradedSampleCount = MAX((NSInteger)0, _qualityDegradedSampleCount - 1);
        return;
    }

    _qualityDegradedSampleCount = MIN(_qualityDegradedSampleCount + 1, (NSInteger)10);
    if (_qualityDegradedSampleCount < OPNStreamQualityDegradedSampleThreshold) return;

    NSMutableArray<NSString *> *signals = [NSMutableArray array];
    if (highLatency) [signals addObject:[NSString stringWithFormat:@"latency %.0f ms", stats.latencyMs]];
    if (highJitter) [signals addObject:[NSString stringWithFormat:@"jitter %.0f ms", stats.jitterMs]];
    if (packetLoss) [signals addObject:[NSString stringWithFormat:@"loss %.1f%%", stats.packetLossPercent]];
    if (renderSlow) [signals addObject:[NSString stringWithFormat:@"render %.0f fps", stats.renderFps]];
    if (decodeSlow) [signals addObject:[NSString stringWithFormat:@"decode %.1f ms", stats.decodeTimeMs]];
    if (droppedFrames) [signals addObject:[NSString stringWithFormat:@"%llu dropped", stats.framesDropped]];

    CFTimeInterval now = CACurrentMediaTime();
    BOOL cooldownElapsed = _lastQualityGuardrailChangeTime <= 0.0 || now - _lastQualityGuardrailChangeTime >= OPNStreamQualityGuardrailCooldownInterval;
    int reducedBitrate = MAX(OPNStreamMinimumGuardrailBitrateMbps, (int)std::floor((double)_runtimeMaxBitrateMbps * 0.80));
    NSString *signalText = [signals componentsJoinedByString:@", "];
    if (cooldownElapsed && reducedBitrate < _runtimeMaxBitrateMbps) {
        _runtimeMaxBitrateMbps = reducedBitrate;
        _lastQualityGuardrailChangeTime = now;
        _qualityDegradedSampleCount = 0;
        OPNRecordSentryCounterMetric("opennow.stream.quality_guardrail.count", 1, @{
            @"action": @"bitrate_reduced",
            @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
            @"new_bitrate_mbps": @(reducedBitrate),
        });
        [self.streamView setMaxBitrateMbps:reducedBitrate];
        [_session setMaxBitrateMbps:reducedBitrate];
        NSString *detail = [NSString stringWithFormat:@"%@ · capped at %d Mbps", signalText, reducedBitrate];
        [self showQualityGuardrailToastWithTitle:@"Stream quality guardrail applied" detail:detail warning:YES];
        [_healthReport recordEventWithTitle:@"Quality guardrail applied" detail:detail ?: @"" now:now];
        OPNLogInfo(@"[StreamVC] Quality guardrail lowered runtime bitrate to %d Mbps after signals: %@", reducedBitrate, signalText);
        return;
    }

    if (!_qualityWarningShown) {
        _qualityWarningShown = YES;
        OPNRecordSentryCounterMetric("opennow.stream.quality_guardrail.count", 1, @{
            @"action": @"warning",
            @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
        });
        NSString *detail = [NSString stringWithFormat:@"%@ · consider 30 FPS or H264 if this continues", signalText];
        [self showQualityGuardrailToastWithTitle:@"Stream quality is unstable" detail:detail warning:YES];
        [_healthReport recordEventWithTitle:@"Quality warning" detail:detail ?: @"" now:CACurrentMediaTime()];
        OPNLogInfo(@"[StreamVC] Quality warning shown after signals: %@", signalText);
    }
}

- (void)copyCurrentLogToClipboardFromShortcut {
    if (_streamEnded) return;
    [OPNLogCapture appendEvent:@"[StreamVC] Command-L requested log copy"];
    [OPNLogCapture copyCapturedLogToClipboard:@"Command-L log copy"];
    [self showLogCopiedToast];
    [self.streamView takeFocus];
    OPNLogInfo(@"[StreamVC] Current log copied to clipboard via CMD+L");
}

- (void)updateStatsOverlay {
    OPNStreamStatsSnapshot *stats = [_session latestStatsSnapshot];
    [_healthReport addStatsSnapshot:stats];
    [self evaluateQualityGuardrailsWithStats:stats];
    CFTimeInterval now = CACurrentMediaTime();
    if (stats.available && _connectedOnce && now - _lastMetricsSampleTime >= 10.0) {
        _lastMetricsSampleTime = now;
        NSDictionary<NSString *, id> *attributes = @{
            @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
            @"codec": stats.codec.length > 0 ? stats.codec : @"unknown",
            @"resolution": stats.resolution.length > 0 ? stats.resolution : @"unknown",
        };
        OPNRecordSentryGaugeMetric("opennow.stream.latency", stats.latencyMs, "millisecond", attributes);
        OPNRecordSentryGaugeMetric("opennow.stream.jitter", stats.jitterMs, "millisecond", attributes);
        OPNRecordSentryGaugeMetric("opennow.stream.packet_loss", stats.packetLossPercent, "percent", attributes);
        OPNRecordSentryGaugeMetric("opennow.stream.bitrate", stats.inboundBitrateMbps, "megabit/second", attributes);
        OPNRecordSentryGaugeMetric("opennow.stream.render_fps", stats.renderFps, "frame/second", attributes);
        OPNRecordSentryGaugeMetric("opennow.stream.frames_dropped", (double)stats.framesDropped, "frame", attributes);
    }
    if (!self.statsOverlay) return;

    NSInteger latencyMs = stats.latencyMs >= 0 ? (NSInteger)std::llround(stats.latencyMs) : -1;
    int64_t packetsLost = stats.available ? stats.packetsLost : -1;
    NSString *resolution = stats.resolution;
    NSString *codec = stats.codec;
    NSString *enhancement = @"";
    if (stats.videoEnhancementActiveTier.length > 0) {
        NSString *activeTier = stats.videoEnhancementActiveTier;
        NSString *drawable = stats.videoEnhancementDrawableResolution;
        NSString *fallbackReason = stats.videoEnhancementFallbackReason;
        if (stats.videoEnhancementFrameTimeMs >= 0.0) {
            enhancement = [NSString stringWithFormat:@"enh %@ %@ %.1fms", activeTier, drawable, stats.videoEnhancementFrameTimeMs];
        } else {
            enhancement = [NSString stringWithFormat:@"enh %@ %@", activeTier, drawable];
        }
        if ([activeTier containsString:@"fallback"] && fallbackReason.length > 0) {
            enhancement = [enhancement stringByAppendingFormat:@" (%@)", fallbackReason];
        }
    }
    [self.statsOverlay updateLatencyMs:latencyMs
                            bitrateMbps:stats.inboundBitrateMbps
                           packetsLost:packetsLost
                              resolution:resolution
                                     fps:stats.fps
                               renderFps:stats.renderFps
                                     codec:codec
                               enhancement:enhancement
                              framesDropped:stats.framesDropped];
    self.statsOverlay.frame = [self statsOverlayFrame];
}

- (void)startStatsRefreshTimer {
    if (self.statsRefreshTimer) return;
    self.statsRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              target:self
                                                            selector:@selector(refreshStatsOverlayTimerFired:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)stopStatsRefreshTimer {
    [self.statsRefreshTimer invalidate];
    self.statsRefreshTimer = nil;
}

- (void)startPlaytimeRefreshTimer {
    if (self.playtimeRefreshTimer) return;
    self.playtimeRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:OPNStreamPlaytimeRefreshInterval
                                                                 target:self
                                                               selector:@selector(refreshPlaytimeTimerFired:)
                                                               userInfo:nil
                                                                repeats:YES];
}

- (void)stopPlaytimeRefreshTimer {
    [self.playtimeRefreshTimer invalidate];
    self.playtimeRefreshTimer = nil;
}

- (void)refreshPlaytimeTimerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshDisplayedPlaytimeFromSessionPoll];
}

- (void)refreshDisplayedPlaytimeFromSessionPoll {
    if (_streamEnded || !_connectedOnce || _playtimeRefreshInFlight || !_hasActiveSessionInfo || _activeSessionInfo.sessionId.empty()) return;
    _playtimeRefreshInFlight = YES;

    OPN::SessionInfo currentSession = _activeSessionInfo;
    __weak __typeof__(self) weakSelf = self;
    OPN::OPNPollSession(currentSession.sessionId, currentSession.serverIp, [weakSelf, currentSession](bool success, const OPN::SessionInfo &info, const std::string &error) {
        OPN::SessionInfo infoCopy = info;
        if (!infoCopy.sessionId.empty() && infoCopy.sessionId == currentSession.sessionId) {
            if (infoCopy.serverIp.empty()) infoCopy.serverIp = currentSession.serverIp;
            if (infoCopy.signalingServer.empty()) infoCopy.signalingServer = currentSession.signalingServer;
            if (infoCopy.signalingUrl.empty()) infoCopy.signalingUrl = currentSession.signalingUrl;
            if (infoCopy.streamingBaseUrl.empty()) infoCopy.streamingBaseUrl = currentSession.streamingBaseUrl;
            if (infoCopy.clientId.empty()) infoCopy.clientId = currentSession.clientId;
            if (infoCopy.deviceId.empty()) infoCopy.deviceId = currentSession.deviceId;
        }
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_playtimeRefreshInFlight = NO;
        if (strongSelf->_streamEnded) return;
        if (!success) {
            OPNLogError(@"[StreamVC] Playtime refresh failed: %s", errorCopy.c_str());
            return;
        }
        if (!infoCopy.sessionId.empty() && infoCopy.sessionId != currentSession.sessionId) {
            OPNLogError(@"[StreamVC] Ignoring playtime poll for mismatched sessionId=%s expected=%s",
                          infoCopy.sessionId.c_str(),
                          currentSession.sessionId.c_str());
            return;
        }
        if (!infoCopy.sessionId.empty()) {
            strongSelf->_activeSessionInfo = infoCopy;
            strongSelf->_hasActiveSessionInfo = YES;
        }
        if (!infoCopy.remainingPlaytimeAvailable) return;
        [strongSelf setRemainingPlaytimeHours:infoCopy.remainingPlaytimeHours unlimited:infoCopy.remainingPlaytimeUnlimited];
        [strongSelf.streamView startRemainingPlaytimeCountdown];
        OPNLogInfo(@"[StreamVC] Refreshed live session playtime remaining=%.2fh unlimited=%d", infoCopy.remainingPlaytimeHours, infoCopy.remainingPlaytimeUnlimited);
        });
    });
}

- (void)refreshStatsOverlayTimerFired:(NSTimer *)timer {
    (void)timer;
    [self updateStatsOverlay];
}

- (void)toggleStatsOverlay {
    if (_streamEnded) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_streamEnded) return;
        if (self.statsOverlay) {
            [self.statsOverlay removeFromSuperview];
            self.statsOverlay = nil;
            if (!self->_connectedOnce) [self stopStatsRefreshTimer];
            [self.streamView takeFocus];
            OPNLogInfo(@"[StreamVC] Stats overlay hidden via CMD+N");
            return;
        }

        OPNStatsOverlayView *overlay = [[OPNStatsOverlayView alloc] initWithFrame:[self statsOverlayFrame]];
        self.statsOverlay = overlay;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [self updateStatsOverlay];
        [self startStatsRefreshTimer];
        [self.streamView takeFocus];
        OPNLogInfo(@"[StreamVC] Stats overlay shown via CMD+N");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self updateStatsOverlay];
        });
    });
}

- (void)toggleShortcutLegendOverlay {
    if (_streamEnded) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_streamEnded) return;
        if (self.shortcutLegendOverlay) {
            [self.shortcutLegendOverlay removeFromSuperview];
            self.shortcutLegendOverlay = nil;
            [self.streamView takeFocus];
            OPNLogInfo(@"[StreamVC] Shortcut legend hidden via CMD+H");
            return;
        }

        OPNShortcutLegendView *overlay = [[OPNShortcutLegendView alloc] initWithFrame:[self shortcutLegendFrame]];
        self.shortcutLegendOverlay = overlay;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [self.streamView takeFocus];
        OPNLogInfo(@"[StreamVC] Shortcut legend shown via CMD+H");
    });
}

- (void)removeQuitShortcutMonitor {
    if (!_quitKeyMonitor) return;
    [NSEvent removeMonitor:_quitKeyMonitor];
    _quitKeyMonitor = nil;
}

- (void)dismissQuitGameOverlayAndRefocus:(BOOL)refocus {
    if (!self.quitOverlay) return;
    [self.quitOverlay removeFromSuperview];
    self.quitOverlay = nil;
    if (refocus && !_streamEnded) {
        [self.streamView takeFocus];
    }
}

- (void)requestQuitGameConfirmation {
    if (_streamEnded) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_streamEnded) return;
        if (self.quitOverlay) {
            [self.quitOverlay removeFromSuperview];
            [self.view addSubview:self.quitOverlay positioned:NSWindowAbove relativeTo:nil];
            [self.view.window makeFirstResponder:self.quitOverlay];
            return;
        }

        [self.streamView releasePointerLock];

        OPNQuitGameOverlayView *overlay = [[OPNQuitGameOverlayView alloc] initWithFrame:self.view.bounds];
        overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        __weak __typeof__(self) weakSelf = self;
        overlay.onCancel = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf dismissQuitGameOverlayAndRefocus:YES];
        };
        overlay.onQuit = ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf dismissQuitGameOverlayAndRefocus:NO];
            [strongSelf endStreamFromUserQuit];
        };
        self.quitOverlay = overlay;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [self.view.window makeFirstResponder:overlay];
    });
}

- (void)ensureLoadingViewWithMessage:(NSString *)message {
    if (self.loadingView) {
        [self.loadingView startAnimating];
        self.loadingView.message = message;
        self.statusLabel = self.loadingView.messageLabel;
        [self configureLoadingViewAdHandler];
        [self.view addSubview:self.loadingView positioned:NSWindowAbove relativeTo:nil];
        return;
    }

    self.loadingView = [[OPNLoadingView alloc] initWithFrame:[self loadingViewFrame]
                                                     message:message];
    self.loadingView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.loadingView setSteps:@[@"Check network route",
                                 @"Allocate cloud session",
                                 @"Connect to game server",
                                 @"Receive stream offer",
                                 @"Negotiate WebRTC",
                                 @"Start video pipeline",
                                 @"Connected"]
                   currentStepIndex:-1];
    self.statusLabel = self.loadingView.messageLabel;
    [self configureLoadingViewAdHandler];
    [self.view addSubview:self.loadingView positioned:NSWindowAbove relativeTo:nil];
}

- (void)resetTransportForRecovery {
    [self cancelRemoteIceGraceTimer];
    if (self.streamView) {
        [self.streamView setStreamActive:NO];
        [self.streamView detachFromPipeline];
    }
    if (_signaling) {
        [_signaling disconnect];
        _signaling = nil;
    }
    if (_session) {
        [self clearCurrentSessionCallbacks];
        [_session stop];
        _session = nil;
    }
    _session = [[OPNStreamSessionHandle alloc] init];
    _webRTCBackendName = @"libwebrtc";
    [self configureStreamViewSessionCallbacks];
    _remoteIceReceived = NO;
    if (self.streamView) {
        [self configureStreamViewSessionCallbacks];
    }
}

- (void)beginLatencyActivity {
    if (_latencyActivity) return;
    NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
    _latencyActivity = [NSProcessInfo.processInfo beginActivityWithOptions:options reason:@"OpenNOW active cloud gaming stream"];
    OPNLogInfo(@"[StreamVC] Latency-critical stream activity started");
}

- (void)endLatencyActivity {
    if (!_latencyActivity) return;
    [NSProcessInfo.processInfo endActivity:_latencyActivity];
    _latencyActivity = nil;
    OPNLogInfo(@"[StreamVC] Latency-critical stream activity ended");
}

- (void)requestRemoteStopForActiveSession {
    if (_remoteStopRequested) return;
    if (!_hasActiveSessionInfo) {
        OPNLogInfo(@"[StreamVC] No active session info available for remote stop");
        return;
    }

    OPN::SessionInfo sessionInfo = _activeSessionInfo;
    if (sessionInfo.sessionId.empty() || sessionInfo.serverIp.empty()) {
        OPNLogError(@"[StreamVC] Cannot stop remote session; sessionId=%s serverIp=%s",
              sessionInfo.sessionId.empty() ? "(empty)" : sessionInfo.sessionId.c_str(),
              sessionInfo.serverIp.empty() ? "(empty)" : sessionInfo.serverIp.c_str());
        return;
    }

    _remoteStopRequested = YES;
    OPNLogInfo(@"[StreamVC] Requesting remote session stop sessionId=%s serverIp=%s",
          sessionInfo.sessionId.c_str(),
          sessionInfo.serverIp.c_str());
    OPN::OPNStopSession(sessionInfo.sessionId,
                        sessionInfo.serverIp,
                        [sessionInfo](bool ok, const std::string &error) {
        if (ok) {
            OPNRecordSentryCounterMetric("opennow.stream.remote_stop.count", 1, @{@"outcome": @"success"});
            OPNLogInfo(@"[StreamVC] Remote session stop succeeded sessionId=%s", sessionInfo.sessionId.c_str());
        } else {
            OPNRecordSentryCounterMetric("opennow.stream.remote_stop.count", 1, @{@"outcome": @"failure"});
            OPNLogError(@"[StreamVC] Remote session stop failed sessionId=%s error=%s",
                  sessionInfo.sessionId.c_str(),
                  error.empty() ? "unknown" : error.c_str());
        }
    });
}

- (void)recordStreamUserActivity {
    _lastStreamActivityTime = CACurrentMediaTime();
    _lastIdleDeviceInputTime = 0;
}

- (void)startInactivityTimer {
    [self stopInactivityTimer];
    [self recordStreamUserActivity];
    self.inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:OPNStreamInactivityCheckInterval
                                                            target:self
                                                          selector:@selector(checkInactivityTimer:)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)stopInactivityTimer {
    [self.inactivityTimer invalidate];
    self.inactivityTimer = nil;
}

- (void)checkInactivityTimer:(NSTimer *)timer {
    (void)timer;
    if (_streamEnded || !_connectedOnce || _recovering) return;
    if (_lastStreamActivityTime <= 0) {
        [self recordStreamUserActivity];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (_idleDeviceInputEnabled) {
        [self sendRandomIdleDeviceInputIfNeededAtTime:now];
        return;
    }
    if (now - _lastStreamActivityTime < OPNStreamInactivityTimeoutInterval) return;
    [self endStreamFromInactivityTimeout];
}

- (void)toggleIdleDeviceInputMode {
    if (_streamEnded) return;
    _idleDeviceInputEnabled = !_idleDeviceInputEnabled;
    [self recordStreamUserActivity];
    [self showAntiAFKNoticeEnabled:_idleDeviceInputEnabled];
    OPNLogInfo(@"[StreamVC] Idle device input mode %@; inactivity timeout %@",
                 _idleDeviceInputEnabled ? @"enabled" : @"disabled",
                 _idleDeviceInputEnabled ? @"disabled" : @"enabled");
}

- (void)sendRandomIdleDeviceInputIfNeededAtTime:(CFTimeInterval)now {
    if (!_session.inputReady) return;
    if (now - _lastStreamActivityTime < OPNStreamIdleDeviceInputInterval) return;
    if (_lastIdleDeviceInputTime > 0 && now - _lastIdleDeviceInputTime < OPNStreamIdleDeviceInputInterval) return;

    static const int16_t deltas[][2] = {
        {OPNStreamIdleDeviceInputPulsePixels, 0},
        {-OPNStreamIdleDeviceInputPulsePixels, 0},
        {0, OPNStreamIdleDeviceInputPulsePixels},
        {0, -OPNStreamIdleDeviceInputPulsePixels},
    };
    uint32_t index = arc4random_uniform((uint32_t)(sizeof(deltas) / sizeof(deltas[0])));
    int16_t dx = deltas[index][0];
    int16_t dy = deltas[index][1];
    OPNSendStreamSessionMouseMove(static_cast<OPN::IStreamSession *>(_session.rawSession), dx, dy);
    CFTimeInterval idleDuration = now - _lastStreamActivityTime;
    _lastStreamActivityTime = now;
    _lastIdleDeviceInputTime = now;
    OPNLogInfo(@"[StreamVC] Sent idle device input pulse dx=%d dy=%d after %.1fs without user activity", dx, dy, idleDuration);

    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNStreamIdleDeviceInputReturnDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded || !strongSelf->_session.inputReady) return;
        OPNSendStreamSessionMouseMove(static_cast<OPN::IStreamSession *>(strongSelf->_session.rawSession), (int16_t)-dx, (int16_t)-dy);
        OPNLogInfo(@"[StreamVC] Sent idle device input return dx=%d dy=%d", (int16_t)-dx, (int16_t)-dy);
    });
}

- (void)endStreamFromInactivityTimeout {
    if (_streamEnded) return;
    OPNLogInfo(@"[StreamVC] Stream ended due to user inactivity");
    OPNRecordSentryCounterMetric("opennow.stream.end_reason.count", 1, @{@"reason": @"inactivity"});
    [OPNLogCapture appendEvent:@"[StreamVC] Stream ended due to user inactivity"];
    [_healthReport recordEventWithTitle:@"Inactivity timeout" detail:@"Session ended because no user activity was detected" now:CACurrentMediaTime()];
    [self requestRemoteStopForActiveSession];
    [self endStreamWithSuccess:NO errorMessage:"Session ended due to inactivity."];
}

- (void)endStreamFromUserQuit {
    if (_streamEnded) return;
    OPNRecordSentryCounterMetric("opennow.stream.end_reason.count", 1, @{@"reason": @"user_quit"});
    [_healthReport recordEventWithTitle:@"User quit" detail:@"Stream ended from the quit confirmation" now:CACurrentMediaTime()];
    [self requestRemoteStopForActiveSession];
    [self endStreamWithSuccess:YES errorMessage:""];
}

- (void)shutdownForApplicationTermination {
    if (![NSThread isMainThread]) {
        __weak OPNStreamViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPNStreamViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf shutdownForApplicationTermination];
        });
        return;
    }

    if (_streamEnded) return;
    _streamEnded = YES;
    OPNRecordSentryCounterMetric("opennow.stream.end_reason.count", 1, @{@"reason": @"application_terminate"});
    OPNLogInfo(@"[StreamVC] Application terminating; preserving remote session for resume");
    [self finishLaunchMeasurementWithSuccess:YES reason:@"application terminating"];
    [self cleanup];
}

- (void)cancelRemoteIceGraceTimer {
    if (!_remoteIceGraceTimer) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)_remoteIceGraceTimer;
    _remoteIceGraceTimer = nullptr;
    dispatch_source_cancel(timer);
}

- (void)startRemoteIceGraceTimerForLaunchGeneration:(NSUInteger)launchGeneration {
    [self cancelRemoteIceGraceTimer];
    if (!_recovering || !_connectedOnce || _streamEnded) return;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;

    void *timerToken = (__bridge_retained void *)timer;
    _remoteIceGraceTimer = timerToken;

    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNSignalingRemoteIceGraceInterval * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              0);
    dispatch_source_set_event_handler(timer, ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_remoteIceGraceTimer != timerToken) return;

        dispatch_source_t firedTimer = (__bridge_transfer dispatch_source_t)strongSelf->_remoteIceGraceTimer;
        strongSelf->_remoteIceGraceTimer = nullptr;
        dispatch_source_cancel(firedTimer);

        if (strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration || strongSelf->_remoteIceReceived) return;

        std::string error = "No remote ICE received after offer";
        OPNLogInfo(@"[StreamVC] No remote ICE received within %.0fms after offer; forcing targeted recovery",
              OPNSignalingRemoteIceGraceInterval * 1000.0);
        if ([strongSelf beginAutomaticRecoveryForError:error]) return;
        if (strongSelf->_connectedOnce) {
            [strongSelf endStreamWithSuccess:NO errorMessage:error];
        }
    });
    dispatch_resume(timer);
}

- (void)scheduleRecoveryAttemptResetForLaunchGeneration:(NSUInteger)launchGeneration {
    NSUInteger resetGeneration = ++_stableResetGeneration;
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNStableRecoveryResetInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded) return;
        if (strongSelf->_stableResetGeneration != resetGeneration) return;
        if (strongSelf->_launchGeneration != launchGeneration) return;
        if (strongSelf->_recovering || !strongSelf->_connectedOnce) return;
        if (strongSelf->_recoveryAttempt > 0) {
            OPNLogInfo(@"[StreamVC] Automatic recovery budget reset after stable connection");
        }
        strongSelf->_recoveryAttempt = 0;
    });
}

- (BOOL)beginAutomaticRecoveryForError:(const std::string &)error {
    if (_streamEnded || !OPNStreamErrorIsRecoverable(error)) return NO;
    if (!_connectedOnce) {
        OPNLogInfo(@"[StreamVC] Skipping automatic recovery before confirmed stream connection: %s", error.c_str());
        return NO;
    }
    if (_recoveryAttempt >= OPNMaxAutomaticRecoveryAttempts) {
        OPNLogError(@"[StreamVC] Automatic recovery exhausted after %ld attempts for error: %s",
              (long)_recoveryAttempt, error.c_str());
        return NO;
    }

    _recoveryAttempt++;
    _recovering = YES;
    OPNRecordSentryCounterMetric("opennow.stream.recovery.count", 1, @{
        @"outcome": @"started",
        @"attempt": @(_recoveryAttempt),
        @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
    });
    _stableResetGeneration++;
    NSUInteger recoveryGeneration = ++_launchGeneration;
    NSTimeInterval delay = OPNRecoveryDelayForAttempt(_recoveryAttempt);
    NSString *message = [NSString stringWithFormat:@"Connection interrupted. Reconnecting (%ld/%ld)...",
                         (long)_recoveryAttempt,
                         (long)OPNMaxAutomaticRecoveryAttempts];
    OPNLogInfo(@"[StreamVC] Starting automatic recovery attempt %ld/%ld in %.2fs after error: %s",
          (long)_recoveryAttempt,
          (long)OPNMaxAutomaticRecoveryAttempts,
          delay,
          error.c_str());
    [_healthReport recordEventWithTitle:@"Recovery attempt" detail:OPNStringFromStdString(error, @"") now:CACurrentMediaTime()];

    [self finishLaunchMeasurementWithSuccess:NO reason:@"recovering"];
    [self ensureLoadingViewWithMessage:message];
    [self.streamView stopRecordingIfNeeded];
    [self resetTransportForRecovery];
    [self resetQualityGuardrailsForBitrate:_runtimeMaxBitrateMbps];
    [self setStatus:message];

    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded) return;
        if (strongSelf->_launchGeneration != recoveryGeneration || !strongSelf->_recovering) return;
        [strongSelf startStreamLaunchFlow];
    });
    return YES;
}

- (void)connectWithSessionInfo:(const OPN::SessionInfo &)sessionInfo
                       settings:(const OPN::StreamSettings &)settings
               launchGeneration:(NSUInteger)launchGeneration {
    if (![NSThread isMainThread]) {
        OPN::SessionInfo sessionInfoCopy = sessionInfo;
        OPN::StreamSettings settingsCopy = settings;
        __weak __typeof__(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf connectWithSessionInfo:sessionInfoCopy settings:settingsCopy launchGeneration:launchGeneration];
        });
        return;
    }

    if (_streamEnded || _launchGeneration != launchGeneration) return;

    [self setLaunchStep:2 message:@"Connecting to game server..."];

    OPN::SessionInfo activeSessionInfo = sessionInfo;
    if (activeSessionInfo.sessionId.empty()) {
        OPNLogError(@"[StreamVC] Cannot connect with empty sessionId");
        [self endStreamWithSuccess:NO errorMessage:"Session response is missing session id"];
        return;
    }

    OPN::StreamSettings negotiatedSettings = OPNSettingsWithNegotiatedProfile(settings, activeSessionInfo);
    [_healthReport setSessionZone:OPNStringFromStdString(activeSessionInfo.zone, @"")
                          gpuType:OPNStringFromStdString(activeSessionInfo.gpuType, @"")
             negotiatedResolution:OPNStringFromStdString(activeSessionInfo.negotiatedStreamProfile.resolution, @"")
                    negotiatedFps:activeSessionInfo.negotiatedStreamProfile.fps
                  negotiatedCodec:OPNStringFromStdString(activeSessionInfo.negotiatedStreamProfile.codec, @"")];
    [_healthReport setFinalResolution:OPNStringFromStdString(negotiatedSettings.resolution, @"")
                                  fps:negotiatedSettings.fps
                                codec:OPNStringFromStdString(negotiatedSettings.codec, @"")
                          bitrateMbps:negotiatedSettings.maxBitrateMbps];
    if (negotiatedSettings.resolution != settings.resolution
        || negotiatedSettings.fps != settings.fps
        || negotiatedSettings.codec != settings.codec
        || negotiatedSettings.colorQuality != settings.colorQuality) {
        OPNLogInfo(@"[StreamVC] Using finalized stream profile %s@%dfps codec=%s color=%s (requested %s@%dfps codec=%s color=%s)",
              negotiatedSettings.resolution.c_str(),
              negotiatedSettings.fps,
              negotiatedSettings.codec.c_str(),
              negotiatedSettings.colorQuality.c_str(),
              settings.resolution.c_str(),
              settings.fps,
              settings.codec.c_str(),
              settings.colorQuality.c_str());
    }
    _activeSessionInfo = activeSessionInfo;
    _hasActiveSessionInfo = YES;

    _signaling = [[OPNWebSocketSignalingClient alloc] initWithSignalingServer:OPNStringFromStdString(activeSessionInfo.signalingServer, @"")
                                                                     sessionId:OPNStringFromStdString(activeSessionInfo.sessionId, @"")
                                                                  signalingUrl:OPNStringFromStdString(activeSessionInfo.signalingUrl, @"")];
    [_signaling setPeerResolution:OPNStringFromStdString(negotiatedSettings.resolution, @"")];

    OPNLogInfo(@"[StreamVC] Signaling client created, server=%s, url=%s", activeSessionInfo.signalingServer.c_str(), activeSessionInfo.signalingUrl.c_str());

    __weak __typeof__(self) weakSelf = self;
    _signaling.onOffer = ^(NSString *sdpText) {
        __typeof__(self) s = weakSelf;
        if (!s || s->_streamEnded || s->_launchGeneration != launchGeneration) return;
        if (!s->_session.valid) {
            [s endStreamWithSuccess:NO errorMessage:"libwebrtc stream session is unavailable"];
            return;
        }
        NSString *serverIceUfrag = [OPNStreamSessionHandle iceUfragFromOfferSdp:sdpText];
        NSString *offerSdpCopy = [sdpText copy] ?: @"";
        s->_remoteIceReceived = NO;
        [s startRemoteIceGraceTimerForLaunchGeneration:launchGeneration];

        [s setLaunchStep:4 message:@"Negotiating stream..."];
        [s->_healthReport markPhase:@"Offer Received" now:CACurrentMediaTime()];
        [s->_session setNativeWindow:(__bridge void *)[s.streamView nativeVideoView]];

        [s setLaunchStep:5 message:@"Starting video pipeline..."];
        OPNStartStreamSession(static_cast<OPN::IStreamSession *>(s->_session.rawSession),
                              activeSessionInfo,
                              sdpText,
                              negotiatedSettings,
                              ^(NSString *answerSdp, NSString *nvstSdp) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_signaling || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            OPNLogInfo(@"[StreamVC] Sending WebRTC answer (sdp=%lu, nvstSdp=%lu)",
                  (unsigned long)answerSdp.length, (unsigned long)nvstSdp.length);
            [s2->_signaling sendAnswerSdp:answerSdp ?: @""
                                  nvstSdp:nvstSdp ?: @""];
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) s3 = weakSelf;
                if (!s3 || !s3->_session.valid || s3->_streamEnded || s3->_launchGeneration != launchGeneration) return;
                OPNInjectManualStreamSessionIceCandidate(static_cast<OPN::IStreamSession *>(s3->_session.rawSession), activeSessionInfo, offerSdpCopy, serverIceUfrag);
            });
        }, ^(NSDictionary *candidate) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_signaling || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            [s2->_signaling sendIceCandidate:candidate ?: @{}];
        }, ^(BOOL connected, NSString *streamErrorText) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            NSString *streamErrorCopy = [streamErrorText copy] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
                if (connected) {
                    [s2 cancelRemoteIceGraceTimer];
                    BOOL recoveredLaunch = s2->_recovering;
                    s2->_connectedOnce = YES;
                    s2->_connectedStartTime = CACurrentMediaTime();
                    s2->_recovering = NO;
                    OPNRecordSentryCounterMetric("opennow.stream.connection.count", 1, OPNStreamMetricAttributes(@"connected", recoveredLaunch, s2->_webRTCBackendName, OPNStringFromStdString(negotiatedSettings.codec, @""), OPNStringFromStdString(negotiatedSettings.resolution, @""), negotiatedSettings.fps));
                    [s2 beginLatencyActivity];
                    [s2 setLaunchStep:6 message:@"Connected!"];
                    [s2->_healthReport markConnected:CACurrentMediaTime()];
                    [s2 finishLaunchMeasurementWithSuccess:YES reason:@"connected"];
                    [s2.streamView setStreamActive:YES];
                    [s2.streamView startRemainingPlaytimeCountdown];
                    if ([s2.streamView isSidebarHUDVisible]) {
                        [s2 refreshDisplayedPlaytimeFromSessionPoll];
                        [s2 startPlaytimeRefreshTimer];
                    }
                    [s2.streamView takeFocus];
                    [s2 startInactivityTimer];
                    [OPNDiscordPresence updatePlayingWithGameTitle:s2->_gameTitle
                                                        resolution:OPNStringFromStdString(negotiatedSettings.resolution, @"")
                                                               fps:negotiatedSettings.fps
                                                       bitrateMbps:negotiatedSettings.maxBitrateMbps
                                                             codec:OPNStringFromStdString(negotiatedSettings.codec, @"")];
                    [s2 showConnectedToastWithResolution:OPNStringFromStdString(negotiatedSettings.resolution, @"") fps:negotiatedSettings.fps bitrate:negotiatedSettings.maxBitrateMbps codec:OPNStringFromStdString(negotiatedSettings.codec, @"")];
                    [s2 startStatsRefreshTimer];
                    [s2 updateStatsOverlay];
                    [s2 scheduleRecoveryAttemptResetForLaunchGeneration:launchGeneration];
                    __weak __typeof__(s2) weakConnectedSelf = s2;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                        __typeof__(s2) connectedSelf = weakConnectedSelf;
                        if (!connectedSelf || connectedSelf->_streamEnded || connectedSelf->_launchGeneration != launchGeneration) return;
                        [connectedSelf.loadingView clearAdPresentation];
                        [connectedSelf.loadingView stopAnimating];
                        [connectedSelf.loadingView removeFromSuperview];
                        connectedSelf.loadingView = nil;
                        connectedSelf.statusLabel = nil;
                    });
                } else {
                    if (streamErrorCopy.length == 0) {
                        [s2 endStreamWithSuccess:YES errorMessage:""];
                    } else {
                        std::string streamError = streamErrorCopy.UTF8String ?: "";
                        std::string displayError = OPNUserFacingGFNErrorMessageForTitle(streamError, s2->_gameTitle);
                        [s2 setStatus:[NSString stringWithFormat:@"Stream error: %s", displayError.c_str()]];
                        if ([s2 beginAutomaticRecoveryForError:streamError]) return;
                        [s2 endStreamWithSuccess:NO errorMessage:streamError];
                    }
                }
            });
        });

        s->_signaling.onIceCandidate = ^(NSDictionary *payload) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_session.valid || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            s2->_remoteIceReceived = YES;
            [s2 cancelRemoteIceGraceTimer];
            [s2->_session addRemoteIceCandidatePayload:payload];
        };

        s->_signaling.onClosed = ^(BOOL clean, NSString *reasonText) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            std::string reasonCopy = reasonText.UTF8String ?: "";
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
                if (clean && strongSelf->_connectedOnce) {
                    OPNLogInfo(@"[StreamVC] Signaling closed cleanly after WebRTC connection; keeping stream active");
                    return;
                }
                std::string error = reasonCopy.empty() ? std::string("Signaling connection closed") : reasonCopy;
                OPNLogError(@"[StreamVC] Signaling closed unexpectedly: clean=%d reason=%s", clean, error.c_str());
                if ([strongSelf beginAutomaticRecoveryForError:error]) return;
                [strongSelf endStreamWithSuccess:NO errorMessage:error];
            });
        };
    };

    [_signaling connect:^(BOOL ok, NSString *errText) {
        __typeof__(self) s = weakSelf;
        if (!s) {
            OPNLogInfo(@"[StreamVC] Signaling Connect callback: self is nil");
            return;
        }
        if (s->_launchGeneration != launchGeneration) {
            OPNLogInfo(@"[StreamVC] Signaling Connect callback ignored for stale generation %lu", (unsigned long)launchGeneration);
            return;
        }
        if (ok) {
            OPNLogInfo(@"[StreamVC] Signaling connected");
            [s setLaunchStep:3 message:@"Waiting for stream offer..."];
        }
        if (!ok) {
            std::string errCopy = errText.UTF8String ?: "";
            OPNLogError(@"[StreamVC] Signaling Connect failed: %s", errCopy.c_str());
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!s || s->_streamEnded || s->_launchGeneration != launchGeneration) return;
                std::string displayError = OPNUserFacingGFNErrorMessageForTitle(errCopy, s->_gameTitle);
                [s setStatus:[NSString stringWithFormat:@"Signaling error: %s", displayError.c_str()]];
                if ([s beginAutomaticRecoveryForError:errCopy]) return;
                [s endStreamWithSuccess:NO errorMessage:errCopy];
            });
        }
    }];
}

- (void)beginSessionAllocationWithSettings:(const OPN::StreamSettings &)settings
                             streamProfile:(const OPN::StreamPreferenceProfile &)streamProfile
                          streamingBaseUrl:(const std::string &)streamingBaseUrl
                          launchGeneration:(NSUInteger)launchGeneration
                          recoveringLaunch:(BOOL)recoveringLaunch {
    if (_streamEnded || _launchGeneration != launchGeneration) return;

    OPNDisplayStreamProfile displayProfile = ResolveDisplayStreamProfile(self.view.window);
    [self setLaunchStep:1 message:recoveringLaunch ? @"Reallocating cloud session..." : @"Allocating cloud session..."];
    if (_streamLaunchTrace) {
        [_streamLaunchTrace setData:@"stream.resolution" value:OPNStringFromStdString(settings.resolution, @"")];
        [_streamLaunchTrace setData:@"stream.codec" value:OPNStringFromStdString(settings.codec, @"")];
        [_streamLaunchTrace setData:@"stream.fps" value:[NSString stringWithFormat:@"%d", settings.fps]];
        [_streamLaunchTrace setData:@"stream.max_bitrate_mbps" value:[NSString stringWithFormat:@"%d", settings.maxBitrateMbps]];
        [_streamLaunchTrace setData:@"stream.region" value:OPNStringFromStdString(streamingBaseUrl, @"")];
    }
    self.launchStartTime = CACurrentMediaTime();
    self.launchSignpostId = os_signpost_id_generate(OPNStreamPerformanceLog());
    self.launchSignpostActive = YES;
    os_signpost_interval_begin(OPNStreamPerformanceLog(),
                               self.launchSignpostId,
                               "StreamLaunch",
                               "appId=%{public}s resolution=%{public}s fps=%d bitrate=%d codec=%{public}s powerSaver=%{public}s",
                                [_appId UTF8String] ?: "",
                               settings.resolution.c_str(),
                               settings.fps,
                               settings.maxBitrateMbps,
                               settings.codec.c_str(),
                               streamProfile.enablePowerSaver ? "on" : "off");

    OPNLogInfo(@"[StreamVC] Selected stream profile display=%dx%d stream=%s fps=%d bitrate=%dMbps codec=%s aspect=%s %.4f l4s=%s powerSaver=%s requested=%s@%dfps/%dMbps/%s network=%s/%dms controllers=0x%x region=%s",
          displayProfile.displayWidth,
          displayProfile.displayHeight,
          settings.resolution.c_str(),
          settings.fps,
          settings.maxBitrateMbps,
          settings.codec.c_str(),
          streamProfile.aspect.label.c_str(),
          streamProfile.AspectRatio(),
          settings.enableL4S ? "on" : "off",
          streamProfile.enablePowerSaver ? "on" : "off",
          streamProfile.resolution.Value().c_str(),
          streamProfile.fps,
          streamProfile.maxBitrateMbps,
          streamProfile.codec.value.c_str(),
          settings.networkType.c_str(),
          settings.networkLatencyMs,
          settings.remoteControllersBitmap,
          streamingBaseUrl.c_str());

    __weak __typeof__(self) weakSelf = self;

    if (_resumeExistingSession) {
        std::string requestedResumeSessionId = OPNStdStringFromNSString(_resumeSessionId);
        std::string requestedResumeServer = OPNStdStringFromNSString(_resumeServer);
        std::string requestedAppId = OPNStdStringFromNSString(_appId);
        std::string apiToken = OPNStdStringFromNSString(_apiToken);
        OPNLogInfo(@"[StreamVC] Claiming active session for silent resume: sessionId=%s", requestedResumeSessionId.c_str());
        OPN::OPNSetSessionManagerAccessToken(apiToken);
        OPN::OPNSetSessionManagerStreamingBaseUrl(streamingBaseUrl);
        [self setLaunchStep:1 message:@"Resuming active session..."];
        OPN::OPNClaimSession(requestedResumeSessionId, requestedResumeServer, requestedAppId, settings, recoveringLaunch,
            [weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch, requestedResumeSessionId](bool success, const OPN::SessionInfo &info, const std::string &error) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
                OPNLogInfo(@"[StreamVC] Active session claim result: success=%d", success);
                if (!success) {
                    if (OPNResumeErrorShouldCreateFreshSession(error)) {
                        OPNLogInfo(@"[StreamVC] Active session could not be claimed; creating a fresh session instead: %s", error.c_str());
                        strongSelf->_resumeExistingSession = NO;
                        strongSelf->_resumeSessionId = @"";
                        strongSelf->_resumeServer = @"";
                        [strongSelf finishLaunchMeasurementWithSuccess:NO reason:@"stale-resume"];
                        [strongSelf beginSessionAllocationWithSettings:settings
                                                         streamProfile:streamProfile
                                                      streamingBaseUrl:streamingBaseUrl
                                                      launchGeneration:launchGeneration
                                                      recoveringLaunch:recoveringLaunch];
                        return;
                    }
                    if (error.find("SESSION_NOT_PAUSED") != std::string::npos || error.find("\"statusCode\":34") != std::string::npos) {
                        OPNLogInfo(@"[StreamVC] Active session is not paused; re-resolving requested sessionId=%s", requestedResumeSessionId.c_str());
                        [strongSelf setLaunchStep:1 message:@"Resuming current active session..."];
                        std::string requestedAppId = OPNStdStringFromNSString(strongSelf->_appId);
                        OPN::OPNGetActiveSessions([weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch, requestedResumeSessionId, requestedAppId](bool sessionsOk, const std::vector<OPN::ActiveSessionEntry> &sessions, const std::string &sessionsError) {
                            std::vector<OPN::ActiveSessionEntry> sessionsCopy = sessions;
                            std::string sessionsErrorCopy = sessionsError;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                __typeof__(self) retrySelf = weakSelf;
                                if (!retrySelf || retrySelf->_streamEnded || retrySelf->_launchGeneration != launchGeneration) return;
                                if (!sessionsOk) {
                                    [retrySelf endStreamWithSuccess:NO errorMessage:sessionsErrorCopy.empty() ? std::string("Unable to resolve active session") : sessionsErrorCopy];
                                    return;
                                }

                                OPN::ActiveSessionEntry selectedSession;
                                BOOL foundSession = NO;
                                for (const OPN::ActiveSessionEntry &session : sessionsCopy) {
                                    if (session.sessionId == requestedResumeSessionId && !session.serverIp.empty()) {
                                        selectedSession = session;
                                        foundSession = YES;
                                        break;
                                    }
                                }
                                if (!foundSession) {
                                    OPNLogError(@"[StreamVC] Requested resume session is no longer active: sessionId=%s", requestedResumeSessionId.c_str());
                                    [retrySelf endStreamWithSuccess:NO errorMessage:"Requested session is no longer available to resume"];
                                    return;
                                }

                                std::string selectedAppId = selectedSession.appId > 0 ? std::to_string(selectedSession.appId) : requestedAppId;
                                retrySelf->_resumeServer = OPNStringFromStdString(selectedSession.serverIp, @"");
                                [retrySelf setLaunchStep:2 message:@"Connecting to current active session..."];
                                OPN::OPNClaimSession(requestedResumeSessionId, selectedSession.serverIp, selectedAppId, settings, true,
                                    [weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch, requestedResumeSessionId](bool retrySuccess, const OPN::SessionInfo &retryInfo, const std::string &retryError) {
                                        __typeof__(self) claimSelf = weakSelf;
                                        if (!claimSelf || claimSelf->_streamEnded || claimSelf->_launchGeneration != launchGeneration) return;
                                        if (!retrySuccess) {
                                            if (OPNResumeErrorShouldCreateFreshSession(retryError)) {
                                                OPNLogInfo(@"[StreamVC] Re-resolved active session could not be claimed; creating a fresh session instead: %s", retryError.c_str());
                                                claimSelf->_resumeExistingSession = NO;
                                                claimSelf->_resumeSessionId = @"";
                                                claimSelf->_resumeServer = @"";
                                                [claimSelf finishLaunchMeasurementWithSuccess:NO reason:@"stale-resume"];
                                                [claimSelf beginSessionAllocationWithSettings:settings
                                                                               streamProfile:streamProfile
                                                                            streamingBaseUrl:streamingBaseUrl
                                                                            launchGeneration:launchGeneration
                                                                            recoveringLaunch:recoveringLaunch];
                                                return;
                                            }
                                            [claimSelf endStreamWithSuccess:NO errorMessage:retryError];
                                            return;
                                        }
                                        if (retryInfo.sessionId != requestedResumeSessionId) {
                                            OPNLogError(@"[StreamVC] Resume claim returned mismatched sessionId=%s expected=%s",
                                                          retryInfo.sessionId.c_str(),
                                                          requestedResumeSessionId.c_str());
                                            [claimSelf endStreamWithSuccess:NO errorMessage:"Resume returned a different session id"];
                                            return;
                                        }
                                        [claimSelf connectWithSessionInfo:retryInfo settings:settings launchGeneration:launchGeneration];
                                    });
                            });
                        });
                        return;
                    }
                    std::string displayError = OPNUserFacingGFNErrorMessageForTitle(error, strongSelf->_gameTitle);
                    NSString *errMsg = [NSString stringWithFormat:@"Resume failed: %s", displayError.c_str()];
                    [strongSelf setStatus:errMsg];
                    if ([strongSelf beginAutomaticRecoveryForError:error]) return;
                    [strongSelf endStreamWithSuccess:NO errorMessage:error];
                    return;
                }
                if (info.sessionId != requestedResumeSessionId) {
                    OPNLogError(@"[StreamVC] Resume claim returned mismatched sessionId=%s expected=%s",
                                  info.sessionId.c_str(),
                                  requestedResumeSessionId.c_str());
                    [strongSelf endStreamWithSuccess:NO errorMessage:"Resume returned a different session id"];
                    return;
                }
                [strongSelf connectWithSessionInfo:info settings:settings launchGeneration:launchGeneration];
            });
        return;
    }

    OPNLogInfo(@"[StreamVC] Creating or reusing GeForce NOW session...");
    std::string apiToken = OPNStdStringFromNSString(_apiToken);
    std::string appId = OPNStdStringFromNSString(_appId);
    std::string gameTitle = OPNStdStringFromNSString(_gameTitle);
    OPN::OPNSetSessionManagerAccessToken(apiToken);
    OPN::OPNSetSessionManagerStreamingBaseUrl(streamingBaseUrl);

    (void)recoveringLaunch;
    OPNStreamCreateOrReuseSession(appId, gameTitle, settings,
        [weakSelf, launchGeneration](const std::string &message, const OPN::SessionInfo &progressSession) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
            NSString *statusMessage = OPNStringFromStdString(message, @"Waiting for session cleanup...");
            [strongSelf setLaunchStep:1 message:statusMessage ?: @"Waiting for session cleanup..."];
            if (!progressSession.sessionId.empty()) {
                [strongSelf updateLaunchAdState:progressSession];
            }
        },
        [weakSelf, settings, launchGeneration](bool success, const OPN::SessionInfo &info, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) {
                OPNLogInfo(@"[StreamVC] LaunchGame callback: self is nil");
                return;
            }
            if (strongSelf->_launchGeneration != launchGeneration) {
                OPNLogInfo(@"[StreamVC] LaunchGame callback ignored for stale generation %lu", (unsigned long)launchGeneration);
                return;
            }
            if (strongSelf->_streamEnded) {
                OPNLogInfo(@"[StreamVC] LaunchGame callback: stream ended");
                return;
            }

            OPNLogInfo(@"[StreamVC] LaunchGame result: success=%d", success);
            if (!success) {
                std::string displayError = OPNUserFacingGFNErrorMessageForTitle(error, strongSelf->_gameTitle);
                NSString *errMsg = [NSString stringWithFormat:@"Session failed: %s", displayError.c_str()];
                OPNLogInfo(@"[StreamVC] %@", errMsg);
                [strongSelf setStatus:errMsg];
                if ([strongSelf beginAutomaticRecoveryForError:error]) return;
                [strongSelf endStreamWithSuccess:NO errorMessage:error];
                return;
            }
            [strongSelf connectWithSessionInfo:info settings:settings launchGeneration:launchGeneration];
        });
}

- (void)startStreamLaunchFlow {
    NSUInteger launchGeneration = ++_launchGeneration;
    BOOL recoveringLaunch = _recovering;
    std::string appId = OPNStdStringFromNSString(_appId);
    std::string gameTitle = OPNStdStringFromNSString(_gameTitle);
    std::string apiToken = OPNStdStringFromNSString(_apiToken);
    if (_streamLaunchTrace) {
        [_streamLaunchTrace setStatus:NO];
        [_streamLaunchTrace finish];
        _streamLaunchTrace = nil;
    }
    _streamLaunchTrace = [OPNSentryTransactionBridge transactionWithName:recoveringLaunch ? @"Stream recovery launch" : @"Stream launch" operation:@"stream.launch"];
    if (_streamLaunchTrace) {
        [_streamLaunchTrace setTag:@"recovery" value:recoveringLaunch ? @"true" : @"false"];
        [_streamLaunchTrace setTag:@"backend" value:_webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown"];
        [_streamLaunchTrace setData:@"app.id" value:_appId ?: @""];
        [_streamLaunchTrace setData:@"game.title" value:_gameTitle ?: @""];
    }
    if (!_healthReportStarted) {
        [_healthReport resetWithGameTitle:_gameTitle ?: @"" appId:_appId ?: @"" backend:_webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown" now:CACurrentMediaTime()];
        _healthReportStarted = YES;
    } else if (recoveringLaunch) {
        [_healthReport markPhase:@"Recovery Prepare" now:CACurrentMediaTime()];
    }
    _launchFlowStartTime = CACurrentMediaTime();
    OPNRecordSentryCounterMetric("opennow.stream.launch.count", 1, @{
        @"outcome": recoveringLaunch ? @"recovery_started" : @"started",
        @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
    });
    OPNLogInfo(@"[StreamVC] Starting stream launch flow for game: %@ (appId=%s, recovery=%d attempt=%ld/%ld)",
          _gameTitle ?: @"",
          appId.c_str(),
          recoveringLaunch,
          (long)_recoveryAttempt,
          (long)OPNMaxAutomaticRecoveryAttempts);
    NSString *launchMessage = recoveringLaunch ? @"Preparing reconnect..." : @"Preparing stream launch...";
    [self ensureLoadingViewWithMessage:launchMessage];
    [self setLaunchStep:0 message:launchMessage];

    if (!_session.valid) {
        std::string error = "libwebrtc stream session is unavailable";
        [self setStatus:@"libwebrtc is unavailable in this build."];
        [self endStreamWithSuccess:NO errorMessage:error];
        return;
    }

    if (_appId.length == 0) {
        OPNLogError(@"[StreamVC] ERROR: appId is empty!");
        [self endStreamWithSuccess:NO errorMessage:"Invalid game ID"];
        return;
    }

    OPNDisplayStreamProfile displayProfile = ResolveDisplayStreamProfile(self.view.window);
    OPN::StreamPreferenceProfile requestedStreamProfile = OPN::LoadStreamPreferenceProfile();
    OPN::StreamPreferenceProfile gameStreamProfile;
    if (OPN::LoadStreamPreferenceProfileForGame(appId, gameStreamProfile)) {
        requestedStreamProfile = gameStreamProfile;
        OPNLogInfo(@"[StreamVC] Applying per-game stream profile for appId=%s resolutionIndex=%d fps=%d codec=%s bitrate=%dMbps region=%s",
              appId.c_str(),
              requestedStreamProfile.resolutionIndex,
              requestedStreamProfile.fps,
              requestedStreamProfile.codec.value.c_str(),
              requestedStreamProfile.maxBitrateMbps,
              requestedStreamProfile.selectedRegionUrl.c_str());
    }
    OPN::StreamDeviceCapabilities capabilities = OPN::LoadStreamDeviceCapabilities();
    OPN::StreamPreferenceProfile streamProfile = OPN::EffectiveStreamPreferenceProfileForCapabilities(requestedStreamProfile, capabilities);
    if (OPNStreamCodecSelectionIsExplicit(requestedStreamProfile)) {
        streamProfile.codecIndex = requestedStreamProfile.codecIndex;
        streamProfile.codec = requestedStreamProfile.codec;
    }
    if (requestedStreamProfile.codec.value != streamProfile.codec.value ||
        requestedStreamProfile.fps != streamProfile.fps ||
        requestedStreamProfile.colorQuality.value != streamProfile.colorQuality.value) {
        OPNLogInfo(@"[StreamVC] Capability-gated stream profile requested codec=%s fps=%d color=%s; effective codec=%s fps=%d color=%s hardware(h264=%d h265=%d av1=%d) display=%dx%d@%d",
              requestedStreamProfile.codec.value.c_str(),
              requestedStreamProfile.fps,
              requestedStreamProfile.colorQuality.value.c_str(),
              streamProfile.codec.value.c_str(),
              streamProfile.fps,
              streamProfile.colorQuality.value.c_str(),
              capabilities.h264HardwareDecodeSupported,
              capabilities.h265HardwareDecodeSupported,
              capabilities.av1HardwareDecodeSupported,
              capabilities.maxDisplayWidth,
              capabilities.maxDisplayHeight,
              capabilities.maxDisplayRefreshRate);
    }
    OPN::StreamResolutionOption effectiveResolution = OPNEffectiveStreamResolution(streamProfile, displayProfile);
    OPN::StreamSettings settings;
    settings.resolution = effectiveResolution.Value();
    settings.fps = streamProfile.enablePowerSaver ? std::min(streamProfile.fps, 30) : streamProfile.fps;
    settings.codec = OPNEffectiveStreamCodec(streamProfile, effectiveResolution, capabilities);
    settings.colorQuality = streamProfile.colorQuality.value.empty() ? "8bit_420" : streamProfile.colorQuality.value;
    settings.maxBitrateMbps = OPNEffectiveMaxBitrateMbps(streamProfile);
    settings.prefilterMode = streamProfile.prefilterMode;
    settings.prefilterSharpness = streamProfile.prefilterSharpness;
    settings.prefilterDenoise = streamProfile.prefilterDenoise;
    settings.prefilterModel = streamProfile.prefilterModel;
    settings.enableL4S = streamProfile.enableL4S;
    settings.enableHdr = streamProfile.enableHdr;
    settings.lowLatencyMode = streamProfile.lowLatencyMode;
    settings.microphoneMode = streamProfile.microphoneMode;
    settings.microphoneDeviceId = streamProfile.microphoneDeviceId;
    settings.microphonePushToTalkKeyCode = streamProfile.microphonePushToTalkKeyCode;
    settings.microphonePushToTalkModifierMask = streamProfile.microphonePushToTalkModifierMask;
    settings.gameVolume = streamProfile.gameVolume;
    settings.microphoneVolume = streamProfile.microphoneVolume;
    settings.gameLanguage = [OPNLocale currentGFNLocale].UTF8String ?: "";
    settings.accountLinked = _accountLinked;
    settings.selectedStore = OPNStdStringFromNSString(_selectedStore);
    settings.remoteControllersBitmap = OPNConnectedControllerBitmap();
    settings.availableSupportedControllers = OPNAvailableSupportedControllers();
    if (streamProfile.lowLatencyMode) {
        settings.prefilterMode = 0;
        settings.prefilterSharpness = 0;
        settings.prefilterDenoise = 0;
        settings.prefilterModel = 0;
    }
    [self.streamView setVideoAspectRatio:(CGFloat)OPNAspectRatioForResolution(effectiveResolution, streamProfile.AspectRatio())];
    [self.streamView setVideoUpscalingMode:streamProfile.lowLatencyMode ? 0 : streamProfile.upscalingMode
                                 sharpness:streamProfile.lowLatencyMode ? 0 : streamProfile.upscalingSharpness
                                  denoise:streamProfile.lowLatencyMode ? 0 : streamProfile.upscalingDenoise
                              streamWidth:effectiveResolution.width
                             streamHeight:effectiveResolution.height];
    [self.streamView setSuppressInputWhenWindowInactive:streamProfile.suppressInputWhenInactive ? YES : NO];
    [self.streamView setDirectMouseInputEnabled:streamProfile.directMouseInput ? YES : NO];
    [self.streamView setMaxBitrateMbps:settings.maxBitrateMbps];
    [self.streamView setMicrophoneMode:OPNStringFromStdString(settings.microphoneMode, @"disabled")
                     pushToTalkKeyCode:(uint16_t)settings.microphonePushToTalkKeyCode
                          modifierMask:(uint16_t)settings.microphonePushToTalkModifierMask];

    if (settings.microphoneMode != "disabled") {
        AVAuthorizationStatus microphoneStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (microphoneStatus == AVAuthorizationStatusDenied || microphoneStatus == AVAuthorizationStatusRestricted) {
            OPNLogError(@"[StreamVC] Microphone permission denied or restricted; cannot start mic-enabled stream");
            OPNRecordSentryCounterMetric("opennow.stream.launch.count", 1, @{@"outcome": @"microphone_permission_denied"});
            [self setStatus:@"Microphone permission is disabled. Enable it in macOS Settings > Privacy & Security > Microphone."];
            [self endStreamWithSuccess:NO errorMessage:"Microphone permission denied"];
            return;
        }
        if (microphoneStatus == AVAuthorizationStatusNotDetermined) {
            NSUInteger permissionGeneration = launchGeneration;
            [self setStatus:@"Requesting microphone permission..."];
            OPNLogInfo(@"[StreamVC] Requesting macOS microphone permission");
            __weak __typeof__(self) permissionWeakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __typeof__(self) strongSelf = permissionWeakSelf;
                    if (!strongSelf || strongSelf->_streamEnded) return;
                    if (strongSelf->_launchGeneration != permissionGeneration) return;
                    if (!granted) {
                        OPNLogError(@"[StreamVC] macOS microphone permission request denied");
                        OPNRecordSentryCounterMetric("opennow.stream.launch.count", 1, @{@"outcome": @"microphone_permission_denied"});
                        [strongSelf setStatus:@"Microphone permission was denied. Enable it in macOS Settings > Privacy & Security > Microphone."];
                        [strongSelf endStreamWithSuccess:NO errorMessage:"Microphone permission denied"];
                        return;
                    }
                    OPNLogInfo(@"[StreamVC] macOS microphone permission granted; restarting launch flow");
                    [strongSelf startStreamLaunchFlow];
                });
            }];
            return;
        }
    }

    [self setLaunchStep:0 message:@"Preparing stream route..."];
    __weak __typeof__(self) weakSelf = self;
    OPN::StreamSettings requestedSettings = settings;
    [_healthReport setRequestedResolution:OPNStringFromStdString(requestedSettings.resolution, @"")
                                      fps:requestedSettings.fps
                                    codec:OPNStringFromStdString(requestedSettings.codec, @"")
                              bitrateMbps:requestedSettings.maxBitrateMbps];
    OPN::StreamPreferenceProfile preflightProfile = streamProfile;
    OPN::StreamDeviceCapabilities launchCapabilities = capabilities;

    auto cloudVariables = std::make_shared<OPN::StreamCloudVariables>();
    auto networkPreflight = std::make_shared<OPN::StreamNetworkPreflightResult>();
    auto cloudReady = std::make_shared<bool>(false);
    auto preflightReady = std::make_shared<bool>(false);
    auto continueWhenReady = std::make_shared<std::function<void()>>();
    *continueWhenReady = [weakSelf,
                          cloudVariables,
                          networkPreflight,
                          cloudReady,
                          preflightReady,
                          requestedSettings,
                          preflightProfile,
                          launchCapabilities,
                          launchGeneration,
                          recoveringLaunch]() {
        if (!*cloudReady || !*preflightReady) return;
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;

        const OPN::StreamCloudVariables variables = *cloudVariables;
        const OPN::StreamNetworkPreflightResult preflightCopy = *networkPreflight;
        OPN::StreamSettings preflightSettings = OPN::StreamSettingsByApplyingCloudVariables(requestedSettings, variables, launchCapabilities);
        if (OPNStreamCodecSelectionIsExplicit(preflightProfile)) preflightSettings.codec = requestedSettings.codec;
        [strongSelf resetQualityGuardrailsForBitrate:preflightSettings.maxBitrateMbps];
        [strongSelf.streamView setMaxBitrateMbps:preflightSettings.maxBitrateMbps];
        if (variables.fetched) {
            OPNLogInfo(@"[StreamVC] Cloud variables applied codec=%s hdr=%d l4s=%d reflex=%d bitrate=%dMbps prefilter=%d/%d sharp=%d/%d denoise=%d/%d supportedPrefilterModes=%lu allowPrefilter=%d gpu=%s",
                  preflightSettings.codec.c_str(),
                  preflightSettings.enableHdr,
                  preflightSettings.enableL4S,
                  preflightSettings.enableReflex,
                  preflightSettings.maxBitrateMbps,
                  requestedSettings.prefilterMode,
                  preflightSettings.prefilterMode,
                  requestedSettings.prefilterSharpness,
                  preflightSettings.prefilterSharpness,
                  requestedSettings.prefilterDenoise,
                  preflightSettings.prefilterDenoise,
                  (unsigned long)variables.supportedPrefilterModes.size(),
                  variables.allowPrefilter,
                  variables.gpuName.c_str());
        }

        OPN::StreamSettings finalSettings = preflightSettings;
        finalSettings.networkTestSessionId = preflightCopy.networkTestSessionId;
        finalSettings.networkType = preflightCopy.networkType;
        finalSettings.networkLatencyMs = preflightCopy.latencyMs;
        if (preflightCopy.recommendedMaxBitrateMbps > 0) {
            finalSettings.maxBitrateMbps = std::min(finalSettings.maxBitrateMbps, preflightCopy.recommendedMaxBitrateMbps);
        }
        OPNLogInfo(@"[StreamVC] Final launch prefilter requested=%d/%d/%d preflight=%d/%d/%d final=%d/%d/%d cloudFetched=%d allowPrefilter=%d",
              requestedSettings.prefilterMode,
              requestedSettings.prefilterSharpness,
              requestedSettings.prefilterDenoise,
              preflightSettings.prefilterMode,
              preflightSettings.prefilterSharpness,
              preflightSettings.prefilterDenoise,
              finalSettings.prefilterMode,
              finalSettings.prefilterSharpness,
              finalSettings.prefilterDenoise,
              variables.fetched,
              variables.allowPrefilter);
        [strongSelf resetQualityGuardrailsForBitrate:finalSettings.maxBitrateMbps];
        [strongSelf.streamView setMaxBitrateMbps:finalSettings.maxBitrateMbps];

        std::string strongAppId = OPNStdStringFromNSString(strongSelf->_appId);
        std::string baseUrl = preflightCopy.streamingBaseUrl.empty() ? OPN::LoadSelectedStreamingBaseUrlForGame(strongAppId) : preflightCopy.streamingBaseUrl;
        [strongSelf->_healthReport setNetworkStreamingBaseUrl:OPNStringFromStdString(preflightCopy.streamingBaseUrl, @"")
                                                  networkType:OPNStringFromStdString(preflightCopy.networkType, @"Unknown")
                                                    latencyMs:preflightCopy.latencyMs
                                        measuredBandwidthMbps:preflightCopy.measuredBandwidthMbps
                                            packetLossPercent:preflightCopy.packetLossPercent
                                                     jitterMs:preflightCopy.jitterMs
                                          usedAutomaticRegion:preflightCopy.usedAutomaticRegion ? YES : NO
                                                       region:OPNStringFromStdString(baseUrl, @"")];
        OPNLogInfo(@"[StreamVC] Network preflight region=%s type=%s latency=%dms bandwidth=%.0fMbps loss=%.1f jitter=%dms bitrate=%dMbps testId=%s automatic=%d",
              baseUrl.c_str(),
              finalSettings.networkType.c_str(),
              finalSettings.networkLatencyMs,
              preflightCopy.measuredBandwidthMbps,
              preflightCopy.packetLossPercent,
              preflightCopy.jitterMs,
              finalSettings.maxBitrateMbps,
              finalSettings.networkTestSessionId.c_str(),
              preflightCopy.usedAutomaticRegion);
        void (^continueAfterNetworkWarning)(void) = ^{
            __typeof__(self) launchSelf = weakSelf;
            if (!launchSelf || launchSelf->_streamEnded || launchSelf->_launchGeneration != launchGeneration) return;
            [launchSelf beginSessionAllocationWithSettings:finalSettings
                                             streamProfile:preflightProfile
                                          streamingBaseUrl:baseUrl
                                          launchGeneration:launchGeneration
                                         recoveringLaunch:recoveringLaunch];
        };
        NSString *networkWarning = nil;
        if (!recoveringLaunch && OPNNetworkPreflightWarning(preflightCopy, preflightSettings.maxBitrateMbps, finalSettings.maxBitrateMbps, &networkWarning)) {
            [strongSelf->_healthReport recordEventWithTitle:@"Network warning" detail:networkWarning ?: @"OpenNOW detected poor network conditions" now:CACurrentMediaTime()];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Network Test Warning";
            alert.informativeText = networkWarning ?: @"OpenNOW detected poor network conditions. You can continue anyway, but stream quality may be reduced.";
            [alert addButtonWithTitle:@"Continue Anyway"];
            [alert addButtonWithTitle:@"Cancel"];
            [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:^(NSModalResponse returnCode) {
                if (returnCode == NSAlertFirstButtonReturn) {
                    continueAfterNetworkWarning();
                    return;
                }
                __typeof__(self) cancelSelf = weakSelf;
                if (!cancelSelf || cancelSelf->_streamEnded || cancelSelf->_launchGeneration != launchGeneration) return;
                [cancelSelf->_healthReport recordEventWithTitle:@"Launch cancelled" detail:@"User cancelled after the network warning" now:CACurrentMediaTime()];
                [cancelSelf endStreamWithSuccess:NO errorMessage:"Launch cancelled after network test warning."];
            }];
            return;
        }
        continueAfterNetworkWarning();
    };

    OPN::FetchStreamCloudVariables(apiToken, [weakSelf, cloudVariables, cloudReady, continueWhenReady, launchGeneration](const OPN::StreamCloudVariables &variables) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
            *cloudVariables = variables;
            *cloudReady = true;
            if (*continueWhenReady) (*continueWhenReady)();
        });
    });
    OPN::RunStreamNetworkPreflight(apiToken,
                                    OPN::LoadSelectedStreamingBaseUrlForGame(appId),
                                   requestedSettings.maxBitrateMbps,
        [weakSelf, networkPreflight, preflightReady, continueWhenReady, launchGeneration](const OPN::StreamNetworkPreflightResult &preflight) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
                *networkPreflight = preflight;
                *preflightReady = true;
                if (*continueWhenReady) (*continueWhenReady)();
            });
        });
}

- (void)endStreamWithSuccess:(BOOL)success errorMessage:(const std::string &)errorMessage {
    if (![NSThread isMainThread]) {
        std::string errorMessageCopy = errorMessage;
        __weak OPNStreamViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPNStreamViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf endStreamWithSuccess:success errorMessage:errorMessageCopy];
        });
        return;
    }

    if (_streamEnded) return;
    _streamEnded = YES;
    if (_connectedStartTime > 0.0) {
        CFTimeInterval streamDurationMs = MAX(0.0, (CACurrentMediaTime() - _connectedStartTime) * 1000.0);
        OPNRecordSentryDistributionMetric("opennow.stream.duration", streamDurationMs, "millisecond", @{
            @"outcome": success ? @"success" : @"failure",
            @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
            @"connected_once": @(_connectedOnce),
        });
    }
    OPNRecordSentryCounterMetric("opennow.stream.connection.count", 1, @{
        @"outcome": success ? @"ended" : @"failed",
        @"backend": _webRTCBackendName.length > 0 ? _webRTCBackendName : @"unknown",
        @"connected_once": @(_connectedOnce),
    });
    std::string displayError = success ? std::string() : OPNUserFacingGFNErrorMessageForTitle(errorMessage, _gameTitle, _connectedOnce);
    [_healthReport addStatsSnapshot:[_session latestStatsSnapshot]];
    OPNSessionReportPayload *finalizedReport = [_healthReport finalizeWithSuccess:success terminalError:OPNStringFromStdString(displayError, @"") now:CACurrentMediaTime()];
    NSString *reason = success
        ? @"ended"
        : (displayError.empty() ? @"failed" : OPNStringFromStdString(displayError, @"failed"));
    [self finishLaunchMeasurementWithSuccess:success reason:reason];
    if (!success) {
        NSString *message = reason.length > 0 ? reason : @"Stream failed";
        [OPNLogCapture appendEvent:[NSString stringWithFormat:@"[StreamVC] Stream ending with error: %@", message]];
        if (OPNShouldReportTerminalStreamFailure(message)) {
            NSString *phase = _connectedOnce ? @"runtime" : (_resumeExistingSession ? @"resume" : @"launch");
            NSString *reportMessage = OPNStreamFailureReportMessage(message);
            OPNLogError(@"[StreamVC] Terminal stream failure phase=%@ connected=%d recovery=%d appId=%s sessionId=%s server=%s error=%@",
                          phase,
                          _connectedOnce,
                          _recovering,
                           [_appId UTF8String] ?: "",
                          _hasActiveSessionInfo ? _activeSessionInfo.sessionId.c_str() : "",
                          _hasActiveSessionInfo ? _activeSessionInfo.serverIp.c_str() : "",
                          reportMessage);
        }
    }
    [self cleanup];

    if (self.onStreamEnd) {
        self.onStreamEnd(success, OPNStringFromStdString(displayError, @""), finalizedReport);
    }
}

- (void)cleanup {
    if (![NSThread isMainThread]) {
        __weak OPNStreamViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            OPNStreamViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf cleanup];
        });
        return;
    }

    _launchGeneration++;
    _stableResetGeneration++;
    _recovering = NO;
    _idleDeviceInputEnabled = NO;
    if (_streamLaunchTrace) {
        [_streamLaunchTrace setStatus:NO];
        [_streamLaunchTrace finish];
        _streamLaunchTrace = nil;
    }
    [self endLatencyActivity];
    [self cancelRemoteIceGraceTimer];
    [self stopInactivityTimer];
    [self stopPlaytimeRefreshTimer];
    [self removeQuitShortcutMonitor];
    [self dismissQuitGameOverlayAndRefocus:NO];
    [self stopStatsRefreshTimer];
    [self.streamView stopRecordingIfNeeded];
    if (self.statsOverlay) {
        [self.statsOverlay removeFromSuperview];
        self.statsOverlay = nil;
    }
    if (self.shortcutLegendOverlay) {
        [self.shortcutLegendOverlay removeFromSuperview];
        self.shortcutLegendOverlay = nil;
    }
    [_connectedToast removeFromSuperview];
    _connectedToast = nil;
    if (self.streamView) {
        [self.streamView setStreamActive:NO];
        [self.streamView detachFromPipeline];
    }
    if (self.loadingView) {
        [self.loadingView stopAnimating];
        [self.loadingView removeFromSuperview];
        self.loadingView = nil;
        self.statusLabel = nil;
    }
    if (_signaling) {
        [_signaling disconnect];
        _signaling = nil;
    }
    if (_session) {
        [self clearCurrentSessionCallbacks];
        [_session stop];
        _session = nil;
    }
}

- (void)dealloc {
    [self cleanup];
    _healthReport = nil;
}

@end
