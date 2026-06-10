#include "OPNLibWebRTCStreamSession.h"
#include "OPNLibWebRTCSessionImpl.h"

#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop
#endif

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <objc/message.h>

@interface OPNAudioDeviceMonitorContext : NSObject
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
@property(nonatomic, assign, getter=isActive) BOOL active;
@end

@implementation OPNAudioDeviceMonitorContext
@end

namespace OPN {

#if defined(OPN_HAVE_LIBWEBRTC)
static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}
#endif

static AudioDeviceID OPNDefaultAudioDevice(AudioObjectPropertySelector selector) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static OSStatus OPNAudioDevicesChanged(AudioObjectID,
                                       UInt32,
                                       const AudioObjectPropertyAddress *,
                                       void *clientData) {
    OPNAudioDeviceMonitorContext *context = (__bridge OPNAudioDeviceMonitorContext *)clientData;
    if (!context.isActive || !context.owner) return noErr;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!context.isActive || !context.owner) return;
        context.owner->HandleAudioDeviceChange();
    });
    return noErr;
}

static void OPNLockRTCAudioSession(id audioSession) {
    SEL selector = NSSelectorFromString(@"lockForConfiguration");
    if ([audioSession respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(audioSession, selector);
    }
}

static void OPNUnlockRTCAudioSession(id audioSession) {
    SEL selector = NSSelectorFromString(@"unlockForConfiguration");
    if ([audioSession respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(audioSession, selector);
    }
}

static void OPNSetRTCAudioSessionActive(id audioSession, BOOL active, NSString *phase) {
    SEL selector = NSSelectorFromString(@"setActive:error:");
    if (![audioSession respondsToSelector:selector]) return;

    NSError *error = nil;
    BOOL ok = ((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(audioSession, selector, active, &error);
    if (!ok || error) {
        OPNLogError(@"[LibWebRTC] RTCAudioSession setActive=%d failed during %@: %@", active, phase, error.localizedDescription ?: @"unknown error");
    }
}

static void OPNResetRTCAudioSessionRouteToDefaults(id audioSession) {
    OPNLockRTCAudioSession(audioSession);

    SEL preferredInputSelector = NSSelectorFromString(@"setPreferredInput:error:");
    if ([audioSession respondsToSelector:preferredInputSelector]) {
        NSError *preferredInputError = nil;
        BOOL ok = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(audioSession, preferredInputSelector, nil, &preferredInputError);
        if (!ok || preferredInputError) {
            OPNLogError(@"[LibWebRTC] RTCAudioSession clear preferred input failed: %@", preferredInputError.localizedDescription ?: @"unknown error");
        }
    }

    SEL outputOverrideSelector = NSSelectorFromString(@"overrideOutputAudioPort:error:");
    if ([audioSession respondsToSelector:outputOverrideSelector]) {
        NSError *outputOverrideError = nil;
        BOOL ok = ((BOOL (*)(id, SEL, NSInteger, NSError **))objc_msgSend)(audioSession, outputOverrideSelector, 0, &outputOverrideError);
        if (!ok || outputOverrideError) {
            OPNLogError(@"[LibWebRTC] RTCAudioSession clear output override failed: %@", outputOverrideError.localizedDescription ?: @"unknown error");
        }
    }

    OPNUnlockRTCAudioSession(audioSession);
}

static bool OPNEnvFlagEnabled(const char *name, bool defaultValue) {
    const char *value = getenv(name);
    if (!value || !*value) return defaultValue;
    std::string normalized(value);
    std::transform(normalized.begin(), normalized.end(), normalized.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return !(normalized == "0" || normalized == "false" || normalized == "no" || normalized == "off");
}

void LibWebRTCStreamSession::SetMicrophoneEnabled(bool enabled) {
    m_microphoneEnabled = enabled;
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.localMicrophoneTrack) {
        impl.localMicrophoneTrack.isEnabled = enabled ? YES : NO;
    }
    if (enabled && impl.localMicrophoneTrack) {
        StartMicrophoneLevelPolling();
    } else if (!enabled && m_onMicrophoneLevel) {
        m_onMicrophoneLevel(0.0);
    }
#endif
}

void LibWebRTCStreamSession::SetGameVolume(double volume) {
    m_gameVolume = std::max(0.0, std::min(volume, 1.0));
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.remoteAudioTrack) {
        impl.remoteAudioTrack.source.volume = m_gameVolume;
    }
#endif
}

void LibWebRTCStreamSession::SetMicrophoneVolume(double volume) {
    m_microphoneVolumeLevel = std::max(0.0, std::min(volume, 1.0));
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (impl.localMicrophoneTrack) {
        impl.localMicrophoneTrack.source.volume = m_microphoneVolumeLevel;
    }
#endif
}

void LibWebRTCStreamSession::RefreshAudioDevices() {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
    if (!monitorContext.isActive || !monitorContext.owner) {
        OPNLogInfo(@"[LibWebRTC] audio device refresh skipped: monitor inactive");
        return;
    }

    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection) {
        OPNLogInfo(@"[LibWebRTC] audio device refresh skipped: peer connection missing");
        return;
    }

    if (impl.audioDevice) {
        [impl.audioDevice handleDefaultDeviceChange];
        OPNLogInfo(@"[LibWebRTC] audio device refresh delegated to CoreAudio RTC device input=%u output=%u",
              m_defaultInputDevice,
              m_defaultOutputDevice);
        return;
    }

    Class audioSessionClass = NSClassFromString(@"RTCAudioSession");
    id audioSession = audioSessionClass ? [audioSessionClass performSelector:@selector(sharedInstance)] : nil;
    if (!audioSession) {
        OPNLogInfo(@"[LibWebRTC] audio device refresh unavailable: RTCAudioSession missing on this platform");
        return;
    }

    SEL useManualAudioSelector = NSSelectorFromString(@"useManualAudio");
    SEL isAudioEnabledSelector = NSSelectorFromString(@"isAudioEnabled");
    SEL setUseManualAudioSelector = NSSelectorFromString(@"setUseManualAudio:");
    SEL setIsAudioEnabledSelector = NSSelectorFromString(@"setIsAudioEnabled:");

    const uint64_t refreshGeneration = m_audioDeviceChangeGeneration;
    const BOOL wasManualAudio = [audioSession respondsToSelector:useManualAudioSelector] ? ((BOOL (*)(id, SEL))objc_msgSend)(audioSession, useManualAudioSelector) : NO;
    const BOOL wasAudioEnabled = [audioSession respondsToSelector:isAudioEnabledSelector] ? ((BOOL (*)(id, SEL))objc_msgSend)(audioSession, isAudioEnabledSelector) : YES;

    const BOOL shouldRestoreMicrophone = impl.localMicrophoneTrack ? (impl.localMicrophoneTrack.isEnabled ? YES : NO) : NO;
    if (impl.remoteAudioTrack) impl.remoteAudioTrack.isEnabled = NO;
    if (impl.localMicrophoneTrack) impl.localMicrophoneTrack.isEnabled = NO;

    if ([audioSession respondsToSelector:setUseManualAudioSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(audioSession, setUseManualAudioSelector, YES);
    }
    if ([audioSession respondsToSelector:setIsAudioEnabledSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(audioSession, setIsAudioEnabledSelector, NO);
    }
    OPNResetRTCAudioSessionRouteToDefaults(audioSession);
    OPNSetRTCAudioSessionActive(audioSession, NO, @"audio route refresh");
    OPNLogInfo(@"[LibWebRTC] audio device refresh scheduled input=%u output=%u rtcAudioSession=1",
          m_defaultInputDevice,
          m_defaultOutputDevice);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!monitorContext.isActive || !monitorContext.owner) return;
        LibWebRTCStreamSession *owner = monitorContext.owner;
        if (!owner->m_impl) return;
        if (owner->m_audioDeviceChangeGeneration != refreshGeneration) {
            OPNLogInfo(@"[LibWebRTC] audio device refresh superseded generation=%llu current=%llu",
                  (unsigned long long)refreshGeneration,
                  (unsigned long long)owner->m_audioDeviceChangeGeneration);
            return;
        }

        id activeAudioSession = audioSessionClass ? [audioSessionClass performSelector:@selector(sharedInstance)] : nil;
        if (activeAudioSession) {
            OPNResetRTCAudioSessionRouteToDefaults(activeAudioSession);
            OPNSetRTCAudioSessionActive(activeAudioSession, YES, @"audio route refresh");
            if ([activeAudioSession respondsToSelector:setIsAudioEnabledSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setIsAudioEnabledSelector, YES);
            }
            if ([activeAudioSession respondsToSelector:setUseManualAudioSelector]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setUseManualAudioSelector, wasManualAudio);
            }
            if (wasManualAudio && !wasAudioEnabled) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(activeAudioSession, setIsAudioEnabledSelector, NO);
            }
        }

        OPNLibWebRTCSessionImpl *activeImpl = OPNImplFromOpaque(owner->m_impl);
        if (activeImpl.remoteAudioTrack) {
            activeImpl.remoteAudioTrack.isEnabled = YES;
            activeImpl.remoteAudioTrack.source.volume = owner->m_gameVolume;
        }
        if (activeImpl.localMicrophoneTrack) {
            activeImpl.localMicrophoneTrack.isEnabled = (owner->m_microphoneEnabled && shouldRestoreMicrophone) ? YES : NO;
            activeImpl.localMicrophoneTrack.source.volume = owner->m_microphoneVolumeLevel;
        }
        OPNLogInfo(@"[LibWebRTC] audio device refresh applied input=%u output=%u remoteTrack=%d micTrack=%d micEnabled=%d",
              owner->m_defaultInputDevice,
              owner->m_defaultOutputDevice,
              activeImpl.remoteAudioTrack ? 1 : 0,
              activeImpl.localMicrophoneTrack ? 1 : 0,
              activeImpl.localMicrophoneTrack && activeImpl.localMicrophoneTrack.isEnabled ? 1 : 0);
    });
#endif
}

void LibWebRTCStreamSession::StartAudioDeviceMonitoring() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    bool expected = false;
    if (!m_audioDeviceMonitoringActive.compare_exchange_strong(expected, true)) {
#pragma clang diagnostic pop
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    m_defaultInputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    m_defaultOutputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);

    OPNAudioDeviceMonitorContext *context = [[OPNAudioDeviceMonitorContext alloc] init];
    context.owner = this;
    context.active = YES;
    m_audioDeviceMonitorContext = (__bridge_retained void *)context;

    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    OSStatus devicesStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OSStatus inputStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OSStatus outputStatus = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultOutputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    OPNLogInfo(@"[LibWebRTC] audio device monitoring started devices=%d input=%d output=%d currentInput=%u currentOutput=%u",
          devicesStatus,
          inputStatus,
          outputStatus,
          m_defaultInputDevice,
          m_defaultOutputDevice);
#pragma clang diagnostic pop
}

void LibWebRTCStreamSession::StopAudioDeviceMonitoring() {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    bool expected = true;
    if (!m_audioDeviceMonitoringActive.compare_exchange_strong(expected, false)) {
#pragma clang diagnostic pop
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    OPNAudioDeviceMonitorContext *context = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
    context.active = NO;
    context.owner = nullptr;

    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devicesAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultInputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultOutputAddress, OPNAudioDevicesChanged, m_audioDeviceMonitorContext);
    if (m_audioDeviceMonitorContext) {
        OPNAudioDeviceMonitorContext *releasedContext = (__bridge_transfer OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        (void)releasedContext;
        m_audioDeviceMonitorContext = nullptr;
    }
    m_defaultInputDevice = kAudioObjectUnknown;
    m_defaultOutputDevice = kAudioObjectUnknown;
    OPNLogInfo(@"[LibWebRTC] audio device monitoring stopped");
#pragma clang diagnostic pop
}

void LibWebRTCStreamSession::HandleAudioDeviceChange() {
    if (!m_audioDeviceMonitoringActive.load()) return;

    const AudioDeviceID inputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice);
    const AudioDeviceID outputDevice = OPNDefaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice);
    if (outputDevice == kAudioObjectUnknown) {
        const uint64_t generation = ++m_audioDeviceChangeGeneration;
        OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        if (m_audioDeviceUnavailableRetryCount < 10) {
            m_audioDeviceUnavailableRetryCount++;
            OPNLogInfo(@"[LibWebRTC] default output device unavailable during hotplug input=%u output=%u retry=%d", inputDevice, outputDevice, m_audioDeviceUnavailableRetryCount);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (!monitorContext.isActive || !monitorContext.owner) return;
                if (monitorContext.owner->m_audioDeviceChangeGeneration != generation) return;
                monitorContext.owner->HandleAudioDeviceChange();
            });
        } else {
            OPNLogError(@"[LibWebRTC] default output device remained unavailable after headset hotplug retries");
        }
        return;
    }

    m_audioDeviceUnavailableRetryCount = 0;

    const bool inputChanged = inputDevice != m_defaultInputDevice;
    const bool outputChanged = outputDevice != m_defaultOutputDevice;
    if (!inputChanged && !outputChanged) return;

    OPNLogInfo(@"[LibWebRTC] default audio device changed input=%u->%u output=%u->%u",
          m_defaultInputDevice,
              inputDevice,
              m_defaultOutputDevice,
              outputDevice);
    m_defaultInputDevice = inputDevice;
    m_defaultOutputDevice = outputDevice;
    RefreshAudioDevices();
#if defined(OPN_HAVE_LIBWEBRTC)
    const uint64_t generation = ++m_audioDeviceChangeGeneration;
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    const bool customAudioDeviceActive = impl.audioDevice != nil;
    if (!customAudioDeviceActive && OPNEnvFlagEnabled("OPN_ENABLE_WEBRTC_AUDIO_HOTSWAP_RECOVERY", true)) {
        OPNAudioDeviceMonitorContext *monitorContext = (__bridge OPNAudioDeviceMonitorContext *)m_audioDeviceMonitorContext;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!monitorContext.isActive || !monitorContext.owner) return;
            if (monitorContext.owner->m_audioDeviceChangeGeneration != generation) return;
            if (!monitorContext.owner->m_impl) return;
            OPNLogInfo(@"[LibWebRTC] forcing stream recovery after audio device change input=%u output=%u",
                  monitorContext.owner->m_defaultInputDevice,
                  monitorContext.owner->m_defaultOutputDevice);
            monitorContext.owner->HandleConnectionState(false, "webrtc audio device changed");
        });
    }
#endif
}

void LibWebRTCStreamSession::StartMicrophoneLevelPolling() {
#if defined(OPN_HAVE_LIBWEBRTC)
    if (m_microphoneLevelTimer) return;
    dispatch_queue_t statsQueue = m_statsQueue ? (__bridge dispatch_queue_t)m_statsQueue : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, statsQueue);
    if (!timer) return;

    m_microphoneLevelTimer = (__bridge_retained void *)timer;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              100 * NSEC_PER_MSEC,
                              20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(this->m_impl);
        if (!impl.peerConnection || !impl.localMicrophoneTrack) return;
        if (!this->m_microphoneEnabled || !impl.localMicrophoneTrack.isEnabled) {
            if (this->m_onMicrophoneLevel) this->m_onMicrophoneLevel(0.0);
            return;
        }
        if (this->m_microphoneLevelRequestInFlight) return;
        this->m_microphoneLevelRequestInFlight = true;
        [impl.peerConnection statisticsWithCompletionHandler:^(RTCStatisticsReport *report) {
            this->HandleMicrophoneLevelReport((__bridge void *)report);
        }];
    });
    dispatch_resume(timer);
    OPNLogInfo(@"[LibWebRTC] microphone level polling started");
#endif
}

void LibWebRTCStreamSession::StopMicrophoneLevelPolling() {
    if (!m_microphoneLevelTimer) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_microphoneLevelTimer;
    m_microphoneLevelTimer = nullptr;
    dispatch_source_cancel(timer);
    m_microphoneLevelRequestInFlight = false;
    if (m_onMicrophoneLevel) m_onMicrophoneLevel(0.0);
}

double LibWebRTCStreamSession::GameVolume() const {
    return m_gameVolume;
}

}
