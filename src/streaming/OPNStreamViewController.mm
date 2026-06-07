#import "OPNStreamViewController.h"
#import "OPNStreamView.h"
#import "../views/OPNLoadingView.h"
#include "OPNSignalingClient.h"
#include "OPNStreamSession.h"
#include "OPNStreamBackend.h"
#include "OPNStreamPreferences.h"
#include "../common/OPNLogCapture.h"
#include "../common/OPNLocale.h"
#include "../common/OPNDiscordPresence.h"
#include "../common/OPNSessionHealthReport.h"
#include "../common/OPNGFNError.h"
#include "OPNSessionManager.h"
#include "../games/OPNGameService.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <VideoToolbox/VideoToolbox.h>
#import <os/signpost.h>
#include <algorithm>
#include <cmath>
#include <sstream>
#include <vector>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include "common/OPNSentry.h"

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

@interface OPNQuitGameOverlayView : NSView
@property (nonatomic, copy) void (^onCancel)(void);
@property (nonatomic, copy) void (^onQuit)(void);
@end

@interface OPNShortcutLegendView : NSView
@end

@interface OPNStatsOverlayView : NSView
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
@property (nonatomic, assign) std::string gameTitle;
@property (nonatomic, assign) std::string appId;
@property (nonatomic, assign) std::string apiToken;
@property (nonatomic, assign) std::string selectedStore;
@property (nonatomic, assign) std::string resumeSessionId;
@property (nonatomic, assign) std::string resumeServer;
@property (nonatomic, assign) BOOL accountLinked;
@property (nonatomic, assign) BOOL resumeExistingSession;
@property (nonatomic, assign) BOOL streamStarted;
@property (nonatomic, assign) BOOL launchSignpostActive;
@property (nonatomic, assign) CFTimeInterval launchStartTime;
@property (nonatomic, assign) os_signpost_id_t launchSignpostId;
- (void)finishLaunchMeasurementWithSuccess:(BOOL)success reason:(NSString *)reason;
- (NSString *)launchStatusMessageForStep:(NSInteger)stepIndex baseMessage:(NSString *)baseMessage;
- (void)resetQualityGuardrailsForBitrate:(int)bitrateMbps;
- (void)evaluateQualityGuardrailsWithStats:(const OPN::StreamStats &)stats;
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

static BOOL OPNShouldReportTerminalStreamFailure(NSString *message) {
    if (message.length == 0) return YES;
    return ![message isEqualToString:@"Session ended due to inactivity."]
        && ![message isEqualToString:@"Microphone permission denied"];
}

static NSString *OPNBoundedStreamFailureMessage(NSString *message) {
    if (message.length <= 700) return message;
    return [[message substringToIndex:700] stringByAppendingString:@"..."];
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

static bool IsDottedIp(const std::string &value) {
    int dots = 0;
    int digits = 0;
    if (value.empty()) return false;
    for (char c : value) {
        if (c == '.') {
            if (digits == 0) return false;
            dots++;
            digits = 0;
        } else if (std::isdigit((unsigned char)c)) {
            digits++;
            if (digits > 3) return false;
        } else {
            return false;
        }
    }
    return dots == 3 && digits > 0;
}

static std::string ExtractPublicIp(const std::string &hostOrIp) {
    if (hostOrIp.empty()) return "";
    if (IsDottedIp(hostOrIp)) return hostOrIp;

    std::string firstLabel = hostOrIp.substr(0, hostOrIp.find('.'));
    std::vector<std::string> parts;
    std::stringstream ss(firstLabel);
    std::string part;
    while (std::getline(ss, part, '-')) {
        if (part.empty()) return "";
        for (char c : part) {
            if (!std::isdigit((unsigned char)c)) return "";
        }
        parts.push_back(part);
    }

    if (parts.size() != 4) return "";
    return parts[0] + "." + parts[1] + "." + parts[2] + "." + parts[3];
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
    if (preflight.latencyMs >= 150) {
        [issues addObject:[NSString stringWithFormat:@"Latency is very high (%d ms).", preflight.latencyMs]];
    } else if (preflight.latencyMs >= 80) {
        [issues addObject:[NSString stringWithFormat:@"Latency is elevated (%d ms).", preflight.latencyMs]];
    }
    if (preflight.measuredBandwidthMbps > 0.0 && preflight.measuredBandwidthMbps < requestedMaxBitrateMbps) {
        [issues addObject:[NSString stringWithFormat:@"Measured bandwidth is %.0f Mbps.", preflight.measuredBandwidthMbps]];
    }
    if (preflight.packetLossPercent >= 2.0) {
        [issues addObject:[NSString stringWithFormat:@"Packet loss is %.1f%%.", preflight.packetLossPercent]];
    }
    if (preflight.jitterMs >= 30) {
        [issues addObject:[NSString stringWithFormat:@"Jitter is %d ms.", preflight.jitterMs]];
    }
    if (effectiveMaxBitrateMbps > 0 && requestedMaxBitrateMbps > effectiveMaxBitrateMbps) {
        [issues addObject:[NSString stringWithFormat:@"OpenNOW lowered the stream bitrate from %d Mbps to %d Mbps for this route.", requestedMaxBitrateMbps, effectiveMaxBitrateMbps]];
    }
    if (preflight.serverReportedWarning && !preflight.warningMessage.empty()) {
        [issues addObject:OPNStringFromStdString(preflight.warningMessage, @"The network test reported a warning.")];
    }
    if (!preflight.continueRecommended) {
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
                                            OPN::StreamWebRTCBackend backend,
                                            const OPN::StreamDeviceCapabilities &capabilities) {
    bool libWebRTCAvailable = backend == OPN::StreamWebRTCBackend::LibWebRTC;
    return OPN::ResolveStreamCodecForCapabilities(profile, resolution, capabilities, libWebRTCAvailable);
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
    NSUInteger count = MIN((NSUInteger)OPN::Input::GAMEPAD_MAX_CONTROLLERS, controllers.count);
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

static std::string ExtractIceUfragFromOffer(const std::string &sdp) {
    std::stringstream ss(sdp);
    std::string line;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const char *prefix = "a=ice-ufrag:";
        if (line.rfind(prefix, 0) == 0) {
            return line.substr(strlen(prefix));
        }
    }
    return "";
}

struct OPNIceMediaTarget {
    std::string sdpMid;
    int sdpMLineIndex = 0;
};

static OPNIceMediaTarget ExtractVideoIceTargetFromOffer(const std::string &sdp) {
    OPNIceMediaTarget target;
    std::stringstream ss(sdp);
    std::string line;
    bool inVideoSection = false;
    int mediaIndex = -1;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("m=", 0) == 0) {
            mediaIndex++;
            inVideoSection = line.rfind("m=video ", 0) == 0;
            if (inVideoSection) {
                target.sdpMLineIndex = mediaIndex;
                target.sdpMid = std::to_string(mediaIndex);
            }
            continue;
        }
        if (inVideoSection && line.rfind("a=mid:", 0) == 0) {
            target.sdpMid = line.substr(strlen("a=mid:"));
            break;
        }
    }
    return target;
}

static void InjectManualIceCandidate(OPN::IStreamSession *session,
                                     const OPN::SessionInfo &sessionInfo,
                                     const std::string &offerSdp,
                                     const std::string &serverIceUfrag) {
    if (!session) return;
    const char *manualIce = getenv("OPN_INJECT_MANUAL_ICE");
    if (manualIce && strcmp(manualIce, "0") == 0) {
        OPN::LogInfo(@"[StreamVC] Manual ICE candidate injection disabled by OPN_INJECT_MANUAL_ICE=0");
        return;
    }
    const bool offerHasPlaceholders = offerSdp.find("0.0.0.0") != std::string::npos;
    const bool forceManualIce = manualIce && strcmp(manualIce, "1") == 0;
    if (!offerHasPlaceholders && !forceManualIce) return;

    std::string ip = ExtractPublicIp(sessionInfo.mediaConnectionInfo.ip);
    int port = sessionInfo.mediaConnectionInfo.port;
    if (ip.empty() || port <= 0) {
        OPN::LogInfo(@"[StreamVC] No valid mediaConnectionInfo for manual ICE candidate (ip=%s, port=%d)",
              sessionInfo.mediaConnectionInfo.ip.c_str(), port);
        return;
    }

    OPNIceMediaTarget target = ExtractVideoIceTargetFromOffer(offerSdp);
    std::string candidate = "candidate:1 1 udp 2130706431 " + ip + " " + std::to_string(port) + " typ host";
    OPN::IceCandidatePayload payload;
    payload.candidate = candidate;
    payload.sdpMid = target.sdpMid;
    payload.sdpMLineIndex = target.sdpMLineIndex;
    payload.usernameFragment = serverIceUfrag;
    OPN::LogInfo(@"[StreamVC] Injecting fallback ICE candidate: %s:%d (sdpMid=%s mline=%d ufrag=%s placeholders=%d forced=%d)",
          ip.c_str(),
          port,
          payload.sdpMid.empty() ? "(none)" : payload.sdpMid.c_str(),
          payload.sdpMLineIndex,
          serverIceUfrag.empty() ? "(none)" : serverIceUfrag.c_str(),
          offerHasPlaceholders ? 1 : 0,
          forceManualIce ? 1 : 0);
    session->AddRemoteIceCandidate(payload);
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
           error.find("UNKNOWN 8A8C0000") != std::string::npos;
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

@implementation OPNShortcutLegendView {
    NSTextField *_titleLabel;
    NSArray<NSTextField *> *_shortcutLabels;
    NSArray<NSTextField *> *_descriptionLabels;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 18.0;
        self.layer.backgroundColor = OPNQuitColor(0.03, 0.035, 0.045, 0.90).CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = OPNQuitColor(1.0, 1.0, 1.0, 0.12).CGColor;

        _titleLabel = OPNQuitLabel(@"Shortcuts", 18.0, NSFontWeightSemibold, OPNQuitColor(0.96, 0.97, 0.99, 1.0), NSTextAlignmentLeft);
        [self addSubview:_titleLabel];

        NSArray<NSString *> *shortcuts = @[@"Hold Options", @"Command-H", @"Command-G", @"Command-R", @"Command-N", @"Command-M", @"Command-K", @"Command-L", @"Command-Q", @"Hold Esc"];
        NSArray<NSString *> *descriptions = @[@"Home dashboard", @"Toggle this legend", @"Audio HUD", @"Record stream", @"Stats HUD", @"Toggle microphone", @"Anti-AFK", @"Copy logs", @"Quit stream", @"Release pointer"];
        NSMutableArray<NSTextField *> *shortcutLabels = [NSMutableArray arrayWithCapacity:shortcuts.count];
        NSMutableArray<NSTextField *> *descriptionLabels = [NSMutableArray arrayWithCapacity:descriptions.count];
        for (NSUInteger i = 0; i < shortcuts.count; i++) {
            NSTextField *shortcut = OPNQuitLabel(shortcuts[i], 12.0, NSFontWeightSemibold, OPNQuitColor(0.75, 0.92, 0.86, 1.0), NSTextAlignmentLeft);
            NSTextField *description = OPNQuitLabel(descriptions[i], 12.0, NSFontWeightRegular, OPNQuitColor(0.74, 0.76, 0.80, 1.0), NSTextAlignmentRight);
            [shortcutLabels addObject:shortcut];
            [descriptionLabels addObject:description];
            [self addSubview:shortcut];
            [self addSubview:description];
        }
        _shortcutLabels = shortcutLabels;
        _descriptionLabels = descriptionLabels;
    }
    return self;
}

- (void)layout {
    [super layout];
    CGFloat padding = 20.0;
    CGFloat width = NSWidth(self.bounds);
    CGFloat top = NSHeight(self.bounds);
    _titleLabel.frame = NSMakeRect(padding, top - 42.0, width - padding * 2.0, 22.0);
    for (NSUInteger i = 0; i < _shortcutLabels.count; i++) {
        CGFloat y = top - 78.0 - (CGFloat)i * 28.0;
        _shortcutLabels[i].frame = NSMakeRect(padding, y, 112.0, 18.0);
        _descriptionLabels[i].frame = NSMakeRect(132.0, y, width - 132.0 - padding, 18.0);
    }
}

@end

@implementation OPNStatsOverlayView {
    NSTextField *_statsLineLabel;
}

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
    style.lineBreakMode = NSLineBreakByTruncatingTail;
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
        _statsLineLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _statsLineLabel.maximumNumberOfLines = 1;
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
    _statsLineLabel.frame = NSInsetRect(self.bounds, 8.0, 1.0);
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

static void OPNReleaseSignalingClientAfterCallbacks(OPN::SignalingClient *client) {
    if (!client) return;
    client->Disconnect();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        delete client;
    });
}

static void OPNReleaseStreamSessionAfterCallbacks(OPN::IStreamSession *session) {
    if (!session) return;
    session->Stop();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        delete session;
    });
}

@implementation OPNStreamViewController {
    OPN::SignalingClient *_signaling;
    OPN::IStreamSession *_session;
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
    std::string _webRTCBackendName;
    OPN::SessionInfo _activeSessionInfo;
    BOOL _hasActiveSessionInfo;
    BOOL _remoteStopRequested;
    NSView *_connectedToast;
    id _latencyActivity;
    CFTimeInterval _lastStreamActivityTime;
    CFTimeInterval _lastIdleDeviceInputTime;
    CFTimeInterval _launchFlowStartTime;
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
    OPN::SessionHealthReportBuilder _healthReport;
}

- (instancetype)initWithGameTitle:(const std::string &)title
                             appId:(const std::string &)appId
                          apiToken:(const std::string &)token
                     accountLinked:(bool)accountLinked
                      selectedStore:(const std::string &)selectedStore {
    return [self initWithGameTitle:title
                             appId:appId
                          apiToken:token
                     accountLinked:accountLinked
                     selectedStore:selectedStore
                   resumeSessionId:""
                       resumeServer:""];
}

- (instancetype)initWithGameTitle:(const std::string &)title
                             appId:(const std::string &)appId
                          apiToken:(const std::string &)token
                     accountLinked:(bool)accountLinked
                     selectedStore:(const std::string &)selectedStore
                   resumeSessionId:(const std::string &)resumeSessionId
                       resumeServer:(const std::string &)resumeServer {
    self = [super init];
    if (self) {
        _gameTitle = title;
        _appId = appId;
        _apiToken = token;
        _accountLinked = accountLinked;
        _selectedStore = selectedStore;
        _resumeSessionId = resumeSessionId;
        _resumeServer = resumeServer;
        _resumeExistingSession = !_resumeSessionId.empty() && !_resumeServer.empty();
        OPN::StreamWebRTCBackend backend = OPN::ResolveStreamWebRTCBackend();
        _session = OPN::CreateStreamSession(backend).release();
        _webRTCBackendName = OPN::StreamWebRTCBackendName(backend);
        OPN::LogInfo(@"[StreamVC] WebRTC backend selected: %s", OPN::StreamWebRTCBackendName(backend).c_str());
        _initialViewFrame = NSMakeRect(0, 0, 1, 1);
        _signaling = nullptr;
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
    [self.streamView setStreamSession:_session];
    [self.streamView setRecordingGameTitle:OPNStringFromStdString(_gameTitle, @"Stream")];
    if (_remainingPlaytimeAvailable) {
        [self.streamView setRemainingPlaytimeHours:_remainingPlaytimeHours unlimited:_remainingPlaytimeUnlimited];
    }
    OPN::LogInfo(@"[StreamVC] loadView called, view=%p", (__bridge void *)view);
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
    OPN::LogInfo(@"[StreamVC] viewDidLoad called");

    NSRect bounds = self.view.bounds;
    OPN::LogInfo(@"[StreamVC] view bounds: %@", NSStringFromRect(bounds));

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
    OPN::LogInfo(@"[StreamVC] viewWillAppear called");
}

- (void)viewDidAppear {
    [super viewDidAppear];
    OPN::LogInfo(@"[StreamVC] viewDidAppear called, streamStarted=%d, streamEnded=%d", _streamStarted, _streamEnded);
    [self installQuitShortcutMonitor];
    if (!_streamStarted && !_streamEnded) {
        OPN::LogInfo(@"[StreamVC] Triggering startStreamLaunchFlow");
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
    _healthReport.MarkPhase(phase, CACurrentMediaTime());
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
        OPN::SessionManager::Shared().ReportSessionAd(sessionInfo,
                                                       adIdString,
                                                       actionString,
                                                       (int)watchedTimeInMs,
                                                       (int)pausedTimeInMs,
                                                       cancelReasonString,
                                                       [weakSelf](bool ok, const OPN::SessionInfo &updatedInfo, const std::string &error) {
            __typeof__(self) callbackSelf = weakSelf;
            if (!callbackSelf || callbackSelf->_streamEnded) return;
            if (!ok) {
                OPN::LogError(@"[StreamVC] Ad report failed: %s", error.c_str());
                return;
            }
            OPN::SessionInfo updatedInfoCopy = updatedInfo;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!callbackSelf || callbackSelf->_streamEnded || !callbackSelf.loadingView) return;
                callbackSelf->_activeSessionInfo = updatedInfoCopy;
                callbackSelf->_hasActiveSessionInfo = YES;
                [callbackSelf.loadingView updateAdState:updatedInfoCopy.adState];
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
            [self.loadingView updateAdState:sessionInfoCopy.adState];
        } else {
            [self.loadingView clearAdPresentation];
        }
    });
}

- (void)finishLaunchMeasurementWithSuccess:(BOOL)success reason:(NSString *)reason {
    if (!self.launchSignpostActive) return;
    self.launchSignpostActive = NO;
    CFTimeInterval elapsedMs = (CACurrentMediaTime() - self.launchStartTime) * 1000.0;
    NSString *safeReason = reason.length > 0 ? reason : @"unknown";
    os_signpost_interval_end(OPNStreamPerformanceLog(),
                             self.launchSignpostId,
                             "StreamLaunch",
                             "success=%{public}s elapsed_ms=%.1f reason=%{public}@",
                             success ? "yes" : "no",
                             elapsedMs,
                             safeReason);
    OPN::LogInfo(@"[StreamVC] Stream launch measurement success=%d elapsed=%.1fms reason=%@", success, elapsedMs, safeReason);
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
    CGFloat width = MIN(620.0, MAX(320.0, NSWidth(self.view.bounds) - 32.0));
    CGFloat height = 22.0;
    return NSMakeRect(MAX(16.0, NSWidth(self.view.bounds) - width - 16.0),
                      floor(NSHeight(self.view.bounds) - height - 8.0),
                      width,
                      height);
}

- (void)showConnectedToastWithResolution:(const std::string &)resolution
                                      fps:(int)fps
                                  bitrate:(int)bitrateMbps
                                    codec:(const std::string &)codec {
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

    NSString *detail = [NSString stringWithFormat:@"%s • %s • %d fps • %d Mbps",
                        _webRTCBackendName.c_str(),
                        codec.c_str(),
                        fps,
                        bitrateMbps];
    if (!resolution.empty()) {
        detail = [NSString stringWithFormat:@"%@ • %s", detail, resolution.c_str()];
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

- (void)evaluateQualityGuardrailsWithStats:(const OPN::StreamStats &)stats {
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
    if (droppedFrames) [signals addObject:[NSString stringWithFormat:@"%llu dropped", (unsigned long long)stats.framesDropped]];

    CFTimeInterval now = CACurrentMediaTime();
    BOOL cooldownElapsed = _lastQualityGuardrailChangeTime <= 0.0 || now - _lastQualityGuardrailChangeTime >= OPNStreamQualityGuardrailCooldownInterval;
    int reducedBitrate = MAX(OPNStreamMinimumGuardrailBitrateMbps, (int)std::floor((double)_runtimeMaxBitrateMbps * 0.80));
    NSString *signalText = [signals componentsJoinedByString:@", "];
    if (cooldownElapsed && reducedBitrate < _runtimeMaxBitrateMbps) {
        _runtimeMaxBitrateMbps = reducedBitrate;
        _lastQualityGuardrailChangeTime = now;
        _qualityDegradedSampleCount = 0;
        [self.streamView setMaxBitrateMbps:reducedBitrate];
        if (_session) _session->SetMaxBitrateMbps(reducedBitrate);
        NSString *detail = [NSString stringWithFormat:@"%@ · capped at %d Mbps", signalText, reducedBitrate];
        [self showQualityGuardrailToastWithTitle:@"Stream quality guardrail applied" detail:detail warning:YES];
        _healthReport.RecordEvent("Quality guardrail applied", [detail UTF8String] ?: "", now);
        OPN::LogInfo(@"[StreamVC] Quality guardrail lowered runtime bitrate to %d Mbps after signals: %@", reducedBitrate, signalText);
        return;
    }

    if (!_qualityWarningShown) {
        _qualityWarningShown = YES;
        NSString *detail = [NSString stringWithFormat:@"%@ · consider 30 FPS or H264 if this continues", signalText];
        [self showQualityGuardrailToastWithTitle:@"Stream quality is unstable" detail:detail warning:YES];
        _healthReport.RecordEvent("Quality warning", [detail UTF8String] ?: "", CACurrentMediaTime());
        OPN::LogInfo(@"[StreamVC] Quality warning shown after signals: %@", signalText);
    }
}

- (void)copyCurrentLogToClipboardFromShortcut {
    if (_streamEnded) return;
    OPN::AppendLogEvent(@"[StreamVC] Command-L requested log copy");
    OPN::CopyCapturedLogToClipboard(@"Command-L log copy");
    [self showLogCopiedToast];
    [self.streamView takeFocus];
    OPN::LogInfo(@"[StreamVC] Current log copied to clipboard via CMD+L");
}

- (void)updateStatsOverlay {
    OPN::StreamStats stats;
    if (_session) {
        _session->RequestStats();
        stats = _session->GetLatestStats();
    }
    _healthReport.AddStatsSample(stats);
    [self evaluateQualityGuardrailsWithStats:stats];
    if (!self.statsOverlay) return;

    NSInteger latencyMs = stats.latencyMs >= 0 ? (NSInteger)std::llround(stats.latencyMs) : -1;
    int64_t packetsLost = stats.available ? stats.packetsLost : -1;
    NSString *resolution = [NSString stringWithUTF8String:stats.resolution.c_str()];
    NSString *codec = [NSString stringWithUTF8String:stats.codec.c_str()];
    NSString *enhancement = @"";
    if (!stats.videoEnhancementActiveTier.empty()) {
        NSString *activeTier = [NSString stringWithUTF8String:stats.videoEnhancementActiveTier.c_str()];
        NSString *drawable = [NSString stringWithUTF8String:stats.videoEnhancementDrawableResolution.c_str()];
        NSString *fallbackReason = [NSString stringWithUTF8String:stats.videoEnhancementFallbackReason.c_str()];
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
    OPN::SessionManager::Shared().PollSession(currentSession.sessionId, currentSession.serverIp, [weakSelf](bool success, const OPN::SessionInfo &info, const std::string &error) {
        OPN::SessionInfo infoCopy = info;
        std::string errorCopy = error;
        dispatch_async(dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_playtimeRefreshInFlight = NO;
        if (strongSelf->_streamEnded) return;
        if (!success) {
            OPN::LogError(@"[StreamVC] Playtime refresh failed: %s", errorCopy.c_str());
            return;
        }
        if (!infoCopy.sessionId.empty()) {
            strongSelf->_activeSessionInfo = infoCopy;
            strongSelf->_hasActiveSessionInfo = YES;
        }
        if (!infoCopy.remainingPlaytimeAvailable) return;
        [strongSelf setRemainingPlaytimeHours:infoCopy.remainingPlaytimeHours unlimited:infoCopy.remainingPlaytimeUnlimited];
        [strongSelf.streamView startRemainingPlaytimeCountdown];
        OPN::LogInfo(@"[StreamVC] Refreshed live session playtime remaining=%.2fh unlimited=%d", infoCopy.remainingPlaytimeHours, infoCopy.remainingPlaytimeUnlimited);
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
            OPN::LogInfo(@"[StreamVC] Stats overlay hidden via CMD+N");
            return;
        }

        OPNStatsOverlayView *overlay = [[OPNStatsOverlayView alloc] initWithFrame:[self statsOverlayFrame]];
        self.statsOverlay = overlay;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [self updateStatsOverlay];
        [self startStatsRefreshTimer];
        [self.streamView takeFocus];
        OPN::LogInfo(@"[StreamVC] Stats overlay shown via CMD+N");
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
            OPN::LogInfo(@"[StreamVC] Shortcut legend hidden via CMD+H");
            return;
        }

        OPNShortcutLegendView *overlay = [[OPNShortcutLegendView alloc] initWithFrame:[self shortcutLegendFrame]];
        self.shortcutLegendOverlay = overlay;
        [self.view addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
        [self.streamView takeFocus];
        OPN::LogInfo(@"[StreamVC] Shortcut legend shown via CMD+H");
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
        [self.streamView setStreamSession:nullptr];
        [self.streamView detachFromPipeline];
    }
    if (_signaling) {
        OPNReleaseSignalingClientAfterCallbacks(_signaling);
        _signaling = nullptr;
    }
    if (_session) {
        OPNReleaseStreamSessionAfterCallbacks(_session);
        _session = nullptr;
    }
    OPN::StreamWebRTCBackend backend = OPN::ResolveStreamWebRTCBackend();
    _session = OPN::CreateStreamSession(backend).release();
    _webRTCBackendName = OPN::StreamWebRTCBackendName(backend);
    _remoteIceReceived = NO;
    if (self.streamView) {
        [self.streamView setStreamSession:_session];
    }
}

- (void)beginLatencyActivity {
    if (_latencyActivity) return;
    NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
    _latencyActivity = [NSProcessInfo.processInfo beginActivityWithOptions:options reason:@"OpenNOW active cloud gaming stream"];
    OPN::LogInfo(@"[StreamVC] Latency-critical stream activity started");
}

- (void)endLatencyActivity {
    if (!_latencyActivity) return;
    [NSProcessInfo.processInfo endActivity:_latencyActivity];
    _latencyActivity = nil;
    OPN::LogInfo(@"[StreamVC] Latency-critical stream activity ended");
}

- (void)requestRemoteStopForActiveSession {
    if (_remoteStopRequested) return;
    if (!_hasActiveSessionInfo) {
        OPN::LogInfo(@"[StreamVC] No active session info available for remote stop");
        return;
    }

    OPN::SessionInfo sessionInfo = _activeSessionInfo;
    if (sessionInfo.sessionId.empty() || sessionInfo.serverIp.empty()) {
        OPN::LogError(@"[StreamVC] Cannot stop remote session; sessionId=%s serverIp=%s",
              sessionInfo.sessionId.empty() ? "(empty)" : sessionInfo.sessionId.c_str(),
              sessionInfo.serverIp.empty() ? "(empty)" : sessionInfo.serverIp.c_str());
        return;
    }

    _remoteStopRequested = YES;
    OPN::LogInfo(@"[StreamVC] Requesting remote session stop sessionId=%s serverIp=%s",
          sessionInfo.sessionId.c_str(),
          sessionInfo.serverIp.c_str());
    OPN::SessionManager::Shared().StopSession(sessionInfo.sessionId,
                                              sessionInfo.serverIp,
                                              [sessionInfo](bool ok, const std::string &error) {
        if (ok) {
            OPN::LogInfo(@"[StreamVC] Remote session stop succeeded sessionId=%s", sessionInfo.sessionId.c_str());
        } else {
            OPN::LogError(@"[StreamVC] Remote session stop failed sessionId=%s error=%s",
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
    OPN::LogInfo(@"[StreamVC] Idle device input mode %@; inactivity timeout %@",
                 _idleDeviceInputEnabled ? @"enabled" : @"disabled",
                 _idleDeviceInputEnabled ? @"disabled" : @"enabled");
}

- (void)sendRandomIdleDeviceInputIfNeededAtTime:(CFTimeInterval)now {
    if (!_session || !_session->InputReady()) return;
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
    _session->SendMouseMove(dx, dy);
    CFTimeInterval idleDuration = now - _lastStreamActivityTime;
    _lastStreamActivityTime = now;
    _lastIdleDeviceInputTime = now;
    OPN::LogInfo(@"[StreamVC] Sent idle device input pulse dx=%d dy=%d after %.1fs without user activity", dx, dy, idleDuration);

    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(OPNStreamIdleDeviceInputReturnDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __typeof__(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_streamEnded || !strongSelf->_session || !strongSelf->_session->InputReady()) return;
        strongSelf->_session->SendMouseMove((int16_t)-dx, (int16_t)-dy);
        OPN::LogInfo(@"[StreamVC] Sent idle device input return dx=%d dy=%d", (int16_t)-dx, (int16_t)-dy);
    });
}

- (void)endStreamFromInactivityTimeout {
    if (_streamEnded) return;
    OPN::LogInfo(@"[StreamVC] Stream ended due to user inactivity");
    OPN::AppendLogEvent(@"[StreamVC] Stream ended due to user inactivity");
    _healthReport.RecordEvent("Inactivity timeout", "Session ended because no user activity was detected", CACurrentMediaTime());
    [self requestRemoteStopForActiveSession];
    [self endStreamWithSuccess:NO errorMessage:"Session ended due to inactivity."];
}

- (void)endStreamFromUserQuit {
    if (_streamEnded) return;
    _healthReport.RecordEvent("User quit", "Stream ended from the quit confirmation", CACurrentMediaTime());
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
    OPN::LogInfo(@"[StreamVC] Application terminating; preserving remote session for resume");
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
        OPN::LogInfo(@"[StreamVC] No remote ICE received within %.0fms after offer; forcing targeted recovery",
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
            OPN::LogInfo(@"[StreamVC] Automatic recovery budget reset after stable connection");
        }
        strongSelf->_recoveryAttempt = 0;
    });
}

- (BOOL)beginAutomaticRecoveryForError:(const std::string &)error {
    if (_streamEnded || !OPNStreamErrorIsRecoverable(error)) return NO;
    if (!_connectedOnce) {
        OPN::LogInfo(@"[StreamVC] Skipping automatic recovery before confirmed stream connection: %s", error.c_str());
        return NO;
    }
    if (_recoveryAttempt >= OPNMaxAutomaticRecoveryAttempts) {
        OPN::LogError(@"[StreamVC] Automatic recovery exhausted after %ld attempts for error: %s",
              (long)_recoveryAttempt, error.c_str());
        return NO;
    }

    _recoveryAttempt++;
    _recovering = YES;
    _stableResetGeneration++;
    NSUInteger recoveryGeneration = ++_launchGeneration;
    NSTimeInterval delay = OPNRecoveryDelayForAttempt(_recoveryAttempt);
    NSString *message = [NSString stringWithFormat:@"Connection interrupted. Reconnecting (%ld/%ld)...",
                         (long)_recoveryAttempt,
                         (long)OPNMaxAutomaticRecoveryAttempts];
    OPN::LogInfo(@"[StreamVC] Starting automatic recovery attempt %ld/%ld in %.2fs after error: %s",
          (long)_recoveryAttempt,
          (long)OPNMaxAutomaticRecoveryAttempts,
          delay,
          error.c_str());
    _healthReport.RecordEvent("Recovery attempt", error, CACurrentMediaTime());

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
    OPN::StreamSettings negotiatedSettings = OPNSettingsWithNegotiatedProfile(settings, activeSessionInfo);
    _healthReport.SetSessionInfo(activeSessionInfo);
    _healthReport.SetFinalSettings(negotiatedSettings);
    if (negotiatedSettings.resolution != settings.resolution
        || negotiatedSettings.fps != settings.fps
        || negotiatedSettings.codec != settings.codec
        || negotiatedSettings.colorQuality != settings.colorQuality) {
        OPN::LogInfo(@"[StreamVC] Using finalized stream profile %s@%dfps codec=%s color=%s (requested %s@%dfps codec=%s color=%s)",
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

    _signaling = new OPN::SignalingClient(
        activeSessionInfo.signalingServer, activeSessionInfo.sessionId, activeSessionInfo.signalingUrl
    );
    _signaling->SetPeerResolution(negotiatedSettings.resolution);

    OPN::LogInfo(@"[StreamVC] Signaling client created, server=%s, url=%s", activeSessionInfo.signalingServer.c_str(), activeSessionInfo.signalingUrl.c_str());

    __weak __typeof__(self) weakSelf = self;
    _signaling->OnOffer([weakSelf, activeSessionInfo, negotiatedSettings, launchGeneration](const std::string &sdp) {
        __typeof__(self) s = weakSelf;
        if (!s || s->_streamEnded || s->_launchGeneration != launchGeneration) return;
        if (!s->_session) {
            [s endStreamWithSuccess:NO errorMessage:"libwebrtc stream session is unavailable"];
            return;
        }
        std::string serverIceUfrag = ExtractIceUfragFromOffer(sdp);
        std::string offerSdpCopy = sdp;
        s->_remoteIceReceived = NO;
        [s startRemoteIceGraceTimerForLaunchGeneration:launchGeneration];

        [s setLaunchStep:4 message:@"Negotiating stream..."];
        s->_healthReport.MarkPhase("Offer Received", CACurrentMediaTime());
        s->_session->SetNativeWindow((__bridge void *)[s.streamView nativeVideoView]);

        s->_session->OnAnswerReady([weakSelf, activeSessionInfo, offerSdpCopy, serverIceUfrag, launchGeneration](const OPN::SendAnswerRequest &answer) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_signaling || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            OPN::LogInfo(@"[StreamVC] Sending WebRTC answer (sdp=%zu, nvstSdp=%zu)",
                  answer.sdp.size(), answer.nvstSdp.size());
            s2->_signaling->SendAnswer(answer);
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) s3 = weakSelf;
                if (!s3 || !s3->_session || s3->_streamEnded || s3->_launchGeneration != launchGeneration) return;
                InjectManualIceCandidate(s3->_session, activeSessionInfo, offerSdpCopy, serverIceUfrag);
            });
        });

        s->_session->OnIceCandidateReady([weakSelf, launchGeneration](const OPN::IceCandidatePayload &candidate) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_signaling || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            s2->_signaling->SendIceCandidate(candidate);
        });

        [s setLaunchStep:5 message:@"Starting video pipeline..."];
        s->_session->Start(activeSessionInfo, sdp, negotiatedSettings, [weakSelf, activeSessionInfo, negotiatedSettings, launchGeneration](bool connected, const std::string &streamError) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            std::string streamErrorCopy = streamError;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
                if (connected) {
                    [s2 cancelRemoteIceGraceTimer];
                    s2->_connectedOnce = YES;
                    s2->_recovering = NO;
                    [s2 beginLatencyActivity];
                    [s2 setLaunchStep:6 message:@"Connected!"];
                    s2->_healthReport.MarkConnected(CACurrentMediaTime());
                    [s2 finishLaunchMeasurementWithSuccess:YES reason:@"connected"];
                    [s2.streamView setStreamSession:s2->_session];
                    [s2.streamView startRemainingPlaytimeCountdown];
                    if ([s2.streamView isSidebarHUDVisible]) {
                        [s2 refreshDisplayedPlaytimeFromSessionPoll];
                        [s2 startPlaytimeRefreshTimer];
                    }
                    [s2.streamView takeFocus];
                    [s2 startInactivityTimer];
                    OPN::DiscordPresence::Shared().UpdatePlaying(s2->_gameTitle,
                                                                  negotiatedSettings.resolution,
                                                                  negotiatedSettings.fps,
                                                                  negotiatedSettings.maxBitrateMbps,
                                                                  negotiatedSettings.codec);
                    [s2 showConnectedToastWithResolution:negotiatedSettings.resolution fps:negotiatedSettings.fps bitrate:negotiatedSettings.maxBitrateMbps codec:negotiatedSettings.codec];
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
                    if (streamErrorCopy.empty()) {
                        [s2 endStreamWithSuccess:YES errorMessage:""];
                    } else {
                        std::string displayError = OPN::UserFacingGFNErrorMessage(streamErrorCopy, s2->_gameTitle);
                        [s2 setStatus:[NSString stringWithFormat:@"Stream error: %s", displayError.c_str()]];
                        if ([s2 beginAutomaticRecoveryForError:streamErrorCopy]) return;
                        [s2 endStreamWithSuccess:NO errorMessage:streamErrorCopy];
                    }
                }
            });
        });

        s->_signaling->OnIceCandidate([weakSelf, launchGeneration](const OPN::IceCandidatePayload &candidate) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || !s2->_session || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            s2->_remoteIceReceived = YES;
            [s2 cancelRemoteIceGraceTimer];
            s2->_session->AddRemoteIceCandidate(candidate);
        });

        s->_signaling->OnClosed([weakSelf, launchGeneration](bool clean, const std::string &reason) {
            __typeof__(self) s2 = weakSelf;
            if (!s2 || s2->_streamEnded || s2->_launchGeneration != launchGeneration) return;
            std::string reasonCopy = reason;
            dispatch_async(dispatch_get_main_queue(), ^{
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
                if (clean && strongSelf->_connectedOnce) {
                    OPN::LogInfo(@"[StreamVC] Signaling closed cleanly after WebRTC connection; keeping stream active");
                    return;
                }
                std::string error = reasonCopy.empty() ? std::string("Signaling connection closed") : reasonCopy;
                OPN::LogError(@"[StreamVC] Signaling closed unexpectedly: clean=%d reason=%s", clean, error.c_str());
                if ([strongSelf beginAutomaticRecoveryForError:error]) return;
                [strongSelf endStreamWithSuccess:NO errorMessage:error];
            });
        });
    });

    _signaling->Connect([weakSelf, launchGeneration](bool ok, const std::string &err) {
        __typeof__(self) s = weakSelf;
        if (!s) {
            OPN::LogInfo(@"[StreamVC] Signaling Connect callback: self is nil");
            return;
        }
        if (s->_launchGeneration != launchGeneration) {
            OPN::LogInfo(@"[StreamVC] Signaling Connect callback ignored for stale generation %lu", (unsigned long)launchGeneration);
            return;
        }
        if (ok) {
            OPN::LogInfo(@"[StreamVC] Signaling connected");
            [s setLaunchStep:3 message:@"Waiting for stream offer..."];
        }
        if (!ok) {
            OPN::LogError(@"[StreamVC] Signaling Connect failed: %s", err.c_str());
            std::string errCopy = err;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!s || s->_streamEnded || s->_launchGeneration != launchGeneration) return;
                std::string displayError = OPN::UserFacingGFNErrorMessage(errCopy, s->_gameTitle);
                [s setStatus:[NSString stringWithFormat:@"Signaling error: %s", displayError.c_str()]];
                if ([s beginAutomaticRecoveryForError:errCopy]) return;
                [s endStreamWithSuccess:NO errorMessage:errCopy];
            });
        }
    });
}

- (void)beginSessionAllocationWithSettings:(const OPN::StreamSettings &)settings
                             streamProfile:(const OPN::StreamPreferenceProfile &)streamProfile
                          streamingBaseUrl:(const std::string &)streamingBaseUrl
                          launchGeneration:(NSUInteger)launchGeneration
                          recoveringLaunch:(BOOL)recoveringLaunch {
    if (_streamEnded || _launchGeneration != launchGeneration) return;

    OPNDisplayStreamProfile displayProfile = ResolveDisplayStreamProfile(self.view.window);
    [self setLaunchStep:1 message:recoveringLaunch ? @"Reallocating cloud session..." : @"Allocating cloud session..."];
    self.launchStartTime = CACurrentMediaTime();
    self.launchSignpostId = os_signpost_id_generate(OPNStreamPerformanceLog());
    self.launchSignpostActive = YES;
    os_signpost_interval_begin(OPNStreamPerformanceLog(),
                               self.launchSignpostId,
                               "StreamLaunch",
                               "appId=%{public}s resolution=%{public}s fps=%d bitrate=%d codec=%{public}s powerSaver=%{public}s",
                               _appId.c_str(),
                               settings.resolution.c_str(),
                               settings.fps,
                               settings.maxBitrateMbps,
                               settings.codec.c_str(),
                               streamProfile.enablePowerSaver ? "on" : "off");

    OPN::LogInfo(@"[StreamVC] Selected stream profile display=%dx%d stream=%s fps=%d bitrate=%dMbps codec=%s aspect=%s %.4f l4s=%s powerSaver=%s requested=%s@%dfps/%dMbps/%s network=%s/%dms controllers=0x%x region=%s",
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
        OPN::LogInfo(@"[StreamVC] Claiming active session for silent resume: sessionId=%s", _resumeSessionId.c_str());
        OPN::SessionManager::Shared().SetAccessToken(_apiToken);
        OPN::SessionManager::Shared().SetStreamingBaseUrl(streamingBaseUrl);
        [self setLaunchStep:1 message:@"Resuming active session..."];
        OPN::SessionManager::Shared().ClaimSession(_resumeSessionId, _resumeServer, _appId, settings, recoveringLaunch,
            [weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch](bool success, const OPN::SessionInfo &info, const std::string &error) {
                __typeof__(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
                OPN::LogInfo(@"[StreamVC] Active session claim result: success=%d", success);
                if (!success) {
                    if (OPNResumeErrorShouldCreateFreshSession(error)) {
                        OPN::LogInfo(@"[StreamVC] Active session could not be claimed; creating a fresh session instead: %s", error.c_str());
                        strongSelf->_resumeExistingSession = NO;
                        strongSelf->_resumeSessionId.clear();
                        strongSelf->_resumeServer.clear();
                        [strongSelf finishLaunchMeasurementWithSuccess:NO reason:@"stale-resume"];
                        [strongSelf beginSessionAllocationWithSettings:settings
                                                         streamProfile:streamProfile
                                                      streamingBaseUrl:streamingBaseUrl
                                                      launchGeneration:launchGeneration
                                                      recoveringLaunch:recoveringLaunch];
                        return;
                    }
                    if (error.find("SESSION_NOT_PAUSED") != std::string::npos || error.find("\"statusCode\":34") != std::string::npos) {
                        OPN::LogInfo(@"[StreamVC] Active session is not paused; re-resolving currently available session");
                        [strongSelf setLaunchStep:1 message:@"Resuming current active session..."];
                        std::string requestedSessionId = strongSelf->_resumeSessionId;
                        std::string requestedAppId = strongSelf->_appId;
                        OPN::SessionManager::Shared().GetActiveSessions([weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch, requestedSessionId, requestedAppId](bool sessionsOk, const std::vector<OPN::ActiveSessionEntry> &sessions, const std::string &sessionsError) {
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
                                int requestedAppIdNumber = atoi(requestedAppId.c_str());
                                for (const OPN::ActiveSessionEntry &session : sessionsCopy) {
                                    if (session.sessionId == requestedSessionId && !session.serverIp.empty()) {
                                        selectedSession = session;
                                        foundSession = YES;
                                        break;
                                    }
                                }
                                if (!foundSession && requestedAppIdNumber > 0) {
                                    for (const OPN::ActiveSessionEntry &session : sessionsCopy) {
                                        if (session.appId == requestedAppIdNumber && !session.sessionId.empty() && !session.serverIp.empty()) {
                                            selectedSession = session;
                                            foundSession = YES;
                                            break;
                                        }
                                    }
                                }
                                if (!foundSession) {
                                    for (const OPN::ActiveSessionEntry &session : sessionsCopy) {
                                        if ((session.status == 1 || session.status == 2 || session.status == 3 || session.status == 6) && !session.sessionId.empty() && !session.serverIp.empty()) {
                                            selectedSession = session;
                                            foundSession = YES;
                                            break;
                                        }
                                    }
                                }
                                if (!foundSession) {
                                    [retrySelf endStreamWithSuccess:NO errorMessage:"No active session is available to resume"];
                                    return;
                                }

                                std::string selectedAppId = selectedSession.appId > 0 ? std::to_string(selectedSession.appId) : requestedAppId;
                                retrySelf->_resumeSessionId = selectedSession.sessionId;
                                retrySelf->_resumeServer = selectedSession.serverIp;
                                [retrySelf setLaunchStep:2 message:@"Connecting to current active session..."];
                                OPN::SessionManager::Shared().ClaimSession(selectedSession.sessionId, selectedSession.serverIp, selectedAppId, settings, true,
                                    [weakSelf, settings, streamProfile, streamingBaseUrl, launchGeneration, recoveringLaunch](bool retrySuccess, const OPN::SessionInfo &retryInfo, const std::string &retryError) {
                                        __typeof__(self) claimSelf = weakSelf;
                                        if (!claimSelf || claimSelf->_streamEnded || claimSelf->_launchGeneration != launchGeneration) return;
                                        if (!retrySuccess) {
                                            if (OPNResumeErrorShouldCreateFreshSession(retryError)) {
                                                OPN::LogInfo(@"[StreamVC] Re-resolved active session could not be claimed; creating a fresh session instead: %s", retryError.c_str());
                                                claimSelf->_resumeExistingSession = NO;
                                                claimSelf->_resumeSessionId.clear();
                                                claimSelf->_resumeServer.clear();
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
                                        [claimSelf connectWithSessionInfo:retryInfo settings:settings launchGeneration:launchGeneration];
                                    });
                            });
                        });
                        return;
                    }
                    std::string displayError = OPN::UserFacingGFNErrorMessage(error, strongSelf->_gameTitle);
                    NSString *errMsg = [NSString stringWithFormat:@"Resume failed: %s", displayError.c_str()];
                    [strongSelf setStatus:errMsg];
                    if ([strongSelf beginAutomaticRecoveryForError:error]) return;
                    [strongSelf endStreamWithSuccess:NO errorMessage:error];
                    return;
                }
                [strongSelf connectWithSessionInfo:info settings:settings launchGeneration:launchGeneration];
            });
        return;
    }

    OPN::LogInfo(@"[StreamVC] Calling GameService::LaunchGame...");
    OPN::GameService::Shared().SetAccessToken(_apiToken);
    OPN::GameService::Shared().SetStreamingBaseUrl(streamingBaseUrl);

    OPN::GameService::Shared().LaunchGame(_appId, _gameTitle, settings, recoveringLaunch,
        [weakSelf, launchGeneration](const std::string &message, const OPN::SessionInfo &progressSession) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;
            NSString *statusMessage = OPNStringFromStdString(message, @"Waiting for session cleanup...");
            [strongSelf setLaunchStep:1 message:statusMessage ?: @"Waiting for session cleanup..."];
            if (!progressSession.sessionId.empty()) {
                [strongSelf updateLaunchAdState:progressSession];
            }
        },
        [weakSelf, settings, launchGeneration](bool success, const OPN::SessionInfo &info, const std::string &, const std::string &error) {
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) {
                OPN::LogInfo(@"[StreamVC] LaunchGame callback: self is nil");
                return;
            }
            if (strongSelf->_launchGeneration != launchGeneration) {
                OPN::LogInfo(@"[StreamVC] LaunchGame callback ignored for stale generation %lu", (unsigned long)launchGeneration);
                return;
            }
            if (strongSelf->_streamEnded) {
                OPN::LogInfo(@"[StreamVC] LaunchGame callback: stream ended");
                return;
            }

            OPN::LogInfo(@"[StreamVC] LaunchGame result: success=%d", success);
            if (!success) {
                std::string displayError = OPN::UserFacingGFNErrorMessage(error, strongSelf->_gameTitle);
                NSString *errMsg = [NSString stringWithFormat:@"Session failed: %s", displayError.c_str()];
                OPN::LogInfo(@"[StreamVC] %@", errMsg);
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
    if (!_healthReportStarted) {
        _healthReport.Reset(_gameTitle, _appId, _webRTCBackendName, CACurrentMediaTime());
        _healthReportStarted = YES;
    } else if (recoveringLaunch) {
        _healthReport.MarkPhase("Recovery Prepare", CACurrentMediaTime());
    }
    _launchFlowStartTime = CACurrentMediaTime();
    OPN::LogInfo(@"[StreamVC] Starting stream launch flow for game: %@ (appId=%s, recovery=%d attempt=%ld/%ld)",
          OPNStringFromStdString(_gameTitle, @""),
          _appId.c_str(),
          recoveringLaunch,
          (long)_recoveryAttempt,
          (long)OPNMaxAutomaticRecoveryAttempts);
    NSString *launchMessage = recoveringLaunch ? @"Preparing reconnect..." : @"Preparing stream launch...";
    [self ensureLoadingViewWithMessage:launchMessage];
    [self setLaunchStep:0 message:launchMessage];

    if (!_session) {
        std::string error = "libwebrtc stream session is unavailable";
        [self setStatus:@"libwebrtc is unavailable in this build."];
        [self endStreamWithSuccess:NO errorMessage:error];
        return;
    }

    if (_appId.empty()) {
        OPN::LogError(@"[StreamVC] ERROR: appId is empty!");
        [self endStreamWithSuccess:NO errorMessage:"Invalid game ID"];
        return;
    }

    OPNDisplayStreamProfile displayProfile = ResolveDisplayStreamProfile(self.view.window);
    OPN::StreamPreferenceProfile requestedStreamProfile = OPN::LoadStreamPreferenceProfile();
    OPN::StreamPreferenceProfile gameStreamProfile;
    if (OPN::LoadStreamPreferenceProfileForGame(_appId, gameStreamProfile)) {
        requestedStreamProfile = gameStreamProfile;
        OPN::LogInfo(@"[StreamVC] Applying per-game stream profile for appId=%s resolutionIndex=%d fps=%d codec=%s bitrate=%dMbps region=%s",
              _appId.c_str(),
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
        OPN::LogInfo(@"[StreamVC] Capability-gated stream profile requested codec=%s fps=%d color=%s; effective codec=%s fps=%d color=%s hardware(h264=%d h265=%d av1=%d) display=%dx%d@%d",
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
    settings.codec = OPNEffectiveStreamCodec(streamProfile, effectiveResolution, OPN::ResolveStreamWebRTCBackend(), capabilities);
    settings.colorQuality = streamProfile.colorQuality.value.empty() ? "8bit_420" : streamProfile.colorQuality.value;
    settings.maxBitrateMbps = OPNEffectiveMaxBitrateMbps(streamProfile);
    settings.prefilterMode = streamProfile.prefilterMode;
    settings.prefilterSharpness = streamProfile.prefilterSharpness;
    settings.prefilterDenoise = streamProfile.prefilterDenoise;
    settings.prefilterModel = streamProfile.prefilterModel;
    settings.enableL4S = streamProfile.enableL4S;
    settings.enableHdr = streamProfile.enableHdr;
    settings.microphoneMode = streamProfile.microphoneMode;
    settings.microphoneDeviceId = streamProfile.microphoneDeviceId;
    settings.microphonePushToTalkKeyCode = streamProfile.microphonePushToTalkKeyCode;
    settings.microphonePushToTalkModifierMask = streamProfile.microphonePushToTalkModifierMask;
    settings.gameVolume = streamProfile.gameVolume;
    settings.microphoneVolume = streamProfile.microphoneVolume;
    settings.gameLanguage = OPN::CurrentGFNLocale();
    settings.accountLinked = _accountLinked;
    settings.selectedStore = _selectedStore;
    settings.remoteControllersBitmap = OPNConnectedControllerBitmap();
    settings.availableSupportedControllers = OPNAvailableSupportedControllers();
    [self.streamView setVideoAspectRatio:(CGFloat)OPNAspectRatioForResolution(effectiveResolution, streamProfile.AspectRatio())];
    [self.streamView setVideoUpscalingMode:streamProfile.upscalingMode
                                 sharpness:streamProfile.upscalingSharpness
                                   denoise:streamProfile.upscalingDenoise
                               streamWidth:effectiveResolution.width
                              streamHeight:effectiveResolution.height];
    [self.streamView setSuppressInputWhenWindowInactive:streamProfile.suppressInputWhenInactive ? YES : NO];
    [self.streamView setDirectMouseInputEnabled:streamProfile.directMouseInput ? YES : NO];
    [self.streamView setMaxBitrateMbps:settings.maxBitrateMbps];
    [self.streamView setMicrophoneMode:settings.microphoneMode
                     pushToTalkKeyCode:(uint16_t)settings.microphonePushToTalkKeyCode
                          modifierMask:(uint16_t)settings.microphonePushToTalkModifierMask];

    if (settings.microphoneMode != "disabled") {
        AVAuthorizationStatus microphoneStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (microphoneStatus == AVAuthorizationStatusDenied || microphoneStatus == AVAuthorizationStatusRestricted) {
            OPN::LogError(@"[StreamVC] Microphone permission denied or restricted; cannot start mic-enabled stream");
            [self setStatus:@"Microphone permission is disabled. Enable it in macOS Settings > Privacy & Security > Microphone."];
            [self endStreamWithSuccess:NO errorMessage:"Microphone permission denied"];
            return;
        }
        if (microphoneStatus == AVAuthorizationStatusNotDetermined) {
            NSUInteger permissionGeneration = launchGeneration;
            [self setStatus:@"Requesting microphone permission..."];
            OPN::LogInfo(@"[StreamVC] Requesting macOS microphone permission");
            __weak __typeof__(self) permissionWeakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __typeof__(self) strongSelf = permissionWeakSelf;
                    if (!strongSelf || strongSelf->_streamEnded) return;
                    if (strongSelf->_launchGeneration != permissionGeneration) return;
                    if (!granted) {
                        OPN::LogError(@"[StreamVC] macOS microphone permission request denied");
                        [strongSelf setStatus:@"Microphone permission was denied. Enable it in macOS Settings > Privacy & Security > Microphone."];
                        [strongSelf endStreamWithSuccess:NO errorMessage:"Microphone permission denied"];
                        return;
                    }
                    OPN::LogInfo(@"[StreamVC] macOS microphone permission granted; restarting launch flow");
                    [strongSelf startStreamLaunchFlow];
                });
            }];
            return;
        }
    }

    [self setLaunchStep:0 message:@"Loading stream policy..."];
    __weak __typeof__(self) weakSelf = self;
    OPN::StreamSettings requestedSettings = settings;
    _healthReport.SetRequestedSettings(requestedSettings);
    OPN::StreamPreferenceProfile preflightProfile = streamProfile;
    OPN::StreamDeviceCapabilities launchCapabilities = capabilities;
    OPN::FetchStreamCloudVariables(_apiToken, [weakSelf, requestedSettings, preflightProfile, launchCapabilities, launchGeneration, recoveringLaunch](const OPN::StreamCloudVariables &variables) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;

            OPN::StreamSettings preflightSettings = OPN::StreamSettingsByApplyingCloudVariables(requestedSettings, variables, launchCapabilities);
            if (OPNStreamCodecSelectionIsExplicit(preflightProfile)) preflightSettings.codec = requestedSettings.codec;
            [strongSelf resetQualityGuardrailsForBitrate:preflightSettings.maxBitrateMbps];
            [strongSelf.streamView setMaxBitrateMbps:preflightSettings.maxBitrateMbps];
            if (variables.fetched) {
                OPN::LogInfo(@"[StreamVC] Cloud variables applied codec=%s hdr=%d l4s=%d reflex=%d bitrate=%dMbps prefilter=%d/%d sharp=%d/%d denoise=%d/%d supportedPrefilterModes=%lu allowPrefilter=%d gpu=%s",
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

            [strongSelf setLaunchStep:0 message:@"Testing network route..."];
            OPN::RunStreamNetworkPreflight(strongSelf->_apiToken,
                                           OPN::GameService::Shared().ProviderStreamingBaseUrl(),
                                           preflightSettings.maxBitrateMbps,
                [weakSelf, requestedSettings, preflightSettings, preflightProfile, variables, launchGeneration, recoveringLaunch](const OPN::StreamNetworkPreflightResult &preflight) {
                    OPN::StreamNetworkPreflightResult preflightCopy = preflight;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __typeof__(self) strongSelf = weakSelf;
                        if (!strongSelf || strongSelf->_streamEnded || strongSelf->_launchGeneration != launchGeneration) return;

                        OPN::StreamSettings finalSettings = preflightSettings;
                        finalSettings.networkTestSessionId = preflightCopy.networkTestSessionId;
                        finalSettings.networkType = preflightCopy.networkType;
                        finalSettings.networkLatencyMs = preflightCopy.latencyMs;
                        if (preflightCopy.recommendedMaxBitrateMbps > 0) {
                            finalSettings.maxBitrateMbps = std::min(finalSettings.maxBitrateMbps, preflightCopy.recommendedMaxBitrateMbps);
                        }
                        OPN::LogInfo(@"[StreamVC] Final launch prefilter requested=%d/%d/%d preflight=%d/%d/%d final=%d/%d/%d cloudFetched=%d allowPrefilter=%d",
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

                        std::string baseUrl = preflightCopy.streamingBaseUrl.empty() ? OPN::LoadSelectedStreamingBaseUrlForGame(strongSelf->_appId) : preflightCopy.streamingBaseUrl;
                        strongSelf->_healthReport.SetNetworkPreflight(preflightCopy, baseUrl);
                        OPN::LogInfo(@"[StreamVC] Network preflight region=%s type=%s latency=%dms bandwidth=%.0fMbps loss=%.1f jitter=%dms bitrate=%dMbps testId=%s automatic=%d",
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
                            strongSelf->_healthReport.RecordEvent("Network warning", [networkWarning UTF8String] ?: "OpenNOW detected poor network conditions", CACurrentMediaTime());
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
                                cancelSelf->_healthReport.RecordEvent("Launch cancelled", "User cancelled after the network warning", CACurrentMediaTime());
                                [cancelSelf endStreamWithSuccess:NO errorMessage:"Launch cancelled after network test warning."];
                            }];
                            return;
                        }
                        continueAfterNetworkWarning();
                    });
                });
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
    std::string displayError = success ? std::string() : OPN::UserFacingGFNErrorMessage(errorMessage, _gameTitle);
    if (_session) {
        _session->RequestStats();
        _healthReport.AddStatsSample(_session->GetLatestStats());
    }
    OPN::SessionHealthReport finalizedReport = _healthReport.Finalize(success, displayError, CACurrentMediaTime());
    NSString *reason = success
        ? @"ended"
        : (displayError.empty() ? @"failed" : OPNStringFromStdString(displayError, @"failed"));
    [self finishLaunchMeasurementWithSuccess:success reason:reason];
    if (!success) {
        NSString *message = reason.length > 0 ? reason : @"Stream failed";
        OPN::AppendLogEvent([NSString stringWithFormat:@"[StreamVC] Stream ending with error: %@", message]);
        if (OPNShouldReportTerminalStreamFailure(message)) {
            NSString *phase = _connectedOnce ? @"runtime" : (_resumeExistingSession ? @"resume" : @"launch");
            NSString *reportMessage = OPNStreamFailureReportMessage(message);
            OPN::LogError(@"[StreamVC] Terminal stream failure phase=%@ connected=%d recovery=%d appId=%s sessionId=%s server=%s error=%@",
                          phase,
                          _connectedOnce,
                          _recovering,
                          _appId.c_str(),
                          _hasActiveSessionInfo ? _activeSessionInfo.sessionId.c_str() : "",
                          _hasActiveSessionInfo ? _activeSessionInfo.serverIp.c_str() : "",
                          reportMessage);
        }
    }
    [self cleanup];

    if (self.onStreamEnd) {
        self.onStreamEnd(success, displayError, finalizedReport);
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
        [self.streamView setStreamSession:nullptr];
        [self.streamView detachFromPipeline];
    }
    if (self.loadingView) {
        [self.loadingView stopAnimating];
        [self.loadingView removeFromSuperview];
        self.loadingView = nil;
        self.statusLabel = nil;
    }
    if (_signaling) {
        OPNReleaseSignalingClientAfterCallbacks(_signaling);
        _signaling = nullptr;
    }
    if (_session) {
        OPNReleaseStreamSessionAfterCallbacks(_session);
        _session = nullptr;
    }
}

- (void)dealloc {
    [self cleanup];
}

@end
