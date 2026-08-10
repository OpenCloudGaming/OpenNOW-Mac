#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dlfcn.h>
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

struct PlatformStartupParams {
    bool asyncRenderEnabled = true;
    unsigned char pad1[7] = {};
    void *firstHintNode = nullptr;
    void *emptyHintNode = nullptr;

    PlatformStartupParams() : firstHintNode(&emptyHintNode) {}
};
}

using GetStreamStartParameters = int (*)(const std::string &, const std::string &, const Nsk::ApplicationStreamStartParameters &, Nsk::StreamStartParameters &);
using PlatformStartup = bool (*)(const Nsk::PlatformStartupParams &);
using PlatformShutdown = void (*)();
using SessionCtor = void (*)(void *);
using JSONDeserialize = int (*)(void *, const std::string &, std::string &);

static uintptr_t imageBase(uintptr_t exportedSymbolAddress, uintptr_t exportedSymbolOffset) {
    return exportedSymbolAddress - exportedSymbolOffset;
}

static uintptr_t loadPointer(const unsigned char *base, size_t offset) {
    uintptr_t value = 0;
    memcpy(&value, base + offset, sizeof(value));
    return value;
}

static void inspectSessionDeserialize(uintptr_t baseAddress, const std::string &session) {
    auto sessionCtor = reinterpret_cast<SessionCtor>(baseAddress + 0x778f8);
    auto deserialize = reinterpret_cast<JSONDeserialize>(baseAddress + 0x90290);
    alignas(16) unsigned char storage[0x300];
    memset(storage, 0, sizeof(storage));
    sessionCtor(storage);
    std::string error;
    int result = deserialize(storage, session, error);
    uintptr_t monitorBegin = loadPointer(storage, 0xc8);
    uintptr_t monitorEnd = loadPointer(storage, 0xd0);
    uintptr_t connectionBegin = loadPointer(storage, 0xf0);
    uintptr_t connectionEnd = loadPointer(storage, 0xf8);
    uintptr_t featuresPointer = loadPointer(storage, 0x110);
    printf("sessionDeserialize=%d error=%s monitorRaw=0x%zx/0x%zx connectionRaw=0x%zx/0x%zx features=0x%zx\n",
           result,
           error.c_str(),
           monitorBegin,
           monitorEnd,
           connectionBegin,
           connectionEnd,
           featuresPointer);
}

int main(int argc, char **argv) {
    const char *libraryPath = argc > 1 ? argv[1] : "../Frameworks/libGeronimo.dylib";
    void *handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }

    auto getParameters = reinterpret_cast<GetStreamStartParameters>(dlsym(handle, "_ZN3Nsk24getStreamStartParametersERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEES8_RKNS_32ApplicationStreamStartParametersERNS_21StreamStartParametersE"));
    if (getParameters == nullptr) {
        fprintf(stderr, "dlsym failed: %s\n", dlerror());
        return 3;
    }
    uintptr_t baseAddress = imageBase(reinterpret_cast<uintptr_t>(getParameters), 0x767b4);
    auto platformStartup = reinterpret_cast<PlatformStartup>(dlsym(handle, "_ZN3Nsk15platformStartupERKNS_21PlatformStartupParamsE"));
    auto platformShutdown = reinterpret_cast<PlatformShutdown>(dlsym(handle, "_ZN3Nsk16platformShutdownEv"));
    bool didStartup = false;
    if (platformStartup != nullptr) {
        Nsk::PlatformStartupParams startupParams;
        didStartup = platformStartup(startupParams);
        printf("platformStartup=%s\n", didStartup ? "true" : "false");
    }

    std::string session = R"json({
      "sessionId": "native-session",
      "subSessionId": "",
      "state": 2,
      "appId": 123,
      "gpuType": "L40",
      "zoneAddress": "control.example.test",
      "zoneName": "CONTROL",
      "appLaunchMode": 0,
      "monitorSettings": [{
        "monitorId": 0,
        "positionX": 0,
        "positionY": 0,
        "widthInPixels": 1920,
        "heightInPixels": 1080,
        "framesPerSecond": 60,
        "sdrHdrMode": 0,
        "dpi": 1,
        "displayData": {
          "displayPrimaryX0": 0,
          "displayPrimaryY0": 0,
          "displayPrimaryX1": 0,
          "displayPrimaryY1": 0,
          "displayPrimaryX2": 0,
          "displayPrimaryY2": 0,
          "displayWhitePointX": 0,
          "displayWhitePointY": 0
        },
        "hdr10PlusGamingData": {
          "version": 0,
          "peakLuminanceIndex": 0,
          "peakFullFrameLuminanceIndex": 0
        }
      }],
      "connectionInfo": [
        { "usage": 14, "ip": "signaling.example.test", "port": 443, "protocol": 2, "resourcePath": "/nvst/", "appLevelProtocol": 5 },
        { "usage": 2, "ip": "video.example.test", "port": 47998, "protocol": 2, "resourcePath": "", "appLevelProtocol": 2 }
      ],
      "finalizedStreamingFeatures": {
        "reflex": false,
        "bitDepth": 8,
        "cloudGsync": false,
        "enabledL4S": false,
        "mouseMovementFlags": 0,
        "trueHdr": false,
        "supportedHidDevices": 0,
        "profile": 0,
        "fallbackToLogicalResolution": false,
        "hidDevices": [],
        "chromaFormat": 0,
        "prefilterMode": 0,
        "prefilterNoiseReduction": 0,
        "prefilterSharpness": 0,
        "hudStreamingMode": 0,
        "qosPolicy": 0,
        "touchSupport": false
      },
      "resumeType": 0,
      "keyboardLayout": "us",
      "locale": "en_US"
    })json";
    std::string profile = R"json({
      "selectedVideoMode": { "width": 1920, "height": 1080, "fps": 60, "scaleFactor": 1 },
      "selectedEncodeMode": { "width": 1920, "height": 1080, "fps": 60 },
      "selectedFeatures": {
        "vvsync": false,
        "vsync": 0,
        "audioChannelCount": 2,
        "hdr": false,
        "reflex": false,
        "bitDepth": 8,
        "cloudGsync": false,
        "l4s": false,
        "profile": 0,
        "fallbackToLogicalResolution": false,
        "hdr10PlusGaming": false,
        "maxBitrateKbps": 50000,
        "dynamicStreamingMode": 0,
        "chromaFormat": 0,
        "prefilterParams": { "mode": 0, "denoiseLevel": 0.0, "sharpnessLevel": 0, "model": 0 },
        "hudStreamingParams": { "mode": 0, "scxQpDelta": 0.0 }
      }
    })json";

    inspectSessionDeserialize(baseAddress, session);

    Nsk::ApplicationStreamStartParameters application;
    memset(application.reserved0, 0, sizeof(application.reserved0));
    application.gameLanguage = "en_US";
    application.clientAppVersion = "OpenNOW";
    application.clientLocale = "en_US";

    Nsk::StreamStartParameters output;
    int result = getParameters(session, profile, application, output);
    printf("result=0x%08x sessionId=%s server=%s appId=%u video=%zu audio=%zu connections=%zu type=%s\n",
           result,
           output.sessionId.c_str(),
           output.serverAddress.c_str(),
           output.appId,
           output.videoSettings.size(),
           output.audioSettings.size(),
           output.connectionInfo.size(),
           output.connectionType.c_str());
    if (didStartup && platformShutdown != nullptr) { platformShutdown(); }
    dlclose(handle);
    return result == 0 ? 0 : 1;
}
