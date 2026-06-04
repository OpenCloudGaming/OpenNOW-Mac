#pragma once

#include "OPNStreamTypes.h"
#include <string>
#include <vector>
#include <functional>

namespace OPN {

struct StreamAspectOption {
    std::string label;
    int widthRatio = 16;
    int heightRatio = 9;
};

struct StreamResolutionOption {
    int width = 1920;
    int height = 1080;

    std::string Value() const;
    std::string Label() const;
};

struct StreamRegionOption {
    std::string name;
    std::string url;
    int latencyMs = -1;
    bool automatic = false;

    std::string Label() const;
};

struct StreamCodecOption {
    std::string label;
    std::string value;
};

struct StreamBitrateOption {
    std::string label;
    int mbps = 50;
};

struct StreamColorQualityOption {
    std::string label;
    std::string value;
};

struct StreamPrefilterModeOption {
    std::string label;
    int value = 0;
};

struct StreamUpscalingModeOption {
    std::string label;
    int value = 0;
};

struct StreamMicrophoneModeOption {
    std::string label;
    std::string value;
};

struct StreamMicrophoneDeviceOption {
    std::string label;
    std::string uniqueId;
    bool automatic = false;
};

struct StreamNetworkPreflightResult {
    std::string streamingBaseUrl;
    std::string networkTestSessionId;
    std::string networkType = "Unknown";
    int latencyMs = -1;
    double measuredBandwidthMbps = 0.0;
    double packetLossPercent = -1.0;
    int jitterMs = -1;
    int recommendedMaxBitrateMbps = 0;
    bool serverReportedWarning = false;
    bool continueRecommended = true;
    bool usedAutomaticRegion = false;
    std::string warningMessage;
};

struct StreamCloudVariables {
    bool fetched = false;
    bool allowH265 = true;
    bool allowAV1 = true;
    bool allowHDR = true;
    bool allowL4S = true;
    bool allowReflex = true;
    bool allowPrefilter = true;
    int maxBitrateMbps = 0;
    int maxSupportedPrefilterMode = 2;
    std::vector<int> supportedPrefilterModes;
    int refreshIntervalSeconds = 3600;
    std::string gpuName;
};

struct StreamDeviceCapabilities {
    bool h264HardwareDecodeSupported = true;
    bool h265HardwareDecodeSupported = false;
    bool av1HardwareDecodeSupported = false;
    bool hdrDisplaySupported = false;
    int maxDisplayWidth = 0;
    int maxDisplayHeight = 0;
    int maxDisplayRefreshRate = 0;
    int displayDpi = 100;
};

struct StreamPreferenceProfile {
    int aspectIndex = 1;
    int resolutionIndex = 2;
    int fpsIndex = 1;
    int codecIndex = 0;
    int bitrateIndex = 2;
    int colorQualityIndex = 0;
    int fps = 60;
    int maxBitrateMbps = 50;
    int prefilterModeIndex = 0;
    int prefilterMode = 0;
    int prefilterSharpness = 0;
    int prefilterDenoise = 0;
    int prefilterModel = 0;
    int upscalingModeIndex = 1;
    int upscalingMode = 1;
    int upscalingSharpness = 4;
    int recordingVideoBitrateMbps = 0;
    int recordingAudioBitrateKbps = 160;
    bool enableL4S = false;
    bool enableHdr = false;
    bool enablePowerSaver = false;
    bool suppressInputWhenInactive = true;
    bool directMouseInput = true;
    double gameVolume = 1.0;
    double microphoneVolume = 1.0;
    std::string microphoneMode = "disabled";
    std::string microphoneDeviceId;
    int microphonePushToTalkKeyCode = 9;
    int microphonePushToTalkModifierMask = 0;
    std::string microphonePushToTalkKeyLabel = "V";
    std::string microphonePushToTalkComboLabel = "V";
    StreamAspectOption aspect;
    StreamResolutionOption resolution;
    StreamCodecOption codec;
    StreamBitrateOption bitrate;
    StreamColorQualityOption colorQuality;
    StreamPrefilterModeOption prefilterModeOption;
    StreamUpscalingModeOption upscalingModeOption;

    double AspectRatio() const;
};

const std::vector<StreamAspectOption> &StreamAspectOptions();
const std::vector<int> &StreamFpsOptions();
const std::vector<StreamCodecOption> &StreamCodecOptions();
const std::vector<StreamBitrateOption> &StreamBitrateOptions();
const std::vector<StreamColorQualityOption> &StreamColorQualityOptions();
const std::vector<StreamPrefilterModeOption> &StreamPrefilterModeOptions();
const std::vector<StreamUpscalingModeOption> &StreamUpscalingModeOptions();
const std::vector<StreamMicrophoneModeOption> &StreamMicrophoneModeOptions();
std::vector<StreamMicrophoneDeviceOption> LoadMicrophoneDeviceOptions();
std::vector<StreamResolutionOption> StreamResolutionOptionsForAspect(int aspectIndex);
StreamDeviceCapabilities LoadStreamDeviceCapabilities();
bool StreamCodecSupportedByCapabilities(const StreamCodecOption &codec,
                                        const StreamDeviceCapabilities &capabilities);
bool StreamFpsSupportedByCapabilities(int fps,
                                      const StreamDeviceCapabilities &capabilities);
bool StreamColorQualitySupportedByCapabilities(const StreamColorQualityOption &colorQuality,
                                               const StreamCodecOption &codec,
                                               const StreamDeviceCapabilities &capabilities);
StreamPreferenceProfile EffectiveStreamPreferenceProfileForCapabilities(StreamPreferenceProfile profile,
                                                                        const StreamDeviceCapabilities &capabilities);
std::string ResolveStreamCodecForCapabilities(const StreamPreferenceProfile &profile,
                                               const StreamResolutionOption &resolution,
                                               const StreamDeviceCapabilities &capabilities,
                                               bool libWebRTCAvailable);
StreamNetworkPreflightResult StreamNetworkPreflightResultFromJSONString(const std::string &jsonText,
                                                                       StreamNetworkPreflightResult seed,
                                                                       int requestedMaxBitrateMbps);
int RecommendedStreamBitrateForNetwork(int requestedMaxBitrateMbps,
                                       int latencyMs,
                                       double measuredBandwidthMbps,
                                       double packetLossPercent,
                                       int jitterMs);
StreamCloudVariables StreamCloudVariablesFromJSONString(const std::string &jsonText);
StreamSettings StreamSettingsByApplyingCloudVariables(StreamSettings settings,
                                                      const StreamCloudVariables &variables,
                                                      const StreamDeviceCapabilities &capabilities);

StreamPreferenceProfile LoadStreamPreferenceProfile();
const char *DefaultStreamingBaseUrl();
std::string LoadSelectedStreamRegionUrl();
std::string LoadSelectedStreamingBaseUrl();
void SaveSelectedStreamRegionUrl(const std::string &url);
std::vector<StreamRegionOption> LoadCachedStreamRegions();
void SaveCachedStreamRegions(const std::vector<StreamRegionOption> &regions);
void FetchStreamRegions(const std::string &token,
                        const std::string &providerStreamingBaseUrl,
                        std::function<void(const std::vector<StreamRegionOption> &regions)> completion);
StreamCloudVariables LoadCachedStreamCloudVariables();
void SaveCachedStreamCloudVariables(const StreamCloudVariables &variables, const std::string &rawJSON);
void FetchStreamCloudVariables(const std::string &token,
                               std::function<void(const StreamCloudVariables &variables)> completion);
void RunStreamNetworkPreflight(const std::string &token,
                               const std::string &providerStreamingBaseUrl,
                               int requestedMaxBitrateMbps,
                               std::function<void(const StreamNetworkPreflightResult &result)> completion);
void SaveStreamAspectIndex(int aspectIndex);
void SaveStreamResolutionIndex(int resolutionIndex);
void SaveStreamFpsIndex(int fpsIndex);
void SaveStreamCodecIndex(int codecIndex);
void SaveStreamBitrateIndex(int bitrateIndex);
void SaveStreamColorQualityIndex(int colorQualityIndex);
void SaveStreamPrefilterModeIndex(int prefilterModeIndex);
void SaveStreamPrefilterSharpness(int sharpness);
void SaveStreamPrefilterDenoise(int denoise);
void SaveStreamUpscalingModeIndex(int upscalingModeIndex);
void SaveStreamUpscalingSharpness(int sharpness);
void SaveStreamRecordingVideoBitrateMbps(int bitrateMbps);
void SaveStreamRecordingAudioBitrateKbps(int bitrateKbps);
void SaveStreamL4SEnabled(bool enabled);
void SaveStreamHDREnabled(bool enabled);
void SaveStreamPowerSaverEnabled(bool enabled);
void SaveStreamSuppressInputWhenInactive(bool enabled);
void SaveStreamDirectMouseInputEnabled(bool enabled);
void SaveStreamGameVolume(double volume);
void SaveStreamMicrophoneVolume(double volume);
void SaveStreamMicrophoneMode(const std::string &mode);
void SaveStreamMicrophoneDeviceId(const std::string &deviceId);
void SaveStreamMicrophonePushToTalkKeyCode(int keyCode);
void SaveStreamMicrophonePushToTalkModifierMask(int modifierMask);
std::string StreamMicrophonePushToTalkKeyLabel(int keyCode);
std::string StreamMicrophonePushToTalkComboLabel(int keyCode, int modifierMask);

}
