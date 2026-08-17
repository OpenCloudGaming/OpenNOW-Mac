#import <Foundation/Foundation.h>

#import <AppKit/AppKit.h>

#include <stdint.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <atomic>
#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace Nsk {
struct DownstreamVideoSettings { alignas(8) unsigned char bytes[0x90]; };
struct AudioStreamSettings { uint16_t sampleRate; };
struct StreamConnectionInfo { std::string host; uint64_t endpointHost; uint16_t endpointPort; uint32_t transferProtocol; };

struct ApplicationStreamStartParameters {
    unsigned char reserved0[0x30];
    std::string gameLanguage;
    std::string clientAppVersion;
    std::string clientLocale;
};

struct PlatformStartupParams {
    bool asyncRenderEnabled = true;
    unsigned char pad1[7] = {};
    void *firstHintNode = nullptr;
    void *emptyHintNode = nullptr;

    PlatformStartupParams() : firstHintNode(&emptyHintNode) {}
};

struct StreamStartParameters {
    std::string sessionId;
    std::string serverAddress;
    uint64_t unknown30 = 0;
    uint32_t appId = 0;
    unsigned char pad3c[4] = {};
    std::string gameLanguage;
    std::string unknown58;
    std::string unknown70;
    std::string unknown88;
    std::string clientAppVersion;
    std::string clientLocale;
    uint32_t resumeType = 0;
    unsigned char padd4[4] = {};
    std::vector<DownstreamVideoSettings> videoSettings;
    std::vector<AudioStreamSettings> audioSettings;
    std::string connectionType;
    std::vector<StreamConnectionInfo> connectionInfo;
    unsigned char features[0x28] = {};
    std::string unknown160;
    uint64_t unknown178 = 0;
    bool unknown180 = false;
};

struct VideoDecoderInitParams { alignas(8) unsigned char bytes[0xd0]; };
struct VideoDecoderCapabilityParams { alignas(8) unsigned char bytes[0x68]; };

struct NVbStreamSettings_t { alignas(8) unsigned char bytes[0x170]; };
struct NVbConnectionInfo_t { unsigned char bytes[0x40c]; };
struct NVbStreamingParams_t { alignas(8) unsigned char bytes[0x208]; };

struct NVbTracingContext_t {
    uint64_t reserved0 = 0;
    uint64_t reserved8 = 0;
    uint64_t reserved10 = 0;
    const char *traceParent = nullptr;
};
}

struct NVbKeyValuePair_t {
    const char *key = nullptr;
    const char *value = nullptr;
};

namespace SessionControl {
struct PrepareParameters {
    std::string serverAddress;
    uint32_t serverPort = 0;
    uint32_t clientProfile = 0;
    std::string deviceId;
    alignas(4) unsigned char communicationParams[0x2c] = {};
    bool synchronous = false;
    unsigned char pad65[3] = {};
    int32_t serverType = -1;
    unsigned char pad6c[4] = {};
    std::string locale;
    std::string sslCertificate;
    std::string sslPrivateKey;
    std::string applicationIdentifier;
    std::string applicationVersion;
    std::string clientName;
    std::string clientAppVersion;
    std::vector<std::string> applicationHeaders;
};

struct SessionParameters {
    uint32_t appId = 0;
    uint32_t pad04 = 0;
    std::string serverAddress;
    uint32_t serverPort = 0;
    int32_t serverType = -1;
    unsigned char pad28[0x0c] = {};
    uint32_t streamSettingsCount = 0;
    uint64_t gamepadBitmap = 0;
    uint64_t supportedHidTypes = 0;
    Nsk::NVbStreamSettings_t *streamSettings = nullptr;
    Nsk::NVbStreamSettings_t defaultStreamSettings;
    unsigned char pad1c0[0x0c] = {};
    uint32_t appLaunchMode = 0;
    NVbKeyValuePair_t *metadata = nullptr;
    uint32_t metadataCount = 0;
    bool networkPacketCaptureEnabled = false;
    unsigned char pad1dd[0x0b] = {};
    std::string partnerCustomData;
    std::string clientLocale;
    std::string keyboardLayout;
    bool allowKeyboardLayoutChange = false;
    bool accountLinked = false;
    unsigned char pad232 = 0;
    uint8_t audioChannelCount = 2;
    bool persistingInGameSettings = false;
    unsigned char pad235[3] = {};
    std::string networkSessionId;
    std::string bifrostSessionId;
    std::vector<Nsk::NVbConnectionInfo_t> connectionInfo;
    uint32_t userAge = 0;
    uint32_t pad284 = 0;
};
}

struct GeronimoStats { alignas(8) unsigned char bytes[0x450]; };

struct OpenNOWNativeNVSTPerformanceStats {
    uint32_t available = 0;
    uint32_t frameWidth = 0;
    uint32_t frameHeight = 0;
    uint32_t streamFramesPerSecond = 0;
    uint32_t codec = 0;
    uint32_t frameLoss = 0;
    uint32_t totalFrameLoss = 0;
    uint32_t packetLoss = 0;
    uint32_t totalPacketLoss = 0;
    double gameFramesPerSecond = -1;
    double latencyMilliseconds = -1;
    double jitterMilliseconds = -1;
    double bitrateMegabitsPerSecond = -1;
    double bandwidthUtilizationPercent = -1;
};

static_assert(sizeof(std::string) == 0x18, "libGeronimo std::string ABI changed");
static_assert(sizeof(Nsk::DownstreamVideoSettings) == 0x90, "libGeronimo DownstreamVideoSettings ABI changed");
static_assert(sizeof(Nsk::AudioStreamSettings) == 0x2, "libGeronimo AudioStreamSettings ABI changed");
static_assert(sizeof(Nsk::StreamConnectionInfo) == 0x28, "libGeronimo StreamConnectionInfo ABI changed");
static_assert(sizeof(Nsk::VideoDecoderCapabilityParams) == 0x68, "libGeronimo VideoDecoder capability ABI changed");
static_assert(sizeof(Nsk::NVbStreamSettings_t) == 0x170, "libGeronimo NVbStreamSettings_t ABI changed");
static_assert(sizeof(Nsk::NVbConnectionInfo_t) == 0x40c, "libGeronimo NVbConnectionInfo_t ABI changed");
static_assert(sizeof(Nsk::NVbTracingContext_t) == 0x20, "libGeronimo NVbTracingContext_t ABI changed");
static_assert(sizeof(NVbKeyValuePair_t) == 0x10, "libBifrost2 NVbKeyValuePair_t size changed");
static_assert(alignof(NVbKeyValuePair_t) == 0x08, "libBifrost2 NVbKeyValuePair_t alignment changed");
static_assert(offsetof(NVbKeyValuePair_t, key) == 0x00, "libBifrost2 NVbKeyValuePair_t key offset changed");
static_assert(offsetof(NVbKeyValuePair_t, value) == 0x08, "libBifrost2 NVbKeyValuePair_t value offset changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, gameLanguage) == 0x30, "libGeronimo gameLanguage offset changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, clientAppVersion) == 0x48, "libGeronimo clientAppVersion offset changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, clientLocale) == 0x60, "libGeronimo clientLocale offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, videoSettings) == 0xd8, "libGeronimo videoSettings offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, audioSettings) == 0xf0, "libGeronimo audioSettings offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, connectionType) == 0x108, "libGeronimo connectionType offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, connectionInfo) == 0x120, "libGeronimo connectionInfo offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, unknown180) == 0x180, "libGeronimo StreamStartParameters ABI changed");
static_assert(sizeof(SessionControl::PrepareParameters) == 0x130, "libGeronimo PrepareParameters size changed");
static_assert(offsetof(SessionControl::PrepareParameters, deviceId) == 0x20, "libGeronimo PrepareParameters deviceId offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, communicationParams) == 0x38, "libGeronimo PrepareParameters communicationParams offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, locale) == 0x70, "libGeronimo PrepareParameters locale offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, sslCertificate) == 0x88, "libGeronimo PrepareParameters sslCertificate offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, sslPrivateKey) == 0xa0, "libGeronimo PrepareParameters sslPrivateKey offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, applicationIdentifier) == 0xb8, "libGeronimo PrepareParameters applicationIdentifier offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, applicationVersion) == 0xd0, "libGeronimo PrepareParameters applicationVersion offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, clientName) == 0xe8, "libGeronimo PrepareParameters clientName offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, clientAppVersion) == 0x100, "libGeronimo PrepareParameters clientAppVersion offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, applicationHeaders) == 0x118, "libGeronimo PrepareParameters applicationHeaders offset changed");
static_assert(offsetof(SessionControl::SessionParameters, serverAddress) == 0x08, "libGeronimo SessionParameters serverAddress offset changed");
static_assert(offsetof(SessionControl::SessionParameters, serverPort) == 0x20, "libGeronimo SessionParameters serverPort offset changed");
static_assert(offsetof(SessionControl::SessionParameters, serverType) == 0x24, "libGeronimo SessionParameters serverType offset changed");
static_assert(offsetof(SessionControl::SessionParameters, streamSettingsCount) == 0x34, "libGeronimo SessionParameters streamSettingsCount offset changed");
static_assert(offsetof(SessionControl::SessionParameters, gamepadBitmap) == 0x38, "libGeronimo SessionParameters gamepadBitmap offset changed");
static_assert(offsetof(SessionControl::SessionParameters, supportedHidTypes) == 0x40, "libGeronimo SessionParameters supportedHidTypes offset changed");
static_assert(offsetof(SessionControl::SessionParameters, streamSettings) == 0x48, "libGeronimo SessionParameters streamSettings offset changed");
static_assert(offsetof(SessionControl::SessionParameters, defaultStreamSettings) == 0x50, "libGeronimo SessionParameters defaultStreamSettings offset changed");
static_assert(offsetof(SessionControl::SessionParameters, appLaunchMode) == 0x1cc, "libGeronimo SessionParameters appLaunchMode offset changed");
static_assert(offsetof(SessionControl::SessionParameters, metadata) == 0x1d0, "libGeronimo SessionParameters metadata offset changed");
static_assert(offsetof(SessionControl::SessionParameters, metadataCount) == 0x1d8, "libGeronimo SessionParameters metadataCount offset changed");
static_assert(offsetof(SessionControl::SessionParameters, networkPacketCaptureEnabled) == 0x1dc, "libGeronimo SessionParameters networkPacketCaptureEnabled offset changed");
static_assert(offsetof(SessionControl::SessionParameters, partnerCustomData) == 0x1e8, "libGeronimo SessionParameters partnerCustomData offset changed");
static_assert(offsetof(SessionControl::SessionParameters, clientLocale) == 0x200, "libGeronimo SessionParameters clientLocale offset changed");
static_assert(offsetof(SessionControl::SessionParameters, keyboardLayout) == 0x218, "libGeronimo SessionParameters keyboardLayout offset changed");
static_assert(offsetof(SessionControl::SessionParameters, allowKeyboardLayoutChange) == 0x230, "libGeronimo SessionParameters allowKeyboardLayoutChange offset changed");
static_assert(offsetof(SessionControl::SessionParameters, accountLinked) == 0x231, "libGeronimo SessionParameters accountLinked offset changed");
static_assert(offsetof(SessionControl::SessionParameters, audioChannelCount) == 0x233, "libGeronimo SessionParameters audioChannelCount offset changed");
static_assert(offsetof(SessionControl::SessionParameters, persistingInGameSettings) == 0x234, "libGeronimo SessionParameters persistingInGameSettings offset changed");
static_assert(offsetof(SessionControl::SessionParameters, networkSessionId) == 0x238, "libGeronimo SessionParameters networkSessionId offset changed");
static_assert(offsetof(SessionControl::SessionParameters, bifrostSessionId) == 0x250, "libGeronimo SessionParameters bifrostSessionId offset changed");
static_assert(offsetof(SessionControl::SessionParameters, connectionInfo) == 0x268, "libGeronimo SessionParameters connectionInfo offset changed");
static_assert(offsetof(SessionControl::SessionParameters, userAge) == 0x280, "libGeronimo SessionParameters userAge offset changed");
static_assert(sizeof(SessionControl::SessionParameters) == 0x288, "libGeronimo SessionParameters size changed");
static_assert(sizeof(GeronimoStats) == 0x450, "libGeronimo GeronimoStats size changed");
static_assert(offsetof(OpenNOWNativeNVSTPerformanceStats, gameFramesPerSecond) == 0x28, "Native performance stats double alignment changed");
static_assert(sizeof(OpenNOWNativeNVSTPerformanceStats) == 0x50, "Native performance stats ABI changed");

namespace {
constexpr size_t GridAppStorageSize = 0x2000;
constexpr size_t GridAppVTableSize = 0x220;
constexpr size_t GridAppPrepareResultSlotOffset = 0x90;
constexpr size_t GridAppStreamingBeginSlotOffset = 0x98;
constexpr size_t GridAppSetupFailureSlotOffset = 0xa8;
constexpr size_t GridAppResumeFailureSlotOffset = 0xb0;
constexpr size_t GridAppSetupSuccessSlotOffset = 0xc0;
constexpr size_t GridAppStreamingTerminatedSlotOffset = 0xc8;
constexpr size_t GridAppUpdateAuthTokenSlotOffset = 0xf0;
constexpr size_t GridAppCursorInfoSlotOffset = 0x118;
constexpr size_t GridAppSetupProgressSlotOffset = 0x140;
constexpr size_t GridAppActiveSessionsSlotOffset = 0x148;
constexpr size_t GridAppStopResultSlotOffset = 0x158;
constexpr size_t GridAppPauseResultSlotOffset = 0x160;
constexpr size_t VideoDecoderInitializeSlotOffset = 0x38;
constexpr size_t SDLGraphicsContextStorageSize = 0x88;
constexpr size_t SDLEventProcessorStorageSize = 0xb0;
constexpr size_t SDLWindowStorageSize = 0x438;

struct PlatformDecoderCreationSettings { alignas(8) unsigned char bytes[0x28]; };
struct PlatformDecoderSettings { alignas(4) unsigned char bytes[0x1f]; };
struct PlatformAudioSettings { alignas(8) unsigned char bytes[0x08]; };
struct SDLGraphicsContextInitParameters { alignas(8) unsigned char bytes[0x30]; };
struct SDLEventProcessorInitParams { alignas(4) unsigned char bytes[0x08]; };
struct SDLWindowInitParams { alignas(8) unsigned char bytes[0x80]; };
struct SDLPoint { int32_t x; int32_t y; };
struct SDLRect { int32_t x; int32_t y; int32_t width; int32_t height; };
struct AsyncVideoFrameRenderer;

static_assert(sizeof(PlatformDecoderCreationSettings) == 0x28, "libGeronimo PlatformDecoderCreationSettings ABI changed");
static_assert(sizeof(PlatformDecoderSettings) == 0x20, "libGeronimo PlatformDecoderSettings storage ABI changed");
static_assert(sizeof(PlatformAudioSettings) == 0x08, "libGeronimo PlatformAudioSettings ABI changed");
static_assert(sizeof(SDLGraphicsContextInitParameters) == 0x30, "libGeronimo SDLGraphicsContext::InitParameters ABI changed");
static_assert(sizeof(SDLEventProcessorInitParams) == 0x08, "libGeronimo SDLEventProcessor::InitParams ABI changed");
static_assert(sizeof(SDLWindowInitParams) == 0x80, "libGeronimo SDLWindow::InitParams ABI changed");
static_assert(sizeof(SDLPoint) == 0x08, "libGeronimo SDL_Point ABI changed");
static_assert(sizeof(SDLRect) == 0x10, "libGeronimo SDL_Rect ABI changed");

using NskPlatformStartup = bool (*)(const Nsk::PlatformStartupParams &);
using PlatformShutdown = void (*)();
using GridAppCtor = void (*)(void *);
using GridAppDtor = void (*)(void *);
using GridAppInitialize = void *(*)(void *, bool);
using GridAppProcessEvents = void (*)(void *);
using GridAppStop = bool (*)(void *, const char *, int);
using GridAppPause = bool (*)(void *, int);
using GridAppPrepare = bool (*)(void *, const SessionControl::PrepareParameters &);
using GridAppSetAuthInfo = bool (*)(void *, void *);
using GridAppStart = bool (*)(void *, const SessionControl::SessionParameters &, const Nsk::NVbTracingContext_t &);
using GridAppResume = bool (*)(void *, const char *, const SessionControl::SessionParameters &, const Nsk::NVbTracingContext_t &);
using GridAppSetDecoderInfo = void (*)(void *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, bool);
using GridAppSendInput = void (*)(void *, const void *);
using GridAppHandleGamepadChanged = bool (*)(void *, uint8_t, int, int, bool);
using GridAppControlFeatures = bool (*)(void *, uint32_t, uint32_t);
using GridAppTogglePerfIndicator = void (*)(void *);
using GridAppCursorInfoUpdate = void (*)(void *, const void *);
using GridAppSetStreamingMaxBitrate = bool (*)(void *, uint16_t, uint32_t);
using GridAppSetDynamicStreamingMode = bool (*)(void *, uint16_t, uint32_t);
using GridAppSetL4sState = bool (*)(void *, uint16_t, bool);
using IOInterfaceGetStatsInterface = void *(*)(void *);
using IOInterfaceGetMaxBitrateKbps = uint32_t (*)(void *);
using IOInterfaceGetDynamicStreamingMode = uint32_t (*)(void *);
using IOInterfaceGetL4sState = uint32_t (*)(void *);
using StatsInterfaceGetStats = void (*)(void *, GeronimoStats &, std::string &, std::string &, std::string &, std::string &, std::string &, std::string &);
using GetStreamStartParameters = int (*)(const std::string &, const std::string &, const Nsk::ApplicationStreamStartParameters &, Nsk::StreamStartParameters &);
using ConvertToStreamingParams = bool (*)(const Nsk::StreamStartParameters &, const Nsk::VideoDecoderInitParams &, Nsk::NVbStreamingParams_t &);
using FreeStreamingParams = void (*)(Nsk::NVbStreamingParams_t &);
using NVbEnumToString = const char *(*)(int32_t, int32_t);
using OpenNOWGeronimoEventHandler = void (*)(void *, int32_t, uint32_t, uint32_t, uint32_t, int32_t, const char *, uint32_t, uint32_t, const char *);
using OpenNOWGeronimoHapticHandler = void (*)(void *, uint16_t, uint16_t, uint16_t, uint16_t);
using OpenNOWGeronimoAuthRefreshHandler = void (*)(void *, uint32_t, char *, size_t);
using NVbCallback = bool (*)(void *, uint32_t, void *);
using ObjectCtor = void (*)(void *);
using ObjectDtor = void (*)(void *);
using SDLGraphicsContextInitialize = uint32_t (*)(void *, const SDLGraphicsContextInitParameters &);
using SDLEventProcessorInitialize = bool (*)(void *, void *, const SDLEventProcessorInitParams &);
using SDLEventProcessorProcessEvents = bool (*)(void *, int);
using SDLWindowInitialize = bool (*)(void *, void *, const SDLWindowInitParams &);
using SDLWindowAsyncRenderer = const std::shared_ptr<AsyncVideoFrameRenderer> &(*)(const void *);
using SDLWindowConvertPointToVideoFrame = void (*)(const void *, SDLPoint, SDLPoint *, SDLRect *);
using PlatformCreateVideoDecoder = void *(*)(PlatformDecoderCreationSettings &, uint32_t);
using PlatformCreateAudioObject = void *(*)();
using VideoDecoderInitialize = int32_t (*)(void *, void *, const PlatformDecoderSettings &, const std::shared_ptr<AsyncVideoFrameRenderer> &);

struct NVbResult_t {
    int32_t code = 0;
    unsigned char bytes[0x10] = {};
};

using NVbCreateClient = void *(*)();
using NVbRegisterCallback = NVbResult_t (*)(void *, void *, NVbCallback);

struct NvstAudioFrame_t {
    alignas(8) unsigned char bytes[0x58];
};

using NVbSendMicAudioFrame = NVbResult_t (*)(void *, const char *, NvstAudioFrame_t);

constexpr size_t NvstInputEventSize = 0x48;
#if defined(__arm64__)
constexpr uintptr_t GetStreamStartParametersJSONStringOffset = 0x767b4;
constexpr uintptr_t ConvertToStreamingParamsOffset = 0x8a060;
constexpr uintptr_t FreeStreamingParamsOffset = 0x89a88;
#elif defined(__x86_64__)
constexpr uintptr_t GetStreamStartParametersJSONStringOffset = 0x86d60;
constexpr uintptr_t ConvertToStreamingParamsOffset = 0x9d740;
constexpr uintptr_t FreeStreamingParamsOffset = 0x9d3a0;
#else
#error Unsupported Geronimo host architecture
#endif
constexpr uint32_t NVbCallbackTypeEvent = 2;
constexpr uint32_t NVbClientEventSessionNotification = 0x0e;
constexpr uint32_t NVbClientEventHaptic = 0x14;
constexpr uint32_t NVbSessionNotificationStreamerConnected = 1;
constexpr uint32_t NVbFeatureGamepadHaptics = 6;
constexpr size_t NVbAuthRefreshResponseCapacity = 16 * 1024;
constexpr uint16_t DefaultHapticDurationMilliseconds = 1000;
constexpr bool GeronimoPrepareSynchronous = false;
constexpr uint32_t GraphicsContextMetal = 3;
constexpr uint32_t DefaultNVbCodecH264 = 1;
constexpr uint32_t MaximumStreamSettingsCount = 64;
constexpr uint32_t MaximumConnectionInfoCount = 64;
constexpr uint32_t MaximumMetadataCount = 64;
constexpr uint16_t MinimumNVbPacketSize = 512;
constexpr size_t NVbStreamSettingsPacketSizeOffset = 0x48;
constexpr uint8_t SDLWindowHighDPIEnabled = 1;
constexpr size_t MicrophoneRouteCapacity = 8;
constexpr size_t MicrophonePCMByteCount = 1920;
constexpr size_t MicrophoneSampleCount = MicrophonePCMByteCount / sizeof(int16_t);
constexpr uint32_t MicrophoneSampleRate = 48000;
constexpr uint32_t MicrophoneBitsPerSample = 16;
constexpr uint32_t MicrophoneChannelCount = 2;
constexpr uint32_t MicrophoneFormat = 4;
constexpr uint32_t VoiceAttackFrames = 2;
constexpr uint32_t VoiceHangoverFrames = 20;

static_assert(!GeronimoPrepareSynchronous, "Geronimo prepare must deliver its result through the event pump");

struct NVbAuthInfo_t {
    const char *token = nullptr;
    uintptr_t authType = 0;
};

static_assert(sizeof(NVbResult_t) == 0x14, "libBifrost2 NVbResult_t ABI changed");
static_assert(sizeof(NVbAuthInfo_t) == 0x10, "libGeronimo NVbAuthInfo_t ABI changed");
static_assert(sizeof(NvstAudioFrame_t) == 0x58, "libGeronimo NvstAudioFrame_t ABI changed");

enum class NativeSessionState {
    created,
    configured,
    preparePending,
    prepared,
    starting,
    setupPending,
    streaming,
    pausePending,
    paused,
    stopping,
    stopped,
    failed,
};

struct GeronimoFunctions {
    GridAppDtor gridAppDtor = nullptr;
    GridAppProcessEvents gridAppProcessEvents = nullptr;
    GridAppStop stop = nullptr;
    GridAppPause pause = nullptr;
    GridAppResume resume = nullptr;
    GridAppSendInput sendInput = nullptr;
    GridAppHandleGamepadChanged handleGamepadChanged = nullptr;
    GridAppControlFeatures controlFeatures = nullptr;
    GridAppSetDecoderInfo setDecoderInfo = nullptr;
    GridAppTogglePerfIndicator togglePerfIndicator = nullptr;
    GridAppCursorInfoUpdate cursorInfoUpdate = nullptr;
    GridAppSetStreamingMaxBitrate setStreamingMaxBitrate = nullptr;
    GridAppSetDynamicStreamingMode setDynamicStreamingMode = nullptr;
    GridAppSetL4sState setL4sState = nullptr;
    IOInterfaceGetStatsInterface ioInterfaceGetStatsInterface = nullptr;
    IOInterfaceGetMaxBitrateKbps ioInterfaceGetMaxBitrateKbps = nullptr;
    IOInterfaceGetDynamicStreamingMode ioInterfaceGetDynamicStreamingMode = nullptr;
    IOInterfaceGetL4sState ioInterfaceGetL4sState = nullptr;
    StatsInterfaceGetStats statsInterfaceGetStats = nullptr;
    ObjectCtor graphicsContextCtor = nullptr;
    ObjectDtor graphicsContextDtor = nullptr;
    SDLGraphicsContextInitialize graphicsContextInitialize = nullptr;
    ObjectCtor eventProcessorCtor = nullptr;
    ObjectDtor eventProcessorDtor = nullptr;
    SDLEventProcessorInitialize eventProcessorInitialize = nullptr;
    SDLEventProcessorProcessEvents eventProcessorProcessEvents = nullptr;
    ObjectCtor windowCtor = nullptr;
    ObjectDtor windowDtor = nullptr;
    SDLWindowInitialize windowInitialize = nullptr;
    SDLWindowAsyncRenderer windowAsyncRenderer = nullptr;
    SDLWindowConvertPointToVideoFrame windowConvertPointToVideoFrame = nullptr;
    PlatformCreateVideoDecoder createVideoDecoder = nullptr;
    PlatformCreateAudioObject createAudioRenderer = nullptr;
    PlatformCreateAudioObject createAudioCapturer = nullptr;
    VideoDecoderInitialize vtDecoderInitialize = nullptr;
};

struct PendingStart {
    GridAppSetAuthInfo setAuthInfo = nullptr;
    GridAppStart start = nullptr;
    GridAppResume resume = nullptr;
    uintptr_t authType = 0;
    bool shouldResume = false;
    std::string resumeSessionId;
    SessionControl::SessionParameters parameters;
    std::vector<Nsk::NVbStreamSettings_t> streamSettings;
    std::vector<std::pair<std::string, std::string>> metadataStrings;
    std::vector<NVbKeyValuePair_t> metadataPointers;
    std::string traceParent;
};

struct StreamingParamsGuard {
    Nsk::NVbStreamingParams_t *parameters = nullptr;
    FreeStreamingParams release = nullptr;

    ~StreamingParamsGuard() {
        if (parameters != nullptr && release != nullptr) { release(*parameters); }
    }
};

struct AdaptiveVoiceActivityState {
    double noiseFloor = 0.008;
    uint32_t attackFrames = 0;
    uint32_t hangoverFrames = 0;
    bool speaking = false;
};

struct MicrophoneRouteSlot {
    std::atomic<void *> client{nullptr};
    std::atomic<uint32_t> inFlight{0};
    std::atomic<float> volume{1.0f};
    std::atomic<bool> vadEnabled{false};
    std::mutex stateMutex;
    std::condition_variable drained;
    AdaptiveVoiceActivityState vad;
};

std::array<MicrophoneRouteSlot, MicrophoneRouteCapacity> gMicrophoneRoutes;
std::mutex gMicrophoneRoutesMutex;
std::mutex gMicrophoneHookMutex;
void **gMicrophoneImportSlot = nullptr;
std::atomic<NVbSendMicAudioFrame> gOriginalSendMicAudioFrame{nullptr};
size_t gMicrophoneHookLeaseCount = 0;
std::mutex gGridAppInitializationMutex;
std::mutex gBifrostRegistrationHookMutex;
void **gBifrostCreateClientImportSlot = nullptr;
void **gBifrostRegistrationImportSlot = nullptr;
std::atomic<NVbCreateClient> gOriginalCreateBifrostClient{nullptr};
std::atomic<NVbRegisterCallback> gOriginalRegisterBifrostCallback{nullptr};
std::atomic<NVbCallback> gOriginalBifrostCallback{nullptr};
std::atomic<void *> gBifrostRegistrationContext{nullptr};
std::atomic<void *> gPreRegisteredBifrostClient{nullptr};
std::atomic<uint32_t> gBifrostClientCreationCount{0};
std::atomic<bool> gBifrostRegistrationIntercepted{false};

NVbResult_t openNOWSendMicAudioFrame(void *client, const char *sessionIdentifier, NvstAudioFrame_t frame);
void *openNOWCreateBifrostClient();
NVbResult_t openNOWRegisterBifrostCallback(void *client, void *context, NVbCallback callback);
bool openNOWBifrostCallback(void *gridApp, uint32_t callbackType, void *callbackData);

struct OpenNOWNativeNVSTGeronimoSession {
    void *libraryHandle = nullptr;
    void *bifrostHandle = nullptr;
    void *gridApp = nullptr;
    void **gridAppVTable = nullptr;
    void *ioInterface = nullptr;
    PlatformShutdown platformShutdown = nullptr;
    NVbEnumToString enumToString = nullptr;
    GeronimoFunctions functions;
    std::mutex eventMutex;
    OpenNOWGeronimoEventHandler eventHandler = nullptr;
    void *eventContext = nullptr;
    std::mutex runtimeHandlerMutex;
    OpenNOWGeronimoHapticHandler hapticHandler = nullptr;
    void *hapticContext = nullptr;
    OpenNOWGeronimoAuthRefreshHandler authRefreshHandler = nullptr;
    void *authRefreshContext = nullptr;
    std::atomic<uint32_t> callbacksInFlight{0};
    std::atomic<bool> acceptsCallbacks{true};
    std::mutex callbackMutex;
    std::condition_variable callbacksDrained;
    std::recursive_mutex operationMutex;
    std::mutex stateMutex;
    std::mutex mediaMutex;
    NativeSessionState state = NativeSessionState::created;
    std::unique_ptr<PendingStart> pendingStart;
    bool startEventDelivered = false;
    bool setupSucceeded = false;
    bool streamingBegan = false;
    bool connectedEventDelivered = false;
    bool stopIssued = false;
    bool microphoneAvailable = false;
    bool microphoneSetupSucceeded = false;
    bool microphoneEnabled = false;
    float microphoneVolume = 1.0f;
    bool voiceActivityEnabled = false;
    MicrophoneRouteSlot *microphoneRoute = nullptr;
    bool microphoneHookLeaseAcquired = false;
    bool registeredGamepads[4] = {};
    bool hapticFeatureEnabled = false;
    NVbCallback originalBifrostCallback = nullptr;
    std::string lastError;
    bool platformStarted = false;
    bool initialized = false;
    void *graphicsContext = nullptr;
    void *eventProcessor = nullptr;
    void *window = nullptr;
    void *videoDecoder = nullptr;
    void *audioRenderer = nullptr;
    void *audioCapturer = nullptr;
    uint32_t requestedCodec = DefaultNVbCodecH264;
    uint32_t activeCodec = 0;
    bool videoDecoderStarted = false;
    std::string initServerAddress;
    std::string startServerAddress;
    std::string sessionId;
    std::string appIdString;
    std::string authToken;
    std::string clientAppVersion;
    std::string clientLocale;
    std::string keyboardLayout;
    std::string deviceId;
    std::string platform;
    CFTypeRef videoSurfaceHandle = nullptr;
};

std::mutex gGridAppSessionsMutex;
std::unordered_map<void *, OpenNOWNativeNVSTGeronimoSession *> gGridAppSessions;
std::mutex gPlatformMutex;
size_t gPlatformReferenceCount = 0;

void setSessionFailure(OpenNOWNativeNVSTGeronimoSession *session, const char *message);
bool setSessionFailureUnlessStopping(OpenNOWNativeNVSTGeronimoSession *session, const char *message);
bool ensureVideoDecoderLocked(OpenNOWNativeNVSTGeronimoSession *session, uint32_t codec);

void setError(char *buffer, size_t length, const char *message) {
    if (buffer == nullptr || length == 0) { return; }
    if (message == nullptr) { message = "Native Geronimo NVST failed."; }
    snprintf(buffer, length, "%s", message);
}

void setDLError(char *buffer, size_t length, const char *prefix) {
    const char *error = dlerror();
    if (error == nullptr) { error = "unknown dynamic loader error"; }
    if (buffer != nullptr && length > 0) {
        snprintf(buffer, length, "%s: %s", prefix, error);
    }
}

std::string stringOrEmpty(const char *value) {
    return value == nullptr ? std::string() : std::string(value);
}

template <typename T>
T loadField(const Nsk::NVbStreamingParams_t &params, size_t offset) {
    T value{};
    memcpy(&value, params.bytes + offset, sizeof(T));
    return value;
}

template <typename T>
T loadUnaligned(const void *base, size_t offset) {
    T value{};
    if (base != nullptr) { memcpy(&value, static_cast<const uint8_t *>(base) + offset, sizeof(T)); }
    return value;
}

template <typename T>
void storeUnaligned(void *base, size_t offset, T value) {
    if (base != nullptr) { memcpy(static_cast<uint8_t *>(base) + offset, &value, sizeof(T)); }
}

void resetVoiceActivity(AdaptiveVoiceActivityState &state) {
    state = AdaptiveVoiceActivityState{};
}

bool processVoiceActivity(AdaptiveVoiceActivityState &state, double rms) {
    const double attackThreshold = std::max(0.015, state.noiseFloor * 3.0);
    const double releaseThreshold = std::max(0.010, state.noiseFloor * 1.8);
    if (!state.speaking) {
        if (rms >= attackThreshold) {
            ++state.attackFrames;
            if (state.attackFrames >= VoiceAttackFrames) {
                state.speaking = true;
                state.hangoverFrames = VoiceHangoverFrames;
            }
        } else {
            state.attackFrames = 0;
            state.noiseFloor = std::clamp(state.noiseFloor * 0.95 + rms * 0.05, 0.0005, 0.08);
        }
    } else if (rms >= releaseThreshold) {
        state.hangoverFrames = VoiceHangoverFrames;
    } else if (state.hangoverFrames > 0) {
        --state.hangoverFrames;
    } else {
        state.speaking = false;
        state.attackFrames = 0;
        state.noiseFloor = std::clamp(state.noiseFloor * 0.95 + rms * 0.05, 0.0005, 0.08);
    }
    return state.speaking;
}

bool processMicrophonePCM(const int16_t *input,
                          int16_t *output,
                          size_t sampleCount,
                          float volume,
                          bool vadEnabled,
                          AdaptiveVoiceActivityState &vad) {
    if (input == nullptr || output == nullptr || sampleCount == 0 || sampleCount > MicrophoneSampleCount) { return false; }
    long double sumSquares = 0;
    for (size_t index = 0; index < sampleCount; ++index) {
        const long double normalized = static_cast<long double>(input[index]) / 32768.0L;
        sumSquares += normalized * normalized;
    }
    const double rms = std::sqrt(static_cast<double>(sumSquares / sampleCount));
    const bool forwardAudio = !vadEnabled || processVoiceActivity(vad, rms);
    const double boundedVolume = std::clamp(static_cast<double>(volume), 0.0, 1.0);
    for (size_t index = 0; index < sampleCount; ++index) {
        if (!forwardAudio || boundedVolume == 0) {
            output[index] = 0;
            continue;
        }
        const double scaled = std::round(static_cast<double>(input[index]) * boundedVolume);
        output[index] = static_cast<int16_t>(std::clamp(scaled, -32768.0, 32767.0));
    }
    return true;
}

bool isSupportedMicrophoneFrame(const NvstAudioFrame_t &frame) {
    return loadUnaligned<uint32_t>(frame.bytes, 0x08) == MicrophoneBitsPerSample &&
           loadUnaligned<uint32_t>(frame.bytes, 0x0c) == MicrophoneSampleRate &&
           loadUnaligned<uint32_t>(frame.bytes, 0x10) == MicrophoneChannelCount &&
           loadUnaligned<uint32_t>(frame.bytes, 0x14) == MicrophoneFormat &&
           loadUnaligned<const void *>(frame.bytes, 0x28) != nullptr &&
           loadUnaligned<uint32_t>(frame.bytes, 0x30) == MicrophonePCMByteCount;
}

MicrophoneRouteSlot *acquireMicrophoneRoute(void *client) {
    if (client == nullptr) { return nullptr; }
    for (MicrophoneRouteSlot &slot : gMicrophoneRoutes) {
        if (slot.client.load(std::memory_order_acquire) != client) { continue; }
        slot.inFlight.fetch_add(1, std::memory_order_acq_rel);
        if (slot.client.load(std::memory_order_acquire) == client) { return &slot; }
        if (slot.inFlight.fetch_sub(1, std::memory_order_acq_rel) == 1) { slot.drained.notify_all(); }
    }
    return nullptr;
}

void releaseMicrophoneRoute(MicrophoneRouteSlot *slot) {
    if (slot != nullptr && slot->inFlight.fetch_sub(1, std::memory_order_acq_rel) == 1) { slot->drained.notify_all(); }
}

MicrophoneRouteSlot *registerMicrophoneRoute(void *client) {
    if (client == nullptr) { return nullptr; }
    std::lock_guard<std::mutex> routesLock(gMicrophoneRoutesMutex);
    for (MicrophoneRouteSlot &slot : gMicrophoneRoutes) {
        if (slot.client.load(std::memory_order_acquire) != nullptr || slot.inFlight.load(std::memory_order_acquire) != 0) { continue; }
        {
            std::lock_guard<std::mutex> stateLock(slot.stateMutex);
            resetVoiceActivity(slot.vad);
        }
        slot.volume.store(1.0f, std::memory_order_release);
        slot.vadEnabled.store(false, std::memory_order_release);
        slot.client.store(client, std::memory_order_release);
        return &slot;
    }
    return nullptr;
}

void unregisterMicrophoneRoute(MicrophoneRouteSlot *slot) {
    if (slot == nullptr) { return; }
    std::unique_lock<std::mutex> routesLock(gMicrophoneRoutesMutex);
    slot->client.store(nullptr, std::memory_order_release);
    slot->drained.wait(routesLock, [slot] { return slot->inFlight.load(std::memory_order_acquire) == 0; });
    {
        std::lock_guard<std::mutex> stateLock(slot->stateMutex);
        resetVoiceActivity(slot->vad);
    }
    slot->volume.store(1.0f, std::memory_order_release);
    slot->vadEnabled.store(false, std::memory_order_release);
}

bool boundedRange(uint64_t offset, uint64_t size, uint64_t limit) {
    return offset <= limit && size <= limit - offset;
}

void **findLazySymbolPointer(void *imageSymbol, const char *symbolName) {
    Dl_info imageInfo{};
    if (imageSymbol == nullptr || symbolName == nullptr || dladdr(imageSymbol, &imageInfo) == 0 || imageInfo.dli_fbase == nullptr) { return nullptr; }
    const auto *header = static_cast<const mach_header_64 *>(imageInfo.dli_fbase);
    if (header->magic != MH_MAGIC_64 || header->ncmds == 0 || header->ncmds > 4096 || header->sizeofcmds > 16 * 1024 * 1024) { return nullptr; }
    const uint8_t *commands = reinterpret_cast<const uint8_t *>(header) + sizeof(*header);
    const uint64_t commandsSize = header->sizeofcmds;
    const segment_command_64 *textSegment = nullptr;
    const segment_command_64 *linkeditSegment = nullptr;
    const symtab_command *symtab = nullptr;
    const dysymtab_command *dysymtab = nullptr;
    std::vector<const section_64 *> lazySections;
    uint64_t commandOffset = 0;
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        if (!boundedRange(commandOffset, sizeof(load_command), commandsSize)) { return nullptr; }
        const auto *command = reinterpret_cast<const load_command *>(commands + commandOffset);
        if (command->cmdsize < sizeof(load_command) || !boundedRange(commandOffset, command->cmdsize, commandsSize)) { return nullptr; }
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(segment_command_64)) { return nullptr; }
            const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
            if (segment->nsects > 4096 || sizeof(segment_command_64) + static_cast<uint64_t>(segment->nsects) * sizeof(section_64) > command->cmdsize) { return nullptr; }
            if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) { textSegment = segment; }
            if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)) == 0) { linkeditSegment = segment; }
            const auto *sections = reinterpret_cast<const section_64 *>(segment + 1);
            for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects; ++sectionIndex) {
                const section_64 &section = sections[sectionIndex];
                if (segment->vmaddr > UINT64_MAX - segment->vmsize || section.addr < segment->vmaddr ||
                    !boundedRange(section.addr, section.size, segment->vmaddr + segment->vmsize)) { return nullptr; }
                if ((section.flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) { lazySections.push_back(&section); }
            }
        } else if (command->cmd == LC_SYMTAB && command->cmdsize >= sizeof(symtab_command)) {
            symtab = reinterpret_cast<const symtab_command *>(command);
        } else if (command->cmd == LC_DYSYMTAB && command->cmdsize >= sizeof(dysymtab_command)) {
            dysymtab = reinterpret_cast<const dysymtab_command *>(command);
        }
        commandOffset += command->cmdsize;
    }
    if (textSegment == nullptr || linkeditSegment == nullptr || symtab == nullptr || dysymtab == nullptr || lazySections.empty()) { return nullptr; }
    const uintptr_t headerAddress = reinterpret_cast<uintptr_t>(header);
    if (headerAddress < textSegment->vmaddr || linkeditSegment->vmaddr < linkeditSegment->fileoff ||
        linkeditSegment->fileoff > UINT64_MAX - linkeditSegment->filesize) { return nullptr; }
    const uintptr_t slide = headerAddress - textSegment->vmaddr;
    const uint64_t linkeditDelta = linkeditSegment->vmaddr - linkeditSegment->fileoff;
    if (slide > UINTPTR_MAX - linkeditDelta) { return nullptr; }
    const uintptr_t linkeditBase = slide + linkeditDelta;
    const uint64_t linkeditEnd = linkeditSegment->fileoff + linkeditSegment->filesize;
    if (symtab->symoff < linkeditSegment->fileoff || symtab->stroff < linkeditSegment->fileoff || dysymtab->indirectsymoff < linkeditSegment->fileoff ||
        !boundedRange(symtab->symoff, static_cast<uint64_t>(symtab->nsyms) * sizeof(nlist_64), linkeditEnd) ||
        !boundedRange(symtab->stroff, symtab->strsize, linkeditEnd) ||
        !boundedRange(dysymtab->indirectsymoff, static_cast<uint64_t>(dysymtab->nindirectsyms) * sizeof(uint32_t), linkeditEnd)) { return nullptr; }
    const auto *symbols = reinterpret_cast<const nlist_64 *>(linkeditBase + symtab->symoff);
    const char *strings = reinterpret_cast<const char *>(linkeditBase + symtab->stroff);
    const auto *indirectSymbols = reinterpret_cast<const uint32_t *>(linkeditBase + dysymtab->indirectsymoff);
    for (const section_64 *section : lazySections) {
        if (section->size % sizeof(void *) != 0) { continue; }
        const uint64_t pointerCount = section->size / sizeof(void *);
        if (!boundedRange(section->reserved1, pointerCount, dysymtab->nindirectsyms)) { continue; }
        if (slide > UINTPTR_MAX - section->addr) { continue; }
        auto **pointers = reinterpret_cast<void **>(slide + section->addr);
        for (uint64_t pointerIndex = 0; pointerIndex < pointerCount; ++pointerIndex) {
            const uint32_t symbolIndex = indirectSymbols[section->reserved1 + pointerIndex];
            if ((symbolIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) != 0 || symbolIndex >= symtab->nsyms) { continue; }
            const uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
            if (stringIndex >= symtab->strsize) { continue; }
            const char *candidate = strings + stringIndex;
            const size_t remaining = symtab->strsize - stringIndex;
            if (memchr(candidate, '\0', remaining) != nullptr && strcmp(candidate, symbolName) == 0) { return &pointers[pointerIndex]; }
        }
    }
    return nullptr;
}

bool acquireBifrostRegistrationHook(void *geronimoHandle,
                                    void *gridApp,
                                    NVbCallback originalCallback,
                                    char *errorBuffer,
                                    size_t errorBufferLength) {
    std::lock_guard<std::mutex> hookLock(gBifrostRegistrationHookMutex);
    void *anchor = dlsym(geronimoHandle, "_ZN7GridApp10initializeEb");
    if (anchor == nullptr || gridApp == nullptr || originalCallback == nullptr) {
        setError(errorBuffer, errorBufferLength, "Geronimo Bifrost callback registration symbols are unavailable.");
        return false;
    }
    void **createSlot = findLazySymbolPointer(anchor, "_nvbCreateClient");
    void **registerSlot = findLazySymbolPointer(anchor, "_nvbRegisterCallback");
    if (createSlot == nullptr || registerSlot == nullptr || reinterpret_cast<uintptr_t>(createSlot) % alignof(void *) != 0 ||
        reinterpret_cast<uintptr_t>(registerSlot) % alignof(void *) != 0) {
        setError(errorBuffer, errorBufferLength, "Geronimo Bifrost callback registration imports could not be verified.");
        return false;
    }
    void *currentCreate = __atomic_load_n(createSlot, __ATOMIC_ACQUIRE);
    void *currentRegistration = __atomic_load_n(registerSlot, __ATOMIC_ACQUIRE);
    void *createHook = reinterpret_cast<void *>(&openNOWCreateBifrostClient);
    void *registrationHook = reinterpret_cast<void *>(&openNOWRegisterBifrostCallback);
    if (currentCreate == nullptr || currentRegistration == nullptr || currentCreate == createHook || currentRegistration == registrationHook) {
        setError(errorBuffer, errorBufferLength, "Geronimo Bifrost callback registration imports are unresolved or already intercepted.");
        return false;
    }
    gOriginalCreateBifrostClient.store(reinterpret_cast<NVbCreateClient>(currentCreate), std::memory_order_release);
    gOriginalRegisterBifrostCallback.store(reinterpret_cast<NVbRegisterCallback>(currentRegistration), std::memory_order_release);
    gOriginalBifrostCallback.store(originalCallback, std::memory_order_release);
    gBifrostRegistrationContext.store(gridApp, std::memory_order_release);
    gPreRegisteredBifrostClient.store(nullptr, std::memory_order_release);
    gBifrostClientCreationCount.store(0, std::memory_order_release);
    gBifrostRegistrationIntercepted.store(false, std::memory_order_release);
    if (!__atomic_compare_exchange_n(createSlot, &currentCreate, createHook, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        gOriginalCreateBifrostClient.store(nullptr, std::memory_order_release);
        gOriginalRegisterBifrostCallback.store(nullptr, std::memory_order_release);
        setError(errorBuffer, errorBufferLength, "Geronimo Bifrost callback registration hook could not be installed.");
        return false;
    }
    gBifrostCreateClientImportSlot = createSlot;
    gBifrostRegistrationImportSlot = registerSlot;
    return true;
}

void releaseBifrostRegistrationHook() {
    std::lock_guard<std::mutex> hookLock(gBifrostRegistrationHookMutex);
    void *registrationHook = reinterpret_cast<void *>(&openNOWRegisterBifrostCallback);
    void *expectedRegistration = registrationHook;
    NVbRegisterCallback originalRegistration = gOriginalRegisterBifrostCallback.load(std::memory_order_acquire);
    if (gBifrostRegistrationImportSlot != nullptr && originalRegistration != nullptr) {
        __atomic_compare_exchange_n(gBifrostRegistrationImportSlot, &expectedRegistration, reinterpret_cast<void *>(originalRegistration), false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    }
    void *createHook = reinterpret_cast<void *>(&openNOWCreateBifrostClient);
    void *expectedCreate = createHook;
    NVbCreateClient originalCreate = gOriginalCreateBifrostClient.load(std::memory_order_acquire);
    if (gBifrostCreateClientImportSlot != nullptr && originalCreate != nullptr) {
        __atomic_compare_exchange_n(gBifrostCreateClientImportSlot, &expectedCreate, reinterpret_cast<void *>(originalCreate), false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    }
    gBifrostCreateClientImportSlot = nullptr;
    gBifrostRegistrationImportSlot = nullptr;
    gOriginalCreateBifrostClient.store(nullptr, std::memory_order_release);
    gOriginalRegisterBifrostCallback.store(nullptr, std::memory_order_release);
    gBifrostRegistrationContext.store(nullptr, std::memory_order_release);
    gPreRegisteredBifrostClient.store(nullptr, std::memory_order_release);
}

void *openNOWCreateBifrostClient() {
    NVbCreateClient originalCreate = gOriginalCreateBifrostClient.load(std::memory_order_acquire);
    if (originalCreate == nullptr) { return nullptr; }
    void *client = originalCreate();
    if (client == nullptr || gBifrostClientCreationCount.fetch_add(1, std::memory_order_acq_rel) + 1 != 2) { return client; }
    NVbRegisterCallback originalRegistration = gOriginalRegisterBifrostCallback.load(std::memory_order_acquire);
    NVbCallback originalCallback = gOriginalBifrostCallback.load(std::memory_order_acquire);
    void *context = gBifrostRegistrationContext.load(std::memory_order_acquire);
    if (originalRegistration == nullptr || originalCallback == nullptr || context == nullptr || gBifrostRegistrationImportSlot == nullptr) { return client; }
    void *currentRegistration = __atomic_load_n(gBifrostRegistrationImportSlot, __ATOMIC_ACQUIRE);
    void *registrationHook = reinterpret_cast<void *>(&openNOWRegisterBifrostCallback);
    if (currentRegistration != registrationHook &&
        !__atomic_compare_exchange_n(gBifrostRegistrationImportSlot, &currentRegistration, registrationHook, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return client;
    }
    NVbResult_t result = originalRegistration(client, context, &openNOWBifrostCallback);
    if (result.code != 0) {
        void *expectedRegistration = registrationHook;
        __atomic_compare_exchange_n(gBifrostRegistrationImportSlot, &expectedRegistration, reinterpret_cast<void *>(originalRegistration), false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
        return client;
    }
    gPreRegisteredBifrostClient.store(client, std::memory_order_release);
    return client;
}

NVbResult_t openNOWRegisterBifrostCallback(void *client, void *context, NVbCallback callback) {
    NVbRegisterCallback originalRegistration = gOriginalRegisterBifrostCallback.load(std::memory_order_acquire);
    NVbCallback originalCallback = gOriginalBifrostCallback.load(std::memory_order_acquire);
    if (originalRegistration == nullptr) { return NVbResult_t{-1}; }
    if (client != gPreRegisteredBifrostClient.load(std::memory_order_acquire) ||
        context != gBifrostRegistrationContext.load(std::memory_order_acquire) || callback != originalCallback) {
        return originalRegistration(client, context, callback);
    }
    gBifrostRegistrationIntercepted.store(true, std::memory_order_release);
    return NVbResult_t{};
}

bool acquireMicrophoneHook(void *geronimoHandle, void *bifrostHandle, char *errorBuffer, size_t errorBufferLength) {
    std::lock_guard<std::mutex> hookLock(gMicrophoneHookMutex);
    void *resolved = dlsym(bifrostHandle, "nvbSendMicAudioFrame");
    void *anchor = dlsym(geronimoHandle, "_ZN18BifrostSDKExecutor17sendMicAudioFrameERK16NvstAudioFrame_t");
    if (resolved == nullptr || anchor == nullptr) {
        setError(errorBuffer, errorBufferLength, "Geronimo microphone hook symbols are unavailable.");
        return false;
    }
    void **slot = findLazySymbolPointer(anchor, "_nvbSendMicAudioFrame");
    if (slot == nullptr || reinterpret_cast<uintptr_t>(slot) % alignof(void *) != 0) {
        setError(errorBuffer, errorBufferLength, "Geronimo microphone lazy import slot could not be verified.");
        return false;
    }
    void *hook = reinterpret_cast<void *>(&openNOWSendMicAudioFrame);
    void *current = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (gMicrophoneHookLeaseCount == 0) {
        if (current == nullptr) {
            setError(errorBuffer, errorBufferLength, "Geronimo microphone import slot is unresolved.");
            return false;
        }
        gMicrophoneImportSlot = slot;
        gOriginalSendMicAudioFrame.store(reinterpret_cast<NVbSendMicAudioFrame>(resolved), std::memory_order_release);
        if (current != hook && !__atomic_compare_exchange_n(slot, &current, hook, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            gMicrophoneImportSlot = nullptr;
            gOriginalSendMicAudioFrame.store(nullptr, std::memory_order_release);
            setError(errorBuffer, errorBufferLength, "Geronimo microphone import hook installation raced with another writer.");
            return false;
        }
    } else if (slot != gMicrophoneImportSlot || current != hook) {
        setError(errorBuffer, errorBufferLength, "Geronimo microphone import hook lease is inconsistent.");
        return false;
    }
    ++gMicrophoneHookLeaseCount;
    return true;
}

void releaseMicrophoneHook() {
    std::lock_guard<std::mutex> hookLock(gMicrophoneHookMutex);
    if (gMicrophoneHookLeaseCount == 0 || --gMicrophoneHookLeaseCount != 0) { return; }
    void *hook = reinterpret_cast<void *>(&openNOWSendMicAudioFrame);
    void *expected = hook;
    NVbSendMicAudioFrame original = gOriginalSendMicAudioFrame.load(std::memory_order_acquire);
    if (gMicrophoneImportSlot != nullptr && original != nullptr) {
        __atomic_compare_exchange_n(gMicrophoneImportSlot, &expected, reinterpret_cast<void *>(original), false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    }
    gMicrophoneImportSlot = nullptr;
    gOriginalSendMicAudioFrame.store(nullptr, std::memory_order_release);
}

NVbResult_t openNOWSendMicAudioFrame(void *client, const char *sessionIdentifier, NvstAudioFrame_t frame) {
    NVbSendMicAudioFrame original = gOriginalSendMicAudioFrame.load(std::memory_order_acquire);
    if (original == nullptr) { return NVbResult_t{-1}; }
    MicrophoneRouteSlot *route = acquireMicrophoneRoute(client);
    if (route == nullptr || !isSupportedMicrophoneFrame(frame)) {
        releaseMicrophoneRoute(route);
        return original(client, sessionIdentifier, frame);
    }
    thread_local NvstAudioFrame_t frameCopy{};
    thread_local std::array<int16_t, MicrophoneSampleCount> pcmCopy{};
    memcpy(&frameCopy, &frame, sizeof(frameCopy));
    const auto *source = static_cast<const int16_t *>(loadUnaligned<const void *>(frameCopy.bytes, 0x28));
    {
        std::lock_guard<std::mutex> stateLock(route->stateMutex);
        processMicrophonePCM(source,
                             pcmCopy.data(),
                             pcmCopy.size(),
                             route->volume.load(std::memory_order_acquire),
                             route->vadEnabled.load(std::memory_order_acquire),
                             route->vad);
    }
    storeUnaligned<const void *>(frameCopy.bytes, 0x28, pcmCopy.data());
    NVbResult_t result = original(client, sessionIdentifier, frameCopy);
    releaseMicrophoneRoute(route);
    return result;
}

const char *nvbResultName(OpenNOWNativeNVSTGeronimoSession *session, int32_t resultCode) {
    if (session == nullptr || session->enumToString == nullptr) { return nullptr; }
    const char *name = session->enumToString(0, resultCode);
    return name != nullptr && strncmp(name, "NVB_R_", 6) == 0 ? name : nullptr;
}

void emitEvent(OpenNOWNativeNVSTGeronimoSession *session,
               int32_t phase,
               uint32_t callbackType,
               uint32_t clientEvent,
               uint32_t notification,
               int32_t resultCode,
               const char *resultName = nullptr,
               uint32_t resumable = 0,
               uint32_t sessionAlive = 0,
               const char *reasonName = nullptr) {
    if (session == nullptr) { return; }
    OpenNOWGeronimoEventHandler handler = nullptr;
    void *context = nullptr;
    {
        std::lock_guard<std::mutex> lock(session->eventMutex);
        handler = session->eventHandler;
        context = session->eventContext;
    }
    if (handler != nullptr) { handler(context, phase, callbackType, clientEvent, notification, resultCode, resultName, resumable, sessionAlive, reasonName); }
}

OpenNOWNativeNVSTGeronimoSession *beginGridAppCallback(void *gridApp) {
    std::lock_guard<std::mutex> lock(gGridAppSessionsMutex);
    auto iterator = gGridAppSessions.find(gridApp);
    if (iterator == gGridAppSessions.end()) { return nullptr; }
    OpenNOWNativeNVSTGeronimoSession *session = iterator->second;
    if (!session->acceptsCallbacks.load(std::memory_order_acquire)) { return nullptr; }
    session->callbacksInFlight.fetch_add(1, std::memory_order_acq_rel);
    return session;
}

void endGridAppCallback(OpenNOWNativeNVSTGeronimoSession *session) {
    if (session == nullptr) { return; }
    if (session->callbacksInFlight.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        std::lock_guard<std::mutex> lock(session->callbackMutex);
        session->callbacksDrained.notify_all();
    }
}

struct GridAppCallbackLease {
    OpenNOWNativeNVSTGeronimoSession *session = nullptr;

    ~GridAppCallbackLease() {
        endGridAppCallback(session);
    }
};

void emitHapticRecords(OpenNOWNativeNVSTGeronimoSession *session, const void *callbackData) {
    if (session == nullptr || callbackData == nullptr || loadUnaligned<uint32_t>(callbackData, 0) != NVbClientEventHaptic) { return; }
    const uint32_t subtype = loadUnaligned<uint32_t>(callbackData, 0x10);
    if (subtype != 1 && subtype != 2) { return; }
    const uint16_t byteCount = std::min<uint16_t>(loadUnaligned<uint16_t>(callbackData, 0x14), 32);
    const size_t recordSize = subtype == 1 ? 6 : 8;
    const size_t recordCount = byteCount / recordSize;
    const auto *records = static_cast<const uint8_t *>(callbackData) + 0x16;
    for (size_t index = 0; index < recordCount; ++index) {
        const uint8_t *record = records + index * recordSize;
        const uint16_t player = loadUnaligned<uint16_t>(record, 0);
        const uint16_t lowFrequency = loadUnaligned<uint16_t>(record, 2);
        const uint16_t highFrequency = loadUnaligned<uint16_t>(record, 4);
        const uint16_t suppliedDuration = subtype == 2 ? loadUnaligned<uint16_t>(record, 6) : 0;
        const uint16_t duration = suppliedDuration == 0 ? DefaultHapticDurationMilliseconds : suppliedDuration;
        OpenNOWGeronimoHapticHandler handler = nullptr;
        void *context = nullptr;
        {
            std::lock_guard<std::mutex> lock(session->runtimeHandlerMutex);
            handler = session->hapticHandler;
            context = session->hapticContext;
        }
        if (handler != nullptr) { handler(context, player, lowFrequency, highFrequency, duration); }
    }
}

bool openNOWBifrostCallback(void *gridApp, uint32_t callbackType, void *callbackData) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    NVbCallback originalCallback = session == nullptr
        ? gOriginalBifrostCallback.load(std::memory_order_acquire)
        : session->originalBifrostCallback;
    if (originalCallback == nullptr) { return false; }
    if (session == nullptr) { return originalCallback(gridApp, callbackType, callbackData); }
    GridAppCallbackLease callbackLease{session};
    const bool handled = originalCallback(gridApp, callbackType, callbackData);
    if (callbackType == NVbCallbackTypeEvent) { emitHapticRecords(session, callbackData); }
    return handled;
}

void openNOWGridAppUpdateAuthToken(void *gridApp, void *updateAuthToken) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr || updateAuthToken == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    char *response = loadUnaligned<char *>(updateAuthToken, 0x08);
    if (response == nullptr) { return; }
    response[0] = '\0';
    OpenNOWGeronimoAuthRefreshHandler handler = nullptr;
    void *context = nullptr;
    {
        std::lock_guard<std::mutex> lock(session->runtimeHandlerMutex);
        handler = session->authRefreshHandler;
        context = session->authRefreshContext;
    }
    if (handler != nullptr) {
        handler(context, loadUnaligned<uint32_t>(updateAuthToken, 0), response, NVbAuthRefreshResponseCapacity);
        response[NVbAuthRefreshResponseCapacity - 1] = '\0';
    }
}

template <typename Function>
Function virtualFunction(void *object, size_t byteOffset) {
    if (object == nullptr || byteOffset % sizeof(void *) != 0) { return nullptr; }
    void **vtable = *static_cast<void ***>(object);
    if (vtable == nullptr) { return nullptr; }
    return reinterpret_cast<Function>(vtable[byteOffset / sizeof(void *)]);
}

void callVoidVirtual(void *object, size_t byteOffset) {
    using Function = void (*)(void *);
    Function function = virtualFunction<Function>(object, byteOffset);
    if (function != nullptr) { function(object); }
}

void emitConnectedIfReady(OpenNOWNativeNVSTGeronimoSession *session) {
    bool shouldEmit = false;
    {
        std::lock_guard<std::mutex> lock(session->stateMutex);
        if (session->startEventDelivered && session->setupSucceeded && session->streamingBegan && !session->connectedEventDelivered) {
            session->state = NativeSessionState::streaming;
            session->connectedEventDelivered = true;
            shouldEmit = true;
        }
    }
    if (shouldEmit) {
        emitEvent(session,
                  45,
                  NVbCallbackTypeEvent,
                  NVbClientEventSessionNotification,
                  NVbSessionNotificationStreamerConnected,
                  0);
    }
}

void openNOWGridAppPrepareResult(void *gridApp, const NVbResult_t *result, void *) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    try {
        int32_t resultCode = result == nullptr ? -1 : result->code;
        bool shouldEmitFailure = false;
        {
            std::lock_guard<std::mutex> lock(session->stateMutex);
            if (session->state == NativeSessionState::preparePending) {
                session->state = resultCode == 0 ? NativeSessionState::prepared : NativeSessionState::failed;
                if (resultCode != 0) {
                    session->lastError = "GridApp prepare callback reported failure.";
                    shouldEmitFailure = true;
                }
            }
        }
        if (shouldEmitFailure) { emitEvent(session, 30, 0, 0, 0, resultCode, nvbResultName(session, resultCode)); }
    } catch (...) {
        try {
            setSessionFailure(session, "GridApp prepare callback handling raised an unexpected C++ exception.");
            emitEvent(session, 70, 0, 0, 0, -12);
        } catch (...) {
            fprintf(stderr, "OpenNOW failed to contain a GridApp prepare callback exception.\n");
        }
    }
}

void openNOWGridAppStreamingBegin(void *gridApp, const void *streamInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    try {
        bool micSetupSucceeded = streamInfo != nullptr && loadUnaligned<uint8_t>(streamInfo, 0) != 0;
        bool acceptsStreamingBegin = false;
        {
            std::lock_guard<std::mutex> stateLock(session->stateMutex);
            if (session->state == NativeSessionState::starting || session->state == NativeSessionState::setupPending || session->state == NativeSessionState::streaming) {
                session->streamingBegan = true;
                acceptsStreamingBegin = true;
            }
        }
        if (!acceptsStreamingBegin) { return; }
        emitEvent(session, 44, 0, 0, 0, 0);
        {
            std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
            session->microphoneSetupSucceeded = session->microphoneAvailable && micSetupSucceeded && session->audioCapturer != nullptr;
            callVoidVirtual(session->audioRenderer, 0x48);
            callVoidVirtual(session->audioCapturer, session->microphoneEnabled && session->microphoneSetupSucceeded ? 0x48 : 0x40);
            if (!session->videoDecoderStarted) {
                callVoidVirtual(session->videoDecoder, 0x58);
                session->videoDecoderStarted = session->videoDecoder != nullptr;
            }
        }
        emitConnectedIfReady(session);
    } catch (...) {
        try {
            setSessionFailure(session, "GridApp streaming-begin callback handling raised an unexpected C++ exception.");
            emitEvent(session, 70, 0, 0, 0, -13);
        } catch (...) {
            fprintf(stderr, "OpenNOW failed to contain a GridApp streaming-begin callback exception.\n");
        }
    }
}

void openNOWGridAppSetupFailure(void *gridApp, const void *failureInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    int32_t resultCode = failureInfo == nullptr ? -1 : loadUnaligned<int32_t>(failureInfo, 0);
    const char *resultName = failureInfo == nullptr ? nullptr : nvbResultName(session, resultCode);
    std::string message = "GridApp session setup failed.";
    if (resultName != nullptr) { message = "GridApp session setup failed with " + std::string(resultName) + "."; }
    if (setSessionFailureUnlessStopping(session, message.c_str())) {
        emitEvent(session, 70, 0, 0, 0, resultCode, resultName);
    }
}

void openNOWGridAppResumeFailure(void *gridApp, const void *failureInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    int32_t resultCode = failureInfo == nullptr ? -1 : loadUnaligned<int32_t>(failureInfo, 0);
    const char *resultName = failureInfo == nullptr ? nullptr : nvbResultName(session, resultCode);
    std::string message = "GridApp resume failed.";
    if (resultName != nullptr) { message = "GridApp resume failed with " + std::string(resultName) + "."; }
    if (setSessionFailureUnlessStopping(session, message.c_str())) {
        emitEvent(session, 70, 0, 0, 0, resultCode, resultName);
    }
}

void openNOWGridAppSetupSuccess(void *gridApp, const void *sessionInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    uint32_t codec = session->requestedCodec;
    bool streamingBegan = false;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::starting && session->state != NativeSessionState::setupPending && session->state != NativeSessionState::streaming) { return; }
        streamingBegan = session->streamingBegan;
    }
    if (sessionInfo != nullptr) {
        auto *begin = loadUnaligned<Nsk::NVbStreamSettings_t *>(sessionInfo, 0x38);
        auto *end = loadUnaligned<Nsk::NVbStreamSettings_t *>(sessionInfo, 0x40);
        if (begin != nullptr && end != nullptr && end > begin) { codec = loadUnaligned<uint32_t>(begin, 0x2c); }
    }
    bool decoderReady = false;
    {
        std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
        decoderReady = ensureVideoDecoderLocked(session, codec);
        if (decoderReady && streamingBegan && !session->videoDecoderStarted) {
            callVoidVirtual(session->videoDecoder, 0x58);
            session->videoDecoderStarted = true;
        }
    }
    if (!decoderReady) {
        setSessionFailure(session, "Geronimo could not initialize the negotiated video decoder.");
        emitEvent(session, 70, 0, 0, 0, -14);
        return;
    }
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state == NativeSessionState::starting || session->state == NativeSessionState::setupPending || session->state == NativeSessionState::streaming) {
            session->setupSucceeded = true;
        }
    }
    emitEvent(session, 46, 0, 0, codec, 0);
    emitConnectedIfReady(session);
}

void openNOWGridAppStreamingTerminated(void *gridApp, const void *terminationInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    uint32_t terminationReason = terminationInfo == nullptr ? 0 : loadUnaligned<uint32_t>(terminationInfo, 0);
    int32_t extendedCode = terminationInfo == nullptr ? -1 : loadUnaligned<int32_t>(terminationInfo, 4);
    uint32_t resumable = terminationInfo == nullptr ? 0 : loadUnaligned<uint8_t>(terminationInfo, 0x40);
    uint32_t sessionAlive = terminationInfo == nullptr ? 0 : loadUnaligned<uint8_t>(terminationInfo, 0x41);
    bool locallyRequested = false;
    bool shouldEmit = false;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        locallyRequested = session->stopIssued;
        shouldEmit = !locallyRequested && session->state != NativeSessionState::stopped;
        if (shouldEmit) { session->state = NativeSessionState::stopped; }
    }
    if (shouldEmit) {
        emitEvent(session,
                  62,
                  0,
                  0,
                  terminationReason,
                  extendedCode,
                  nvbResultName(session, extendedCode),
                  resumable,
                  sessionAlive,
                  nvbResultName(session, static_cast<int32_t>(terminationReason)));
    }
}

void openNOWGridAppCursorInfoUpdate(void *gridApp, const void *cursorInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    try {
        session->functions.cursorInfoUpdate(gridApp, cursorInfo);
        if (cursorInfo == nullptr) { return; }
        const uint32_t cursorState = loadUnaligned<uint32_t>(cursorInfo, 0x0c);
        if (cursorState != 1 && cursorState != 2) { return; }
        emitEvent(session,
                  80,
                  0,
                  loadUnaligned<uint16_t>(cursorInfo, 0x04),
                  cursorState,
                  static_cast<int32_t>(loadUnaligned<uint32_t>(cursorInfo, 0x00)));
    } catch (...) {
        setSessionFailureUnlessStopping(session, "GridApp cursor update raised an unexpected C++ exception.");
    }
}

void openNOWGridAppSetupProgress(void *gridApp, const void *parameters) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    uint32_t state = parameters == nullptr ? 0 : loadUnaligned<uint32_t>(parameters, 0);
    uint32_t queuePosition = parameters == nullptr ? 0 : loadUnaligned<uint32_t>(parameters, 4);
    int32_t eta = parameters == nullptr ? 0 : loadUnaligned<int32_t>(parameters, 8);
    emitEvent(session, 35, 0, state, queuePosition, eta);
}

void openNOWGridAppActiveSessions(void *gridApp, const void *result) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    int32_t resultCode = result == nullptr ? -1 : loadUnaligned<int32_t>(result, 0);
    emitEvent(session, 36, 0, 0, 0, resultCode, result == nullptr ? nullptr : nvbResultName(session, resultCode));
}

void openNOWGridAppStopResult(void *gridApp, const void *failureInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    int32_t resultCode = failureInfo == nullptr ? -1 : loadUnaligned<int32_t>(failureInfo, 0);
    bool locallyRequested = false;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        locallyRequested = session->stopIssued;
        session->state = NativeSessionState::stopped;
    }
    emitEvent(session, locallyRequested ? 60 : 61, 0, 0, 0, resultCode, failureInfo == nullptr ? nullptr : nvbResultName(session, resultCode));
}

void openNOWGridAppPauseResult(void *gridApp, const void *failureInfo) {
    OpenNOWNativeNVSTGeronimoSession *session = beginGridAppCallback(gridApp);
    if (session == nullptr) { return; }
    GridAppCallbackLease callbackLease{session};
    int32_t resultCode = failureInfo == nullptr ? -1 : loadUnaligned<int32_t>(failureInfo, 0);
    bool wasPending = false;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state == NativeSessionState::pausePending) {
            session->state = resultCode == 0 ? NativeSessionState::paused : NativeSessionState::streaming;
            wasPending = true;
        }
    }
    if (wasPending) { emitEvent(session, resultCode == 0 ? 50 : 70, 0, 0, 0, resultCode, failureInfo == nullptr ? nullptr : nvbResultName(session, resultCode)); }
}

NSDictionary *jsonDictionary(const std::string &json) {
    if (json.empty()) { return @{}; }
    NSString *string = [[NSString alloc] initWithBytes:json.data() length:json.size() encoding:NSUTF8StringEncoding];
    if (string == nil) { return @{}; }
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) { return @{}; }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) { return @{}; }
    return static_cast<NSDictionary *>(object);
}

id jsonValueAtPath(NSDictionary *dictionary, const char *path) {
    if (dictionary == nil || path == nullptr) { return nil; }
    NSString *keyPath = [NSString stringWithUTF8String:path];
    if (keyPath == nil || keyPath.length == 0) { return nil; }
    NSArray<NSString *> *parts = [keyPath componentsSeparatedByString:@"."];
    id current = dictionary;
    for (NSString *part in parts) {
        if (![current isKindOfClass:[NSDictionary class]]) { return nil; }
        current = [static_cast<NSDictionary *>(current) objectForKey:part];
        if (current == nil || current == [NSNull null]) { return nil; }
    }
    return current;
}

std::string jsonStringAtPath(NSDictionary *dictionary, const char *path) {
    id value = jsonValueAtPath(dictionary, path);
    if ([value isKindOfClass:[NSString class]]) {
        const char *utf8 = [static_cast<NSString *>(value) UTF8String];
        return utf8 == nullptr ? std::string() : std::string(utf8);
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        NSString *string = [static_cast<NSNumber *>(value) stringValue];
        const char *utf8 = [string UTF8String];
        return utf8 == nullptr ? std::string() : std::string(utf8);
    }
    return std::string();
}

int32_t jsonIntAtPath(NSDictionary *dictionary, const char *path) {
    id value = jsonValueAtPath(dictionary, path);
    if ([value isKindOfClass:[NSNumber class]]) { return [static_cast<NSNumber *>(value) intValue]; }
    if ([value isKindOfClass:[NSString class]]) { return [static_cast<NSString *>(value) intValue]; }
    return 0;
}

bool jsonBoolAtPath(NSDictionary *dictionary, const char *path) {
    id value = jsonValueAtPath(dictionary, path);
    if ([value isKindOfClass:[NSNumber class]]) { return [static_cast<NSNumber *>(value) boolValue]; }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lowered = [static_cast<NSString *>(value) lowercaseString];
        return [lowered isEqualToString:@"true"] || [lowered isEqualToString:@"1"];
    }
    return false;
}

bool jsonUInt64AtPath(NSDictionary *dictionary, const char *path, uint64_t &result) {
    id value = jsonValueAtPath(dictionary, path);
    if (![value isKindOfClass:[NSNumber class]]) { return false; }
    NSNumber *number = static_cast<NSNumber *>(value);
    if ([number compare:@0] == NSOrderedAscending || [number compare:[NSNumber numberWithUnsignedLongLong:UINT32_MAX]] == NSOrderedDescending) { return false; }
    result = [number unsignedLongLongValue];
    return true;
}

std::vector<std::string> jsonStringArrayAtPath(NSDictionary *dictionary, const char *path) {
    std::vector<std::string> values;
    id value = jsonValueAtPath(dictionary, path);
    if (![value isKindOfClass:[NSArray class]]) { return values; }
    for (id element in static_cast<NSArray *>(value)) {
        if (![element isKindOfClass:[NSString class]]) { continue; }
        const char *utf8 = [static_cast<NSString *>(element) UTF8String];
        if (utf8 != nullptr && utf8[0] != '\0') { values.emplace_back(utf8); }
    }
    return values;
}

enum class MetadataParseResult {
    success,
    malformed,
    overflow,
};

MetadataParseResult parseMetadata(NSDictionary *geronimo,
                                  std::vector<std::pair<std::string, std::string>> &metadata,
                                  std::string &error) {
    metadata.clear();
    id value = geronimo == nil ? nil : [geronimo objectForKey:@"metaData"];
    if (value == nil) { return MetadataParseResult::success; }
    if (![value isKindOfClass:[NSArray class]]) {
        error = "Native Geronimo metadata must be a metaData array.";
        return MetadataParseResult::malformed;
    }
    NSArray *entries = static_cast<NSArray *>(value);
    if (entries.count > MaximumMetadataCount) {
        error = "Native Geronimo metadata exceeds the maximum of 64 entries.";
        return MetadataParseResult::overflow;
    }
    metadata.reserve(entries.count);
    for (NSUInteger index = 0; index < entries.count; ++index) {
        id entry = [entries objectAtIndex:index];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            error = "Native Geronimo metadata entries must be objects with string key and value fields.";
            return MetadataParseResult::malformed;
        }
        id key = [static_cast<NSDictionary *>(entry) objectForKey:@"key"];
        id entryValue = [static_cast<NSDictionary *>(entry) objectForKey:@"value"];
        if (![key isKindOfClass:[NSString class]] || ![entryValue isKindOfClass:[NSString class]]) {
            error = "Native Geronimo metadata entries must contain string key and value fields.";
            return MetadataParseResult::malformed;
        }
        const char *keyUTF8 = [static_cast<NSString *>(key) UTF8String];
        const char *valueUTF8 = [static_cast<NSString *>(entryValue) UTF8String];
        if (keyUTF8 == nullptr || valueUTF8 == nullptr) {
            error = "Native Geronimo metadata contains a string that cannot be encoded as UTF-8.";
            return MetadataParseResult::malformed;
        }
        const NSUInteger keyByteCount = [static_cast<NSString *>(key) lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const NSUInteger valueByteCount = [static_cast<NSString *>(entryValue) lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (strlen(keyUTF8) != keyByteCount || strlen(valueUTF8) != valueByteCount) {
            error = "Native Geronimo metadata strings cannot contain embedded null bytes.";
            return MetadataParseResult::malformed;
        }
        metadata.emplace_back(keyUTF8, valueUTF8);
    }
    return MetadataParseResult::success;
}

void materializeMetadataPointers(PendingStart &pending) {
    pending.metadataPointers.clear();
    pending.metadataPointers.reserve(pending.metadataStrings.size());
    for (const auto &entry : pending.metadataStrings) {
        pending.metadataPointers.push_back(NVbKeyValuePair_t{entry.first.c_str(), entry.second.c_str()});
    }
    pending.parameters.metadata = pending.metadataPointers.empty() ? nullptr : pending.metadataPointers.data();
    pending.parameters.metadataCount = static_cast<uint32_t>(pending.metadataPointers.size());
}

std::string firstNonEmptyString(NSDictionary *first, NSDictionary *second, const char *const *paths, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        std::string value = jsonStringAtPath(first, paths[index]);
        if (!value.empty()) { return value; }
        value = jsonStringAtPath(second, paths[index]);
        if (!value.empty()) { return value; }
    }
    return std::string();
}

struct HostAndPort {
    std::string host;
    uint16_t port = 443;
};

HostAndPort hostAndPort(const std::string &address, uint16_t fallbackPort = 443) {
    HostAndPort result;
    result.port = fallbackPort == 0 ? 443 : fallbackPort;
    std::string value = address;
    size_t scheme = value.find("://");
    if (scheme != std::string::npos) { value = value.substr(scheme + 3); }
    size_t path = value.find('/');
    if (path != std::string::npos) { value = value.substr(0, path); }
    size_t at = value.rfind('@');
    if (at != std::string::npos) { value = value.substr(at + 1); }
    std::string host = value;
    std::string portString;
    if (!value.empty() && value.front() == '[') {
        size_t closingBracket = value.find(']');
        if (closingBracket != std::string::npos) {
            host = value.substr(1, closingBracket - 1);
            if (closingBracket + 2 < value.size() && value[closingBracket + 1] == ':') {
                portString = value.substr(closingBracket + 2);
            }
        }
    } else {
        size_t firstColon = value.find(':');
        if (firstColon != std::string::npos && firstColon == value.rfind(':')) {
            host = value.substr(0, firstColon);
            portString = value.substr(firstColon + 1);
        }
    }
    if (!portString.empty()) {
        bool numeric = true;
        for (char character : portString) {
            if (!std::isdigit(static_cast<unsigned char>(character))) { numeric = false; break; }
        }
        if (numeric) {
            int parsed = atoi(portString.c_str());
            if (parsed > 0 && parsed <= 65535) { result.port = static_cast<uint16_t>(parsed); }
        }
    }
    result.host = host;
    return result;
}

bool authTypeForTokenType(const std::string &tokenType, uint32_t &authType) {
    std::string lowered = tokenType;
    for (char &character : lowered) { character = static_cast<char>(std::tolower(static_cast<unsigned char>(character))); }
    if (lowered == "7" || lowered == "jarvis" || lowered == "nvb_auth_jarvis") {
        authType = 7;
        return true;
    }
    if (lowered == "8" || lowered == "jwt" || lowered == "nvb_auth_jwt") {
        authType = 8;
        return true;
    }
    if (lowered == "9" || lowered == "jwt_gfn" || lowered == "jwt-gfn" || lowered == "nvb_auth_jwt_gfn") {
        authType = 9;
        return true;
    }
    return false;
}

int32_t convertedServerType(int32_t serverType) {
    switch (serverType) {
    case 1: return 0;
    case 2: return 1;
    case 3: return 2;
    case 4: return 3;
    case 5: return 4;
    case 1001: return 0x33;
    default: return -1;
    }
}

void *resolve(void *handle, const char *symbol, char *errorBuffer, size_t errorBufferLength) {
    dlerror();
    void *address = dlsym(handle, symbol);
    if (address == nullptr) { setDLError(errorBuffer, errorBufferLength, symbol); }
    return address;
}

void *resolvePrivateFromImage(void *anchorSymbol, uintptr_t anchorOffset, uintptr_t targetOffset) {
    if (anchorSymbol == nullptr || anchorOffset == 0 || targetOffset == 0) { return nullptr; }
    uintptr_t imageBase = reinterpret_cast<uintptr_t>(anchorSymbol) - anchorOffset;
    return reinterpret_cast<void *>(imageBase + targetOffset);
}

void *resolvePrivateNskSymbol(void *handle, void *anchorSymbol, const char *symbol, uintptr_t targetOffset, char *errorBuffer, size_t errorBufferLength) {
    dlerror();
    void *address = dlsym(handle, symbol);
    if (address != nullptr) { return address; }
    address = resolvePrivateFromImage(anchorSymbol, GetStreamStartParametersJSONStringOffset, targetOffset);
    if (address == nullptr) { setDLError(errorBuffer, errorBufferLength, symbol); }
    return address;
}

uint32_t codecFromJSON(NSDictionary *cloud, NSDictionary *geronimo) {
    const char *const codecPaths[] = { "streamingProfile.codec", "codec", "videoCodec" };
    std::string codec = firstNonEmptyString(cloud, geronimo, codecPaths, sizeof(codecPaths) / sizeof(codecPaths[0]));
    for (char &character : codec) { character = static_cast<char>(std::tolower(static_cast<unsigned char>(character))); }
    if (codec.find("av1") != std::string::npos) { return 4; }
    if (codec.find("265") != std::string::npos || codec.find("hevc") != std::string::npos) { return 2; }
    return DefaultNVbCodecH264;
}

uint32_t videoDecoderCreationCodec(uint32_t requestedCodec) {
    return requestedCodec == 1 || requestedCodec == 2 || requestedCodec == 4 ? requestedCodec : 0;
}

bool audioFrameTriggersRendererReopen(uint32_t configuredChannelCount, uint32_t incomingChannelCount) {
    return configuredChannelCount != incomingChannelCount;
}

bool acquirePlatform(NskPlatformStartup startup) {
    std::lock_guard<std::mutex> lock(gPlatformMutex);
    if (gPlatformReferenceCount == 0) {
        Nsk::PlatformStartupParams parameters;
        if (startup == nullptr || !startup(parameters)) { return false; }
    }
    ++gPlatformReferenceCount;
    return true;
}

void releasePlatform(PlatformShutdown shutdown) {
    std::lock_guard<std::mutex> lock(gPlatformMutex);
    if (gPlatformReferenceCount == 0) { return; }
    --gPlatformReferenceCount;
    if (gPlatformReferenceCount == 0 && shutdown != nullptr) { shutdown(); }
}

bool resolveGeronimoFunctions(void *handle, GeronimoFunctions &functions, char *errorBuffer, size_t errorBufferLength) {
    functions.gridAppDtor = reinterpret_cast<GridAppDtor>(resolve(handle, "_ZN7GridAppD2Ev", errorBuffer, errorBufferLength));
    functions.gridAppProcessEvents = reinterpret_cast<GridAppProcessEvents>(resolve(handle, "_ZN7GridApp13processEventsEv", errorBuffer, errorBufferLength));
    functions.stop = reinterpret_cast<GridAppStop>(resolve(handle, "_ZN7GridApp4stopEPKci", errorBuffer, errorBufferLength));
    functions.pause = reinterpret_cast<GridAppPause>(resolve(handle, "_ZN7GridApp14pauseStreamingEi", errorBuffer, errorBufferLength));
    functions.resume = reinterpret_cast<GridAppResume>(resolve(handle, "_ZN7GridApp6resumeEPKcRKN14SessionControl17SessionParametersERK19NVbTracingContext_t", errorBuffer, errorBufferLength));
    functions.sendInput = reinterpret_cast<GridAppSendInput>(resolve(handle, "_ZN7GridApp18sendNvstInputEventERK16NvstInputEvent_t", errorBuffer, errorBufferLength));
    functions.handleGamepadChanged = reinterpret_cast<GridAppHandleGamepadChanged>(resolve(handle, "_ZN7GridApp25handleGamepadChangedEventEhiib", errorBuffer, errorBufferLength));
    functions.controlFeatures = reinterpret_cast<GridAppControlFeatures>(resolve(handle, "_ZN7GridApp15controlFeaturesE23NVbFeatureControlType_tj", errorBuffer, errorBufferLength));
    functions.setDecoderInfo = reinterpret_cast<GridAppSetDecoderInfo>(resolve(handle, "_ZN7GridApp14setDecoderInfoE25NvstVideoDecodeUnitType_tj17NvstH264Profile_tj26NvstDynamicStreamingMode_tjb", errorBuffer, errorBufferLength));
    functions.togglePerfIndicator = reinterpret_cast<GridAppTogglePerfIndicator>(resolve(handle, "_ZN7GridApp29togglePerfIndicatorVisibilityEv", errorBuffer, errorBufferLength));
    functions.cursorInfoUpdate = reinterpret_cast<GridAppCursorInfoUpdate>(resolve(handle, "_ZN7GridApp18onCursorInfoUpdateERK10CursorInfo", errorBuffer, errorBufferLength));
    functions.setStreamingMaxBitrate = reinterpret_cast<GridAppSetStreamingMaxBitrate>(resolve(handle, "_ZN7GridApp22setStreamingMaxBitrateEtj", errorBuffer, errorBufferLength));
    functions.setDynamicStreamingMode = reinterpret_cast<GridAppSetDynamicStreamingMode>(resolve(handle, "_ZN7GridApp23setDynamicStreamingModeEt26NvstDynamicStreamingMode_t", errorBuffer, errorBufferLength));
    functions.setL4sState = reinterpret_cast<GridAppSetL4sState>(resolve(handle, "_ZN7GridApp11setL4sStateEtb", errorBuffer, errorBufferLength));
    functions.ioInterfaceGetStatsInterface = reinterpret_cast<IOInterfaceGetStatsInterface>(resolve(handle, "_ZN11IOInterface17getStatsInterfaceEv", errorBuffer, errorBufferLength));
    functions.ioInterfaceGetMaxBitrateKbps = reinterpret_cast<IOInterfaceGetMaxBitrateKbps>(resolve(handle, "_ZN11IOInterface17getMaxBitrateKbpsEv", errorBuffer, errorBufferLength));
    functions.ioInterfaceGetDynamicStreamingMode = reinterpret_cast<IOInterfaceGetDynamicStreamingMode>(resolve(handle, "_ZN11IOInterface23getDynamicStreamingModeEv", errorBuffer, errorBufferLength));
    functions.ioInterfaceGetL4sState = reinterpret_cast<IOInterfaceGetL4sState>(resolve(handle, "_ZN11IOInterface11getL4sStateEv", errorBuffer, errorBufferLength));
    functions.statsInterfaceGetStats = reinterpret_cast<StatsInterfaceGetStats>(resolve(handle, "_ZN14StatsInterface8getStatsER13GeronimoStatsRNSt3__112basic_stringIcNS2_11char_traitsIcEENS2_9allocatorIcEEEES9_S9_S9_S9_S9_", errorBuffer, errorBufferLength));
    functions.graphicsContextCtor = reinterpret_cast<ObjectCtor>(resolve(handle, "_ZN18SDLGraphicsContextC1Ev", errorBuffer, errorBufferLength));
    functions.graphicsContextDtor = reinterpret_cast<ObjectDtor>(resolve(handle, "_ZN18SDLGraphicsContextD1Ev", errorBuffer, errorBufferLength));
    functions.graphicsContextInitialize = reinterpret_cast<SDLGraphicsContextInitialize>(resolve(handle, "_ZN18SDLGraphicsContext10initializeERKNS_14InitParametersE", errorBuffer, errorBufferLength));
    functions.eventProcessorCtor = reinterpret_cast<ObjectCtor>(resolve(handle, "_ZN17SDLEventProcessorC1Ev", errorBuffer, errorBufferLength));
    functions.eventProcessorDtor = reinterpret_cast<ObjectDtor>(resolve(handle, "_ZN17SDLEventProcessorD1Ev", errorBuffer, errorBufferLength));
    functions.eventProcessorInitialize = reinterpret_cast<SDLEventProcessorInitialize>(resolve(handle, "_ZN17SDLEventProcessor10initializeEP11IOInterfaceRKNS_10InitParamsE", errorBuffer, errorBufferLength));
    functions.eventProcessorProcessEvents = reinterpret_cast<SDLEventProcessorProcessEvents>(resolve(handle, "_ZN17SDLEventProcessor13processEventsEi", errorBuffer, errorBufferLength));
    functions.windowCtor = reinterpret_cast<ObjectCtor>(resolve(handle, "_ZN9SDLWindowC1Ev", errorBuffer, errorBufferLength));
    functions.windowDtor = reinterpret_cast<ObjectDtor>(resolve(handle, "_ZN9SDLWindowD1Ev", errorBuffer, errorBufferLength));
    functions.windowInitialize = reinterpret_cast<SDLWindowInitialize>(resolve(handle, "_ZN9SDLWindow10initializeEP11IOInterfaceRKNS_10InitParamsE", errorBuffer, errorBufferLength));
    functions.windowAsyncRenderer = reinterpret_cast<SDLWindowAsyncRenderer>(resolve(handle, "_ZNK9SDLWindow13asyncRendererEv", errorBuffer, errorBufferLength));
    functions.windowConvertPointToVideoFrame = reinterpret_cast<SDLWindowConvertPointToVideoFrame>(resolve(handle, "_ZNK9SDLWindow24convertPointToVideoFrameE9SDL_PointPS0_P8SDL_Rect", errorBuffer, errorBufferLength));
    functions.createVideoDecoder = reinterpret_cast<PlatformCreateVideoDecoder>(resolve(handle, "_Z26platformCreateVideoDecoderR31PlatformDecoderCreationSettingsj", errorBuffer, errorBufferLength));
    functions.createAudioRenderer = reinterpret_cast<PlatformCreateAudioObject>(resolve(handle, "_Z27platformCreateAudioRendererv", errorBuffer, errorBufferLength));
    functions.createAudioCapturer = reinterpret_cast<PlatformCreateAudioObject>(resolve(handle, "_Z27platformCreateAudioCapturerv", errorBuffer, errorBufferLength));
    functions.vtDecoderInitialize = reinterpret_cast<VideoDecoderInitialize>(resolve(handle, "_ZN9VTDecoder10initializeEP11IOInterfaceRK23PlatformDecoderSettingsRKNSt3__110shared_ptrI23AsyncVideoFrameRendererEE", errorBuffer, errorBufferLength));
    return functions.gridAppDtor != nullptr &&
           functions.gridAppProcessEvents != nullptr &&
           functions.stop != nullptr &&
           functions.pause != nullptr &&
           functions.resume != nullptr &&
           functions.sendInput != nullptr &&
           functions.handleGamepadChanged != nullptr &&
           functions.controlFeatures != nullptr &&
           functions.setDecoderInfo != nullptr &&
           functions.togglePerfIndicator != nullptr &&
           functions.cursorInfoUpdate != nullptr &&
           functions.setStreamingMaxBitrate != nullptr &&
           functions.setDynamicStreamingMode != nullptr &&
           functions.setL4sState != nullptr &&
           functions.ioInterfaceGetStatsInterface != nullptr &&
           functions.ioInterfaceGetMaxBitrateKbps != nullptr &&
           functions.ioInterfaceGetDynamicStreamingMode != nullptr &&
           functions.ioInterfaceGetL4sState != nullptr &&
           functions.statsInterfaceGetStats != nullptr &&
           functions.graphicsContextCtor != nullptr &&
           functions.graphicsContextDtor != nullptr &&
           functions.graphicsContextInitialize != nullptr &&
           functions.eventProcessorCtor != nullptr &&
           functions.eventProcessorDtor != nullptr &&
           functions.eventProcessorInitialize != nullptr &&
           functions.eventProcessorProcessEvents != nullptr &&
           functions.windowCtor != nullptr &&
           functions.windowDtor != nullptr &&
           functions.windowInitialize != nullptr &&
           functions.windowAsyncRenderer != nullptr &&
           functions.windowConvertPointToVideoFrame != nullptr &&
           functions.createVideoDecoder != nullptr &&
           functions.createAudioRenderer != nullptr &&
           functions.createAudioCapturer != nullptr &&
           functions.vtDecoderInitialize != nullptr;
}

void *allocateConstructedObject(size_t size, ObjectCtor constructor) {
    if (constructor == nullptr) { return nullptr; }
    void *storage = ::operator new(size, std::nothrow);
    if (storage == nullptr) { return nullptr; }
    memset(storage, 0, size);
    constructor(storage);
    return storage;
}

void destroyConstructedObject(void *&object, ObjectDtor destructor) {
    if (object == nullptr) { return; }
    if (destructor != nullptr) { destructor(object); }
    ::operator delete(object);
    object = nullptr;
}

void destroyPolymorphicObject(void *&object) {
    if (object == nullptr) { return; }
    using DeletingDestructor = void (*)(void *);
    DeletingDestructor destructor = virtualFunction<DeletingDestructor>(object, 0x08);
    void *ownedObject = object;
    object = nullptr;
    if (destructor != nullptr) { destructor(ownedObject); }
}

bool installGridAppCallbacks(OpenNOWNativeNVSTGeronimoSession *session, char *errorBuffer, size_t errorBufferLength) {
    auto **sourceVTable = reinterpret_cast<void **>(resolve(session->libraryHandle, "_ZTV7GridApp", errorBuffer, errorBufferLength));
    if (sourceVTable == nullptr) { return false; }
    auto **clone = static_cast<void **>(malloc(GridAppVTableSize));
    if (clone == nullptr) {
        setError(errorBuffer, errorBufferLength, "Failed to allocate the GridApp callback vtable.");
        return false;
    }
    memcpy(clone, sourceVTable, GridAppVTableSize);
    void **addressPoint = clone + 2;
    const struct {
        size_t offset;
        const char *symbol;
    } verifiedSlots[] = {
        {GridAppSetupFailureSlotOffset, "_ZN7GridApp21onSessionSetUpFailureERKN14SessionControl23SessionSetUpFailureInfoE"},
        {GridAppResumeFailureSlotOffset, "_ZN7GridApp15onResumeFailureERKN14SessionControl23SessionSetUpFailureInfoE"},
        {GridAppSetupSuccessSlotOffset, "_ZN7GridApp21onSessionSetupSuccessERK11SessionInfo"},
        {GridAppStreamingTerminatedSlotOffset, "_ZN7GridApp21onStreamingTerminatedERKNS_22SessionTerminationInfoE"},
        {GridAppUpdateAuthTokenSlotOffset, "_ZN7GridApp15updateAuthTokenERN14NVbEventData_t16_UpdateAuthTokenE"},
        {GridAppCursorInfoSlotOffset, "_ZN7GridApp18onCursorInfoUpdateERK10CursorInfo"},
        {GridAppSetupProgressSlotOffset, "_ZN7GridApp22onSessionSetupProgressERKN14SessionControl23SessionUpdateParametersE"},
        {GridAppActiveSessionsSlotOffset, "_ZN7GridApp16onActiveSessionsERK20ActiveSessionsResult"},
        {GridAppStopResultSlotOffset, "_ZN7GridApp12onStopResultERKN14SessionControl23SessionSetUpFailureInfoE"},
        {GridAppPauseResultSlotOffset, "_ZN7GridApp13onPauseResultERKN14SessionControl23SessionSetUpFailureInfoE"},
    };
    void *pureVirtual = dlsym(session->libraryHandle, "__cxa_pure_virtual");
    if (pureVirtual == nullptr ||
        addressPoint[GridAppPrepareResultSlotOffset / sizeof(void *)] != pureVirtual ||
        addressPoint[GridAppStreamingBeginSlotOffset / sizeof(void *)] != pureVirtual) {
        free(clone);
        setError(errorBuffer, errorBufferLength, "GridApp host callback slots no longer match the verified ABI.");
        return false;
    }
    for (const auto &slot : verifiedSlots) {
        void *expected = resolve(session->libraryHandle, slot.symbol, errorBuffer, errorBufferLength);
        if (expected == nullptr || addressPoint[slot.offset / sizeof(void *)] != expected) {
            free(clone);
            setError(errorBuffer, errorBufferLength, "GridApp lifecycle callback slots no longer match the verified ABI.");
            return false;
        }
    }
    addressPoint[GridAppPrepareResultSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppPrepareResult);
    addressPoint[GridAppStreamingBeginSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppStreamingBegin);
    addressPoint[GridAppSetupFailureSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppSetupFailure);
    addressPoint[GridAppResumeFailureSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppResumeFailure);
    addressPoint[GridAppSetupSuccessSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppSetupSuccess);
    addressPoint[GridAppStreamingTerminatedSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppStreamingTerminated);
    addressPoint[GridAppUpdateAuthTokenSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppUpdateAuthToken);
    addressPoint[GridAppCursorInfoSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppCursorInfoUpdate);
    addressPoint[GridAppSetupProgressSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppSetupProgress);
    addressPoint[GridAppActiveSessionsSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppActiveSessions);
    addressPoint[GridAppStopResultSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppStopResult);
    addressPoint[GridAppPauseResultSlotOffset / sizeof(void *)] = reinterpret_cast<void *>(&openNOWGridAppPauseResult);
    *static_cast<void ***>(session->gridApp) = addressPoint;
    session->gridAppVTable = clone;
    try {
        std::lock_guard<std::mutex> lock(gGridAppSessionsMutex);
        gGridAppSessions.emplace(session->gridApp, session);
    } catch (...) {
        *static_cast<void ***>(session->gridApp) = sourceVTable + 2;
        session->gridAppVTable = nullptr;
        free(clone);
        setError(errorBuffer, errorBufferLength, "Failed to register the GridApp callback owner.");
        return false;
    }
    return true;
}

void detachGridAppCallbacks(OpenNOWNativeNVSTGeronimoSession *session) {
    if (session == nullptr) { return; }
    {
        std::lock_guard<std::mutex> lock(gGridAppSessionsMutex);
        session->acceptsCallbacks.store(false, std::memory_order_release);
        gGridAppSessions.erase(session->gridApp);
    }
    std::unique_lock<std::mutex> lock(session->callbackMutex);
    session->callbacksDrained.wait(lock, [session] {
        return session->callbacksInFlight.load(std::memory_order_acquire) == 0;
    });
}

void setSessionFailure(OpenNOWNativeNVSTGeronimoSession *session, const char *message) {
    std::lock_guard<std::mutex> lock(session->stateMutex);
    session->state = NativeSessionState::failed;
    session->lastError = message == nullptr ? "Native Geronimo media initialization failed." : message;
}

bool setSessionFailureUnlessStopping(OpenNOWNativeNVSTGeronimoSession *session, const char *message) {
    std::lock_guard<std::mutex> lock(session->stateMutex);
    if (session->state == NativeSessionState::paused || session->state == NativeSessionState::stopping ||
        session->state == NativeSessionState::stopped || session->state == NativeSessionState::failed) { return false; }
    session->state = NativeSessionState::failed;
    session->lastError = message == nullptr ? "Native Geronimo session failed." : message;
    return true;
}

bool initializeAudioObject(void *object, void *ioInterface, const PlatformAudioSettings &settings) {
    using Initialize = bool (*)(void *, void *, const PlatformAudioSettings &);
    Initialize initialize = virtualFunction<Initialize>(object, 0x38);
    return initialize != nullptr && initialize(object, ioInterface, settings);
}

bool videoSurfaceDimensions(void *nativeHandle, uint32_t &width, uint32_t &height) {
    if (nativeHandle == nullptr) { return false; }
    id nativeObject = (__bridge id)nativeHandle;
    NSView *surfaceView = nil;
    if ([nativeObject isKindOfClass:[NSWindow class]]) {
        surfaceView = [static_cast<NSWindow *>(nativeObject) contentView];
    } else if ([nativeObject isKindOfClass:[NSView class]]) {
        surfaceView = static_cast<NSView *>(nativeObject);
    }
    if (surfaceView == nil) { return false; }
    NSSize size = surfaceView.bounds.size;
    if (size.width < 1 || size.height < 1 || size.width > UINT32_MAX || size.height > UINT32_MAX) { return false; }
    width = static_cast<uint32_t>(size.width);
    height = static_cast<uint32_t>(size.height);
    return width > 0 && height > 0;
}

bool ensureVideoDecoderLocked(OpenNOWNativeNVSTGeronimoSession *session, uint32_t codec) {
    const uint32_t creationCodec = videoDecoderCreationCodec(codec);
    if (creationCodec == 0) { return false; }
    if (session->videoDecoder != nullptr && session->activeCodec == codec) { return true; }
    callVoidVirtual(session->videoDecoder, 0x60);
    destroyPolymorphicObject(session->videoDecoder);
    session->activeCodec = 0;
    session->videoDecoderStarted = false;

    PlatformDecoderCreationSettings creationSettings{};
    storeUnaligned<uint32_t>(creationSettings.bytes, 0x00, 0);
    storeUnaligned<uint32_t>(creationSettings.bytes, 0x10, 2);
    storeUnaligned<uint32_t>(creationSettings.bytes, 0x18, GraphicsContextMetal);
    storeUnaligned<uint32_t>(creationSettings.bytes, 0x1c, 1);
    void *candidate = session->functions.createVideoDecoder(creationSettings, creationCodec);
    if (candidate == nullptr) { return false; }
    const std::shared_ptr<AsyncVideoFrameRenderer> &renderer = session->functions.windowAsyncRenderer(session->window);
    if (!renderer) {
        destroyPolymorphicObject(candidate);
        return false;
    }
    VideoDecoderInitialize initialize = virtualFunction<VideoDecoderInitialize>(candidate, VideoDecoderInitializeSlotOffset);
    if (initialize == nullptr || initialize != session->functions.vtDecoderInitialize) {
        destroyPolymorphicObject(candidate);
        return false;
    }
    PlatformDecoderSettings decoderSettings{};
    storeUnaligned<uint32_t>(decoderSettings.bytes, 0x00, 42);
    storeUnaligned<uint32_t>(decoderSettings.bytes, 0x0c, codec);
    storeUnaligned<uint8_t>(decoderSettings.bytes, 0x1d, 1);
    int32_t decoderResult = initialize(candidate, session->ioInterface, decoderSettings, renderer);
    if (decoderResult != 0) {
        destroyPolymorphicObject(candidate);
        return false;
    }
    session->videoDecoder = candidate;
    session->activeCodec = codec;
    session->videoDecoderStarted = false;
    session->functions.setDecoderInfo(session->gridApp, 2, 1, 3, 42, 0, 0, false);
    return true;
}

bool setupPlatformMedia(OpenNOWNativeNVSTGeronimoSession *session) {
    std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
    if (session->videoSurfaceHandle == nullptr) {
        setSessionFailure(session, "Native Geronimo requires a video surface before prepare completes.");
        return false;
    }

    session->graphicsContext = allocateConstructedObject(SDLGraphicsContextStorageSize, session->functions.graphicsContextCtor);
    if (session->graphicsContext == nullptr) {
        setSessionFailure(session, "Failed to allocate SDLGraphicsContext.");
        return false;
    }
    SDLGraphicsContextInitParameters graphicsParameters{};
    storeUnaligned<uint32_t>(graphicsParameters.bytes, 0x00, GraphicsContextMetal);
    storeUnaligned<uint8_t>(graphicsParameters.bytes, 0x04, 1);
    if (session->functions.graphicsContextInitialize(session->graphicsContext, graphicsParameters) != 0) {
        setSessionFailure(session, "SDLGraphicsContext Metal initialization failed.");
        return false;
    }

    session->eventProcessor = allocateConstructedObject(SDLEventProcessorStorageSize, session->functions.eventProcessorCtor);
    if (session->eventProcessor == nullptr) {
        setSessionFailure(session, "Failed to allocate SDLEventProcessor.");
        return false;
    }
    SDLEventProcessorInitParams eventParameters{};
    eventParameters.bytes[3] = 1;
    if (!session->functions.eventProcessorInitialize(session->eventProcessor, session->ioInterface, eventParameters)) {
        setSessionFailure(session, "SDLEventProcessor initialization failed.");
        return false;
    }

    session->window = allocateConstructedObject(SDLWindowStorageSize, session->functions.windowCtor);
    if (session->window == nullptr) {
        setSessionFailure(session, "Failed to allocate SDLWindow.");
        return false;
    }
    SDLWindowInitParams windowParameters{};
    storeUnaligned<void *>(windowParameters.bytes, 0x00, session->graphicsContext);
    storeUnaligned<void *>(windowParameters.bytes, 0x08, session->eventProcessor);
    storeUnaligned<const char *>(windowParameters.bytes, 0x28, "OpenNOW");
    uint32_t windowWidth = 0;
    uint32_t windowHeight = 0;
    void *videoSurfaceHandle = const_cast<void *>(session->videoSurfaceHandle);
    if (!videoSurfaceDimensions(videoSurfaceHandle, windowWidth, windowHeight)) {
        setSessionFailure(session, "Native Geronimo video surface has invalid dimensions.");
        return false;
    }
    storeUnaligned<uint32_t>(windowParameters.bytes, 0x1c, windowWidth);
    storeUnaligned<uint32_t>(windowParameters.bytes, 0x20, windowHeight);
    storeUnaligned<uint8_t>(windowParameters.bytes, 0x38, SDLWindowHighDPIEnabled);
    storeUnaligned<void *>(windowParameters.bytes, 0x70, videoSurfaceHandle);
    storeUnaligned<uint8_t>(windowParameters.bytes, 0x78, 1);
    if (!session->functions.windowInitialize(session->window, session->ioInterface, windowParameters)) {
        setSessionFailure(session, "SDLWindow initialization failed for the OpenNOW native surface.");
        return false;
    }

    PlatformAudioSettings audioSettings{};
    storeUnaligned<uint64_t>(audioSettings.bytes, 0x00, 0x020000020000bb80ULL);
    session->audioRenderer = session->functions.createAudioRenderer();
    if (session->audioRenderer == nullptr || !initializeAudioObject(session->audioRenderer, session->ioInterface, audioSettings)) {
        destroyPolymorphicObject(session->audioRenderer);
        setSessionFailure(session, "Geronimo audio renderer initialization failed.");
        return false;
    }

    if (session->microphoneAvailable) {
        session->audioCapturer = session->functions.createAudioCapturer();
        if (session->audioCapturer != nullptr && !initializeAudioObject(session->audioCapturer, session->ioInterface, audioSettings)) {
            destroyPolymorphicObject(session->audioCapturer);
        }
    }

    if (!ensureVideoDecoderLocked(session, session->requestedCodec)) {
        setSessionFailure(session, "Geronimo video decoder creation failed.");
        return false;
    }
    return true;
}

void teardownPlatformMedia(OpenNOWNativeNVSTGeronimoSession *session) {
    std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
    callVoidVirtual(session->videoDecoder, 0x60);
    destroyPolymorphicObject(session->videoDecoder);
    session->activeCodec = 0;
    session->videoDecoderStarted = false;

    void *capturer = session->audioCapturer;
    session->audioCapturer = nullptr;
    if (capturer != nullptr) {
        auto shutdownCapturer = [capturer] {
            void *ownedCapturer = capturer;
            callVoidVirtual(ownedCapturer, 0x50);
            destroyPolymorphicObject(ownedCapturer);
        };
        try {
            std::thread worker(shutdownCapturer);
            worker.join();
        } catch (...) {
            shutdownCapturer();
        }
    }

    callVoidVirtual(session->audioRenderer, 0x58);
    destroyPolymorphicObject(session->audioRenderer);
    destroyConstructedObject(session->window, session->functions.windowDtor);
    destroyConstructedObject(session->eventProcessor, session->functions.eventProcessorDtor);
    destroyConstructedObject(session->graphicsContext, session->functions.graphicsContextDtor);
}

int32_t completePreparedStart(OpenNOWNativeNVSTGeronimoSession *session) {
    std::unique_ptr<PendingStart> pending;
    {
        std::lock_guard<std::mutex> lock(session->stateMutex);
        if (session->state != NativeSessionState::prepared || session->pendingStart == nullptr) { return 0; }
        session->state = NativeSessionState::starting;
        pending = std::move(session->pendingStart);
    }
    NVbAuthInfo_t authInfo;
    authInfo.token = session->authToken.c_str();
    authInfo.authType = pending->authType;
    if (!pending->setAuthInfo(session->gridApp, &authInfo)) {
        std::string message = "GridApp::setAuthInfo failed authType=" + std::to_string(authInfo.authType) + ".";
        setSessionFailure(session, message.c_str());
        emitEvent(session, 70, 0, 0, 0, -6);
        return -6;
    }
    pending->parameters.streamSettingsCount = static_cast<uint32_t>(pending->streamSettings.size());
    pending->parameters.streamSettings = pending->streamSettings.empty() ? nullptr : pending->streamSettings.data();
    if (!pending->streamSettings.empty()) {
        pending->parameters.defaultStreamSettings = pending->streamSettings.front();
    }
    if (!setupPlatformMedia(session)) {
        teardownPlatformMedia(session);
        emitEvent(session, 70, 0, 0, 0, -10);
        return -10;
    }
    Nsk::NVbTracingContext_t tracingContext;
    tracingContext.traceParent = pending->traceParent.c_str();
    emitEvent(session, 30, 0, 0, 0, 0);
    materializeMetadataPointers(*pending);
    bool accepted = pending->shouldResume
        ? pending->resume(session->gridApp, pending->resumeSessionId.c_str(), pending->parameters, tracingContext)
        : pending->start(session->gridApp, pending->parameters, tracingContext);
    if (!accepted) {
        setSessionFailure(session, pending->shouldResume ? "GridApp::resume failed after successful prepare." : "GridApp::start failed after successful prepare.");
        teardownPlatformMedia(session);
        emitEvent(session, 70, 0, 0, 0, -11);
        return -11;
    }
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        session->startEventDelivered = true;
        if (session->state == NativeSessionState::starting) { session->state = NativeSessionState::setupPending; }
    }
    emitEvent(session, 40, 0, 0, 0, 0);
    emitConnectedIfReady(session);
    return 0;
}
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoInspectEndpoint(const char *address,
                                                               uint16_t fallbackPort,
                                                               char *hostBuffer,
                                                               size_t hostBufferLength,
                                                               uint16_t *port) {
    HostAndPort endpoint = hostAndPort(stringOrEmpty(address), fallbackPort);
    if (endpoint.host.empty() || port == nullptr) { return -1; }
    setError(hostBuffer, hostBufferLength, endpoint.host.c_str());
    *port = endpoint.port;
    return 0;
}

extern "C" void *OpenNOWNativeNVSTGeronimoCreate(const char *frameworksPath, char *errorBuffer, size_t errorBufferLength) {
    void *handle = nullptr;
    void *bifrostHandle = nullptr;
    void *gridApp = nullptr;
    bool gridAppConstructed = false;
    bool platformStarted = false;
    bool bifrostRegistrationHookAcquired = false;
    PlatformShutdown platformShutdown = nullptr;
    GeronimoFunctions functions;
    OpenNOWNativeNVSTGeronimoSession *session = nullptr;
    try {
        std::string directory = stringOrEmpty(frameworksPath);
        if (directory.empty()) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo NVST frameworks path is empty.");
            return nullptr;
        }
        std::string libraryPath = directory + "/libGeronimo.dylib";
        handle = dlopen(libraryPath.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (handle == nullptr) {
            setDLError(errorBuffer, errorBufferLength, "dlopen libGeronimo.dylib failed");
            return nullptr;
        }
        std::string bifrostPath = directory + "/libBifrost2.dylib";
        bifrostHandle = dlopen(bifrostPath.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (bifrostHandle == nullptr) {
            setDLError(errorBuffer, errorBufferLength, "dlopen libBifrost2.dylib failed");
            dlclose(handle);
            return nullptr;
        }

        auto ctor = reinterpret_cast<GridAppCtor>(resolve(handle, "_ZN7GridAppC2Ev", errorBuffer, errorBufferLength));
        auto platformStartup = reinterpret_cast<NskPlatformStartup>(resolve(handle, "_ZN3Nsk15platformStartupERKNS_21PlatformStartupParamsE", errorBuffer, errorBufferLength));
        platformShutdown = reinterpret_cast<PlatformShutdown>(resolve(handle, "_ZN3Nsk16platformShutdownEv", errorBuffer, errorBufferLength));
        auto initialize = reinterpret_cast<GridAppInitialize>(resolve(handle, "_ZN7GridApp10initializeEb", errorBuffer, errorBufferLength));
        auto originalBifrostCallback = reinterpret_cast<NVbCallback>(resolve(handle, "_ZN7GridApp13onNVbCallbackEPv17NVbCallbackType_tP17NVbCallbackData_t", errorBuffer, errorBufferLength));
        auto enumToString = reinterpret_cast<NVbEnumToString>(resolve(bifrostHandle, "nvbEnumToString", errorBuffer, errorBufferLength));
        if (ctor == nullptr || platformStartup == nullptr || platformShutdown == nullptr || initialize == nullptr || originalBifrostCallback == nullptr ||
            enumToString == nullptr ||
            !resolveGeronimoFunctions(handle, functions, errorBuffer, errorBufferLength)) {
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }

        if (!acquirePlatform(platformStartup)) {
            setError(errorBuffer, errorBufferLength, "Geronimo platform startup failed.");
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }
        platformStarted = true;

        gridApp = aligned_alloc(16, GridAppStorageSize);
        if (gridApp == nullptr) {
            setError(errorBuffer, errorBufferLength, "Failed to allocate GridApp storage.");
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }
        memset(gridApp, 0, GridAppStorageSize);
        ctor(gridApp);
        gridAppConstructed = true;
        std::unique_lock<std::mutex> initializationLock(gGridAppInitializationMutex);
        if (!acquireBifrostRegistrationHook(handle, gridApp, originalBifrostCallback, errorBuffer, errorBufferLength)) {
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }
        bifrostRegistrationHookAcquired = true;
        void *ioInterface = initialize(gridApp, true);
        const bool callbackIntercepted = gBifrostRegistrationIntercepted.load(std::memory_order_acquire);
        releaseBifrostRegistrationHook();
        bifrostRegistrationHookAcquired = false;
        initializationLock.unlock();
        if (ioInterface == nullptr) {
            setError(errorBuffer, errorBufferLength, "GridApp initialization failed.");
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }
        if (!callbackIntercepted) {
            setError(errorBuffer, errorBufferLength, "GridApp did not register the verified Bifrost callback.");
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }

        session = new (std::nothrow) OpenNOWNativeNVSTGeronimoSession();
        if (session == nullptr) {
            setError(errorBuffer, errorBufferLength, "Failed to allocate native Geronimo session.");
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            return nullptr;
        }
        session->libraryHandle = handle;
        session->bifrostHandle = bifrostHandle;
        session->gridApp = gridApp;
        session->ioInterface = ioInterface;
        session->platformShutdown = platformShutdown;
        session->enumToString = enumToString;
        session->originalBifrostCallback = originalBifrostCallback;
        session->functions = functions;
        session->platformStarted = true;
        session->initialized = true;
        if (!acquireMicrophoneHook(handle, bifrostHandle, errorBuffer, errorBufferLength)) {
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            delete session;
            return nullptr;
        }
        session->microphoneHookLeaseAcquired = true;
        session->microphoneRoute = registerMicrophoneRoute(loadUnaligned<void *>(gridApp, 0x18));
        if (session->microphoneRoute == nullptr) {
            setError(errorBuffer, errorBufferLength, "No native microphone route slot is available.");
            releaseMicrophoneHook();
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            delete session;
            return nullptr;
        }
        if (!installGridAppCallbacks(session, errorBuffer, errorBufferLength)) {
            unregisterMicrophoneRoute(session->microphoneRoute);
            releaseMicrophoneHook();
            functions.gridAppDtor(gridApp);
            free(gridApp);
            releasePlatform(platformShutdown);
            dlclose(bifrostHandle);
            dlclose(handle);
            delete session;
            return nullptr;
        }
        return session;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session creation raised an unexpected C++ exception.");
        if (bifrostRegistrationHookAcquired) { releaseBifrostRegistrationHook(); }
        if (session != nullptr && session->gridAppVTable != nullptr) { detachGridAppCallbacks(session); }
        if (session != nullptr && session->microphoneRoute != nullptr) { unregisterMicrophoneRoute(session->microphoneRoute); }
        if (session != nullptr && session->microphoneHookLeaseAcquired) { releaseMicrophoneHook(); }
        if (gridAppConstructed && functions.gridAppDtor != nullptr) { functions.gridAppDtor(gridApp); }
        if (gridApp != nullptr) { free(gridApp); }
        if (session != nullptr && session->gridAppVTable != nullptr) { free(session->gridAppVTable); }
        delete session;
        if (platformStarted && platformShutdown != nullptr) { releasePlatform(platformShutdown); }
        if (bifrostHandle != nullptr) { dlclose(bifrostHandle); }
        if (handle != nullptr) { dlclose(handle); }
        return nullptr;
    }
}

extern "C" const char *OpenNOWNativeNVSTGeronimoResultCodeName(void *sessionPointer, int32_t resultCode) {
    return nvbResultName(static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer), resultCode);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetEventHandler(void *sessionPointer,
                                                              OpenNOWGeronimoEventHandler eventHandler,
                                                              void *eventContext,
                                                              char *errorBuffer,
                                                              size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->libraryHandle == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for callback registration.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    if ((eventHandler == nullptr) != (eventContext == nullptr)) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo callback handler and context must both be set or cleared.");
        return -2;
    }
    {
        std::lock_guard<std::mutex> lock(session->eventMutex);
        session->eventHandler = eventHandler;
        session->eventContext = eventContext;
    }
    emitEvent(session, 20, 0, 0, 0, 0);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetHapticHandler(void *sessionPointer,
                                                                OpenNOWGeronimoHapticHandler handler,
                                                                void *context) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return -1; }
    std::lock_guard<std::mutex> lock(session->runtimeHandlerMutex);
    session->hapticHandler = handler;
    session->hapticContext = context;
    return 0;
}

extern "C" uint32_t OpenNOWNativeNVSTGeronimoVideoDecoderCreationCodec(uint32_t requestedCodec) {
    return videoDecoderCreationCodec(requestedCodec);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoAudioFrameTriggersRendererReopen(uint32_t configuredChannelCount,
                                                                                uint32_t incomingChannelCount) {
    return audioFrameTriggersRendererReopen(configuredChannelCount, incomingChannelCount) ? 1 : 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetAuthRefreshHandler(void *sessionPointer,
                                                                    OpenNOWGeronimoAuthRefreshHandler handler,
                                                                    void *context) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return -1; }
    std::lock_guard<std::mutex> lock(session->runtimeHandlerMutex);
    session->authRefreshHandler = handler;
    session->authRefreshContext = context;
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoDecodeHapticCallbackData(const uint8_t *callbackData,
                                                                        size_t callbackDataLength,
                                                                        OpenNOWGeronimoHapticHandler handler,
                                                                        void *context) {
    if (callbackData == nullptr || callbackDataLength < 0x16 || handler == nullptr) { return -1; }
    const uint16_t byteCount = std::min<uint16_t>(loadUnaligned<uint16_t>(callbackData, 0x14), 32);
    if (callbackDataLength < 0x16 + byteCount) { return -2; }
    OpenNOWNativeNVSTGeronimoSession session;
    session.hapticHandler = handler;
    session.hapticContext = context;
    emitHapticRecords(&session, callbackData);
    const uint32_t subtype = loadUnaligned<uint32_t>(callbackData, 0x10);
    return subtype == 1 ? byteCount / 6 : (subtype == 2 ? byteCount / 8 : 0);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoUpdateGamepadTopology(void *sessionPointer,
                                                                     uint8_t connectedPlayerBitmap,
                                                                     uint8_t hapticPlayerBitmap,
                                                                     char *errorBuffer,
                                                                     size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.handleGamepadChanged == nullptr || session->functions.controlFeatures == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for gamepad topology.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    try {
        const bool shouldEnableHaptics = (connectedPlayerBitmap & hapticPlayerBitmap & 0x0f) != 0;
        if (session->hapticFeatureEnabled && !shouldEnableHaptics) {
            if (!session->functions.controlFeatures(session->gridApp, NVbFeatureGamepadHaptics, 0)) {
                setError(errorBuffer, errorBufferLength, "Geronimo rejected gamepad haptics feature state.");
                return -3;
            }
            session->hapticFeatureEnabled = false;
        }
        for (uint8_t sourceIndex = 0; sourceIndex < 4; ++sourceIndex) {
            const bool shouldRegister = (connectedPlayerBitmap & (1u << sourceIndex)) != 0;
            if (session->registeredGamepads[sourceIndex] == shouldRegister) { continue; }
            if (!session->functions.handleGamepadChanged(session->gridApp, sourceIndex, 0xffff, 0xffff, shouldRegister)) {
                setError(errorBuffer, errorBufferLength, shouldRegister ? "Geronimo rejected native gamepad connection." : "Geronimo rejected native gamepad disconnection.");
                return -2;
            }
            session->registeredGamepads[sourceIndex] = shouldRegister;
        }
        if (!session->hapticFeatureEnabled && shouldEnableHaptics) {
            if (!session->functions.controlFeatures(session->gridApp, NVbFeatureGamepadHaptics, 1)) {
                setError(errorBuffer, errorBufferLength, "Geronimo rejected gamepad haptics feature state.");
                return -3;
            }
            session->hapticFeatureEnabled = true;
        }
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "GridApp gamepad topology update raised an unexpected C++ exception.");
        return -4;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetVideoSurface(void *sessionPointer,
                                                              void *nativeHandle,
                                                              char *errorBuffer,
                                                              size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->libraryHandle == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for video surface binding.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    if (nativeHandle == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo video surface handle is null.");
        return -2;
    }
    id nativeObject = (__bridge id)nativeHandle;
    if (![nativeObject isKindOfClass:[NSWindow class]] && ![nativeObject isKindOfClass:[NSView class]]) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo video surface must be an NSWindow or NSView.");
        return -4;
    }
    CFTypeRef previousVideoSurfaceHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(session->mediaMutex);
        if (session->window != nullptr) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo video surface cannot change after SDLWindow initialization.");
            return -3;
        }
        previousVideoSurfaceHandle = session->videoSurfaceHandle;
        session->videoSurfaceHandle = CFBridgingRetain(nativeObject);
    }
    if (previousVideoSurfaceHandle != nullptr) { CFRelease(previousVideoSurfaceHandle); }
    emitEvent(session, 22, 0, 0, 0, 0);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetMicrophoneEnabled(void *sessionPointer,
                                                                    int32_t enabled,
                                                                    char *errorBuffer,
                                                                    size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for microphone control.");
        return -1;
    }
    if (![NSThread isMainThread]) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo microphone control must run on the main thread.");
        return -2;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo microphone control requires a streaming session.");
            return -3;
        }
    }
    std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
    if (!session->microphoneAvailable || session->audioCapturer == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo microphone capture is unavailable for this session.");
        return -4;
    }
    if (enabled != 0 && !session->microphoneSetupSucceeded) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo microphone setup did not complete for this session.");
        return -5;
    }
    session->microphoneEnabled = enabled != 0;
    if (!session->microphoneEnabled && session->microphoneRoute != nullptr) {
        std::lock_guard<std::mutex> stateLock(session->microphoneRoute->stateMutex);
        resetVoiceActivity(session->microphoneRoute->vad);
    }
    callVoidVirtual(session->audioCapturer, session->microphoneEnabled ? 0x48 : 0x40);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetMicrophoneVolume(void *sessionPointer, double volume) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->microphoneRoute == nullptr || !std::isfinite(volume)) { return -1; }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    const float boundedVolume = static_cast<float>(std::clamp(volume, 0.0, 1.0));
    session->microphoneVolume = boundedVolume;
    session->microphoneRoute->volume.store(boundedVolume, std::memory_order_release);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetVoiceActivityEnabled(void *sessionPointer, int32_t enabled) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->microphoneRoute == nullptr) { return -1; }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    session->voiceActivityEnabled = enabled != 0;
    std::lock_guard<std::mutex> stateLock(session->microphoneRoute->stateMutex);
    resetVoiceActivity(session->microphoneRoute->vad);
    session->microphoneRoute->vadEnabled.store(session->voiceActivityEnabled, std::memory_order_release);
    return 0;
}

extern "C" size_t OpenNOWNativeNVSTGeronimoTestVoiceActivityStateSize() {
    return sizeof(AdaptiveVoiceActivityState);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoTestResetVoiceActivityState(void *stateBytes, size_t stateByteCount) {
    if (stateBytes == nullptr || stateByteCount != sizeof(AdaptiveVoiceActivityState) || reinterpret_cast<uintptr_t>(stateBytes) % alignof(AdaptiveVoiceActivityState) != 0) { return -1; }
    new (stateBytes) AdaptiveVoiceActivityState();
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoTestProcessMicrophonePCM(int16_t *samples,
                                                                        size_t sampleCount,
                                                                        double volume,
                                                                        int32_t vadEnabled,
                                                                        void *stateBytes,
                                                                        size_t stateByteCount) {
    if (samples == nullptr || stateBytes == nullptr || stateByteCount != sizeof(AdaptiveVoiceActivityState) ||
        reinterpret_cast<uintptr_t>(stateBytes) % alignof(AdaptiveVoiceActivityState) != 0 || !std::isfinite(volume)) { return -1; }
    auto &state = *static_cast<AdaptiveVoiceActivityState *>(stateBytes);
    return processMicrophonePCM(samples, samples, sampleCount, static_cast<float>(volume), vadEnabled != 0, state) ? 0 : -2;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoTestMicrophoneFrameSupported(uint32_t sampleRate,
                                                                            uint32_t bitsPerSample,
                                                                            uint32_t channels,
                                                                            uint32_t format,
                                                                            uint32_t byteCount) {
    NvstAudioFrame_t frame{};
    int16_t sample = 0;
    storeUnaligned<uint32_t>(frame.bytes, 0x08, bitsPerSample);
    storeUnaligned<uint32_t>(frame.bytes, 0x0c, sampleRate);
    storeUnaligned<uint32_t>(frame.bytes, 0x10, channels);
    storeUnaligned<uint32_t>(frame.bytes, 0x14, format);
    storeUnaligned<const void *>(frame.bytes, 0x28, &sample);
    storeUnaligned<uint32_t>(frame.bytes, 0x30, byteCount);
    return isSupportedMicrophoneFrame(frame) ? 1 : 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoTestProcessMicrophoneFrame(void *frameBytes,
                                                                          size_t frameByteCount,
                                                                          double volume,
                                                                          int32_t vadEnabled,
                                                                          void *stateBytes,
                                                                          size_t stateByteCount) {
    if (frameBytes == nullptr || frameByteCount != sizeof(NvstAudioFrame_t) || stateBytes == nullptr ||
        stateByteCount != sizeof(AdaptiveVoiceActivityState) || reinterpret_cast<uintptr_t>(stateBytes) % alignof(AdaptiveVoiceActivityState) != 0 ||
        !std::isfinite(volume)) { return -1; }
    NvstAudioFrame_t frame{};
    memcpy(&frame, frameBytes, sizeof(frame));
    if (!isSupportedMicrophoneFrame(frame)) { return 0; }
    auto *samples = static_cast<int16_t *>(loadUnaligned<void *>(frame.bytes, 0x28));
    auto &state = *static_cast<AdaptiveVoiceActivityState *>(stateBytes);
    return processMicrophonePCM(samples, samples, MicrophoneSampleCount, static_cast<float>(volume), vadEnabled != 0, state) ? 1 : -2;
}

extern "C" void *OpenNOWNativeNVSTGeronimoTestRegisterMicrophoneRoute(void *client) {
    return registerMicrophoneRoute(client);
}

extern "C" void OpenNOWNativeNVSTGeronimoTestUnregisterMicrophoneRoute(void *route) {
    unregisterMicrophoneRoute(static_cast<MicrophoneRouteSlot *>(route));
}

extern "C" size_t OpenNOWNativeNVSTGeronimoTestMicrophoneRouteCount() {
    size_t count = 0;
    for (MicrophoneRouteSlot &slot : gMicrophoneRoutes) {
        if (slot.client.load(std::memory_order_acquire) != nullptr) { ++count; }
    }
    return count;
}

int32_t startOrResumeGeronimo(void *sessionPointer,
                              const char *rawSessionJSON,
                              const char *streamingProfileJSON,
                              const char *cloudSessionJSON,
                              const char *gameLanguage,
                              const char *clientAppVersion,
                              const char *clientLocale,
                              const char *traceParent,
                              const char *authTokenType,
                              const char *authToken,
                              int32_t microphoneAvailable,
                              int32_t microphoneEnabled,
                              bool shouldResume,
                              char *errorBuffer,
                              size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->libraryHandle == nullptr || session->gridApp == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    try {
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::created) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo start can only be requested once per session.");
            return -9;
        }
    }
    {
        std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
        if (session->videoSurfaceHandle == nullptr) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo start requires a bound video surface.");
            return -10;
        }
    }
    auto getParameters = reinterpret_cast<GetStreamStartParameters>(resolve(session->libraryHandle, "_ZN3Nsk24getStreamStartParametersERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEES8_RKNS_32ApplicationStreamStartParametersERNS_21StreamStartParametersE", errorBuffer, errorBufferLength));
    auto prepare = reinterpret_cast<GridAppPrepare>(resolve(session->libraryHandle, "_ZN7GridApp7prepareERKN14SessionControl17PrepareParametersE", errorBuffer, errorBufferLength));
    auto setAuthInfo = reinterpret_cast<GridAppSetAuthInfo>(resolve(session->libraryHandle, "_ZN7GridApp11setAuthInfoER13NVbAuthInfo_t", errorBuffer, errorBufferLength));
    auto start = reinterpret_cast<GridAppStart>(resolve(session->libraryHandle, "_ZN7GridApp5startERKN14SessionControl17SessionParametersERK19NVbTracingContext_t", errorBuffer, errorBufferLength));
    auto resume = reinterpret_cast<GridAppResume>(resolve(session->libraryHandle, "_ZN7GridApp6resumeEPKcRKN14SessionControl17SessionParametersERK19NVbTracingContext_t", errorBuffer, errorBufferLength));
    auto convertToStreamingParams = reinterpret_cast<ConvertToStreamingParams>(resolvePrivateNskSymbol(session->libraryHandle, reinterpret_cast<void *>(getParameters), "_ZN3Nsk24convertToStreamingParamsERKNS_21StreamStartParametersERKNS_22VideoDecoderInitParamsER20NVbStreamingParams_t", ConvertToStreamingParamsOffset, errorBuffer, errorBufferLength));
    auto freeStreamingParams = reinterpret_cast<FreeStreamingParams>(resolvePrivateNskSymbol(session->libraryHandle, reinterpret_cast<void *>(getParameters), "_ZN3Nsk4freeER20NVbStreamingParams_t", FreeStreamingParamsOffset, errorBuffer, errorBufferLength));
    if (getParameters == nullptr || prepare == nullptr || setAuthInfo == nullptr || start == nullptr || resume == nullptr || convertToStreamingParams == nullptr || freeStreamingParams == nullptr) { return -2; }

    std::string rawSession = stringOrEmpty(rawSessionJSON);
    std::string streamingProfile = stringOrEmpty(streamingProfileJSON);
    std::string cloudSession = stringOrEmpty(cloudSessionJSON);
    if (rawSession.empty() || streamingProfile.empty() || cloudSession.empty()) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo start requires normalized session JSON, streaming profile JSON, and Cloud session JSON.");
        return -3;
    }
    NSDictionary *geronimo = jsonDictionary(rawSession);
    std::vector<std::pair<std::string, std::string>> metadataStrings;
    std::string metadataError;
    MetadataParseResult metadataResult = parseMetadata(geronimo, metadataStrings, metadataError);
    if (metadataResult != MetadataParseResult::success) {
        setError(errorBuffer, errorBufferLength, metadataError.c_str());
        return metadataResult == MetadataParseResult::overflow ? -12 : -4;
    }

    Nsk::ApplicationStreamStartParameters application;
    memset(application.reserved0, 0, sizeof(application.reserved0));
    application.gameLanguage = stringOrEmpty(gameLanguage).empty() ? "en_US" : stringOrEmpty(gameLanguage);
    application.clientAppVersion = stringOrEmpty(clientAppVersion).empty() ? "OpenNOW" : stringOrEmpty(clientAppVersion);
    application.clientLocale = stringOrEmpty(clientLocale).empty() ? application.gameLanguage : stringOrEmpty(clientLocale);

    Nsk::StreamStartParameters startParameters;
    int parameterResult = getParameters(rawSession, streamingProfile, application, startParameters);
    if (parameterResult != 0) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer,
                     errorBufferLength,
                     "Nsk::getStreamStartParameters failed with 0x%08x rawBytes=%zu profileBytes=%zu.",
                     parameterResult,
                     rawSession.size(),
                     streamingProfile.size());
        }
        return parameterResult;
    }

    NSDictionary *cloud = jsonDictionary(cloudSession);
    NSDictionary *profile = jsonDictionary(streamingProfile);
    int32_t maxPacketSize = jsonIntAtPath(profile, "maxPacketSize");
    if (maxPacketSize != 0 && (maxPacketSize < MinimumNVbPacketSize || maxPacketSize > UINT16_MAX)) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo start received an invalid measured maximum packet size.");
        return -4;
    }
    session->microphoneAvailable = microphoneAvailable != 0;
    session->microphoneEnabled = session->microphoneAvailable && microphoneEnabled != 0;
    session->requestedCodec = codecFromJSON(cloud, geronimo);
    const char *const tokenPaths[] = { "token", "authToken", "jwt", "auth.token", "sessionToken" };
    const char *const tokenTypePaths[] = { "tokenType", "authType", "auth.type" };
    const char *const serverPaths[] = { "serverAddress", "sessionControlInfo.ip", "zoneAddress" };
    const char *const sessionPaths[] = { "session", "sessionId" };
    session->authToken = stringOrEmpty(authToken);
    if (session->authToken.empty()) { session->authToken = firstNonEmptyString(cloud, geronimo, tokenPaths, sizeof(tokenPaths) / sizeof(tokenPaths[0])); }
    std::string tokenType = stringOrEmpty(authTokenType);
    if (tokenType.empty()) { tokenType = firstNonEmptyString(cloud, geronimo, tokenTypePaths, sizeof(tokenTypePaths) / sizeof(tokenTypePaths[0])); }
    std::string serverAddress = firstNonEmptyString(cloud, geronimo, serverPaths, sizeof(serverPaths) / sizeof(serverPaths[0]));
    session->sessionId = firstNonEmptyString(cloud, geronimo, sessionPaths, sizeof(sessionPaths) / sizeof(sessionPaths[0]));
    uint32_t appId = static_cast<uint32_t>(jsonIntAtPath(cloud, "sessionRequestData.appId"));
    if (appId == 0) { appId = static_cast<uint32_t>(jsonIntAtPath(cloud, "appId")); }
    if (appId == 0) { appId = startParameters.appId; }
    int32_t width = jsonIntAtPath(profile, "selectedVideoMode.width");
    int32_t height = jsonIntAtPath(profile, "selectedVideoMode.height");
    int32_t fps = jsonIntAtPath(profile, "selectedVideoMode.fps");
    if (width <= 0 && !startParameters.videoSettings.empty()) { width = 1; }
    if (height <= 0 && !startParameters.videoSettings.empty()) { height = 1; }
    if (fps <= 0 && !startParameters.videoSettings.empty()) { fps = 1; }
    int32_t configuredPort = jsonIntAtPath(geronimo, "port");
    if (configuredPort <= 0) { configuredPort = jsonIntAtPath(cloud, "port"); }
    if (configuredPort <= 0) { configuredPort = jsonIntAtPath(cloud, "sessionControlInfo.port"); }
    uint16_t fallbackPort = configuredPort > 0 && configuredPort <= UINT16_MAX ? static_cast<uint16_t>(configuredPort) : 443;
    HostAndPort endpoint = hostAndPort(serverAddress, fallbackPort);
    if (session->authToken.empty() || endpoint.host.empty() || appId == 0 || session->sessionId.empty() || width <= 0 || height <= 0 || fps <= 0) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer,
                     errorBufferLength,
                     "Geronimo native start is missing required fields token=%s server=%s appId=%u sessionId=%s width=%d height=%d fps=%d.",
                     session->authToken.empty() ? "missing" : "present",
                     endpoint.host.empty() ? "missing" : "present",
                     appId,
                     session->sessionId.empty() ? "missing" : "present",
                     width,
                     height,
                     fps);
        }
        return -4;
    }

    session->initServerAddress = endpoint.host;
    session->startServerAddress = endpoint.host;
    session->appIdString = std::to_string(appId);
    session->clientAppVersion = stringOrEmpty(clientAppVersion).empty() ? "OpenNOW" : stringOrEmpty(clientAppVersion);
    session->clientLocale = stringOrEmpty(clientLocale).empty() ? "en_US" : stringOrEmpty(clientLocale);
    session->keyboardLayout = jsonStringAtPath(geronimo, "keyboardLayout");
    if (session->keyboardLayout.empty()) { session->keyboardLayout = "en_US"; }
    session->deviceId = jsonStringAtPath(geronimo, "deviceId");
    if (session->deviceId.empty()) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo start requires a device id.");
        return -4;
    }
    int32_t rawServerType = jsonIntAtPath(geronimo, "serverType");
    if (rawServerType == 0) { rawServerType = jsonIntAtPath(cloud, "serverType"); }
    int32_t nativeServerType = convertedServerType(rawServerType);
    if (nativeServerType < 0) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "Native Geronimo start received unsupported server type %d.", rawServerType);
        }
        return -5;
    }

    SessionControl::PrepareParameters prepareParameters;
    prepareParameters.serverAddress = session->initServerAddress;
    prepareParameters.serverPort = endpoint.port;
    prepareParameters.clientProfile = width >= 1920 && height >= 1080 ? 5 : 3;
    prepareParameters.deviceId = session->deviceId;
    const uint32_t communicationParameters[] = {3, 3, 13, 500, 1000, 10000, 1000, 50, 3000, 1000, 300};
    memcpy(prepareParameters.communicationParams, communicationParameters, sizeof(communicationParameters));
    prepareParameters.synchronous = GeronimoPrepareSynchronous;
    prepareParameters.serverType = nativeServerType;
    prepareParameters.locale = session->clientLocale;
    prepareParameters.applicationIdentifier = "GFN-PC";
    prepareParameters.applicationVersion = "30.0";
    prepareParameters.clientName = "OpenNOW";
    prepareParameters.clientAppVersion = session->clientAppVersion;
    prepareParameters.applicationHeaders = jsonStringArrayAtPath(geronimo, "applicationHeaders");

    uint32_t resolvedAuthType = 0;
    if (!authTypeForTokenType(tokenType, resolvedAuthType)) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo start received an unsupported auth token type.");
        return -6;
    }

    Nsk::VideoDecoderInitParams decoderParams;
    memset(decoderParams.bytes, 0, sizeof(decoderParams.bytes));
    Nsk::VideoDecoderCapabilityParams decoderCapabilities;
    memset(decoderCapabilities.bytes, 0, sizeof(decoderCapabilities.bytes));
    storeUnaligned<uint32_t>(decoderParams.bytes, 0x00, 0);
    storeUnaligned<uint32_t>(decoderParams.bytes, 0x04, 0);
    storeUnaligned<void *>(decoderParams.bytes, 0x10, &decoderCapabilities);
    storeUnaligned<uint32_t>(decoderCapabilities.bytes, 0x60, GraphicsContextMetal);
    Nsk::NVbStreamingParams_t streamingParams;
    memset(streamingParams.bytes, 0, sizeof(streamingParams.bytes));
    StreamingParamsGuard streamingParamsGuard{&streamingParams, freeStreamingParams};
    if (!convertToStreamingParams(startParameters, decoderParams, streamingParams)) {
        setSessionFailure(session, "Nsk::convertToStreamingParams rejected the native stream profile.");
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer,
                     errorBufferLength,
                     "Nsk::convertToStreamingParams failed appId=%u sessionId=%s server=%s:%u videoSettings=%zu audioSettings=%zu connectionInfo=%zu.",
                     appId,
                     session->sessionId.empty() ? "missing" : "present",
                     session->startServerAddress.c_str(),
                     endpoint.port,
                     startParameters.videoSettings.size(),
                     startParameters.audioSettings.size(),
                     startParameters.connectionInfo.size());
        }
        return -7;
    }

    auto pending = std::make_unique<PendingStart>();
    pending->setAuthInfo = setAuthInfo;
    pending->start = start;
    pending->resume = resume;
    pending->authType = resolvedAuthType;
    pending->shouldResume = shouldResume;
    pending->resumeSessionId = session->sessionId;
    pending->metadataStrings = std::move(metadataStrings);
    pending->parameters.appId = appId;
    pending->parameters.serverAddress = session->startServerAddress;
    pending->parameters.serverPort = endpoint.port;
    pending->parameters.serverType = nativeServerType;
    uint32_t streamSettingsCount = loadField<uint32_t>(streamingParams, 0x28);
    Nsk::NVbStreamSettings_t *streamSettings = loadField<Nsk::NVbStreamSettings_t *>(streamingParams, 0x30);
    if (streamSettingsCount > MaximumStreamSettingsCount || (streamSettingsCount > 0 && streamSettings == nullptr)) {
        setSessionFailure(session, "Geronimo returned invalid native stream settings.");
        setError(errorBuffer, errorBufferLength, "Geronimo returned invalid native stream settings.");
        return -8;
    }
    if (streamSettingsCount > 0) {
        pending->streamSettings.assign(streamSettings, streamSettings + streamSettingsCount);
        if (maxPacketSize >= MinimumNVbPacketSize) {
            for (auto &setting : pending->streamSettings) {
                storeUnaligned<uint16_t>(setting.bytes, NVbStreamSettingsPacketSizeOffset, static_cast<uint16_t>(maxPacketSize));
            }
        }
        pending->parameters.defaultStreamSettings = pending->streamSettings.front();
    }
    pending->parameters.supportedHidTypes = static_cast<uint64_t>(jsonIntAtPath(geronimo, "finalizedStreamingFeatures.supportedHidDevices"));
    uint64_t gamepadBitmap = 0;
    if (jsonUInt64AtPath(geronimo, "remoteControllersBitmap", gamepadBitmap)) {
        pending->parameters.gamepadBitmap = gamepadBitmap;
    }
    pending->parameters.appLaunchMode = static_cast<uint32_t>(std::max(0, jsonIntAtPath(geronimo, "appLaunchMode")));
    pending->parameters.networkPacketCaptureEnabled = jsonBoolAtPath(geronimo, "networkPacketCaptureEnabled");
    pending->parameters.partnerCustomData = jsonStringAtPath(geronimo, "partnerCustomData");
    pending->parameters.clientLocale = session->clientLocale;
    pending->parameters.keyboardLayout = session->keyboardLayout;
    pending->parameters.allowKeyboardLayoutChange = jsonBoolAtPath(geronimo, "allowKeyboardLayoutChange");
    pending->parameters.accountLinked = jsonBoolAtPath(geronimo, "accountLinked");
    pending->parameters.persistingInGameSettings = jsonBoolAtPath(geronimo, "persistingInGameSettings");
    pending->parameters.networkSessionId = jsonStringAtPath(geronimo, "networkSessionId");
    pending->parameters.bifrostSessionId = jsonStringAtPath(geronimo, "bifrostSessionId");
    pending->parameters.userAge = static_cast<uint32_t>(std::max(0, jsonIntAtPath(geronimo, "userAge")));
    uint32_t connectionCount = loadField<uint32_t>(streamingParams, 0x168);
    Nsk::NVbConnectionInfo_t *connections = loadField<Nsk::NVbConnectionInfo_t *>(streamingParams, 0x170);
    if (connectionCount > MaximumConnectionInfoCount || (connectionCount > 0 && connections == nullptr)) {
        setSessionFailure(session, "Geronimo returned invalid native connection information.");
        setError(errorBuffer, errorBufferLength, "Geronimo returned invalid native connection information.");
        return -8;
    }
    if (connectionCount > 0) {
        pending->parameters.connectionInfo.assign(connections, connections + connectionCount);
    }
    pending->traceParent = stringOrEmpty(traceParent);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::created) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo session stopped while start parameters were being configured.");
            return -8;
        }
        session->state = NativeSessionState::configured;
        session->lastError.clear();
        session->pendingStart = std::move(pending);
    }

    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::configured) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo session stopped before prepare.");
            return -8;
        }
        session->state = NativeSessionState::preparePending;
    }
    if (!prepare(session->gridApp, prepareParameters)) {
        setSessionFailure(session, "GridApp::prepare rejected the native session.");
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer,
                     errorBufferLength,
                     "GridApp::prepare failed appId=%u server=%s:%u.",
                     appId,
                     session->startServerAddress.c_str(),
                     endpoint.port);
        }
        return -5;
    }
    return 0;
    } catch (...) {
        setSessionFailure(session, "Native Geronimo start raised an unexpected C++ exception.");
        setError(errorBuffer, errorBufferLength, "Native Geronimo start raised an unexpected C++ exception.");
        return -11;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoStart(void *sessionPointer,
                                                     const char *rawSessionJSON,
                                                     const char *streamingProfileJSON,
                                                     const char *cloudSessionJSON,
                                                     const char *gameLanguage,
                                                     const char *clientAppVersion,
                                                     const char *clientLocale,
                                                     const char *traceParent,
                                                     const char *authTokenType,
                                                     const char *authToken,
                                                     int32_t microphoneAvailable,
                                                     int32_t microphoneEnabled,
                                                     char *errorBuffer,
                                                     size_t errorBufferLength) {
    return startOrResumeGeronimo(sessionPointer,
                                 rawSessionJSON,
                                 streamingProfileJSON,
                                 cloudSessionJSON,
                                 gameLanguage,
                                 clientAppVersion,
                                 clientLocale,
                                 traceParent,
                                 authTokenType,
                                 authToken,
                                 microphoneAvailable,
                                 microphoneEnabled,
                                 false,
                                 errorBuffer,
                                 errorBufferLength);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoConvertServerType(int32_t serverType) {
    return convertedServerType(serverType);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoConvertAuthTokenType(const char *tokenType) {
    if (tokenType == nullptr) { return -1; }
    uint32_t authType = 0;
    return authTypeForTokenType(tokenType, authType) ? static_cast<int32_t>(authType) : -1;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoInspectMetadata(const char *geronimoJSON,
                                                               uint32_t index,
                                                               char *keyBuffer,
                                                               size_t keyBufferLength,
                                                               char *valueBuffer,
                                                               size_t valueBufferLength,
                                                               uint32_t *count,
                                                               int32_t *pointersStable,
                                                               char *errorBuffer,
                                                               size_t errorBufferLength) {
    @autoreleasepool {
        auto pending = std::make_unique<PendingStart>();
        std::string error;
        MetadataParseResult result = parseMetadata(jsonDictionary(stringOrEmpty(geronimoJSON)), pending->metadataStrings, error);
        if (result != MetadataParseResult::success) {
            setError(errorBuffer, errorBufferLength, error.c_str());
            return result == MetadataParseResult::overflow ? -2 : -1;
        }
        std::unique_ptr<PendingStart> deferred = std::move(pending);
        std::vector<std::string> unrelatedAllocations(256, std::string(256, 'x'));
        static_cast<void>(unrelatedAllocations);
        materializeMetadataPointers(*deferred);
        bool stable = deferred->parameters.metadataCount == deferred->metadataStrings.size();
        for (size_t pairIndex = 0; stable && pairIndex < deferred->metadataStrings.size(); ++pairIndex) {
            const NVbKeyValuePair_t &pair = deferred->metadataPointers[pairIndex];
            stable = pair.key == deferred->metadataStrings[pairIndex].first.c_str() &&
                     pair.value == deferred->metadataStrings[pairIndex].second.c_str();
        }
        if (count != nullptr) { *count = deferred->parameters.metadataCount; }
        if (pointersStable != nullptr) { *pointersStable = stable ? 1 : 0; }
        if (index >= deferred->metadataPointers.size()) {
            if (index == UINT32_MAX) { return 0; }
            setError(errorBuffer, errorBufferLength, "Native Geronimo metadata inspection index is out of range.");
            return -3;
        }
        setError(keyBuffer, keyBufferLength, deferred->metadataPointers[index].key);
        setError(valueBuffer, valueBufferLength, deferred->metadataPointers[index].value);
        return 0;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoResume(void *sessionPointer,
                                                      const char *rawSessionJSON,
                                                      const char *streamingProfileJSON,
                                                      const char *cloudSessionJSON,
                                                      const char *gameLanguage,
                                                      const char *clientAppVersion,
                                                      const char *clientLocale,
                                                      const char *traceParent,
                                                      const char *authTokenType,
                                                      const char *authToken,
                                                      int32_t microphoneAvailable,
                                                      int32_t microphoneEnabled,
                                                      char *errorBuffer,
                                                      size_t errorBufferLength) {
    return startOrResumeGeronimo(sessionPointer,
                                 rawSessionJSON,
                                 streamingProfileJSON,
                                 cloudSessionJSON,
                                 gameLanguage,
                                 clientAppVersion,
                                 clientLocale,
                                 traceParent,
                                 authTokenType,
                                 authToken,
                                 microphoneAvailable,
                                 microphoneEnabled,
                                 true,
                                 errorBuffer,
                                 errorBufferLength);
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoPump(void *sessionPointer,
                                                    int32_t waitTimeoutMilliseconds,
                                                    char *errorBuffer,
                                                    size_t errorBufferLength) {
    @autoreleasepool {
        auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
        if (session == nullptr || session->gridApp == nullptr || session->functions.gridAppProcessEvents == nullptr) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for event pumping.");
            return -1;
        }
        if (![NSThread isMainThread]) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo events must be pumped on the main thread.");
            return -2;
        }
        if (waitTimeoutMilliseconds < 0) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo pump timeout cannot be negative.");
            return -3;
        }
        std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
        try {
            {
                std::lock_guard<std::mutex> stateLock(session->stateMutex);
                if (session->state == NativeSessionState::stopped) { return 1; }
                if (session->state == NativeSessionState::failed) {
                    setError(errorBuffer, errorBufferLength, session->lastError.c_str());
                    return -4;
                }
            }

            session->functions.gridAppProcessEvents(session->gridApp);
            int32_t startResult = completePreparedStart(session);
            if (startResult != 0) {
                std::lock_guard<std::mutex> stateLock(session->stateMutex);
                setError(errorBuffer, errorBufferLength, session->lastError.c_str());
                return startResult;
            }
            {
                std::lock_guard<std::mutex> stateLock(session->stateMutex);
                if (session->state == NativeSessionState::stopped) { return 1; }
                if (session->state == NativeSessionState::failed) {
                    setError(errorBuffer, errorBufferLength, session->lastError.c_str());
                    return -4;
                }
                if (session->state == NativeSessionState::stopping) { return 0; }
            }
            void *eventProcessor = nullptr;
            {
                std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
                eventProcessor = session->eventProcessor;
            }
            if (eventProcessor != nullptr) {
                if (!session->functions.eventProcessorProcessEvents(eventProcessor, waitTimeoutMilliseconds)) {
                    setSessionFailure(session, "SDL requested native Geronimo event-loop shutdown.");
                    emitEvent(session, 70, 0, 0, 0, -6);
                    setError(errorBuffer, errorBufferLength, "SDL requested native Geronimo event-loop shutdown.");
                    return -6;
                }
            }
            {
                std::lock_guard<std::mutex> stateLock(session->stateMutex);
                if (session->state == NativeSessionState::stopped) { return 1; }
                if (session->state == NativeSessionState::failed) {
                    setError(errorBuffer, errorBufferLength, session->lastError.c_str());
                    return -4;
                }
            }
            return 0;
        } catch (...) {
            setSessionFailure(session, "Native Geronimo event pumping raised an unexpected C++ exception.");
            setError(errorBuffer, errorBufferLength, "Native Geronimo event pumping raised an unexpected C++ exception.");
            return -5;
        }
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoPause(void *sessionPointer, char *errorBuffer, size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.pause == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for pause.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    if (session->microphoneRoute != nullptr) {
        std::lock_guard<std::mutex> routeLock(session->microphoneRoute->stateMutex);
        resetVoiceActivity(session->microphoneRoute->vad);
    }
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for pause.");
            return -2;
        }
        session->state = NativeSessionState::pausePending;
    }
    try {
        if (!session->functions.pause(session->gridApp, 0)) {
            {
                std::lock_guard<std::mutex> stateLock(session->stateMutex);
                if (session->state == NativeSessionState::pausePending) { session->state = NativeSessionState::streaming; }
            }
            setError(errorBuffer, errorBufferLength, "GridApp::pauseStreaming failed.");
            return -3;
        }
        return 0;
    } catch (...) {
        {
            std::lock_guard<std::mutex> stateLock(session->stateMutex);
            if (session->state == NativeSessionState::pausePending) { session->state = NativeSessionState::streaming; }
        }
        setError(errorBuffer, errorBufferLength, "GridApp::pauseStreaming raised an unexpected C++ exception.");
        return -4;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSendInput(void *sessionPointer,
                                                         const uint8_t *inputEventBytes,
                                                         size_t inputEventByteCount,
                                                         char *errorBuffer,
                                                         size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.sendInput == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for input.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for input.");
            return -2;
        }
    }
    if (inputEventBytes == nullptr || inputEventByteCount != NvstInputEventSize) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "Native input requires verified NvstInputEvent_t bytes=%zu expected=%zu.", inputEventByteCount, NvstInputEventSize);
        }
        return -3;
    }
    try {
        uint32_t eventType = loadUnaligned<uint32_t>(inputEventBytes, 0);
        if (eventType == 18) {
            uint8_t sourceIndex = loadUnaligned<uint8_t>(inputEventBytes, 0x3e);
            if (sourceIndex >= 4) {
                setError(errorBuffer, errorBufferLength, "Native gamepad input source index is outside the supported range.");
                return -5;
            }
            if (!session->registeredGamepads[sourceIndex]) {
                if (!session->functions.handleGamepadChanged(session->gridApp, sourceIndex, 0xffff, 0xffff, true)) {
                    setError(errorBuffer, errorBufferLength, "Geronimo rejected native gamepad registration.");
                    return -6;
                }
                session->registeredGamepads[sourceIndex] = true;
            }
        }
        session->functions.sendInput(session->gridApp, inputEventBytes);
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "GridApp::sendNvstInputEvent raised an unexpected C++ exception.");
        return -4;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSendAbsoluteMouse(void *sessionPointer,
                                                                  int32_t windowX,
                                                                  int32_t windowY,
                                                                  uint64_t timestampNanoseconds,
                                                                  char *errorBuffer,
                                                                  size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.sendInput == nullptr ||
        session->functions.windowConvertPointToVideoFrame == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for absolute mouse input.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for absolute mouse input.");
            return -2;
        }
    }
    try {
        SDLPoint videoPoint{};
        SDLRect videoFrame{};
        {
            std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
            if (session->window == nullptr) {
                setError(errorBuffer, errorBufferLength, "Native Geronimo window is unavailable for absolute mouse input.");
                return -3;
            }
            session->functions.windowConvertPointToVideoFrame(session->window, SDLPoint{windowX, windowY}, &videoPoint, &videoFrame);
        }
        if (videoFrame.width <= 0 || videoFrame.height <= 0) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo returned an invalid absolute mouse viewport.");
            return -4;
        }
        uint8_t inputEventBytes[NvstInputEventSize] = {};
        storeUnaligned<uint32_t>(inputEventBytes, 0x00, 2);
        storeUnaligned<int32_t>(inputEventBytes, 0x08, 1);
        storeUnaligned<uint16_t>(inputEventBytes, 0x0c, 0x0800);
        storeUnaligned<int32_t>(inputEventBytes, 0x10, videoPoint.x);
        storeUnaligned<int32_t>(inputEventBytes, 0x14, videoPoint.y);
        storeUnaligned<int32_t>(inputEventBytes, 0x18, videoFrame.width);
        storeUnaligned<int32_t>(inputEventBytes, 0x1c, videoFrame.height);
        storeUnaligned<uint64_t>(inputEventBytes, 0x28, timestampNanoseconds / 1'000);
        session->functions.sendInput(session->gridApp, inputEventBytes);
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "GridApp absolute mouse input raised an unexpected C++ exception.");
        return -5;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoTogglePerformanceOverlay(void *sessionPointer,
                                                                         char *errorBuffer,
                                                                         size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.togglePerfIndicator == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for the performance overlay.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for the performance overlay.");
            return -2;
        }
    }
    try {
        session->functions.togglePerfIndicator(session->gridApp);
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "GridApp::togglePerfIndicatorVisibility raised an unexpected C++ exception.");
        return -3;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetStreamingMaxBitrate(void *sessionPointer,
                                                                       uint32_t bitrateKbps,
                                                                       char *errorBuffer,
                                                                       size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->ioInterface == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is unavailable for bitrate control.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) { return -2; }
    }
    if (!session->functions.setStreamingMaxBitrate(session->gridApp, 0, bitrateKbps)) {
        setError(errorBuffer, errorBufferLength, "GridApp rejected the native NVST bitrate update.");
        return -3;
    }
    return session->functions.ioInterfaceGetMaxBitrateKbps(session->ioInterface) == bitrateKbps ? 0 : -4;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetDynamicStreamingMode(void *sessionPointer,
                                                                        uint32_t mode,
                                                                        char *errorBuffer,
                                                                        size_t errorBufferLength) {
    if (mode > 3) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo dynamic streaming mode is invalid.");
        return -1;
    }
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->ioInterface == nullptr) { return -2; }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) { return -3; }
    }
    if (!session->functions.setDynamicStreamingMode(session->gridApp, 0, mode)) {
        setError(errorBuffer, errorBufferLength, "GridApp rejected the native NVST dynamic streaming update.");
        return -4;
    }
    return session->functions.ioInterfaceGetDynamicStreamingMode(session->ioInterface) == mode ? 0 : -5;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetL4SState(void *sessionPointer,
                                                            int32_t enabled,
                                                            char *errorBuffer,
                                                            size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->ioInterface == nullptr) { return -1; }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) { return -2; }
    }
    if (!session->functions.setL4sState(session->gridApp, 0, enabled != 0)) {
        setError(errorBuffer, errorBufferLength, "GridApp rejected the native NVST L4S update.");
        return -3;
    }
    const uint32_t state = session->functions.ioInterfaceGetL4sState(session->ioInterface);
    return state == static_cast<uint32_t>(enabled != 0) ? 0 : -4;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoCopyPerformanceStats(void *sessionPointer,
                                                                    void *performanceStatsBytes,
                                                                    size_t performanceStatsByteCount,
                                                                    char *serverLocationBuffer,
                                                                    size_t serverLocationBufferLength,
                                                                    char *errorBuffer,
                                                                    size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (performanceStatsBytes == nullptr || performanceStatsByteCount != sizeof(OpenNOWNativeNVSTPerformanceStats)) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "Native Geronimo performance stats require %zu output bytes.", sizeof(OpenNOWNativeNVSTPerformanceStats));
        }
        return -1;
    }
    if (serverLocationBuffer != nullptr && serverLocationBufferLength > 0) { serverLocationBuffer[0] = '\0'; }
    if (session == nullptr || session->ioInterface == nullptr ||
        session->functions.ioInterfaceGetStatsInterface == nullptr || session->functions.statsInterfaceGetStats == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for performance stats.");
        return -2;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for performance stats.");
            return -3;
        }
    }
    try {
        void *statsInterface = session->functions.ioInterfaceGetStatsInterface(session->ioInterface);
        if (statsInterface == nullptr) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stats interface is unavailable.");
            return -4;
        }
        GeronimoStats rawStats{};
        std::string gpuType;
        std::string rendererType;
        std::string clientAppVersion;
        std::string locale;
        std::string region;
        std::string zone;
        session->functions.statsInterfaceGetStats(statsInterface, rawStats, gpuType, rendererType, clientAppVersion, locale, region, zone);

        OpenNOWNativeNVSTPerformanceStats performanceStats;
        const uint32_t bitrateKilobitsPerSecond = loadUnaligned<uint32_t>(rawStats.bytes, 0xa0);
        const double gameFramesPerSecond = loadUnaligned<double>(rawStats.bytes, 0x410);
        const bool hasLiveStats = bitrateKilobitsPerSecond > 0 || (std::isfinite(gameFramesPerSecond) && gameFramesPerSecond > 0);
        const uint32_t currentWidth = loadUnaligned<uint16_t>(rawStats.bytes, 0x3ea);
        const uint32_t currentHeight = loadUnaligned<uint16_t>(rawStats.bytes, 0x3ec);
        performanceStats.available = hasLiveStats ? 1 : 0;
        performanceStats.frameWidth = currentWidth > 0 ? currentWidth : loadUnaligned<uint16_t>(rawStats.bytes, 0x3e4);
        performanceStats.frameHeight = currentHeight > 0 ? currentHeight : loadUnaligned<uint16_t>(rawStats.bytes, 0x3e6);
        performanceStats.streamFramesPerSecond = loadUnaligned<uint16_t>(rawStats.bytes, 0x3e8);
        performanceStats.codec = loadUnaligned<uint32_t>(rawStats.bytes, 0x3bc);
        performanceStats.frameLoss = loadUnaligned<uint32_t>(rawStats.bytes, 0x3f0);
        performanceStats.totalFrameLoss = loadUnaligned<uint32_t>(rawStats.bytes, 0x08);
        performanceStats.packetLoss = loadUnaligned<uint32_t>(rawStats.bytes, 0xa8);
        performanceStats.totalPacketLoss = loadUnaligned<uint32_t>(rawStats.bytes, 0x3f4);
        performanceStats.gameFramesPerSecond = std::isfinite(gameFramesPerSecond) && gameFramesPerSecond >= 0 ? gameFramesPerSecond : -1;
        if (hasLiveStats) {
            const int32_t jitterMicroseconds = loadUnaligned<int32_t>(rawStats.bytes, 0x24);
            performanceStats.latencyMilliseconds = loadUnaligned<uint32_t>(rawStats.bytes, 0xac);
            performanceStats.jitterMilliseconds = jitterMicroseconds >= 0 ? static_cast<double>(jitterMicroseconds) / 1'000.0 : -1;
            performanceStats.bitrateMegabitsPerSecond = static_cast<double>(bitrateKilobitsPerSecond) / 1'000.0;
            performanceStats.bandwidthUtilizationPercent = loadUnaligned<uint32_t>(rawStats.bytes, 0xa4);
        }
        const std::string &serverLocation = zone.empty() ? region : zone;
        if (serverLocationBuffer != nullptr && serverLocationBufferLength > 0) {
            snprintf(serverLocationBuffer, serverLocationBufferLength, "%s", serverLocation.c_str());
        }
        memcpy(performanceStatsBytes, &performanceStats, sizeof(performanceStats));
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "Reading native Geronimo performance stats raised an unexpected C++ exception.");
        return -5;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSendText(void *sessionPointer,
                                                        const uint8_t *utf8Bytes,
                                                        size_t utf8ByteCount,
                                                        char *errorBuffer,
                                                        size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->functions.sendInput == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for text input.");
        return -1;
    }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state != NativeSessionState::streaming) {
            setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for text input.");
            return -2;
        }
    }
    if (utf8Bytes == nullptr || utf8ByteCount == 0 || utf8ByteCount > UINT16_MAX) {
        setError(errorBuffer, errorBufferLength, "Native text input must contain between 1 and 65535 UTF-8 bytes.");
        return -3;
    }
    alignas(8) uint8_t eventBytes[NvstInputEventSize] = {};
    storeUnaligned<uint32_t>(eventBytes, 0x00, 20);
    storeUnaligned<const uint8_t *>(eventBytes, 0x08, utf8Bytes);
    storeUnaligned<uint16_t>(eventBytes, 0x10, static_cast<uint16_t>(utf8ByteCount));
    try {
        session->functions.sendInput(session->gridApp, eventBytes);
        return 0;
    } catch (...) {
        setError(errorBuffer, errorBufferLength, "GridApp::sendNvstInputEvent raised an unexpected text-input exception.");
        return -4;
    }
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoStopWithResult(void *sessionPointer,
                                                              const char *reason,
                                                              int32_t code,
                                                              char *errorBuffer,
                                                              size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return 0; }
    std::lock_guard<std::recursive_mutex> operationLock(session->operationMutex);
    if (session->microphoneRoute != nullptr) {
        std::lock_guard<std::mutex> routeLock(session->microphoneRoute->stateMutex);
        resetVoiceActivity(session->microphoneRoute->vad);
    }
    bool completesImmediately = false;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        if (session->state == NativeSessionState::stopping || session->state == NativeSessionState::stopped) { return 0; }
        completesImmediately = session->state == NativeSessionState::created ||
                               session->state == NativeSessionState::configured ||
                               session->state == NativeSessionState::failed;
        session->stopIssued = true;
        session->state = completesImmediately ? NativeSessionState::stopped : NativeSessionState::stopping;
        session->pendingStart.reset();
    }
    if (completesImmediately) {
        emitEvent(session, 60, 0, 0, 0, code);
        return 0;
    }
    try {
        if (session->gridApp == nullptr || session->functions.stop == nullptr ||
            !session->functions.stop(session->gridApp, reason == nullptr ? "OpenNOW native NVST stop" : reason, code)) {
            setSessionFailure(session, "GridApp::stop rejected the native stop request.");
            setError(errorBuffer, errorBufferLength, "GridApp::stop rejected the native stop request.");
            emitEvent(session, 70, 0, 0, 0, -2);
            return -2;
        }
        return 0;
    } catch (...) {
        setSessionFailure(session, "GridApp::stop raised an unexpected C++ exception.");
        setError(errorBuffer, errorBufferLength, "GridApp::stop raised an unexpected C++ exception.");
        emitEvent(session, 70, 0, 0, 0, -2);
        return -2;
    }
}

extern "C" void OpenNOWNativeNVSTGeronimoStop(void *sessionPointer) {
    OpenNOWNativeNVSTGeronimoStopWithResult(sessionPointer, "OpenNOW native NVST stop", 0, nullptr, 0);
}

extern "C" void OpenNOWNativeNVSTGeronimoDestroy(void *sessionPointer) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return; }
    std::unique_lock<std::recursive_mutex> operationLock(session->operationMutex);
    if (session->hapticFeatureEnabled && session->functions.controlFeatures != nullptr) {
        try { session->functions.controlFeatures(session->gridApp, NVbFeatureGamepadHaptics, 0); }
        catch (...) { fprintf(stderr, "OpenNOW failed to disable native haptics during teardown.\n"); }
    }
    session->hapticFeatureEnabled = false;
    for (uint8_t sourceIndex = 0; sourceIndex < 4; ++sourceIndex) {
        if (session->registeredGamepads[sourceIndex] && session->functions.handleGamepadChanged != nullptr) {
            try { session->functions.handleGamepadChanged(session->gridApp, sourceIndex, 0xffff, 0xffff, false); }
            catch (...) { fprintf(stderr, "OpenNOW failed to disconnect a native gamepad during teardown.\n"); }
        }
        session->registeredGamepads[sourceIndex] = false;
    }
    NativeSessionState state;
    {
        std::lock_guard<std::mutex> stateLock(session->stateMutex);
        state = session->state;
    }
    if (state != NativeSessionState::created && state != NativeSessionState::configured && state != NativeSessionState::paused &&
        state != NativeSessionState::stopped && state != NativeSessionState::failed && session->functions.stop != nullptr) {
        try {
            session->functions.stop(session->gridApp, "OpenNOW native NVST forced destroy", 0);
        } catch (...) {
            fprintf(stderr, "OpenNOW forced native stop raised an unexpected C++ exception.\n");
        }
    }
    if (session->gridAppVTable != nullptr) { detachGridAppCallbacks(session); }
    {
        std::lock_guard<std::mutex> eventLock(session->eventMutex);
        session->eventHandler = nullptr;
        session->eventContext = nullptr;
    }
    {
        std::lock_guard<std::mutex> handlerLock(session->runtimeHandlerMutex);
        session->hapticHandler = nullptr;
        session->hapticContext = nullptr;
        session->authRefreshHandler = nullptr;
        session->authRefreshContext = nullptr;
    }
    try { teardownPlatformMedia(session); }
    catch (...) { fprintf(stderr, "OpenNOW native media destruction raised an unexpected C++ exception.\n"); }
    if (session->microphoneRoute != nullptr) {
        unregisterMicrophoneRoute(session->microphoneRoute);
        session->microphoneRoute = nullptr;
    }
    if (session->microphoneHookLeaseAcquired) {
        releaseMicrophoneHook();
        session->microphoneHookLeaseAcquired = false;
    }
    if (session->gridApp != nullptr) {
        if (session->initialized && session->functions.gridAppDtor != nullptr) {
            try {
                session->functions.gridAppDtor(session->gridApp);
            } catch (...) {
                fprintf(stderr, "OpenNOW GridApp destruction raised an unexpected C++ exception.\n");
            }
        }
        session->initialized = false;
        free(session->gridApp);
        session->gridApp = nullptr;
    }
    if (session->platformStarted && session->platformShutdown != nullptr) {
        try {
            releasePlatform(session->platformShutdown);
        } catch (...) {
            fprintf(stderr, "OpenNOW Geronimo platform shutdown raised an unexpected C++ exception.\n");
        }
        session->platformStarted = false;
    }
    if (session->gridAppVTable != nullptr) {
        free(session->gridAppVTable);
        session->gridAppVTable = nullptr;
    }
    CFTypeRef videoSurfaceHandle = nullptr;
    {
        std::lock_guard<std::mutex> mediaLock(session->mediaMutex);
        videoSurfaceHandle = session->videoSurfaceHandle;
        session->videoSurfaceHandle = nullptr;
    }
    if (videoSurfaceHandle != nullptr) { CFRelease(videoSurfaceHandle); }
    if (session->libraryHandle != nullptr) {
        dlclose(session->libraryHandle);
        session->libraryHandle = nullptr;
    }
    if (session->bifrostHandle != nullptr) {
        dlclose(session->bifrostHandle);
        session->bifrostHandle = nullptr;
    }
    operationLock.unlock();
    delete session;
}
