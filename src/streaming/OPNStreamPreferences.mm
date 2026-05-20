#include "OPNStreamPreferences.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <VideoToolbox/VideoToolbox.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <ifaddrs.h>
#include <memory>
#include <net/if.h>

namespace OPN {

static NSString *const kAspectIndexKey = @"OpenNOW.Stream.AspectIndex";
static NSString *const kResolutionIndexKey = @"OpenNOW.Stream.ResolutionIndex";
static NSString *const kFpsIndexKey = @"OpenNOW.Stream.FpsIndex";
static NSString *const kCodecIndexKey = @"OpenNOW.Stream.CodecIndex";
static NSString *const kBitrateIndexKey = @"OpenNOW.Stream.BitrateIndex";
static NSString *const kColorQualityIndexKey = @"OpenNOW.Stream.ColorQualityIndex";
static NSString *const kL4SEnabledKey = @"OpenNOW.Stream.L4SEnabled";
static NSString *const kPowerSaverEnabledKey = @"OpenNOW.Stream.PowerSaverEnabled";
static NSString *const kSuppressInputWhenInactiveKey = @"OpenNOW.Stream.SuppressInputWhenInactive";
static NSString *const kGameVolumeKey = @"OpenNOW.Stream.GameVolume";
static NSString *const kMicrophoneVolumeKey = @"OpenNOW.Stream.MicrophoneVolume";
static NSString *const kMicrophoneModeKey = @"OpenNOW.Stream.MicrophoneMode";
static NSString *const kMicrophoneDeviceIdKey = @"OpenNOW.Stream.MicrophoneDeviceId";
static NSString *const kMicrophonePushToTalkKeyCodeKey = @"OpenNOW.Stream.MicrophonePushToTalkKeyCode";
static NSString *const kMicrophonePushToTalkModifierMaskKey = @"OpenNOW.Stream.MicrophonePushToTalkModifierMask";
static NSString *const kSelectedRegionUrlKey = @"OpenNOW.Stream.RegionUrl";
static NSString *const kCachedRegionsKey = @"OpenNOW.Stream.CachedRegions";
static NSString *const kNvClientId = @"ec7e38d4-03af-4b58-b131-cfb0495903ab";
static NSString *const kNvClientVersion = @"2.0.80.173";
static constexpr const char *kDefaultStreamingBaseUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/";

std::string StreamResolutionOption::Value() const {
    return std::to_string(width) + "x" + std::to_string(height);
}

std::string StreamResolutionOption::Label() const {
    return std::to_string(width) + " x " + std::to_string(height);
}

std::string StreamRegionOption::Label() const {
    if (automatic) return "Automatic";
    if (latencyMs >= 0) return name + " (" + std::to_string(latencyMs) + " ms)";
    return name;
}

double StreamPreferenceProfile::AspectRatio() const {
    return aspect.heightRatio > 0 ? (double)aspect.widthRatio / (double)aspect.heightRatio : 16.0 / 9.0;
}

const std::vector<StreamAspectOption> &StreamAspectOptions() {
    static const std::vector<StreamAspectOption> options = {
        {"16:9", 16, 9},
        {"16:10", 16, 10},
        {"21:9", 21, 9},
        {"32:9", 32, 9},
    };
    return options;
}

const std::vector<int> &StreamFpsOptions() {
    static const std::vector<int> options = {30, 60, 120, 240};
    return options;
}

const std::vector<StreamCodecOption> &StreamCodecOptions() {
    static const std::vector<StreamCodecOption> options = {
        {"H264  Low Latency", "H264"},
        {"H265  Quality", "H265"},
        {"AV1  CPU", "AV1"},
        {"Auto", "auto"},
    };
    return options;
}

const std::vector<StreamBitrateOption> &StreamBitrateOptions() {
    static const std::vector<StreamBitrateOption> options = {
        {"15 Mbps", 15},
        {"25 Mbps", 25},
        {"50 Mbps", 50},
        {"75 Mbps", 75},
        {"100 Mbps", 100},
    };
    return options;
}

const std::vector<StreamColorQualityOption> &StreamColorQualityOptions() {
    static const std::vector<StreamColorQualityOption> options = {
        {"8-bit 4:2:0", "8bit_420"},
        {"8-bit 4:4:4", "8bit_444"},
        {"10-bit 4:2:0", "10bit_420"},
        {"10-bit 4:4:4", "10bit_444"},
    };
    return options;
}

const std::vector<StreamMicrophoneModeOption> &StreamMicrophoneModeOptions() {
    static const std::vector<StreamMicrophoneModeOption> options = {
        {"Disabled", "disabled"},
        {"Push-to-Talk", "push-to-talk"},
        {"Open Mic", "voice-activity"},
    };
    return options;
}

std::string StreamMicrophonePushToTalkKeyLabel(int keyCode) {
    switch (keyCode) {
        case 0: return "A";
        case 1: return "S";
        case 2: return "D";
        case 3: return "F";
        case 4: return "H";
        case 5: return "G";
        case 6: return "Z";
        case 7: return "X";
        case 8: return "C";
        case 9: return "V";
        case 11: return "B";
        case 12: return "Q";
        case 13: return "W";
        case 14: return "E";
        case 15: return "R";
        case 16: return "Y";
        case 17: return "T";
        case 18: return "1";
        case 19: return "2";
        case 20: return "3";
        case 21: return "4";
        case 22: return "6";
        case 23: return "5";
        case 24: return "=";
        case 25: return "9";
        case 26: return "7";
        case 27: return "-";
        case 28: return "8";
        case 29: return "0";
        case 30: return "]";
        case 31: return "O";
        case 32: return "U";
        case 33: return "[";
        case 34: return "I";
        case 35: return "P";
        case 36: return "Return";
        case 37: return "L";
        case 38: return "J";
        case 39: return "'";
        case 40: return "K";
        case 41: return ";";
        case 42: return "\\";
        case 43: return ",";
        case 44: return "/";
        case 45: return "N";
        case 46: return "M";
        case 47: return ".";
        case 48: return "Tab";
        case 49: return "Space";
        case 50: return "`";
        case 51: return "Backspace";
        case 53: return "Escape";
        case 55: return "Left Command";
        case 56: return "Left Shift";
        case 57: return "Caps Lock";
        case 58: return "Left Option";
        case 59: return "Left Control";
        case 60: return "Right Shift";
        case 61: return "Right Option";
        case 62: return "Right Control";
        case 96: return "F5";
        case 97: return "F6";
        case 98: return "F7";
        case 99: return "F3";
        case 100: return "F8";
        case 101: return "F9";
        case 103: return "F11";
        case 109: return "F10";
        case 111: return "F12";
        case 118: return "F4";
        case 120: return "F2";
        case 122: return "F1";
        default: return "Key " + std::to_string(keyCode);
    }
}

static int StreamMicrophonePushToTalkModifierBitForKeyCode(int keyCode) {
    switch (keyCode) {
        case 55: return 0x08;
        case 56:
        case 60: return 0x01;
        case 57: return 0x10;
        case 58:
        case 61: return 0x04;
        case 59:
        case 62: return 0x02;
        default: return 0;
    }
}

static int SanitizedPushToTalkModifierMask(int modifierMask) {
    return modifierMask & 0x1f;
}

static int NormalizedPushToTalkModifierMask(int keyCode, int modifierMask) {
    int normalized = SanitizedPushToTalkModifierMask(modifierMask);
    int keyModifierBit = StreamMicrophonePushToTalkModifierBitForKeyCode(keyCode);
    if (keyModifierBit != 0) normalized |= keyModifierBit;
    return normalized;
}

std::string StreamMicrophonePushToTalkComboLabel(int keyCode, int modifierMask) {
    int visibleModifiers = SanitizedPushToTalkModifierMask(modifierMask) & ~StreamMicrophonePushToTalkModifierBitForKeyCode(keyCode);
    std::vector<std::string> parts;
    if (visibleModifiers & 0x02) parts.push_back("Control");
    if (visibleModifiers & 0x04) parts.push_back("Option");
    if (visibleModifiers & 0x01) parts.push_back("Shift");
    if (visibleModifiers & 0x08) parts.push_back("Command");
    if (visibleModifiers & 0x10) parts.push_back("Caps Lock");
    parts.push_back(StreamMicrophonePushToTalkKeyLabel(keyCode));

    std::string label;
    for (size_t i = 0; i < parts.size(); i++) {
        if (i > 0) label += " + ";
        label += parts[i];
    }
    return label;
}

std::vector<StreamMicrophoneDeviceOption> LoadMicrophoneDeviceOptions() {
    std::vector<StreamMicrophoneDeviceOption> devices;
    devices.push_back({"Default Device", "", true});

    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddress, 0, nullptr, &dataSize) != noErr || dataSize == 0) {
        return devices;
    }

    std::vector<AudioObjectID> audioDevices(dataSize / sizeof(AudioObjectID));
    if (audioDevices.empty()) return devices;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddress, 0, nullptr, &dataSize, audioDevices.data()) != noErr) {
        return devices;
    }

    for (AudioObjectID audioDevice : audioDevices) {
        AudioObjectPropertyAddress streamAddress = {
            kAudioDevicePropertyStreams,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain,
        };
        UInt32 streamDataSize = 0;
        if (AudioObjectGetPropertyDataSize(audioDevice, &streamAddress, 0, nullptr, &streamDataSize) != noErr || streamDataSize == 0) {
            continue;
        }

        CFStringRef nameRef = nullptr;
        UInt32 nameSize = sizeof(nameRef);
        AudioObjectPropertyAddress nameAddress = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        if (AudioObjectGetPropertyData(audioDevice, &nameAddress, 0, nullptr, &nameSize, &nameRef) != noErr || !nameRef) {
            continue;
        }

        CFStringRef uidRef = nullptr;
        UInt32 uidSize = sizeof(uidRef);
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        AudioObjectGetPropertyData(audioDevice, &uidAddress, 0, nullptr, &uidSize, &uidRef);

        NSString *name = CFBridgingRelease(nameRef);
        NSString *uid = uidRef ? CFBridgingRelease(uidRef) : nil;
        std::string label = name.length > 0 ? name.UTF8String : "Microphone";
        std::string id = uid.length > 0 ? uid.UTF8String : std::to_string(audioDevice);
        bool duplicate = false;
        for (const StreamMicrophoneDeviceOption &existing : devices) {
            if (existing.uniqueId == id) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) devices.push_back({label, id, false});
    }
    return devices;
}

std::vector<StreamResolutionOption> StreamResolutionOptionsForAspect(int aspectIndex) {
    switch (aspectIndex) {
        case 0:
            return {{1280, 720}, {1600, 900}, {1920, 1080}, {2560, 1440}, {3840, 2160}};
        case 1:
            return {{1280, 800}, {1440, 900}, {1680, 1050}, {1920, 1200}, {2560, 1600}, {2880, 1800}};
        case 2:
            return {{2560, 1080}, {3440, 1440}, {3840, 1600}};
        case 3:
            return {{3840, 1080}, {5120, 1440}};
        default:
            return {{1280, 800}, {1440, 900}, {1680, 1050}, {1920, 1200}, {2560, 1600}, {2880, 1800}};
    }
}

static bool HardwareDecodeSupported(CMVideoCodecType codecType) {
    if (@available(macOS 10.13, *)) {
        return VTIsHardwareDecodeSupported(codecType);
    }
    return codecType == kCMVideoCodecType_H264;
}

static std::string UppercaseAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return (char)std::toupper(character);
    });
    return value;
}

StreamDeviceCapabilities LoadStreamDeviceCapabilities() {
    StreamDeviceCapabilities capabilities;
    capabilities.h264HardwareDecodeSupported = HardwareDecodeSupported(kCMVideoCodecType_H264);
    capabilities.h265HardwareDecodeSupported = HardwareDecodeSupported(kCMVideoCodecType_HEVC);
    capabilities.av1HardwareDecodeSupported = HardwareDecodeSupported(kCMVideoCodecType_AV1);

    NSScreen *screen = NSScreen.mainScreen;
    if (screen) {
        NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
        if ([screenNumber isKindOfClass:NSNumber.class]) {
            CGDirectDisplayID displayId = (CGDirectDisplayID)screenNumber.unsignedIntValue;
            size_t width = CGDisplayPixelsWide(displayId);
            size_t height = CGDisplayPixelsHigh(displayId);
            if (width > 0 && height > 0) {
                capabilities.maxDisplayWidth = (int)width;
                capabilities.maxDisplayHeight = (int)height;
            }
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayId);
            if (mode) {
                double refreshRate = CGDisplayModeGetRefreshRate(mode);
                if (std::isfinite(refreshRate) && refreshRate > 0.0) {
                    capabilities.maxDisplayRefreshRate = (int)std::llround(refreshRate);
                }
                CGDisplayModeRelease(mode);
            }
        }
        if (capabilities.maxDisplayWidth == 0 || capabilities.maxDisplayHeight == 0) {
            CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 1.0;
            capabilities.maxDisplayWidth = (int)std::llround(NSWidth(screen.frame) * scale);
            capabilities.maxDisplayHeight = (int)std::llround(NSHeight(screen.frame) * scale);
        }
        if (@available(macOS 10.15, *)) {
            NSInteger maximumFramesPerSecond = screen.maximumFramesPerSecond;
            if (maximumFramesPerSecond > capabilities.maxDisplayRefreshRate) {
                capabilities.maxDisplayRefreshRate = (int)maximumFramesPerSecond;
            }
            capabilities.hdrDisplaySupported = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0;
        }
    }
    return capabilities;
}

bool StreamCodecSupportedByCapabilities(const StreamCodecOption &codec,
                                        const StreamDeviceCapabilities &capabilities) {
    std::string value = UppercaseAscii(codec.value.empty() ? std::string("H264") : codec.value);
    if (value == "AUTO") {
        return true;
    }
    if (value == "H264") return true;
    if (value == "H265" || value == "HEVC") return capabilities.h265HardwareDecodeSupported;
    if (value == "AV1") return capabilities.av1HardwareDecodeSupported;
    return false;
}

bool StreamFpsSupportedByCapabilities(int fps,
                                      const StreamDeviceCapabilities &capabilities) {
    if (fps <= 60) return true;
    if (capabilities.maxDisplayRefreshRate <= 0) return true;
    return fps <= std::max(60, capabilities.maxDisplayRefreshRate);
}

bool StreamColorQualitySupportedByCapabilities(const StreamColorQualityOption &colorQuality,
                                               const StreamCodecOption &codec,
                                               const StreamDeviceCapabilities &capabilities) {
    if (!StreamCodecSupportedByCapabilities(codec, capabilities)) return false;
    std::string color = UppercaseAscii(colorQuality.value);
    if (color.rfind("10BIT", 0) != 0) return true;

    std::string codecValue = UppercaseAscii(codec.value.empty() ? std::string("H264") : codec.value);
    if (codecValue == "H265" || codecValue == "HEVC") return capabilities.h265HardwareDecodeSupported;
    if (codecValue == "AV1") return capabilities.av1HardwareDecodeSupported;
    if (codecValue == "AUTO") return capabilities.h265HardwareDecodeSupported || capabilities.av1HardwareDecodeSupported;
    return false;
}

static int FirstSupportedCodecIndex(const StreamDeviceCapabilities &capabilities) {
    const std::vector<StreamCodecOption> &codecs = StreamCodecOptions();
    for (size_t i = 0; i < codecs.size(); i++) {
        if (codecs[i].value == "H264" && StreamCodecSupportedByCapabilities(codecs[i], capabilities)) return (int)i;
    }
    for (size_t i = 0; i < codecs.size(); i++) {
        if (StreamCodecSupportedByCapabilities(codecs[i], capabilities)) return (int)i;
    }
    return 0;
}

static int NearestSupportedFpsIndex(int requestedFps, const StreamDeviceCapabilities &capabilities) {
    const std::vector<int> &fpsOptions = StreamFpsOptions();
    int fallbackIndex = 0;
    int fallbackFps = fpsOptions.empty() ? 60 : fpsOptions.front();
    for (size_t i = 0; i < fpsOptions.size(); i++) {
        int fps = fpsOptions[i];
        if (!StreamFpsSupportedByCapabilities(fps, capabilities)) continue;
        if (fps <= requestedFps && fps >= fallbackFps) {
            fallbackFps = fps;
            fallbackIndex = (int)i;
        }
    }
    return fallbackIndex;
}

StreamPreferenceProfile EffectiveStreamPreferenceProfileForCapabilities(StreamPreferenceProfile profile,
                                                                        const StreamDeviceCapabilities &capabilities) {
    const std::vector<StreamCodecOption> &codecs = StreamCodecOptions();
    if (profile.codecIndex < 0 || profile.codecIndex >= (int)codecs.size() ||
        !StreamCodecSupportedByCapabilities(profile.codec, capabilities)) {
        profile.codecIndex = FirstSupportedCodecIndex(capabilities);
        profile.codec = codecs[(size_t)profile.codecIndex];
    }

    if (!StreamFpsSupportedByCapabilities(profile.fps, capabilities)) {
        const std::vector<int> &fpsOptions = StreamFpsOptions();
        profile.fpsIndex = NearestSupportedFpsIndex(profile.fps, capabilities);
        profile.fps = fpsOptions[(size_t)profile.fpsIndex];
    }

    const std::vector<StreamColorQualityOption> &colorOptions = StreamColorQualityOptions();
    if (profile.colorQualityIndex < 0 || profile.colorQualityIndex >= (int)colorOptions.size() ||
        !StreamColorQualitySupportedByCapabilities(profile.colorQuality, profile.codec, capabilities)) {
        profile.colorQualityIndex = 0;
        profile.colorQuality = colorOptions.front();
    }
    return profile;
}

std::string ResolveStreamCodecForCapabilities(const StreamPreferenceProfile &profile,
                                              const StreamResolutionOption &resolution,
                                              const StreamDeviceCapabilities &capabilities,
                                              bool libWebRTCAvailable) {
    std::string requested = UppercaseAscii(profile.codec.value.empty() ? std::string("H264") : profile.codec.value);
    if (requested != "AUTO") {
        return StreamCodecSupportedByCapabilities(profile.codec, capabilities) ? requested : "H264";
    }
    if (!libWebRTCAvailable) return "H264";

    const int64_t pixels = (int64_t)std::max(1, resolution.width) * (int64_t)std::max(1, resolution.height);
    const bool prefersTenBit = profile.colorQuality.value.rfind("10bit", 0) == 0;
    const bool prefersHighResolution = pixels >= (int64_t)2560 * 1440;
    const bool prefersVeryHighResolution = pixels >= (int64_t)3840 * 2160;
    const bool highFps = profile.fps >= 144;
    if (!highFps && prefersVeryHighResolution && capabilities.av1HardwareDecodeSupported) return "AV1";
    if (!highFps && (prefersTenBit || prefersHighResolution || profile.maxBitrateMbps >= 75) && capabilities.h265HardwareDecodeSupported) return "H265";
    return "H264";
}

static int ClampedStoredInteger(NSString *key, int defaultValue, int upperBoundExclusive) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:key];
    int stored = [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value intValue] : defaultValue;
    if (upperBoundExclusive <= 0) return 0;
    return std::max(0, std::min(stored, upperBoundExclusive - 1));
}

static double ClampedStoredDouble(NSString *key, double defaultValue, double minValue, double maxValue) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:key];
    double stored = [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value doubleValue] : defaultValue;
    if (!std::isfinite(stored)) stored = defaultValue;
    return std::max(minValue, std::min(stored, maxValue));
}

StreamPreferenceProfile LoadStreamPreferenceProfile() {
    StreamPreferenceProfile profile;
    const auto &aspects = StreamAspectOptions();
    profile.aspectIndex = ClampedStoredInteger(kAspectIndexKey, 1, (int)aspects.size());
    profile.aspect = aspects[(size_t)profile.aspectIndex];

    std::vector<StreamResolutionOption> resolutions = StreamResolutionOptionsForAspect(profile.aspectIndex);
    profile.resolutionIndex = ClampedStoredInteger(kResolutionIndexKey, profile.aspectIndex == 1 ? 2 : 0, (int)resolutions.size());
    profile.resolution = resolutions[(size_t)profile.resolutionIndex];

    const auto &fpsOptions = StreamFpsOptions();
    profile.fpsIndex = ClampedStoredInteger(kFpsIndexKey, 1, (int)fpsOptions.size());
    profile.fps = fpsOptions[(size_t)profile.fpsIndex];

    const auto &codecOptions = StreamCodecOptions();
    profile.codecIndex = ClampedStoredInteger(kCodecIndexKey, 0, (int)codecOptions.size());
    profile.codec = codecOptions[(size_t)profile.codecIndex];

    const auto &bitrateOptions = StreamBitrateOptions();
    profile.bitrateIndex = ClampedStoredInteger(kBitrateIndexKey, 2, (int)bitrateOptions.size());
    profile.bitrate = bitrateOptions[(size_t)profile.bitrateIndex];
    profile.maxBitrateMbps = profile.bitrate.mbps;

    const auto &colorQualityOptions = StreamColorQualityOptions();
    profile.colorQualityIndex = ClampedStoredInteger(kColorQualityIndexKey, 0, (int)colorQualityOptions.size());
    profile.colorQuality = colorQualityOptions[(size_t)profile.colorQualityIndex];

    profile.enableL4S = [NSUserDefaults.standardUserDefaults boolForKey:kL4SEnabledKey];
    profile.enablePowerSaver = [NSUserDefaults.standardUserDefaults boolForKey:kPowerSaverEnabledKey];
    id suppressInputValue = [NSUserDefaults.standardUserDefaults objectForKey:kSuppressInputWhenInactiveKey];
    profile.suppressInputWhenInactive = [suppressInputValue isKindOfClass:NSNumber.class] ? [(NSNumber *)suppressInputValue boolValue] : true;
    profile.gameVolume = ClampedStoredDouble(kGameVolumeKey, 1.0, 0.0, 1.0);
    profile.microphoneVolume = ClampedStoredDouble(kMicrophoneVolumeKey, 1.0, 0.0, 1.0);
    NSString *microphoneMode = [NSUserDefaults.standardUserDefaults stringForKey:kMicrophoneModeKey];
    profile.microphoneMode = microphoneMode.length > 0 ? [microphoneMode UTF8String] : "disabled";
    bool validMicrophoneMode = false;
    for (const StreamMicrophoneModeOption &option : StreamMicrophoneModeOptions()) {
        if (option.value == profile.microphoneMode) {
            validMicrophoneMode = true;
            break;
        }
    }
    if (!validMicrophoneMode) profile.microphoneMode = "disabled";
    NSString *microphoneDeviceId = [NSUserDefaults.standardUserDefaults stringForKey:kMicrophoneDeviceIdKey];
    profile.microphoneDeviceId = microphoneDeviceId.length > 0 ? [microphoneDeviceId UTF8String] : "";
    profile.microphonePushToTalkKeyCode = ClampedStoredInteger(kMicrophonePushToTalkKeyCodeKey, 9, 128);
    profile.microphonePushToTalkModifierMask = NormalizedPushToTalkModifierMask(profile.microphonePushToTalkKeyCode,
                                                                                ClampedStoredInteger(kMicrophonePushToTalkModifierMaskKey, 0, 32));
    profile.microphonePushToTalkKeyLabel = StreamMicrophonePushToTalkKeyLabel(profile.microphonePushToTalkKeyCode);
    profile.microphonePushToTalkComboLabel = StreamMicrophonePushToTalkComboLabel(profile.microphonePushToTalkKeyCode,
                                                                                  profile.microphonePushToTalkModifierMask);
    return profile;
}

const char *DefaultStreamingBaseUrl() {
    return kDefaultStreamingBaseUrl;
}

static std::string NormalizedBaseUrl(const std::string &url) {
    if (url.empty()) return kDefaultStreamingBaseUrl;
    return url.back() == '/' ? url : url + "/";
}

static std::string CurrentNetworkType() {
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0 || !interfaces) return "Unknown";

    bool hasWifi = false;
    bool hasWired = false;
    for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
        if (!item->ifa_name || (item->ifa_flags & IFF_UP) == 0 || (item->ifa_flags & IFF_RUNNING) == 0) continue;
        if ((item->ifa_flags & IFF_LOOPBACK) != 0) continue;
        std::string name(item->ifa_name);
        if (name.rfind("awdl", 0) == 0 || name.rfind("llw", 0) == 0 || name.rfind("utun", 0) == 0) continue;
        if (name == "en0" || name == "en1") {
            hasWifi = true;
        } else if (name.rfind("en", 0) == 0 || name.rfind("bridge", 0) == 0) {
            hasWired = true;
        }
    }
    freeifaddrs(interfaces);
    if (hasWired) return "Ethernet";
    if (hasWifi) return "WiFi";
    return "Unknown";
}

static int RecommendedPreflightBitrate(int requestedMaxBitrateMbps, int latencyMs) {
    int requested = std::max(1, requestedMaxBitrateMbps);
    if (latencyMs < 0) return requested;
    if (latencyMs >= 120) return std::min(requested, 25);
    if (latencyMs >= 85) return std::min(requested, 50);
    if (latencyMs >= 60) return std::min(requested, 75);
    return requested;
}

std::string LoadSelectedStreamRegionUrl() {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:kSelectedRegionUrlKey];
    return value.length > 0 ? std::string([value UTF8String]) : std::string();
}

std::string LoadSelectedStreamingBaseUrl() {
    std::string selected = LoadSelectedStreamRegionUrl();
    if (!selected.empty()) return NormalizedBaseUrl(selected);
    std::vector<StreamRegionOption> regions = LoadCachedStreamRegions();
    auto best = std::find_if(regions.begin(), regions.end(), [](const StreamRegionOption &region) {
        return !region.url.empty() && region.latencyMs >= 0;
    });
    return best == regions.end() ? kDefaultStreamingBaseUrl : NormalizedBaseUrl(best->url);
}

void SaveSelectedStreamRegionUrl(const std::string &url) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (url.empty()) {
        [defaults removeObjectForKey:kSelectedRegionUrlKey];
    } else {
        [defaults setObject:[NSString stringWithUTF8String:NormalizedBaseUrl(url).c_str()] forKey:kSelectedRegionUrlKey];
    }
    [defaults synchronize];
}

std::vector<StreamRegionOption> LoadCachedStreamRegions() {
    std::vector<StreamRegionOption> regions;
    NSArray *items = [NSUserDefaults.standardUserDefaults arrayForKey:kCachedRegionsKey];
    if (![items isKindOfClass:NSArray.class]) return regions;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : nil;
        NSString *url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : nil;
        NSNumber *latency = [item[@"latencyMs"] isKindOfClass:NSNumber.class] ? item[@"latencyMs"] : nil;
        if (name.length == 0 || url.length == 0) continue;
        StreamRegionOption region;
        region.name = [name UTF8String];
        region.url = NormalizedBaseUrl([url UTF8String]);
        region.latencyMs = latency ? latency.intValue : -1;
        regions.push_back(region);
    }
    return regions;
}

void SaveCachedStreamRegions(const std::vector<StreamRegionOption> &regions) {
    NSMutableArray *items = [NSMutableArray array];
    for (const StreamRegionOption &region : regions) {
        if (region.automatic || region.name.empty() || region.url.empty()) continue;
        NSMutableDictionary *item = [@{
            @"name": [NSString stringWithUTF8String:region.name.c_str()],
            @"url": [NSString stringWithUTF8String:NormalizedBaseUrl(region.url).c_str()],
        } mutableCopy];
        if (region.latencyMs >= 0) item[@"latencyMs"] = @(region.latencyMs);
        [items addObject:item];
    }
    [NSUserDefaults.standardUserDefaults setObject:items forKey:kCachedRegionsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static NSMutableURLRequest *ServerInfoRequest(const std::string &baseUrl, const std::string &token) {
    std::string normalized = NormalizedBaseUrl(baseUrl);
    NSString *base = [NSString stringWithUTF8String:normalized.c_str()] ?: @"";
    NSString *urlString = [base stringByAppendingString:@"v2/serverInfo"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 4.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:kNvClientId forHTTPHeaderField:@"nv-client-id"];
    [request setValue:@"BROWSER" forHTTPHeaderField:@"nv-client-type"];
    [request setValue:kNvClientVersion forHTTPHeaderField:@"nv-client-version"];
    [request setValue:@"WEBRTC" forHTTPHeaderField:@"nv-client-streamer"];
    [request setValue:@"WINDOWS" forHTTPHeaderField:@"nv-device-os"];
    [request setValue:@"DESKTOP" forHTTPHeaderField:@"nv-device-type"];
    if (!token.empty()) {
        NSString *tokenString = [NSString stringWithUTF8String:token.c_str()];
        if (tokenString.length > 0) {
            [request setValue:[@"GFNJWT " stringByAppendingString:tokenString] forHTTPHeaderField:@"Authorization"];
        }
    }
    return request;
}

static void MeasureRegions(std::shared_ptr<std::vector<StreamRegionOption>> regions,
                           const std::string &token,
                           std::function<void(const std::vector<StreamRegionOption> &)> completion) {
    if (!regions || regions->empty()) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion({}); });
        return;
    }

    dispatch_group_t group = dispatch_group_create();
    NSURLSession *session = NSURLSession.sharedSession;
    for (size_t i = 0; i < regions->size(); i++) {
        dispatch_group_enter(group);
        NSDate *start = [NSDate date];
        NSMutableURLRequest *request = ServerInfoRequest((*regions)[i].url, token);
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (!error && http.statusCode >= 200 && http.statusCode < 500) {
                (*regions)[i].latencyMs = (int)std::llround([[NSDate date] timeIntervalSinceDate:start] * 1000.0);
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        std::sort(regions->begin(), regions->end(), [](const StreamRegionOption &a, const StreamRegionOption &b) {
            if (a.latencyMs >= 0 && b.latencyMs >= 0 && a.latencyMs != b.latencyMs) return a.latencyMs < b.latencyMs;
            if (a.latencyMs >= 0 && b.latencyMs < 0) return true;
            if (a.latencyMs < 0 && b.latencyMs >= 0) return false;
            return a.name < b.name;
        });
        SaveCachedStreamRegions(*regions);
        completion(*regions);
    });
}

void FetchStreamRegions(const std::string &token,
                        const std::string &providerStreamingBaseUrl,
                        std::function<void(const std::vector<StreamRegionOption> &regions)> completion) {
    std::string baseUrl = providerStreamingBaseUrl.empty() ? kDefaultStreamingBaseUrl : providerStreamingBaseUrl;
    std::string tokenCopy = token;
    NSMutableURLRequest *request = ServerInfoRequest(baseUrl, tokenCopy);
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || !data || http.statusCode != 200) {
            std::vector<StreamRegionOption> cached = LoadCachedStreamRegions();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cached); });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *metadata = [json[@"metaData"] isKindOfClass:NSArray.class] ? json[@"metaData"] : nil;
        auto regions = std::make_shared<std::vector<StreamRegionOption>>();
        for (NSDictionary *entry in metadata) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : nil;
            NSString *value = [entry[@"value"] isKindOfClass:NSString.class] ? entry[@"value"] : nil;
            if (key.length == 0 || value.length == 0) continue;
            if ([key isEqualToString:@"gfn-regions"] || [key hasPrefix:@"gfn-"]) continue;
            if (![value hasPrefix:@"https://"]) continue;
            StreamRegionOption region;
            region.name = [key UTF8String];
            region.url = NormalizedBaseUrl([value UTF8String]);
            regions->push_back(region);
        }
        if (regions->empty()) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(LoadCachedStreamRegions()); });
            return;
        }
        MeasureRegions(regions, tokenCopy, completion);
    }] resume];
}

void RunStreamNetworkPreflight(const std::string &token,
                               const std::string &providerStreamingBaseUrl,
                               int requestedMaxBitrateMbps,
                               std::function<void(const StreamNetworkPreflightResult &result)> completion) {
    StreamNetworkPreflightResult initial;
    initial.streamingBaseUrl = LoadSelectedStreamingBaseUrl();
    initial.networkType = CurrentNetworkType();
    initial.recommendedMaxBitrateMbps = std::max(1, requestedMaxBitrateMbps);

    std::string selectedRegionUrl = LoadSelectedStreamRegionUrl();
    FetchStreamRegions(token, providerStreamingBaseUrl, [initial, selectedRegionUrl, requestedMaxBitrateMbps, completion](const std::vector<StreamRegionOption> &regions) mutable {
        StreamNetworkPreflightResult result = initial;
        const StreamRegionOption *chosen = nullptr;
        if (!selectedRegionUrl.empty()) {
            std::string normalizedSelected = NormalizedBaseUrl(selectedRegionUrl);
            auto selected = std::find_if(regions.begin(), regions.end(), [&normalizedSelected](const StreamRegionOption &region) {
                return NormalizedBaseUrl(region.url) == normalizedSelected;
            });
            if (selected != regions.end()) chosen = &(*selected);
        }
        if (!chosen) {
            auto measured = std::find_if(regions.begin(), regions.end(), [](const StreamRegionOption &region) {
                return !region.url.empty() && region.latencyMs >= 0;
            });
            if (measured != regions.end()) {
                chosen = &(*measured);
                result.usedAutomaticRegion = selectedRegionUrl.empty();
            }
        }
        if (chosen && !chosen->url.empty()) {
            result.streamingBaseUrl = NormalizedBaseUrl(chosen->url);
            result.latencyMs = chosen->latencyMs;
        }
        result.recommendedMaxBitrateMbps = RecommendedPreflightBitrate(requestedMaxBitrateMbps, result.latencyMs);
        completion(result);
    });
}

void SaveStreamAspectIndex(int aspectIndex) {
    int clamped = std::max(0, std::min(aspectIndex, (int)StreamAspectOptions().size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kAspectIndexKey];
    std::vector<StreamResolutionOption> resolutions = StreamResolutionOptionsForAspect(clamped);
    int currentResolution = ClampedStoredInteger(kResolutionIndexKey, clamped == 1 ? 2 : 0, (int)resolutions.size());
    [NSUserDefaults.standardUserDefaults setInteger:currentResolution forKey:kResolutionIndexKey];
}

void SaveStreamResolutionIndex(int resolutionIndex) {
    StreamPreferenceProfile current = LoadStreamPreferenceProfile();
    std::vector<StreamResolutionOption> resolutions = StreamResolutionOptionsForAspect(current.aspectIndex);
    int clamped = std::max(0, std::min(resolutionIndex, (int)resolutions.size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kResolutionIndexKey];
}

void SaveStreamFpsIndex(int fpsIndex) {
    int clamped = std::max(0, std::min(fpsIndex, (int)StreamFpsOptions().size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kFpsIndexKey];
}

void SaveStreamCodecIndex(int codecIndex) {
    int clamped = std::max(0, std::min(codecIndex, (int)StreamCodecOptions().size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kCodecIndexKey];
}

void SaveStreamBitrateIndex(int bitrateIndex) {
    int clamped = std::max(0, std::min(bitrateIndex, (int)StreamBitrateOptions().size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kBitrateIndexKey];
}

void SaveStreamColorQualityIndex(int colorQualityIndex) {
    int clamped = std::max(0, std::min(colorQualityIndex, (int)StreamColorQualityOptions().size() - 1));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kColorQualityIndexKey];
}

void SaveStreamL4SEnabled(bool enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kL4SEnabledKey];
}

void SaveStreamPowerSaverEnabled(bool enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kPowerSaverEnabledKey];
}

void SaveStreamSuppressInputWhenInactive(bool enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kSuppressInputWhenInactiveKey];
}

void SaveStreamGameVolume(double volume) {
    [NSUserDefaults.standardUserDefaults setDouble:std::max(0.0, std::min(volume, 1.0)) forKey:kGameVolumeKey];
}

void SaveStreamMicrophoneVolume(double volume) {
    [NSUserDefaults.standardUserDefaults setDouble:std::max(0.0, std::min(volume, 1.0)) forKey:kMicrophoneVolumeKey];
}

void SaveStreamMicrophoneMode(const std::string &mode) {
    bool valid = false;
    for (const StreamMicrophoneModeOption &option : StreamMicrophoneModeOptions()) {
        if (option.value == mode) {
            valid = true;
            break;
        }
    }
    const std::string &stored = valid ? mode : StreamMicrophoneModeOptions().front().value;
    [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithUTF8String:stored.c_str()] forKey:kMicrophoneModeKey];
}

void SaveStreamMicrophoneDeviceId(const std::string &deviceId) {
    if (deviceId.empty()) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kMicrophoneDeviceIdKey];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithUTF8String:deviceId.c_str()] forKey:kMicrophoneDeviceIdKey];
}

void SaveStreamMicrophonePushToTalkKeyCode(int keyCode) {
    int clamped = std::max(0, std::min(keyCode, 127));
    [NSUserDefaults.standardUserDefaults setInteger:clamped forKey:kMicrophonePushToTalkKeyCodeKey];
}

void SaveStreamMicrophonePushToTalkModifierMask(int modifierMask) {
    [NSUserDefaults.standardUserDefaults setInteger:SanitizedPushToTalkModifierMask(modifierMask)
                                             forKey:kMicrophonePushToTalkModifierMaskKey];
}

}
