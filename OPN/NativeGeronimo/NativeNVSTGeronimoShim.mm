#import <Foundation/Foundation.h>

#include <stdint.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cctype>
#include <new>
#include <string>
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

namespace SessionControl {
struct PrepareParameters {
    std::string serverAddress;
    uint32_t serverPort = 0;
    uint32_t clientProfile = 0;
    std::string appId;
    alignas(4) unsigned char communicationParams[0x2c] = {};
    bool synchronous = true;
    unsigned char pad65[3] = {};
    int32_t serverType = 0x34;
    unsigned char pad6c[4] = {};
    std::string locale;
    std::string sslCertificate;
    std::string sslPrivateKey;
    std::string deviceId;
    std::string platform;
    std::string clientName;
    std::string clientAppVersion;
    std::vector<std::string> applicationHeaders;
};

struct SessionParameters {
    uint32_t appId = 0;
    uint32_t pad04 = 0;
    std::string serverAddress;
    uint32_t serverPort = 0;
    uint32_t sessionMode = 0;
    unsigned char pad28[0x0c] = {};
    uint32_t streamSettingsCount = 0;
    uint64_t reserved38 = 0;
    uint64_t supportedHidTypes = 0;
    Nsk::NVbStreamSettings_t *streamSettings = nullptr;
    Nsk::NVbStreamSettings_t defaultStreamSettings;
    unsigned char pad1c0[0x0c] = {};
    uint32_t configurationProfile = 0;
    void *metadata = nullptr;
    uint32_t metadataCount = 0;
    bool useL4S = false;
    unsigned char pad1dd[0x0b] = {};
    std::string clientAppVersion;
    std::string region;
    std::string clientLocale;
    uint32_t keyboardLayoutMode = 0;
    bool keyboardLayoutAutomatic = false;
    unsigned char pad235[3] = {};
    std::string keyboardLayout;
    std::string streamingSessionId;
    std::vector<Nsk::NVbConnectionInfo_t> connectionInfo;
    uint32_t connectionInfoFlags = 0;
};
}

static_assert(sizeof(std::string) == 0x18, "libGeronimo std::string ABI changed");
static_assert(sizeof(Nsk::DownstreamVideoSettings) == 0x90, "libGeronimo DownstreamVideoSettings ABI changed");
static_assert(sizeof(Nsk::AudioStreamSettings) == 0x2, "libGeronimo AudioStreamSettings ABI changed");
static_assert(sizeof(Nsk::StreamConnectionInfo) == 0x28, "libGeronimo StreamConnectionInfo ABI changed");
static_assert(sizeof(Nsk::NVbStreamSettings_t) == 0x170, "libGeronimo NVbStreamSettings_t ABI changed");
static_assert(sizeof(Nsk::NVbConnectionInfo_t) == 0x40c, "libGeronimo NVbConnectionInfo_t ABI changed");
static_assert(sizeof(Nsk::NVbTracingContext_t) == 0x20, "libGeronimo NVbTracingContext_t ABI changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, gameLanguage) == 0x30, "libGeronimo gameLanguage offset changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, clientAppVersion) == 0x48, "libGeronimo clientAppVersion offset changed");
static_assert(offsetof(Nsk::ApplicationStreamStartParameters, clientLocale) == 0x60, "libGeronimo clientLocale offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, videoSettings) == 0xd8, "libGeronimo videoSettings offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, audioSettings) == 0xf0, "libGeronimo audioSettings offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, connectionType) == 0x108, "libGeronimo connectionType offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, connectionInfo) == 0x120, "libGeronimo connectionInfo offset changed");
static_assert(offsetof(Nsk::StreamStartParameters, unknown180) == 0x180, "libGeronimo StreamStartParameters ABI changed");
static_assert(offsetof(SessionControl::PrepareParameters, appId) == 0x20, "libGeronimo PrepareParameters appId offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, communicationParams) == 0x38, "libGeronimo PrepareParameters communicationParams offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, locale) == 0x70, "libGeronimo PrepareParameters locale offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, sslCertificate) == 0x88, "libGeronimo PrepareParameters sslCertificate offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, sslPrivateKey) == 0xa0, "libGeronimo PrepareParameters sslPrivateKey offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, deviceId) == 0xb8, "libGeronimo PrepareParameters deviceId offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, platform) == 0xd0, "libGeronimo PrepareParameters platform offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, clientName) == 0xe8, "libGeronimo PrepareParameters clientName offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, clientAppVersion) == 0x100, "libGeronimo PrepareParameters clientAppVersion offset changed");
static_assert(offsetof(SessionControl::PrepareParameters, applicationHeaders) == 0x118, "libGeronimo PrepareParameters applicationHeaders offset changed");
static_assert(offsetof(SessionControl::SessionParameters, serverAddress) == 0x08, "libGeronimo SessionParameters serverAddress offset changed");
static_assert(offsetof(SessionControl::SessionParameters, serverPort) == 0x20, "libGeronimo SessionParameters serverPort offset changed");
static_assert(offsetof(SessionControl::SessionParameters, streamSettingsCount) == 0x34, "libGeronimo SessionParameters streamSettingsCount offset changed");
static_assert(offsetof(SessionControl::SessionParameters, supportedHidTypes) == 0x40, "libGeronimo SessionParameters supportedHidTypes offset changed");
static_assert(offsetof(SessionControl::SessionParameters, streamSettings) == 0x48, "libGeronimo SessionParameters streamSettings offset changed");
static_assert(offsetof(SessionControl::SessionParameters, defaultStreamSettings) == 0x50, "libGeronimo SessionParameters defaultStreamSettings offset changed");
static_assert(offsetof(SessionControl::SessionParameters, clientAppVersion) == 0x1e8, "libGeronimo SessionParameters clientAppVersion offset changed");
static_assert(offsetof(SessionControl::SessionParameters, clientLocale) == 0x218, "libGeronimo SessionParameters clientLocale offset changed");
static_assert(offsetof(SessionControl::SessionParameters, keyboardLayout) == 0x238, "libGeronimo SessionParameters keyboardLayout offset changed");
static_assert(offsetof(SessionControl::SessionParameters, streamingSessionId) == 0x250, "libGeronimo SessionParameters streamingSessionId offset changed");
static_assert(offsetof(SessionControl::SessionParameters, connectionInfo) == 0x268, "libGeronimo SessionParameters connectionInfo offset changed");
static_assert(offsetof(SessionControl::SessionParameters, connectionInfoFlags) == 0x280, "libGeronimo SessionParameters connectionInfoFlags offset changed");

namespace {
constexpr size_t GridAppStorageSize = 0x2000;

using NskPlatformStartup = bool (*)(const Nsk::PlatformStartupParams &);
using PlatformShutdown = void (*)();
using GridAppCtor = void (*)(void *);
using GridAppInitialize = void *(*)(void *, bool);
using GridAppUninitialize = void (*)(void *);
using GridAppStop = void (*)(void *, const char *, int);
using GridAppPause = bool (*)(void *);
using GridAppPrepare = bool (*)(void *, const SessionControl::PrepareParameters &);
using GridAppSetAuthInfo = bool (*)(void *, void *);
using GridAppStart = bool (*)(void *, const SessionControl::SessionParameters &, const Nsk::NVbTracingContext_t &);
using GridAppSendInput = void (*)(void *, const void *);
using GridAppOnNVbCallback = void (*)(void *, uint32_t, void *);
using GetStreamStartParameters = int (*)(const std::string &, const std::string &, const Nsk::ApplicationStreamStartParameters &, Nsk::StreamStartParameters &);
using ConvertToStreamingParams = bool (*)(const Nsk::StreamStartParameters &, const Nsk::VideoDecoderInitParams &, Nsk::NVbStreamingParams_t &);
using FreeStreamingParams = void (*)(Nsk::NVbStreamingParams_t &);
using OpenNOWGeronimoEventHandler = void (*)(void *, int32_t, uint32_t, uint32_t, uint32_t, int32_t);
using NVbCallbackFunction = void (*)(void *, uint32_t, void *);

struct NVbResult_t {
    int32_t code = 0;
    unsigned char bytes[0x10] = {};
};

using NVbRegisterCallback = NVbResult_t (*)(void *, void *, NVbCallbackFunction);

constexpr size_t NvstInputEventSize = 0x48;
constexpr size_t GridAppBifrostClientOffset = 0x18;
constexpr uint32_t NVbCallbackTypeEvent = 2;
constexpr uint32_t NVbClientEventSessionNotification = 0x0e;

struct NVbAuthInfo_t {
    const char *token = nullptr;
    uintptr_t authType = 0;
};

static_assert(sizeof(NVbResult_t) == 0x14, "libBifrost2 NVbResult_t ABI changed");
static_assert(sizeof(NVbAuthInfo_t) == 0x10, "libGeronimo NVbAuthInfo_t ABI changed");

struct OpenNOWNativeNVSTGeronimoSession {
    void *libraryHandle = nullptr;
    void *bifrostHandle = nullptr;
    void *gridApp = nullptr;
    PlatformShutdown platformShutdown = nullptr;
    GridAppUninitialize uninitialize = nullptr;
    GridAppStop stop = nullptr;
    GridAppPause pause = nullptr;
    GridAppSendInput sendInput = nullptr;
    GridAppOnNVbCallback gridAppOnNVbCallback = nullptr;
    OpenNOWGeronimoEventHandler eventHandler = nullptr;
    void *eventContext = nullptr;
    bool platformStarted = false;
    bool initialized = false;
    bool streaming = false;
    std::string initServerAddress;
    std::string startServerAddress;
    std::string sessionId;
    std::string appIdString;
    std::string authToken;
    std::string clientAppVersion;
    std::string clientLocale;
    std::string keyboardLayout;
    std::string deviceId;
    std::string osVersion;
    std::string platform;
};

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

void emitEvent(OpenNOWNativeNVSTGeronimoSession *session, int32_t phase, uint32_t callbackType, uint32_t clientEvent, uint32_t notification, int32_t resultCode) {
    if (session == nullptr || session->eventHandler == nullptr) { return; }
    session->eventHandler(session->eventContext, phase, callbackType, clientEvent, notification, resultCode);
}

void openNOWGeronimoNVbCallback(void *context, uint32_t callbackType, void *callbackData) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(context);
    uint32_t clientEvent = 0;
    uint32_t notification = 0;
    if (callbackData != nullptr && callbackType == NVbCallbackTypeEvent) {
        clientEvent = loadUnaligned<uint32_t>(callbackData, 0);
        if (clientEvent == NVbClientEventSessionNotification) {
            notification = loadUnaligned<uint32_t>(callbackData, 8);
        }
    }
    emitEvent(session, 30, callbackType, clientEvent, notification, 0);
    if (session != nullptr && session->gridAppOnNVbCallback != nullptr && session->gridApp != nullptr) {
        session->gridAppOnNVbCallback(session->gridApp, callbackType, callbackData);
    }
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

HostAndPort hostAndPort(const std::string &address) {
    HostAndPort result;
    std::string value = address;
    size_t scheme = value.find("://");
    if (scheme != std::string::npos) { value = value.substr(scheme + 3); }
    size_t path = value.find('/');
    if (path != std::string::npos) { value = value.substr(0, path); }
    size_t at = value.rfind('@');
    if (at != std::string::npos) { value = value.substr(at + 1); }
    size_t colon = value.rfind(':');
    if (colon != std::string::npos && colon + 1 < value.size()) {
        std::string portString = value.substr(colon + 1);
        bool numeric = true;
        for (char character : portString) {
            if (!std::isdigit(static_cast<unsigned char>(character))) { numeric = false; break; }
        }
        if (numeric) {
            int parsed = atoi(portString.c_str());
            if (parsed > 0 && parsed <= 65535) { result.port = static_cast<uint16_t>(parsed); }
            value = value.substr(0, colon);
        }
    }
    if (value.size() > 1 && value.front() == '[' && value.back() == ']') { value = value.substr(1, value.size() - 2); }
    result.host = value;
    return result;
}

uint32_t authTypeForTokenType(const std::string &tokenType) {
    std::string lowered = tokenType;
    for (char &character : lowered) { character = static_cast<char>(std::tolower(static_cast<unsigned char>(character))); }
    if (lowered.find("jarvis") != std::string::npos) { return 8; }
    return 9;
}

void *resolve(void *handle, const char *symbol, char *errorBuffer, size_t errorBufferLength) {
    dlerror();
    void *address = dlsym(handle, symbol);
    if (address == nullptr) { setDLError(errorBuffer, errorBufferLength, symbol); }
    return address;
}
}

extern "C" void *OpenNOWNativeNVSTGeronimoCreate(const char *frameworksPath, char *errorBuffer, size_t errorBufferLength) {
    std::string directory = stringOrEmpty(frameworksPath);
    if (directory.empty()) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo NVST frameworks path is empty.");
        return nullptr;
    }
    std::string libraryPath = directory + "/libGeronimo.dylib";
    void *handle = dlopen(libraryPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        setDLError(errorBuffer, errorBufferLength, "dlopen libGeronimo.dylib failed");
        return nullptr;
    }
    std::string bifrostPath = directory + "/libBifrost2.dylib";
    void *bifrostHandle = dlopen(bifrostPath.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (bifrostHandle == nullptr) {
        setDLError(errorBuffer, errorBufferLength, "dlopen libBifrost2.dylib failed");
        dlclose(handle);
        return nullptr;
    }

    auto ctor = reinterpret_cast<GridAppCtor>(resolve(handle, "_ZN7GridAppC2Ev", errorBuffer, errorBufferLength));
    auto platformStartup = reinterpret_cast<NskPlatformStartup>(resolve(handle, "_ZN3Nsk15platformStartupERKNS_21PlatformStartupParamsE", errorBuffer, errorBufferLength));
    auto platformShutdown = reinterpret_cast<PlatformShutdown>(resolve(handle, "_ZN3Nsk16platformShutdownEv", errorBuffer, errorBufferLength));
    auto initialize = reinterpret_cast<GridAppInitialize>(resolve(handle, "_ZN7GridApp10initializeEb", errorBuffer, errorBufferLength));
    auto uninitialize = reinterpret_cast<GridAppUninitialize>(resolve(handle, "_ZN7GridApp12uninitializeEv", errorBuffer, errorBufferLength));
    auto stop = reinterpret_cast<GridAppStop>(resolve(handle, "_ZN7GridApp4stopEPKci", errorBuffer, errorBufferLength));
    auto pause = reinterpret_cast<GridAppPause>(resolve(handle, "_ZN7GridApp5pauseEv", errorBuffer, errorBufferLength));
    auto sendInput = reinterpret_cast<GridAppSendInput>(resolve(handle, "_ZN7GridApp18sendNvstInputEventERK16NvstInputEvent_t", errorBuffer, errorBufferLength));
    if (ctor == nullptr || platformStartup == nullptr || platformShutdown == nullptr || initialize == nullptr || uninitialize == nullptr || stop == nullptr || pause == nullptr || sendInput == nullptr) {
        dlclose(bifrostHandle);
        dlclose(handle);
        return nullptr;
    }

    Nsk::PlatformStartupParams platformParams;
    if (!platformStartup(platformParams)) {
        setError(errorBuffer, errorBufferLength, "Geronimo platform startup failed.");
        dlclose(bifrostHandle);
        dlclose(handle);
        return nullptr;
    }

    void *gridApp = aligned_alloc(16, GridAppStorageSize);
    if (gridApp == nullptr) {
        setError(errorBuffer, errorBufferLength, "Failed to allocate GridApp storage.");
        platformShutdown();
        dlclose(bifrostHandle);
        dlclose(handle);
        return nullptr;
    }
    memset(gridApp, 0, GridAppStorageSize);
    ctor(gridApp);
    if (initialize(gridApp, true) == nullptr) {
        setError(errorBuffer, errorBufferLength, "GridApp initialization failed.");
        uninitialize(gridApp);
        free(gridApp);
        platformShutdown();
        dlclose(bifrostHandle);
        dlclose(handle);
        return nullptr;
    }

    auto *session = new (std::nothrow) OpenNOWNativeNVSTGeronimoSession();
    if (session == nullptr) {
        setError(errorBuffer, errorBufferLength, "Failed to allocate native Geronimo session.");
        uninitialize(gridApp);
        free(gridApp);
        platformShutdown();
        dlclose(bifrostHandle);
        dlclose(handle);
        return nullptr;
    }
    session->libraryHandle = handle;
    session->bifrostHandle = bifrostHandle;
    session->gridApp = gridApp;
    session->platformShutdown = platformShutdown;
    session->uninitialize = uninitialize;
    session->stop = stop;
    session->pause = pause;
    session->sendInput = sendInput;
    session->platformStarted = true;
    session->initialized = true;
    return session;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSetEventHandler(void *sessionPointer,
                                                              OpenNOWGeronimoEventHandler eventHandler,
                                                              void *eventContext,
                                                              char *errorBuffer,
                                                              size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->bifrostHandle == nullptr || session->libraryHandle == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for callback registration.");
        return -1;
    }

    auto registerCallback = reinterpret_cast<NVbRegisterCallback>(resolve(session->bifrostHandle, "nvbRegisterCallback", errorBuffer, errorBufferLength));
    auto gridAppCallback = reinterpret_cast<GridAppOnNVbCallback>(resolve(session->libraryHandle, "_ZN7GridApp13onNVbCallbackEPv17NVbCallbackType_tP17NVbCallbackData_t", errorBuffer, errorBufferLength));
    if (registerCallback == nullptr || gridAppCallback == nullptr) { return -2; }

    void *client = loadUnaligned<void *>(session->gridApp, GridAppBifrostClientOffset);
    if (client == nullptr) {
        setError(errorBuffer, errorBufferLength, "GridApp Bifrost client is unavailable for callback registration.");
        return -3;
    }

    session->eventHandler = eventHandler;
    session->eventContext = eventContext;
    session->gridAppOnNVbCallback = gridAppCallback;

    NVbResult_t result = registerCallback(client, session, openNOWGeronimoNVbCallback);
    if (result.code != 0) {
        session->eventHandler = nullptr;
        session->eventContext = nullptr;
        session->gridAppOnNVbCallback = nullptr;
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "nvbRegisterCallback wrapper failed result=0x%08x.", result.code);
        }
        return result.code;
    }

    emitEvent(session, 20, 0, 0, 0, 0);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoStart(void *sessionPointer,
                                                    const char *rawSessionJSON,
                                                    const char *streamingProfileJSON,
                                                    const char *cloudSessionJSON,
                                                    const char *gameLanguage,
                                                    const char *clientAppVersion,
                                                    const char *clientLocale,
                                                    const char *traceParent,
                                                    char *errorBuffer,
                                                    size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->libraryHandle == nullptr || session->gridApp == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized.");
        return -1;
    }
    auto getParameters = reinterpret_cast<GetStreamStartParameters>(resolve(session->libraryHandle, "_ZN3Nsk24getStreamStartParametersERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEES8_RKNS_32ApplicationStreamStartParametersERNS_21StreamStartParametersE", errorBuffer, errorBufferLength));
    auto prepare = reinterpret_cast<GridAppPrepare>(resolve(session->libraryHandle, "_ZN7GridApp7prepareERKN14SessionControl17PrepareParametersE", errorBuffer, errorBufferLength));
    auto setAuthInfo = reinterpret_cast<GridAppSetAuthInfo>(resolve(session->libraryHandle, "_ZN7GridApp11setAuthInfoER13NVbAuthInfo_t", errorBuffer, errorBufferLength));
    auto start = reinterpret_cast<GridAppStart>(resolve(session->libraryHandle, "_ZN7GridApp5startERKN14SessionControl17SessionParametersERK19NVbTracingContext_t", errorBuffer, errorBufferLength));
    auto convertToStreamingParams = reinterpret_cast<ConvertToStreamingParams>(resolve(session->libraryHandle, "_ZN3Nsk24convertToStreamingParamsERKNS_21StreamStartParametersERKNS_22VideoDecoderInitParamsER20NVbStreamingParams_t", errorBuffer, errorBufferLength));
    auto freeStreamingParams = reinterpret_cast<FreeStreamingParams>(resolve(session->libraryHandle, "_ZN3Nsk4freeER20NVbStreamingParams_t", errorBuffer, errorBufferLength));
    if (getParameters == nullptr || prepare == nullptr || setAuthInfo == nullptr || start == nullptr || convertToStreamingParams == nullptr || freeStreamingParams == nullptr) { return -2; }

    std::string rawSession = stringOrEmpty(rawSessionJSON);
    std::string streamingProfile = stringOrEmpty(streamingProfileJSON);
    std::string cloudSession = stringOrEmpty(cloudSessionJSON);
    if (rawSession.empty() || streamingProfile.empty() || cloudSession.empty()) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo start requires normalized session JSON, streaming profile JSON, and Cloud session JSON.");
        return -3;
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
    NSDictionary *geronimo = jsonDictionary(rawSession);
    NSDictionary *profile = jsonDictionary(streamingProfile);
    const char *const tokenPaths[] = { "token", "authToken", "jwt", "auth.token", "sessionToken" };
    const char *const tokenTypePaths[] = { "tokenType", "authType", "auth.type" };
    const char *const serverPaths[] = { "serverAddress", "sessionControlInfo.ip", "zoneAddress" };
    const char *const sessionPaths[] = { "session", "sessionId" };
    session->authToken = firstNonEmptyString(cloud, geronimo, tokenPaths, sizeof(tokenPaths) / sizeof(tokenPaths[0]));
    std::string tokenType = firstNonEmptyString(cloud, geronimo, tokenTypePaths, sizeof(tokenTypePaths) / sizeof(tokenTypePaths[0]));
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
    HostAndPort endpoint = hostAndPort(serverAddress);
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
    if (session->keyboardLayout.empty()) { session->keyboardLayout = "us"; }
    session->deviceId = jsonStringAtPath(geronimo, "deviceId");
    if (session->deviceId.empty()) { session->deviceId = "OpenNOW"; }
    session->osVersion = "macOS";
    session->platform = "DESKTOP";

    SessionControl::PrepareParameters prepareParameters;
    prepareParameters.serverAddress = session->initServerAddress;
    prepareParameters.serverPort = endpoint.port;
    prepareParameters.clientProfile = 0;
    prepareParameters.appId = session->appIdString;
    prepareParameters.synchronous = true;
    prepareParameters.serverType = 0x34;
    prepareParameters.locale = session->clientLocale;
    prepareParameters.deviceId = session->deviceId;
    prepareParameters.platform = session->platform;
    prepareParameters.clientName = "OpenNOW";
    prepareParameters.clientAppVersion = session->clientAppVersion;
    if (!prepare(session->gridApp, prepareParameters)) {
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

    NVbAuthInfo_t authInfo;
    authInfo.token = session->authToken.c_str();
    authInfo.authType = authTypeForTokenType(tokenType);
    if (!setAuthInfo(session->gridApp, &authInfo)) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "GridApp::setAuthInfo failed authType=%lu.", static_cast<unsigned long>(authInfo.authType));
        }
        return -6;
    }

    Nsk::VideoDecoderInitParams decoderParams;
    memset(decoderParams.bytes, 0, sizeof(decoderParams.bytes));
    Nsk::NVbStreamingParams_t streamingParams;
    memset(streamingParams.bytes, 0, sizeof(streamingParams.bytes));
    if (!convertToStreamingParams(startParameters, decoderParams, streamingParams)) {
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

    SessionControl::SessionParameters sessionParameters;
    sessionParameters.appId = appId;
    sessionParameters.serverAddress = session->startServerAddress;
    sessionParameters.serverPort = endpoint.port;
    sessionParameters.sessionMode = 0;
    sessionParameters.streamSettingsCount = loadField<uint32_t>(streamingParams, 0x28);
    sessionParameters.streamSettings = loadField<Nsk::NVbStreamSettings_t *>(streamingParams, 0x30);
    if (sessionParameters.streamSettingsCount > 0 && sessionParameters.streamSettings != nullptr) {
        memcpy(&sessionParameters.defaultStreamSettings, sessionParameters.streamSettings, sizeof(sessionParameters.defaultStreamSettings));
    }
    sessionParameters.clientAppVersion = session->clientAppVersion;
    sessionParameters.region = session->startServerAddress;
    sessionParameters.clientLocale = session->clientLocale;
    sessionParameters.keyboardLayout = session->keyboardLayout;
    sessionParameters.streamingSessionId = session->sessionId;
    uint32_t connectionCount = loadField<uint32_t>(streamingParams, 0x168);
    Nsk::NVbConnectionInfo_t *connections = loadField<Nsk::NVbConnectionInfo_t *>(streamingParams, 0x170);
    if (connectionCount > 0 && connections != nullptr) {
        sessionParameters.connectionInfo.assign(connections, connections + connectionCount);
    }

    Nsk::NVbTracingContext_t tracingContext;
    std::string traceParentStorage = stringOrEmpty(traceParent);
    tracingContext.traceParent = traceParentStorage.c_str();
    bool startResult = start(session->gridApp, sessionParameters, tracingContext);
    freeStreamingParams(streamingParams);
    if (!startResult) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer,
                     errorBufferLength,
                     "GridApp::start failed appId=%u sessionId=%s server=%s:%u videoSettings=%u connectionInfo=%u.",
                     appId,
                     session->sessionId.empty() ? "missing" : "present",
                     session->startServerAddress.c_str(),
                     endpoint.port,
                     sessionParameters.streamSettingsCount,
                     connectionCount);
        }
        return -8;
    }
    session->streaming = true;
    emitEvent(session, 40, 0, 0, 0, 0);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoPause(void *sessionPointer, char *errorBuffer, size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->pause == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for pause.");
        return -1;
    }
    if (!session->streaming) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for pause.");
        return -2;
    }
    if (!session->pause(session->gridApp)) {
        setError(errorBuffer, errorBufferLength, "GridApp::pause failed.");
        return -3;
    }
    emitEvent(session, 50, 0, 0, 0, 0);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoSendInput(void *sessionPointer, const uint8_t *inputEventBytes, size_t inputEventByteCount, char *errorBuffer, size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr || session->gridApp == nullptr || session->sendInput == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for input.");
        return -1;
    }
    if (!session->streaming) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo stream is not active for input.");
        return -2;
    }
    if (inputEventBytes == nullptr || inputEventByteCount != NvstInputEventSize) {
        if (errorBuffer != nullptr && errorBufferLength > 0) {
            snprintf(errorBuffer, errorBufferLength, "Native input requires verified NvstInputEvent_t bytes=%zu expected=%zu.", inputEventByteCount, NvstInputEventSize);
        }
        return -3;
    }
    session->sendInput(session->gridApp, inputEventBytes);
    return 0;
}

extern "C" int32_t OpenNOWNativeNVSTGeronimoStopWithResult(void *sessionPointer, const char *reason, int32_t code, char *errorBuffer, size_t errorBufferLength) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return 0; }
    if (!session->streaming) { return 0; }
    if (session->stop == nullptr || session->gridApp == nullptr) {
        setError(errorBuffer, errorBufferLength, "Native Geronimo session is not initialized for stop.");
        return -1;
    }
    session->stop(session->gridApp, reason == nullptr ? "OpenNOW native NVST stop" : reason, code);
    session->streaming = false;
    emitEvent(session, 60, 0, 0, 0, code);
    return 0;
}

extern "C" void OpenNOWNativeNVSTGeronimoStop(void *sessionPointer) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return; }
    OpenNOWNativeNVSTGeronimoStopWithResult(sessionPointer, "OpenNOW native NVST stop", 0, nullptr, 0);
    session->streaming = false;
}

extern "C" void OpenNOWNativeNVSTGeronimoDestroy(void *sessionPointer) {
    auto *session = static_cast<OpenNOWNativeNVSTGeronimoSession *>(sessionPointer);
    if (session == nullptr) { return; }
    OpenNOWNativeNVSTGeronimoStop(sessionPointer);
    if (session->initialized && session->uninitialize != nullptr && session->gridApp != nullptr) {
        session->uninitialize(session->gridApp);
        session->initialized = false;
    }
    if (session->gridApp != nullptr) {
        free(session->gridApp);
        session->gridApp = nullptr;
    }
    if (session->platformStarted && session->platformShutdown != nullptr) {
        session->platformShutdown();
        session->platformStarted = false;
    }
    if (session->libraryHandle != nullptr) {
        dlclose(session->libraryHandle);
        session->libraryHandle = nullptr;
    }
    if (session->bifrostHandle != nullptr) {
        dlclose(session->bifrostHandle);
        session->bifrostHandle = nullptr;
    }
    delete session;
}
