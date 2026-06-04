#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#import <AppKit/NSWorkspace.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "doctest.h"

#include <arpa/inet.h>
#include <cstdlib>
#include <functional>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#include "../src/streaming/OPNStreamBackend.h"
#include "../src/streaming/OPNSessionAdPresentation.h"
#include "../src/streaming/OPNStreamPreferences.h"
#include "../src/auth/OPNAuthService.h"
#include "../src/common/OPNAuthTypes.h"
#include "../src/common/OPNGameRemediation.h"
#include "../src/common/OPNGFNError.h"
#include "../src/common/OPNHTTP.h"
#include "../src/common/OPNLocale.h"
#include "../src/common/OPNProtocolDebug.h"
#include "../src/games/OPNGameDataCache.h"
#include "../src/games/OPNGameService.h"

namespace {

constexpr int kOAuthCallbackPorts[] = {2259, 6460, 7119, 8870, 9096};
static NSString *const kOpenNOWDefaultsDomain = @"io.github.opencloudgaming.opennow";

class AuthTestEnvironment final {
public:
    AuthTestEnvironment()
        : suiteName([NSString stringWithFormat:@"opennow.auth.tests.%@", [[NSUUID UUID] UUIDString]]),
          rootPath([NSTemporaryDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"opennow-auth-tests-%@", [[NSUUID UUID] UUIDString]]]),
          defaults([[NSUserDefaults alloc] initWithSuiteName:suiteName]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:rootPath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [defaults removePersistentDomainForName:suiteName];
        [defaults synchronize];
        setenv("OPN_AUTH_USER_DEFAULTS_SUITE", [suiteName UTF8String], 1);
        setenv("OPN_AUTH_APPLICATION_SUPPORT_DIR", [rootPath UTF8String], 1);
    }

    ~AuthTestEnvironment() {
        [defaults removePersistentDomainForName:suiteName];
        [defaults synchronize];
        [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
        unsetenv("OPN_AUTH_USER_DEFAULTS_SUITE");
        unsetenv("OPN_AUTH_APPLICATION_SUPPORT_DIR");
    }

    NSUserDefaults *UserDefaults() const {
        return defaults;
    }

    NSString *RootPath() const {
        return rootPath;
    }

private:
    NSString *suiteName;
    NSString *rootPath;
    NSUserDefaults *defaults;
};

static OPN::AuthSession MakeAuthenticatedSession(const std::string &userId,
                                                 const std::string &email,
                                                 const std::string &accessToken) {
    OPN::AuthSession session;
    session.accessToken = accessToken;
    session.idToken = "id-" + userId;
    session.refreshToken = "refresh-" + userId;
    session.userId = userId;
    session.displayName = "User " + userId;
    session.email = email;
    session.membershipTier = "Premium";
    session.expiresAt = static_cast<int64_t>([[NSDate date] timeIntervalSince1970]) + 3600;
    session.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 3600000;
    session.clientToken = "client-" + userId;
    session.clientTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 3600000;
    session.clientTokenExpiryLength = 3600000;
    session.idTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 3600000;
    session.isAuthenticated = true;
    return session;
}

static NSData *JSONData(NSDictionary *dictionary) {
    return [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:nil];
}

static bool WaitUntil(const std::function<bool()> &predicate, NSTimeInterval timeoutSeconds = 2.0) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while (!predicate() && [deadline timeIntervalSinceNow] > 0) {
        @autoreleasepool {
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                                  beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    return predicate();
}

struct MockHTTPResponse {
    NSInteger statusCode = 200;
    NSData *data = nil;
    NSError *error = nil;
};

static std::function<MockHTTPResponse(NSURLRequest *)> gMockURLHandler;

}

@interface OPNTestURLProtocol : NSURLProtocol
@end

@implementation OPNTestURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return gMockURLHandler && ([request.URL.host isEqualToString:@"login.nvidia.com"] ||
                               [request.URL.host isEqualToString:@"pcs.geforcenow.com"] ||
                               [request.URL.host isEqualToString:@"prod.cloudmatchbeta.nvidiagrid.net"]);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    if (!gMockURLHandler) {
        NSError *error = [NSError errorWithDomain:@"OpenNOWTests" code:1 userInfo:nil];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    MockHTTPResponse response = gMockURLHandler(self.request);
    if (response.error) {
        [self.client URLProtocol:self didFailWithError:response.error];
        return;
    }

    NSHTTPURLResponse *http = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:response.statusCode
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:http cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (response.data) {
        [self.client URLProtocol:self didLoadData:response.data];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

namespace {

class ScopedURLMock final {
public:
    explicit ScopedURLMock(std::function<MockHTTPResponse(NSURLRequest *)> handler) {
        gMockURLHandler = std::move(handler);
        [NSURLProtocol registerClass:[OPNTestURLProtocol class]];
    }

    ~ScopedURLMock() {
        [NSURLProtocol unregisterClass:[OPNTestURLProtocol class]];
        gMockURLHandler = nullptr;
    }
};

static NSURL *gLastOpenedURL = nil;

static BOOL OPNTestOpenURL(id, SEL, NSURL *url) {
    gLastOpenedURL = url;
    return YES;
}

class ScopedWorkspaceOpenURLStub final {
public:
    ScopedWorkspaceOpenURLStub()
        : method(class_getInstanceMethod([NSWorkspace class], @selector(openURL:))),
          original(method ? method_setImplementation(method, reinterpret_cast<IMP>(OPNTestOpenURL)) : nullptr) {
        gLastOpenedURL = nil;
    }

    ~ScopedWorkspaceOpenURLStub() {
        if (method && original) {
            method_setImplementation(method, original);
        }
        gLastOpenedURL = nil;
    }

    NSURL *LastURL() const {
        return gLastOpenedURL;
    }

private:
    Method method;
    IMP original;
};

static int BindLocalPort(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0) {
        close(sock);
        return -1;
    }
    listen(sock, 1);
    return sock;
}

class ScopedBoundPorts final {
public:
    ~ScopedBoundPorts() {
        for (int sock : sockets) {
            close(sock);
        }
    }

    void BindAllCandidatePorts() {
        for (int port : kOAuthCallbackPorts) {
            int sock = BindLocalPort(port);
            if (sock >= 0) sockets.push_back(sock);
        }
    }

    int BindAllButOneCandidatePort() {
        int selectedPort = 0;
        for (int port : kOAuthCallbackPorts) {
            int sock = BindLocalPort(port);
            if (sock < 0) continue;
            if (selectedPort == 0) {
                selectedPort = port;
                close(sock);
            } else {
                sockets.push_back(sock);
            }
        }
        return selectedPort;
    }

private:
    std::vector<int> sockets;
};

static int ConnectToLocalhost(int port) {
    for (int attempt = 0; attempt < 50; ++attempt) {
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) return -1;
        sockaddr_in addr = {};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        if (connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0) {
            return sock;
        }
        close(sock);
        usleep(10000);
    }
    return -1;
}

static void SendOAuthCallbackRequest(int port, const std::string &request) {
    int sock = ConnectToLocalhost(port);
    REQUIRE(sock >= 0);
    ssize_t sent = send(sock, request.c_str(), request.size(), 0);
    CHECK_EQ(sent, static_cast<ssize_t>(request.size()));
    char response[512] = {0};
    recv(sock, response, sizeof(response) - 1, 0);
    close(sock);
}

static void OpenAndCloseOAuthCallback(int port) {
    int sock = ConnectToLocalhost(port);
    REQUIRE(sock >= 0);
    close(sock);
}

static NSString *QueryValue(NSURL *url, NSString *name) {
    NSDictionary *params = OPN::AuthService::parseQueryString(url.query);
    NSString *value = params[name];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

}

namespace streaming_backend_tests {

TEST_SUITE("streaming/backend")

TEST_CASE("ResolveStreamWebRTCBackend") {
    OPN::StreamWebRTCBackend backend = OPN::ResolveStreamWebRTCBackend();
    CHECK(backend == OPN::StreamWebRTCBackend::LibWebRTC);
}

TEST_CASE("StreamWebRTCBackendName") {
    std::string name = OPN::StreamWebRTCBackendName(OPN::StreamWebRTCBackend::LibWebRTC);
    CHECK_EQ(name, "libwebrtc");
}

TEST_CASE("StreamWebRTCBackendNameDefaultCase") {
    std::string name = OPN::StreamWebRTCBackendName(static_cast<OPN::StreamWebRTCBackend>(0xFF));
    CHECK_EQ(name, "libwebrtc");
}

}

namespace streaming_preference_tests {

TEST_SUITE("streaming/preferences")

class ScopedDirectMouseInputPreference final {
public:
    ScopedDirectMouseInputPreference()
        : key(@"OpenNOW.Stream.DirectMouseInput"),
          originalValue([NSUserDefaults.standardUserDefaults objectForKey:key]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        [NSUserDefaults.standardUserDefaults synchronize];
    }

    ~ScopedDirectMouseInputPreference() {
        if (originalValue) {
            [NSUserDefaults.standardUserDefaults setObject:originalValue forKey:key];
        } else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
        [NSUserDefaults.standardUserDefaults synchronize];
    }

    void Reset() const {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        [NSUserDefaults.standardUserDefaults synchronize];
    }

private:
    NSString *key;
    id originalValue;
};

class ScopedStreamIntegerPreference final {
public:
    explicit ScopedStreamIntegerPreference(NSString *preferenceKey)
        : key(preferenceKey),
          originalValue([NSUserDefaults.standardUserDefaults objectForKey:key]),
          originalBundleValue([[NSUserDefaults.standardUserDefaults persistentDomainForName:kOpenNOWDefaultsDomain] objectForKey:key]),
          originalGlobalValue([[NSUserDefaults.standardUserDefaults persistentDomainForName:NSGlobalDomain] objectForKey:key]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        RemoveDomainValue(kOpenNOWDefaultsDomain);
        RemoveDomainValue(NSGlobalDomain);
        [NSUserDefaults.standardUserDefaults synchronize];
    }

    ~ScopedStreamIntegerPreference() {
        if (originalValue) {
            [NSUserDefaults.standardUserDefaults setObject:originalValue forKey:key];
        } else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
        RestoreDomainValue(kOpenNOWDefaultsDomain, originalBundleValue);
        RestoreDomainValue(NSGlobalDomain, originalGlobalValue);
        [NSUserDefaults.standardUserDefaults synchronize];
    }

private:
    void RemoveDomainValue(NSString *domainName) const {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *domain = [[defaults persistentDomainForName:domainName] mutableCopy];
        if (!domain) return;
        [domain removeObjectForKey:key];
        [defaults setPersistentDomain:domain forName:domainName];
    }

    void RestoreDomainValue(NSString *domainName, id value) const {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *domain = [[defaults persistentDomainForName:domainName] mutableCopy];
        if (!domain) domain = [NSMutableDictionary dictionary];
        if (value) {
            [domain setObject:value forKey:key];
        } else {
            [domain removeObjectForKey:key];
        }
        [defaults setPersistentDomain:domain forName:domainName];
    }

    NSString *key;
    id originalValue;
    id originalBundleValue;
    id originalGlobalValue;
};

class ScopedStreamObjectPreference final {
public:
    explicit ScopedStreamObjectPreference(NSString *preferenceKey)
        : key(preferenceKey),
          originalValue([NSUserDefaults.standardUserDefaults objectForKey:key]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        [NSUserDefaults.standardUserDefaults synchronize];
    }

    ~ScopedStreamObjectPreference() {
        if (originalValue) {
            [NSUserDefaults.standardUserDefaults setObject:originalValue forKey:key];
        } else {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
        [NSUserDefaults.standardUserDefaults synchronize];
    }

private:
    NSString *key;
    id originalValue;
};

static OPN::StreamPreferenceProfile ProfileWithSelections(int codecIndex, int fpsIndex, int colorQualityIndex) {
    OPN::StreamPreferenceProfile profile;
    const std::vector<OPN::StreamCodecOption> &codecs = OPN::StreamCodecOptions();
    const std::vector<int> &fpsOptions = OPN::StreamFpsOptions();
    const std::vector<OPN::StreamColorQualityOption> &colorOptions = OPN::StreamColorQualityOptions();
    profile.codecIndex = codecIndex;
    profile.codec = codecs[(size_t)codecIndex];
    profile.fpsIndex = fpsIndex;
    profile.fps = fpsOptions[(size_t)fpsIndex];
    profile.colorQualityIndex = colorQualityIndex;
    profile.colorQuality = colorOptions[(size_t)colorQualityIndex];
    return profile;
}

TEST_CASE("EffectiveStreamPreferenceProfileForCapabilitiesFallsBackUnsupportedSelections") {
    OPN::StreamDeviceCapabilities capabilities;
    capabilities.h264HardwareDecodeSupported = true;
    capabilities.h265HardwareDecodeSupported = false;
    capabilities.av1HardwareDecodeSupported = false;
    capabilities.maxDisplayRefreshRate = 60;

    OPN::StreamPreferenceProfile profile = ProfileWithSelections(1, 3, 2);
    OPN::StreamPreferenceProfile effective = OPN::EffectiveStreamPreferenceProfileForCapabilities(profile, capabilities);

    CHECK_EQ(effective.codec.value, "H264");
    CHECK_EQ(effective.fps, 60);
    CHECK_EQ(effective.colorQuality.value, "8bit_420");
}

TEST_CASE("ResolveStreamCodecForCapabilitiesPrefersHevcForTenBitAuto") {
    OPN::StreamDeviceCapabilities capabilities;
    capabilities.h264HardwareDecodeSupported = true;
    capabilities.h265HardwareDecodeSupported = true;
    capabilities.av1HardwareDecodeSupported = false;

    OPN::StreamPreferenceProfile profile = ProfileWithSelections(3, 1, 2);
    std::string codec = OPN::ResolveStreamCodecForCapabilities(profile, {2560, 1440}, capabilities, true);

    CHECK_EQ(codec, "H265");
}

TEST_CASE("DirectMouseInputPreferenceDefaultsOnAndPersistsChanges") {
    ScopedDirectMouseInputPreference preference;

    CHECK(OPN::LoadStreamPreferenceProfile().directMouseInput);

    OPN::SaveStreamDirectMouseInputEnabled(false);
    CHECK(!OPN::LoadStreamPreferenceProfile().directMouseInput);

    OPN::SaveStreamDirectMouseInputEnabled(true);
    CHECK(OPN::LoadStreamPreferenceProfile().directMouseInput);

    preference.Reset();
    CHECK(OPN::LoadStreamPreferenceProfile().directMouseInput);
}

TEST_CASE("PrefilterPreferencesDefaultOffAndClampCustomLevels") {
    ScopedStreamIntegerPreference mode(@"OpenNOW.Stream.PrefilterModeIndex");
    ScopedStreamIntegerPreference sharpness(@"OpenNOW.Stream.PrefilterSharpness");
    ScopedStreamIntegerPreference denoise(@"OpenNOW.Stream.PrefilterDenoise");

    OPN::StreamPreferenceProfile defaults = OPN::LoadStreamPreferenceProfile();
    CHECK_EQ(defaults.prefilterMode, 0);
    CHECK_EQ(defaults.prefilterSharpness, 0);
    CHECK_EQ(defaults.prefilterDenoise, 0);

    OPN::SaveStreamPrefilterModeIndex(2);
    OPN::SaveStreamPrefilterSharpness(99);
    OPN::SaveStreamPrefilterDenoise(-4);

    OPN::StreamPreferenceProfile custom = OPN::LoadStreamPreferenceProfile();
    CHECK_EQ(custom.prefilterMode, 2);
    CHECK_EQ(custom.prefilterSharpness, 10);
    CHECK_EQ(custom.prefilterDenoise, 0);
}

TEST_CASE("PrefilterPreferencesReadBundleAndGlobalDefaults") {
    ScopedStreamIntegerPreference mode(@"OpenNOW.Stream.PrefilterModeIndex");
    ScopedStreamIntegerPreference sharpness(@"OpenNOW.Stream.PrefilterSharpness");
    ScopedStreamIntegerPreference denoise(@"OpenNOW.Stream.PrefilterDenoise");
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    NSMutableDictionary *bundleDomain = [[defaults persistentDomainForName:kOpenNOWDefaultsDomain] mutableCopy];
    if (!bundleDomain) bundleDomain = [NSMutableDictionary dictionary];
    [bundleDomain setObject:@2 forKey:@"OpenNOW.Stream.PrefilterModeIndex"];
    [bundleDomain setObject:@10 forKey:@"OpenNOW.Stream.PrefilterSharpness"];
    [defaults setPersistentDomain:bundleDomain forName:kOpenNOWDefaultsDomain];

    NSMutableDictionary *globalDomain = [[defaults persistentDomainForName:NSGlobalDomain] mutableCopy];
    if (!globalDomain) globalDomain = [NSMutableDictionary dictionary];
    [globalDomain setObject:@7 forKey:@"OpenNOW.Stream.PrefilterDenoise"];
    [defaults setPersistentDomain:globalDomain forName:NSGlobalDomain];

    OPN::StreamPreferenceProfile fallback = OPN::LoadStreamPreferenceProfile();
    CHECK_EQ(fallback.prefilterMode, 2);
    CHECK_EQ(fallback.prefilterSharpness, 10);
    CHECK_EQ(fallback.prefilterDenoise, 7);
}

TEST_CASE("UpscalingPreferencesDefaultEnhancedAndClampSharpness") {
    ScopedStreamIntegerPreference mode(@"OpenNOW.Stream.UpscalingModeIndex");
    ScopedStreamIntegerPreference sharpness(@"OpenNOW.Stream.UpscalingSharpness");

    OPN::StreamPreferenceProfile defaults = OPN::LoadStreamPreferenceProfile();
    CHECK_EQ(defaults.upscalingMode, 1);
    CHECK_EQ(defaults.upscalingSharpness, 4);

    OPN::SaveStreamUpscalingModeIndex(99);
    OPN::SaveStreamUpscalingSharpness(-3);

    OPN::StreamPreferenceProfile clamped = OPN::LoadStreamPreferenceProfile();
    CHECK_EQ(clamped.upscalingMode, 2);
    CHECK_EQ(clamped.upscalingSharpness, 0);
}

TEST_CASE("HDRPreferenceDefaultsOffAndPersistsChanges") {
    ScopedStreamObjectPreference preference(@"OpenNOW.Stream.HDREnabled");

    CHECK(!OPN::LoadStreamPreferenceProfile().enableHdr);

    OPN::SaveStreamHDREnabled(true);
    CHECK(OPN::LoadStreamPreferenceProfile().enableHdr);

    OPN::SaveStreamHDREnabled(false);
    CHECK(!OPN::LoadStreamPreferenceProfile().enableHdr);
}

TEST_CASE("NetworkPreflightParsesMeasurementsAndRecommendsBitrate") {
    OPN::StreamNetworkPreflightResult seed;
    seed.latencyMs = 40;
    seed.networkType = "WiFi";
    std::string json = R"({
        "requestStatus": {"statusCode": 0, "statusDescription": "ok"},
        "networkTestSessionId": "net-123",
        "results": {
            "latencyMs": 92,
            "measuredBandwidthKbps": 41000,
            "packetLoss": 0.015,
            "jitterMs": 34,
            "recommendedMaxBitrateKbps": 30000
        },
        "warning": true,
        "warningMessage": "Selected zone is degraded"
    })";

    OPN::StreamNetworkPreflightResult parsed = OPN::StreamNetworkPreflightResultFromJSONString(json, seed, 75);

    CHECK_EQ(parsed.networkTestSessionId, "net-123");
    CHECK_EQ(parsed.latencyMs, 92);
    CHECK_EQ((int)parsed.measuredBandwidthMbps, 41);
    CHECK(parsed.packetLossPercent > 1.4);
    CHECK_EQ(parsed.jitterMs, 34);
    CHECK_EQ(parsed.recommendedMaxBitrateMbps, 30);
    CHECK(parsed.serverReportedWarning);
    CHECK_EQ(parsed.warningMessage, "Selected zone is degraded");
}

TEST_CASE("CloudVariablesParseAndClampNativeSettings") {
    std::string json = R"({
        "variables": [
            {"key": "enableHevc", "value": false},
            {"key": "enableAV1", "value": false},
            {"key": "enableHDR", "value": false},
            {"key": "enableL4S", "value": false},
            {"key": "enableReflex", "value": false},
            {"key": "maxBitrateKbps", "value": 25000},
            {"key": "gpuName", "value": "RTX 4080"}
        ],
        "ttlSeconds": 120
    })";

    OPN::StreamCloudVariables variables = OPN::StreamCloudVariablesFromJSONString(json);
    OPN::StreamSettings settings;
    settings.codec = "H265";
    settings.maxBitrateMbps = 75;
    settings.enableHdr = true;
    settings.enableL4S = true;
    settings.enableReflex = true;
    OPN::StreamDeviceCapabilities capabilities;
    capabilities.hdrDisplaySupported = true;

    OPN::StreamSettings applied = OPN::StreamSettingsByApplyingCloudVariables(settings, variables, capabilities);

    CHECK(variables.fetched);
    CHECK_EQ(variables.maxBitrateMbps, 25);
    CHECK_EQ(variables.gpuName, "RTX 4080");
    CHECK_EQ(applied.codec, "H264");
    CHECK_EQ(applied.maxBitrateMbps, 25);
    CHECK(!applied.enableHdr);
    CHECK(!applied.enableL4S);
    CHECK(!applied.enableReflex);
}

TEST_CASE("CloudVariablesPreservePrefilterModesUnlessExplicitlyDisabled") {
    std::string json = R"({
        "subscription": {
            "features": [
                {"key": "SUPPORTED_DL_PREFILTERING", "setValue": ["0", "1"]}
            ]
        },
        "maxSupportedModesForPrefilter": 2
    })";

    OPN::StreamCloudVariables variables = OPN::StreamCloudVariablesFromJSONString(json);
    OPN::StreamSettings settings;
    settings.prefilterMode = 2;
    settings.prefilterSharpness = 8;
    settings.prefilterDenoise = 6;
    settings.prefilterModel = 1;

    OPN::StreamSettings applied = OPN::StreamSettingsByApplyingCloudVariables(settings, variables, OPN::StreamDeviceCapabilities{});

    CHECK(variables.fetched);
    CHECK_EQ(variables.supportedPrefilterModes.size(), (size_t)2);
    CHECK_EQ(applied.prefilterMode, 2);
    CHECK_EQ(applied.prefilterSharpness, 8);
    CHECK_EQ(applied.prefilterDenoise, 6);
    CHECK_EQ(applied.prefilterModel, 1);

    std::string disabledJson = R"({"variables":[{"key":"enablePrefilter","value":false}]})";
    OPN::StreamCloudVariables disabledVariables = OPN::StreamCloudVariablesFromJSONString(disabledJson);
    OPN::StreamSettings disabled = OPN::StreamSettingsByApplyingCloudVariables(settings, disabledVariables, OPN::StreamDeviceCapabilities{});

    CHECK(disabledVariables.fetched);
    CHECK_EQ(disabled.prefilterMode, 0);
    CHECK_EQ(disabled.prefilterSharpness, 0);
    CHECK_EQ(disabled.prefilterDenoise, 0);
    CHECK_EQ(disabled.prefilterModel, 0);
}

TEST_CASE("CloudVariablesDoNotDisablePrefilterWhenUnfetched") {
    OPN::StreamCloudVariables variables;
    variables.fetched = false;
    variables.allowPrefilter = false;

    OPN::StreamSettings settings;
    settings.prefilterMode = 2;
    settings.prefilterSharpness = 10;
    settings.prefilterDenoise = 9;
    settings.prefilterModel = 1;

    OPN::StreamSettings applied = OPN::StreamSettingsByApplyingCloudVariables(settings, variables, OPN::StreamDeviceCapabilities{});

    CHECK_EQ(applied.prefilterMode, 2);
    CHECK_EQ(applied.prefilterSharpness, 10);
    CHECK_EQ(applied.prefilterDenoise, 9);
    CHECK_EQ(applied.prefilterModel, 1);
}

}

namespace gfn_error_tests {

TEST_SUITE("gfn/errors")

TEST_CASE("UserFacingGFNErrorMessageMapsHexAndGSECDiagnostics") {
    std::string queue = OPN::UserFacingGFNErrorMessage("backend failed with 0xC0F5213E");
    CHECK(queue.find("queue") != std::string::npos);

    std::string sessionLimitHex = OPN::UserFacingGFNErrorMessage("SESSION_LIMIT_EXCEEDED_STATUS 41F1C0A5", "Test Game");
    CHECK(sessionLimitHex.find("already running") != std::string::npos);
    CHECK(sessionLimitHex.find("1106362533") != std::string::npos);

    std::string gsec = OPN::UserFacingGFNErrorMessage("SRC_GSEC_AUTH_FAILED");
    CHECK(gsec.find("internal game-seat service error") != std::string::npos);
}

TEST_CASE("UserFacingGFNErrorMessageUsesUnifiedRequestStatusCode") {
    std::string response = R"json({"requestStatus":{"statusCode":11,"statusDescription":"SESSION_LIMIT_EXCEEDED_STATUS 41F1C0A5","unifiedErrorCode":1106362533}})json";
    std::string message = OPN::UserFacingGFNErrorMessage(response, "Test Game");
    CHECK(message.find("Test Game is already running") != std::string::npos);
    CHECK(message.find("1106362533") != std::string::npos);
    CHECK(message.find("SESSION_LIMIT_EXCEEDED_STATUS 41F1C0A5") != std::string::npos);
}

TEST_CASE("UserFacingGFNErrorMessageMapsActionableStoreAndAdFailures") {
    std::string accountLink = OPN::UserFacingGFNErrorMessage("API error: STORE_ACCOUNT_LINK_REQUIRED");
    CHECK(accountLink.find("not linked") != std::string::npos);

    std::string install = OPN::UserFacingGFNErrorMessage("launch failed: INSTALL_TO_PLAY");
    CHECK(install.find("installed or prepared") != std::string::npos);

    std::string entitlement = OPN::UserFacingGFNErrorMessage("launch failed: purchase required");
    CHECK(entitlement.find("not owned or linked") != std::string::npos);

    std::string ads = OPN::UserFacingGFNErrorMessage("sessionAdsRequired=true queuePaused=true");
    CHECK(ads.find("ad playback") != std::string::npos);
}

}

namespace game_remediation_tests {

TEST_SUITE("games/remediation")

static OPN::GameInfo GameWithSteamVariant() {
    OPN::GameInfo game;
    game.title = "Test Game";
    OPN::GameVariant variant;
    variant.id = "123";
    variant.appStore = "STEAM";
    variant.storeUrl = "https://store.steampowered.com/app/123";
    game.variants.push_back(variant);
    return game;
}

TEST_CASE("GameOwnershipRemediationClassifiesUnownedGame") {
    OPN::GameInfo game = GameWithSteamVariant();

    OPN::GameOwnershipRemediation remediation = OPN::GameOwnershipRemediationForLaunch(game, 0, true);

    CHECK(remediation.Required());
    CHECK(remediation.kind == OPN::GameOwnershipRemediationKind::PurchaseOrAdd);
    CHECK_EQ(remediation.storeVariantIndex, 0);
    CHECK_EQ(remediation.storeName, "Steam");
    CHECK(remediation.reason.find("not marked as owned") != std::string::npos);
}

TEST_CASE("GameOwnershipRemediationClassifiesLinkedAccountRequirement") {
    OPN::GameInfo game = GameWithSteamVariant();
    game.variants[0].inLibrary = true;

    OPN::GameOwnershipRemediation remediation = OPN::GameOwnershipRemediationForLaunch(game, 0, false);

    CHECK(remediation.Required());
    CHECK(remediation.kind == OPN::GameOwnershipRemediationKind::LinkAccount);
    CHECK(remediation.reason.find("linked Steam account") != std::string::npos);
}

TEST_CASE("GameOwnershipRemediationClassifiesInstallToPlayBeforeOwnership") {
    OPN::GameInfo game = GameWithSteamVariant();
    game.playType = "INSTALL_TO_PLAY";
    game.variants[0].inLibrary = true;

    OPN::GameOwnershipRemediation remediation = OPN::GameOwnershipRemediationForLaunch(game, 0, true);

    CHECK(remediation.Required());
    CHECK(remediation.kind == OPN::GameOwnershipRemediationKind::InstallToPlay);
    CHECK(remediation.reason.find("installed or prepared") != std::string::npos);
}

TEST_CASE("GameOwnershipRemediationAllowsOwnedLinkedGame") {
    OPN::GameInfo game = GameWithSteamVariant();
    game.variants[0].serviceStatus = "IN_LIBRARY";

    OPN::GameOwnershipRemediation remediation = OPN::GameOwnershipRemediationForLaunch(game, 0, true);

    CHECK(!remediation.Required());
}

}

namespace session_ad_tests {

TEST_SUITE("streaming/session-ads")

TEST_CASE("SessionAdPresentationHiddenWhenAdsNotRequired") {
    OPN::SessionAdState state;

    OPN::SessionAdPresentation presentation = OPN::SessionAdPresentationForState(state);

    CHECK(!presentation.Visible());
    CHECK(!presentation.HasPlayableAd());
    CHECK(presentation.kind == OPN::SessionAdPresentationKind::None);
}

TEST_CASE("SessionAdPresentationShowsWaitingForRequiredEmptyAds") {
    OPN::SessionAdState state;
    state.isAdsRequired = true;
    state.sessionAdsRequired = true;
    state.serverSentEmptyAds = true;

    OPN::SessionAdPresentation presentation = OPN::SessionAdPresentationForState(state);

    CHECK(presentation.Visible());
    CHECK(!presentation.HasPlayableAd());
    CHECK(presentation.kind == OPN::SessionAdPresentationKind::WaitingForAd);
    CHECK_EQ(presentation.title, "Waiting for an ad");
}

TEST_CASE("SessionAdPresentationShowsQueuePausedGracePeriod") {
    OPN::SessionAdState state;
    state.isAdsRequired = true;
    state.isQueuePaused = true;
    state.gracePeriodSeconds = 30;

    OPN::SessionAdPresentation presentation = OPN::SessionAdPresentationForState(state);

    CHECK(presentation.Visible());
    CHECK(!presentation.HasPlayableAd());
    CHECK(presentation.kind == OPN::SessionAdPresentationKind::QueuePaused);
    CHECK_EQ(presentation.chipText, "Queue Paused");
}

TEST_CASE("SessionAdPresentationReturnsPlayableAd") {
    OPN::SessionAdState state;
    state.isAdsRequired = true;
    OPN::SessionAdInfo ad;
    ad.adId = "ad-1";
    ad.title = "Sponsored Session";
    ad.mediaUrl = "https://example.invalid/ad.mp4";
    state.sessionAds.push_back(ad);

    OPN::SessionAdPresentation presentation = OPN::SessionAdPresentationForState(state);

    CHECK(presentation.Visible());
    CHECK(presentation.HasPlayableAd());
    CHECK(presentation.kind == OPN::SessionAdPresentationKind::PlayableAd);
    REQUIRE(presentation.ad != nullptr);
    CHECK_EQ(presentation.ad->adId, "ad-1");
    CHECK_EQ(presentation.title, "Sponsored Session");
}

}

namespace protocol_debug_tests {

TEST_SUITE("protocol/debug")

TEST_CASE("SanitizedProtocolJSONStringRedactsSensitiveFields") {
    NSDictionary *payload = @{
        @"Authorization": @"GFNJWT abc.def",
        @"clientIp": @"203.0.113.10",
        @"sessionRequestData": @{
            @"deviceHashId": @"device-123",
            @"networkTestSessionId": @"net-123",
            @"appId": @"12345",
            @"metaData": @[
                @{@"key": @"SubSessionId", @"value": @"sub-session-secret"},
                @{@"key": @"store", @"value": @"STEAM"},
            ],
            @"resourcePath": @"/v2/session/secret-session-id",
            @"requestedStreamingFeatures": @{
                @"reflex": @YES,
            },
        },
    };

    NSString *sanitized = OPN::SanitizedProtocolJSONStringFromJSONObject(payload);
    std::string text([sanitized UTF8String] ?: "");

    CHECK(text.find("abc.def") == std::string::npos);
    CHECK(text.find("203.0.113.10") == std::string::npos);
    CHECK(text.find("device-123") == std::string::npos);
    CHECK(text.find("net-123") == std::string::npos);
    CHECK(text.find("sub-session-secret") == std::string::npos);
    CHECK(text.find("secret-session-id") == std::string::npos);
    CHECK(text.find("12345") != std::string::npos);
    CHECK(text.find("STEAM") != std::string::npos);
    CHECK(text.find("<redacted>") != std::string::npos);
}

TEST_CASE("ProtocolDebugCaptureFilenameSanitizesLabels") {
    NSString *filename = OPN::ProtocolDebugCaptureFilename(@"NetTest Session / Request", 7);
    std::string text([filename UTF8String] ?: "");

    CHECK(text.find("nettest-session-request") != std::string::npos);
    CHECK(text.find("/") == std::string::npos);
    CHECK(text.find(" ") == std::string::npos);
    CHECK(text.rfind(".json") == text.size() - 5);
}

TEST_CASE("ProtocolDebugCaptureDirectoryWritesSanitizedPayload") {
    NSString *captureDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"opennow-protocol-capture-%@", [[NSUUID UUID] UUIDString]]];
    const char *oldCaptureDir = std::getenv("OPN_PROTOCOL_CAPTURE_DIR");
    std::string oldCaptureDirValue = oldCaptureDir ? oldCaptureDir : "";
    setenv("OPN_PROTOCOL_CAPTURE_DIR", [captureDir UTF8String], 1);

    NSDictionary *payload = @{
        @"networkTestSessionId": @"secret-session",
        @"requestedMaxBitrateKbps": @50000,
    };
    OPN::LogProtocolJSONObject(@"NetTest Session / Request", payload);

    if (oldCaptureDir) setenv("OPN_PROTOCOL_CAPTURE_DIR", oldCaptureDirValue.c_str(), 1);
    else unsetenv("OPN_PROTOCOL_CAPTURE_DIR");

    NSArray<NSString *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:captureDir error:nil];
    REQUIRE_EQ(files.count, 1);
    NSString *path = [captureDir stringByAppendingPathComponent:files.firstObject];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    std::string contents([text UTF8String] ?: "");

    CHECK(contents.find("secret-session") == std::string::npos);
    CHECK(contents.find("<redacted>") != std::string::npos);
    CHECK(contents.find("50000") != std::string::npos);

    [NSFileManager.defaultManager removeItemAtPath:captureDir error:nil];
}

}

namespace locale_tests {

TEST_SUITE("locale/fallbacks")

TEST_CASE("GFNLocaleFallbacksPreserveRegionThenLanguageThenEnglish") {
    std::vector<std::string> fallbacks = OPN::GFNLocaleFallbacksForLocale("pt-BR");

    REQUIRE_EQ(fallbacks.size(), 3);
    CHECK_EQ(fallbacks[0], "pt_BR");
    CHECK_EQ(fallbacks[1], "pt");
    CHECK_EQ(fallbacks[2], "en_US");
}

TEST_CASE("GFNLocaleFallbacksAvoidDuplicateEnglish") {
    std::vector<std::string> fallbacks = OPN::GFNLocaleFallbacksForLocale("en-GB");

    REQUIRE_EQ(fallbacks.size(), 2);
    CHECK_EQ(fallbacks[0], "en_GB");
    CHECK_EQ(fallbacks[1], "en_US");
}

}

namespace auth_query_tests {

TEST_SUITE("auth/query")

TEST_CASE("ParseQueryString") {
    NSString *query = @"access_token=abc123&refresh_token=xyz%2078&empty=&skip";
    NSDictionary *params = OPN::AuthService::parseQueryString(query);
    CHECK_EQ(static_cast<int>(params.count), 3);
    CHECK_EQ(std::string([params[@"access_token"] UTF8String]), "abc123");
    CHECK_EQ(std::string([params[@"refresh_token"] UTF8String]), "xyz 78");
    CHECK_EQ(std::string([params[@"empty"] UTF8String]), "");
}

TEST_CASE("ParseQueryStringEmptyAndNil") {
    NSDictionary *empty = OPN::AuthService::parseQueryString(@"");
    CHECK_EQ(static_cast<int>(empty.count), 0);

    NSDictionary *nilValue = OPN::AuthService::parseQueryString(nil);
    CHECK_EQ(static_cast<int>(nilValue.count), 0);
}

TEST_CASE("ParseQueryStringSkipsMalformedPairsAndUsesLastValue") {
    NSDictionary *params = OPN::AuthService::parseQueryString(@"token=first&bad&token=second&too=many=parts&blank=%E0%A4%A");
    CHECK_EQ(static_cast<int>(params.count), 2);
    CHECK_EQ(std::string([params[@"token"] UTF8String]), "second");
    CHECK_EQ(std::string([params[@"blank"] UTF8String]), "");
}

}

namespace auth_session_tests {

TEST_SUITE("auth/session")

TEST_CASE("AuthSessionClearAndValidity") {
    OPN::AuthSession session;
    session.accessToken = "token";
    session.clientToken = "client";
    session.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 100000;
    session.clientTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 100000;
    session.userId = "user123";
    session.displayName = "Tester";
    session.email = "tester@example.com";
    session.membershipTier = "Premium";

    CHECK(session.HasAccessToken());
    CHECK(session.IsAccessTokenValid());
    CHECK(session.IsClientTokenValid());

    session.Clear();
    CHECK(!session.HasAccessToken());
    CHECK(!session.IsAccessTokenValid());
    CHECK(!session.IsClientTokenValid());
    CHECK_EQ(session.userId, "");
    CHECK_EQ(session.displayName, "");
    CHECK_EQ(session.email, "");
    CHECK_EQ(session.membershipTier, "");
}

TEST_CASE("AuthSessionCurrentEpochMsMonotonic") {
    int64_t before = OPN::AuthSession::CurrentEpochMs();
    int64_t after = OPN::AuthSession::CurrentEpochMs();
    CHECK(after >= before);
}

}

namespace auth_oauth_session_tests {

TEST_SUITE("auth/oauth-session")

TEST_CASE("ParseOAuthSession") {
    NSString *header = @"eyJhbGciOiJub25lIn0";
    NSString *payload = @"eyJzdWIiOiJ0ZXN0LXVzZXIiLCJuYW1lIjoiVGVzdCBVc2VyIiwiZW1haWwiOiJ0ZXN0QGV4YW1wbGUuY29tIiwibWVtYmVyc2hpcF90aWVyIjoiUHJlbWl1bSIsImV4cCI6OTk5OTk5OTk5OX0";
    NSString *idToken = [NSString stringWithFormat:@"%@.%@.signature", header, payload];

    NSDictionary *json = @{
        @"access_token": @"abc123",
        @"id_token": idToken,
        @"refresh_token": @"refresh-token",
        @"client_token": @"client-token",
        @"expires_in": @"3600",
        @"client_token_expires_in": @"7200"
    };

    OPN::AuthSession session = OPN::AuthService::ParseOAuthSession(json);
    CHECK_EQ(session.accessToken, "abc123");
    CHECK_EQ(session.idToken, [idToken UTF8String]);
    CHECK_EQ(session.refreshToken, "refresh-token");
    CHECK_EQ(session.clientToken, "client-token");
    CHECK(session.HasAccessToken());
    CHECK(session.IsClientTokenValid());
    CHECK(session.idTokenExpiry > 0);
    CHECK_EQ(session.userId, "test-user");
    CHECK_EQ(session.displayName, "Test User");
    CHECK_EQ(session.email, "test@example.com");
    CHECK_EQ(session.membershipTier, "Premium");
}

TEST_CASE("ParseOAuthSessionWithoutIdToken") {
    NSDictionary *json = @{
        @"access_token": @"abc123",
        @"refresh_token": @"refresh-token",
        @"expires_in": @"3600"
    };

    OPN::AuthSession session = OPN::AuthService::ParseOAuthSession(json);
    CHECK_EQ(session.accessToken, "abc123");
    CHECK_EQ(session.refreshToken, "refresh-token");
    CHECK(session.HasAccessToken());
    CHECK_EQ(session.idToken, "");
    CHECK_EQ(session.userId, "");
    CHECK_EQ(session.displayName, "");
    CHECK_EQ(session.email, "");
    CHECK_EQ(session.membershipTier, "");
}

TEST_CASE("ParseOAuthSessionMissingMembershipTierDefaultsToFree") {
    NSString *header = @"eyJhbGciOiJub25lIn0";
    NSString *payload = @"eyJzdWIiOiJ0ZXN0LXVzZXIiLCJuYW1lIjoiVGVzdCBVc2VyIiwiZW1haWwiOiJ0ZXN0QGV4YW1wbGUuY29tIiwiZXhwIjo5OTk5OTk5OTk5fQ";
    NSString *idToken = [NSString stringWithFormat:@"%@.%@.signature", header, payload];

    NSDictionary *json = @{
        @"access_token": @"abc123",
        @"id_token": idToken,
        @"expires_in": @"3600"
    };

    OPN::AuthSession session = OPN::AuthService::ParseOAuthSession(json);
    CHECK_EQ(session.membershipTier, "Free");
}

TEST_CASE("ParseOAuthSessionHandlesMalformedIdTokensAndDefaultExpiry") {
    NSDictionary *singlePartToken = @{
        @"access_token": @"token-a",
        @"id_token": @"not-a-jwt"
    };
    OPN::AuthSession singlePartSession = OPN::AuthService::ParseOAuthSession(singlePartToken);
    CHECK(singlePartSession.isAuthenticated);
    CHECK_EQ(singlePartSession.idTokenExpiry, 0);
    CHECK_EQ(singlePartSession.userId, "");
    CHECK(singlePartSession.accessTokenExpiry > OPN::AuthSession::CurrentEpochMs());

    NSDictionary *invalidPayloadToken = @{
        @"access_token": @"token-b",
        @"id_token": @"header.invalid-payload.signature",
        @"client_token": @"client-token",
        @"client_token_expires_in": @"0"
    };
    OPN::AuthSession invalidPayloadSession = OPN::AuthService::ParseOAuthSession(invalidPayloadToken);
    CHECK(invalidPayloadSession.isAuthenticated);
    CHECK_EQ(invalidPayloadSession.idTokenExpiry, 0);
    CHECK_EQ(invalidPayloadSession.clientTokenExpiry, 0);
    CHECK_EQ(invalidPayloadSession.membershipTier, "Free");
}

TEST_CASE("ParseOAuthSessionHandlesUnauthenticatedResponse") {
    OPN::AuthSession session = OPN::AuthService::ParseOAuthSession(@{});
    CHECK(!session.isAuthenticated);
    CHECK(!session.HasAccessToken());
    CHECK(session.expiresAt > 0);
    CHECK(session.accessTokenExpiry > OPN::AuthSession::CurrentEpochMs());
}

}

namespace auth_persistence_tests {

TEST_SUITE("auth/persistence")

TEST_CASE("SaveLoadSelectAndRemoveSessions") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();

    CHECK(!auth.LoadSavedSession().isAuthenticated);
    CHECK(auth.LoadSavedSessions().empty());
    CHECK(!auth.LoadSavedSessionForUserId("").isAuthenticated);

    OPN::AuthSession invalidSession;
    invalidSession.isAuthenticated = true;
    auth.SaveSession(invalidSession);
    CHECK(auth.LoadSavedSessions().empty());

    OPN::AuthSession first = MakeAuthenticatedSession("user-a", "a@example.com", "access-a");
    OPN::AuthSession second = MakeAuthenticatedSession("user-b", "b@example.com", "access-b");
    auth.SaveSession(first);
    auth.SaveSession(second);

    std::vector<OPN::AuthSession> sessions = auth.LoadSavedSessions();
    CHECK_EQ(static_cast<int>(sessions.size()), 2);
    CHECK_EQ(auth.LoadSavedSession().userId, "user-b");
    CHECK_EQ(auth.LoadSavedSessionForUserId("user-a").email, "a@example.com");
    CHECK(!auth.LoadSavedSessionForUserId("missing-user").isAuthenticated);

    auth.SetActiveSessionUserId("missing-user");
    CHECK_EQ(auth.LoadSavedSession().userId, "user-b");

    auth.SetActiveSessionUserId("user-a");
    CHECK_EQ(auth.LoadSavedSession().userId, "user-a");

    auth.RemoveSavedSession("user-a");
    CHECK_EQ(auth.LoadSavedSession().userId, "user-b");
    CHECK_EQ(static_cast<int>(auth.LoadSavedSessions().size()), 1);

    auth.RemoveSavedSession("user-b");
    CHECK(!auth.LoadSavedSession().isAuthenticated);
    CHECK(auth.LoadSavedSessions().empty());

    (void)environment.RootPath();
}

TEST_CASE("LoadSavedSessionFallsBackToFirstStoredAccount") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    OPN::AuthSession first = MakeAuthenticatedSession("fallback-a", "fallback-a@example.com", "fallback-a-token");
    OPN::AuthSession second = MakeAuthenticatedSession("fallback-b", "fallback-b@example.com", "fallback-b-token");
    auth.SaveSession(first);
    auth.SaveSession(second);

    [environment.UserDefaults() setObject:@"missing-user" forKey:@"OPN_ActiveUserId"];
    [environment.UserDefaults() synchronize];

    OPN::AuthSession loaded = auth.LoadSavedSession();
    CHECK(loaded.isAuthenticated);
    CHECK_EQ(loaded.userId, "fallback-b");
}

TEST_CASE("SaveSessionUsesEmailDisplayNameAndAccessTokenIdentities") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();

    OPN::AuthSession emailIdentity = MakeAuthenticatedSession("", "identity@example.com", "identity-email-token");
    auth.SaveSession(emailIdentity);

    OPN::AuthSession displayNameIdentity = MakeAuthenticatedSession("", "", "identity-display-token");
    displayNameIdentity.displayName = "Display Identity";
    auth.SaveSession(displayNameIdentity);

    OPN::AuthSession accessTokenIdentity = MakeAuthenticatedSession("", "", "identity-access-token");
    accessTokenIdentity.displayName.clear();
    auth.SaveSession(accessTokenIdentity);

    CHECK(auth.LoadSavedSessionForUserId("identity@example.com").isAuthenticated);
    CHECK(auth.LoadSavedSessionForUserId("Display Identity").isAuthenticated);
    CHECK(auth.LoadSavedSessionForUserId("identity-access-token").isAuthenticated);
    CHECK_EQ(static_cast<int>(auth.LoadSavedSessions().size()), 3);
    (void)environment.RootPath();
}

TEST_CASE("LoadSavedSessionMigratesLegacySingleSession") {
    AuthTestEnvironment environment;
    NSString *legacyDir = [environment.RootPath() stringByAppendingPathComponent:@"com.nvidia.geforcenow"];
    [[NSFileManager defaultManager] createDirectoryAtPath:legacyDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *legacyPath = [legacyDir stringByAppendingPathComponent:@"session.plist"];
    NSDictionary *legacySession = @{
        @"access_token": @"legacy-access",
        @"user_id": @"legacy-user",
        @"email": @"legacy@example.com",
        @"display_name": @"Legacy User",
        @"access_token_expiry": @(OPN::AuthSession::CurrentEpochMs() + 3600000)
    };
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:legacySession
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:nil];
    CHECK([plistData writeToFile:legacyPath atomically:YES]);
    [environment.UserDefaults() setBool:YES forKey:@"GFN_HasSavedSession"];
    [environment.UserDefaults() synchronize];

    OPN::AuthSession loaded = OPN::AuthService::Shared().LoadSavedSession();
    CHECK(loaded.isAuthenticated);
    CHECK_EQ(loaded.userId, "legacy-user");
    CHECK_EQ(loaded.membershipTier, "Free");
    CHECK_EQ(static_cast<int>(OPN::AuthService::Shared().LoadSavedSessions().size()), 1);
}

TEST_CASE("ClearSessionRemovesStoredFilesWhenNoActiveUser") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    OPN::AuthSession session = MakeAuthenticatedSession("clear-user", "clear@example.com", "clear-token");
    auth.SaveSession(session);
    [environment.UserDefaults() removeObjectForKey:@"OPN_ActiveUserId"];
    [environment.UserDefaults() setBool:YES forKey:@"OPN_HasSavedSession"];
    [environment.UserDefaults() synchronize];

    auth.ClearSession();
    CHECK(!auth.LoadSavedSession().isAuthenticated);
    CHECK(auth.LoadSavedSessions().empty());
}

TEST_CASE("StayLoggedInUsesDefaultLegacyAndOpenNOWValues") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();

    CHECK(auth.GetStayLoggedIn());
    [environment.UserDefaults() setBool:NO forKey:@"GFN_StayLoggedIn"];
    [environment.UserDefaults() synchronize];
    CHECK(!auth.GetStayLoggedIn());

    auth.SetStayLoggedIn(true);
    CHECK(auth.GetStayLoggedIn());
}

}

namespace auth_device_tests {

TEST_SUITE("auth/device")

TEST_CASE("PersistentDeviceUUIDMigratesLegacyValue") {
    AuthTestEnvironment environment;
    [environment.UserDefaults() setObject:@"legacy-device-id" forKey:@"GFN_PersistentDeviceUUID"];
    [environment.UserDefaults() synchronize];

    std::string uuid = OPN::AuthService::GetPersistentDeviceUUID();
    CHECK_EQ(uuid, "legacy-device-id");
    CHECK_EQ(std::string([[environment.UserDefaults() stringForKey:@"OPN_PersistentDeviceUUID"] UTF8String]), "legacy-device-id");
}

}

namespace auth_network_tests {

TEST_SUITE("auth/network")

TEST_CASE("FetchClientTokenHandlesSuccessMissingTokenHttpAndTransportFailures") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *) -> MockHTTPResponse {
        ++callIndex;
        if (callIndex == 1) {
            return MockHTTPResponse{200, JSONData(@{@"client_token": @"client-success", @"expires_in": @123}), nil};
        }
        if (callIndex == 2) {
            return MockHTTPResponse{200, JSONData(@{@"expires_in": @123}), nil};
        }
        if (callIndex == 3) {
            return MockHTTPResponse{503, JSONData(@{@"error": @"unavailable"}), nil};
        }
        NSError *error = [NSError errorWithDomain:@"OpenNOWTests" code:7 userInfo:nil];
        return MockHTTPResponse{0, nil, error};
    });

    bool done = false;
    bool success = false;
    std::string token;
    std::string error;

    auth.FetchClientToken("access-token", [&](bool ok, const std::string &clientToken, const std::string &message) {
        success = ok;
        token = clientToken;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(token, "client-success");
    CHECK_EQ(error, "123");

    done = false;
    auth.FetchClientToken("access-token", [&](bool ok, const std::string &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "No client_token in response");

    done = false;
    auth.FetchClientToken("access-token", [&](bool ok, const std::string &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "HTTP 503");

    done = false;
    auth.FetchClientToken("access-token", [&](bool ok, const std::string &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK(!error.empty());

    (void)environment.RootPath();
}

TEST_CASE("FetchStarFleetUserInfoHandlesSuccessHttpAndTransportFailures") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *) -> MockHTTPResponse {
        ++callIndex;
        if (callIndex == 1) {
            return MockHTTPResponse{200, JSONData(@{@"sub": @"user-info-id", @"email": @"info@example.com"}), nil};
        }
        if (callIndex == 2) {
            return MockHTTPResponse{401, JSONData(@{@"error": @"unauthorized"}), nil};
        }
        NSError *error = [NSError errorWithDomain:@"OpenNOWTests" code:8 userInfo:nil];
        return MockHTTPResponse{0, nil, error};
    });

    bool done = false;
    bool success = false;
    NSDictionary *info = nil;
    std::string error;

    auth.FetchStarFleetUserInfo("access-token", [&](bool ok, NSDictionary *userInfo, const std::string &message) {
        success = ok;
        info = userInfo;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(std::string([info[@"sub"] UTF8String]), "user-info-id");
    CHECK_EQ(error, "");

    done = false;
    auth.FetchStarFleetUserInfo("access-token", [&](bool ok, NSDictionary *, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "HTTP 401");

    done = false;
    auth.FetchStarFleetUserInfo("access-token", [&](bool ok, NSDictionary *, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK(!error.empty());

    (void)environment.RootPath();
}

TEST_CASE("ServerLogoutHandlesEmptyTokenSuccessAndTransportFailure") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    auth.SaveSession(MakeAuthenticatedSession("logout-user", "logout@example.com", "logout-token"));

    bool done = false;
    bool success = false;
    std::string error;
    auth.ServerLogout("", "", [&](bool ok, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(done);
    CHECK(success);
    CHECK_EQ(error, "");

    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *) -> MockHTTPResponse {
        ++callIndex;
        if (callIndex == 1) {
            return MockHTTPResponse{200, [NSData data], nil};
        }
        NSError *error = [NSError errorWithDomain:@"OpenNOWTests" code:9 userInfo:nil];
        return MockHTTPResponse{0, nil, error};
    });

    auth.SaveSession(MakeAuthenticatedSession("logout-user", "logout@example.com", "logout-token"));
    done = false;
    auth.ServerLogout("id token/with spaces", "", [&](bool ok, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(error, "");

    auth.SaveSession(MakeAuthenticatedSession("logout-user", "logout@example.com", "logout-token"));
    done = false;
    auth.ServerLogout("id-token", "fr_FR", [&](bool ok, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK(!error.empty());
}

TEST_CASE("RefreshSessionHandlesMissingAndUnrefreshableSessions") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    bool done = false;
    bool success = true;
    std::string error;

    auth.RefreshSession([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });
    CHECK(done);
    CHECK(!success);
    CHECK_EQ(error, "No saved session available");

    OPN::AuthSession expired = MakeAuthenticatedSession("expired-user", "expired@example.com", "expired-token");
    expired.refreshToken.clear();
    expired.clientToken.clear();
    expired.clientTokenExpiry = 0;
    expired.clientTokenExpiryLength = 0;
    expired.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() - 1000;
    auth.SaveSession(expired);

    done = false;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &message) {
        success = ok;
        error = message;
        CHECK_EQ(session.userId, "expired-user");
        done = true;
    });
    CHECK(done);
    CHECK(!success);
    CHECK_EQ(error, "No refresh mechanism available");
}

TEST_CASE("RefreshSessionRefreshesClientTokenAndOAuthTokens") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *request) -> MockHTTPResponse {
        ++callIndex;
        if ([request.URL.path isEqualToString:@"/client_token"]) {
            return MockHTTPResponse{200, JSONData(@{@"client_token": @"fresh-client-token", @"expires_in": @"900"}), nil};
        }
        return MockHTTPResponse{200, JSONData(@{
            @"access_token": @"refreshed-access",
            @"refresh_token": @"refreshed-refresh",
            @"client_token": @"refreshed-client",
            @"expires_in": @"1800",
            @"client_token_expires_in": @"1800"
        }), nil};
    });

    OPN::AuthSession validNeedsClient = MakeAuthenticatedSession("client-refresh-user", "client-refresh@example.com", "valid-access");
    validNeedsClient.clientToken.clear();
    validNeedsClient.clientTokenExpiry = 0;
    validNeedsClient.clientTokenExpiryLength = 0;
    auth.SaveSession(validNeedsClient);

    bool done = false;
    bool success = false;
    OPN::AuthSession refreshedClient;
    std::string error;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &message) {
        success = ok;
        refreshedClient = session;
        error = message;
        done = true;
    });
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(refreshedClient.clientToken, "fresh-client-token");
    CHECK_EQ(error, "");

    OPN::AuthSession expiredWithRefresh = MakeAuthenticatedSession("oauth-refresh-user", "oauth-refresh@example.com", "old-access");
    expiredWithRefresh.clientToken.clear();
    expiredWithRefresh.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() - 1000;
    auth.SaveSession(expiredWithRefresh);

    done = false;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &message) {
        success = ok;
        refreshedClient = session;
        error = message;
        done = true;
    }, true);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(refreshedClient.accessToken, "refreshed-access");
    CHECK_EQ(refreshedClient.refreshToken, "refreshed-refresh");
    CHECK_EQ(refreshedClient.clientToken, "refreshed-client");
    CHECK_EQ(error, "");
    CHECK(callIndex >= 2);
}

TEST_CASE("RefreshSessionUsesClientTokenGrantAndMergesSavedFields") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *) -> MockHTTPResponse {
        ++callIndex;
        return MockHTTPResponse{200, JSONData(@{
            @"access_token": @"client-grant-access",
            @"expires_in": @"1200"
        }), nil};
    });

    OPN::AuthSession saved = MakeAuthenticatedSession("client-grant-user", "client-grant@example.com", "old-access");
    saved.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() - 1000;
    saved.clientToken = "saved-client-token";
    saved.clientTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 3600000;
    saved.clientTokenExpiryLength = 3600000;
    auth.SaveSession(saved);

    bool done = false;
    bool success = false;
    OPN::AuthSession refreshed;
    std::string error;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &message) {
        success = ok;
        refreshed = session;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(refreshed.accessToken, "client-grant-access");
    CHECK_EQ(refreshed.refreshToken, "refresh-client-grant-user");
    CHECK_EQ(refreshed.clientToken, "saved-client-token");
    CHECK_EQ(refreshed.email, "client-grant@example.com");
    CHECK_EQ(error, "");
    CHECK_EQ(callIndex, 1);
}

TEST_CASE("RefreshSessionRefreshesExpiringClientTokenUsingFallbackWindow") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    ScopedURLMock mock([](NSURLRequest *) -> MockHTTPResponse {
        return MockHTTPResponse{200, JSONData(@{@"client_token": @"window-client-token"}), nil};
    });

    OPN::AuthSession saved = MakeAuthenticatedSession("window-user", "window@example.com", "window-access");
    saved.clientToken = "expiring-client-token";
    saved.clientTokenExpiry = OPN::AuthSession::CurrentEpochMs() + 1000;
    saved.clientTokenExpiryLength = 0;
    auth.SaveSession(saved);

    bool done = false;
    bool success = false;
    OPN::AuthSession refreshed;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &) {
        success = ok;
        refreshed = session;
        done = true;
    });

    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(refreshed.clientToken, "window-client-token");
    CHECK(refreshed.clientTokenExpiryLength > 0);
}

TEST_CASE("RefreshSessionFallsBackFromClientTokenGrantToRefreshToken") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *) -> MockHTTPResponse {
        ++callIndex;
        if (callIndex == 1) {
            return MockHTTPResponse{401, JSONData(@{@"error": @"client_token_denied"}), nil};
        }
        return MockHTTPResponse{200, JSONData(@{
            @"access_token": @"fallback-access",
            @"refresh_token": @"fallback-refresh",
            @"client_token": @"fallback-client",
            @"expires_in": @"1200",
            @"client_token_expires_in": @"1200"
        }), nil};
    });

    OPN::AuthSession saved = MakeAuthenticatedSession("fallback-refresh-user", "fallback-refresh@example.com", "old-access");
    saved.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() - 1000;
    saved.clientToken = "denied-client-token";
    auth.SaveSession(saved);

    bool done = false;
    bool success = false;
    OPN::AuthSession refreshed;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &session, const std::string &) {
        success = ok;
        refreshed = session;
        done = true;
    });

    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(refreshed.accessToken, "fallback-access");
    CHECK_EQ(refreshed.refreshToken, "fallback-refresh");
    CHECK_EQ(refreshed.clientToken, "fallback-client");
    CHECK_EQ(callIndex, 2);
}

TEST_CASE("RefreshSessionReportsOAuthRefreshErrors") {
    AuthTestEnvironment environment;
    OPN::AuthService &auth = OPN::AuthService::Shared();
    ScopedURLMock mock([](NSURLRequest *) -> MockHTTPResponse {
        return MockHTTPResponse{400, JSONData(@{@"error_description": @"refresh denied"}), nil};
    });

    OPN::AuthSession expiredWithRefresh = MakeAuthenticatedSession("refresh-error-user", "refresh-error@example.com", "old-access");
    expiredWithRefresh.clientToken.clear();
    expiredWithRefresh.accessTokenExpiry = OPN::AuthSession::CurrentEpochMs() - 1000;
    auth.SaveSession(expiredWithRefresh);

    bool done = false;
    bool success = true;
    std::string error;
    auth.RefreshSession([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    }, true);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "refresh denied");
}

}

namespace auth_oauth_callback_tests {

TEST_SUITE("auth/oauth-callback")

TEST_CASE("StartOAuthLoginFailsWhenNoCallbackPortIsAvailable") {
    AuthTestEnvironment environment;
    ScopedBoundPorts ports;
    ports.BindAllCandidatePorts();

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(done);
    CHECK(!success);
    CHECK_EQ(error, "No available port for OAuth callback");
    (void)environment.RootPath();
}

TEST_CASE("StartOAuthLoginHandlesInvalidCallbackRequest") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    SendOAuthCallbackRequest(callbackPort, "POST / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "Invalid OAuth callback request");
}

TEST_CASE("StartOAuthLoginReportsCallbackErrorDescription") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    SendOAuthCallbackRequest(callbackPort, "GET /?error=access_denied&error_description=Denied%20Now HTTP/1.1\r\nHost: localhost\r\n\r\n");
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "Denied Now");
}

TEST_CASE("StartOAuthLoginRejectsMismatchedState") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    SendOAuthCallbackRequest(callbackPort, "GET /?code=auth-code&state=wrong-state HTTP/1.1\r\nHost: localhost\r\n\r\n");
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK(!error.empty());
}

TEST_CASE("StartOAuthLoginHandlesEmptyCallbackRequest") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    OpenAndCloseOAuthCallback(callbackPort);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "Empty OAuth callback request");
}

TEST_CASE("StartOAuthLoginHandlesMalformedCallbackRequest") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    SendOAuthCallbackRequest(callbackPort, "GET /missing-space");
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "Malformed OAuth callback request");
}

TEST_CASE("StartOAuthLoginExchangesMatchingCallbackCode") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    int callIndex = 0;
    ScopedURLMock mock([&](NSURLRequest *request) -> MockHTTPResponse {
        ++callIndex;
        if ([request.URL.path isEqualToString:@"/token"]) {
            return MockHTTPResponse{200, JSONData(@{
                @"access_token": @"oauth-callback-access",
                @"refresh_token": @"oauth-callback-refresh",
                @"expires_in": @"1800"
            }), nil};
        }
        return MockHTTPResponse{200, JSONData(@{@"client_token": @"oauth-callback-client", @"expires_in": @"600"}), nil};
    });

    bool done = false;
    bool success = false;
    OPN::AuthSession session;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &authSession, const std::string &message) {
        success = ok;
        session = authSession;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    CHECK_EQ(std::string([QueryValue(workspace.LastURL(), @"idp_id") UTF8String]), OPN::AuthService::kDefaultIdpId);
    NSString *state = QueryValue(workspace.LastURL(), @"state");
    REQUIRE(state.length > 0);
    std::string request = "GET /?code=auth-code&state=" + std::string([state UTF8String]) + " HTTP/1.1\r\nHost: localhost\r\n\r\n";
    SendOAuthCallbackRequest(callbackPort, request);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(session.accessToken, "oauth-callback-access");
    CHECK_EQ(session.refreshToken, "oauth-callback-refresh");
    CHECK_EQ(session.clientToken, "oauth-callback-client");
    CHECK_EQ(session.idpId, OPN::AuthService::kDefaultIdpId);
    CHECK_EQ(error, "");
    CHECK_EQ(callIndex, 2);
}

TEST_CASE("StartOAuthLoginUsesSelectedProviderIdp") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    ScopedURLMock mock([](NSURLRequest *request) -> MockHTTPResponse {
        if ([request.URL.path isEqualToString:@"/token"]) {
            return MockHTTPResponse{200, JSONData(@{
                @"access_token": @"alliance-access",
                @"refresh_token": @"alliance-refresh",
                @"expires_in": @"1800"
            }), nil};
        }
        return MockHTTPResponse{200, JSONData(@{@"client_token": @"alliance-client", @"expires_in": @"600"}), nil};
    });

    bool done = false;
    bool success = false;
    OPN::AuthSession session;
    OPN::AuthService::Shared().StartOAuthLogin("ally-idp", [&](bool ok, const OPN::AuthSession &authSession, const std::string &) {
        success = ok;
        session = authSession;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    CHECK_EQ(std::string([QueryValue(workspace.LastURL(), @"idp_id") UTF8String]), "ally-idp");
    NSString *state = QueryValue(workspace.LastURL(), @"state");
    REQUIRE(state.length > 0);
    std::string request = "GET /?code=auth-code&state=" + std::string([state UTF8String]) + " HTTP/1.1\r\nHost: localhost\r\n\r\n";
    SendOAuthCallbackRequest(callbackPort, request);

    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(session.accessToken, "alliance-access");
    CHECK_EQ(session.idpId, "ally-idp");
}

TEST_CASE("StartOAuthLoginReportsTokenExchangeHttpError") {
    AuthTestEnvironment environment;
    ScopedWorkspaceOpenURLStub workspace;
    ScopedBoundPorts reservedPorts;
    int callbackPort = reservedPorts.BindAllButOneCandidatePort();
    REQUIRE(callbackPort != 0);

    ScopedURLMock mock([](NSURLRequest *) -> MockHTTPResponse {
        return MockHTTPResponse{400, JSONData(@{@"message": @"token exchange rejected"}), nil};
    });

    bool done = false;
    bool success = true;
    std::string error;
    OPN::AuthService::Shared().StartOAuthLogin([&](bool ok, const OPN::AuthSession &, const std::string &message) {
        success = ok;
        error = message;
        done = true;
    });

    CHECK(WaitUntil([&] { return workspace.LastURL() != nil; }));
    NSString *state = QueryValue(workspace.LastURL(), @"state");
    REQUIRE(state.length > 0);
    std::string request = "GET /?code=auth-code&state=" + std::string([state UTF8String]) + " HTTP/1.1\r\nHost: localhost\r\n\r\n";
    SendOAuthCallbackRequest(callbackPort, request);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(!success);
    CHECK_EQ(error, "token exchange rejected");
}

TEST_CASE("game-cache/catalog freshness metadata") {
    OPN::GameDataCache &cache = OPN::GameDataCache::Shared();
    std::string unique = [[[NSUUID UUID] UUIDString] UTF8String];
    std::string key = cache.CatalogKey("account-" + unique, "unit-" + unique, "last_played", {"owned"}, 24);
    CHECK(cache.CatalogKey("other-account-" + unique, "unit-" + unique, "last_played", {"owned"}, 24) != key);

    OPN::CatalogBrowseResult saved;
    saved.numberReturned = 1;
    saved.numberSupported = 1;
    saved.totalCount = 1;
    saved.selectedSortId = "last_played";
    saved.selectedFilterIds = {"owned"};
    OPN::GameInfo game;
    game.id = unique;
    game.title = "Cached Game";
    saved.games.push_back(game);
    cache.SaveCatalog(key, saved);

    OPN::CatalogBrowseResult loaded;
    CHECK(cache.LoadCatalog(key, loaded));
    REQUIRE(loaded.games.size() == 1);
    CHECK_EQ(loaded.games[0].title, "Cached Game");

    OPN::CatalogBrowseResult fresh;
    CHECK(cache.LoadFreshCatalog(key, 60.0, fresh));
    REQUIRE(fresh.games.size() == 1);
    CHECK_EQ(fresh.selectedFilterIds[0], "owned");

    OPN::CatalogBrowseResult stale;
    CHECK(!cache.LoadFreshCatalog(key, 0.0, stale));
}

TEST_CASE("game-cache/catalog definitions freshness") {
    OPN::GameDataCache &cache = OPN::GameDataCache::Shared();
    NSString *locale = [@"unit-" stringByAppendingString:[[NSUUID UUID] UUIDString]];
    NSDictionary *definitions = @{
        @"filterGroupDefinitions": @[
            @{
                @"id": @"stores",
                @"label": @"Stores",
                @"filters": @[
                    @{@"id": @"steam", @"label": @"Steam", @"filters": @[@"{\"store\":\"steam\"}"]}
                ]
            }
        ],
        @"sortOrderDefinitions": @[
            @{@"id": @"title", @"label": @"Title", @"orderBy": @"title:ASC"}
        ]
    };

    cache.SaveCatalogDefinitions(locale, definitions);

    NSDictionary *loaded = nil;
    CHECK(cache.LoadCatalogDefinitions(locale, 60.0, &loaded));
    REQUIRE(loaded != nil);
    NSArray *groups = loaded[@"filterGroupDefinitions"];
    CHECK([groups isKindOfClass:NSArray.class]);
    CHECK_EQ(groups.count, 1u);

    NSDictionary *stale = nil;
    CHECK(!cache.LoadCatalogDefinitions(locale, 0.0, &stale));
    CHECK(stale == nil);
}

TEST_CASE("game-cache/images handle missing and empty data") {
    OPN::GameDataCache &cache = OPN::GameDataCache::Shared();
    NSString *url = [@"https://images.example.test/" stringByAppendingString:[[NSUUID UUID] UUIDString]];

    CHECK(cache.LoadImage(url) == nil);
    cache.SaveImage(url, [NSData data]);
    CHECK(cache.LoadImage(url) == nil);

    NSData *imageData = [@"image-bytes" dataUsingEncoding:NSUTF8StringEncoding];
    cache.SaveImage(url, imageData);
    NSData *loaded = cache.LoadImage(url);
    REQUIRE(loaded != nil);
    CHECK([loaded isEqualToData:imageData]);
}

TEST_CASE("http-utils validate responses and parse json") {
    NSString *jsonError = nil;
    NSData *jsonData = OPN::JSONDataFromObject(@{@"ok": @YES}, &jsonError);
    REQUIRE(jsonData != nil);
    CHECK(jsonError == nil);

    id object = OPN::JSONObjectFromData(jsonData, &jsonError);
    REQUIRE([object isKindOfClass:NSDictionary.class]);
    CHECK([object[@"ok"] boolValue]);

    NSString *parseError = nil;
    CHECK(OPN::JSONObjectFromData([@"not-json" dataUsingEncoding:NSUTF8StringEncoding], &parseError) == nil);
    REQUIRE(parseError != nil);
    CHECK([parseError containsString:@"Invalid JSON"]);

    NSURL *url = [NSURL URLWithString:@"https://example.test/status"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:503 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    NSString *httpError = nil;
    CHECK(!OPN::ValidateHTTPResponse(response, [NSData data], nil, 200, &httpError));
    CHECK([httpError isEqualToString:@"HTTP 503"]);
}

TEST_CASE("game-service/provider info selects matching idp endpoint") {
    ScopedURLMock mock([](NSURLRequest *request) {
        CHECK([request.URL.host isEqualToString:@"pcs.geforcenow.com"]);
        CHECK([request.URL.path isEqualToString:@"/v1/serviceUrls"]);
        NSDictionary *body = @{
            @"gfnServiceInfo": @{
                @"defaultProvider": @"nvidia",
                @"loginRequired": @YES,
                @"loginPreferredProviders": @[@"nvidia", @"ally"],
                @"gfnServiceEndpoints": @[
                    @{
                        @"loginProvider": @"nvidia",
                        @"loginProviderCode": @"NV",
                        @"loginProviderDisplayName": @"NVIDIA",
                        @"streamingServiceUrl": @"https://prod.cloudmatchbeta.nvidiagrid.net/",
                        @"idpId": @"default-idp",
                        @"loginProviderPriority": @0
                    },
                    @{
                        @"loginProvider": @"ally",
                        @"loginProviderCode": @"AL",
                        @"loginProviderDisplayName": @"Alliance",
                        @"streamingServiceUrl": @"https://ally.cloudmatch.example.net",
                        @"idpId": @"ally-idp",
                        @"redeemRedirectUrl": @"https://ally.example.net/redeem",
                        @"loginProviderPriority": @2
                    }
                ]
            }
        };
        return MockHTTPResponse{200, JSONData(body), nil};
    });

    OPN::GameService::Shared().SetAccessToken("provider-token");
    bool done = false;
    bool success = false;
    OPN::GameProviderInfo info;
    OPN::GameProviderEndpoint endpoint;
    OPN::GameService::Shared().FetchProviderInfo("ally-idp", [&](bool ok,
                                                                   const OPN::GameProviderInfo &providerInfo,
                                                                   const OPN::GameProviderEndpoint &selectedEndpoint,
                                                                   const std::string &) {
        success = ok;
        info = providerInfo;
        endpoint = selectedEndpoint;
        done = true;
    });

    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(info.defaultProvider, "nvidia");
    REQUIRE(info.endpoints.size() == 2);
    CHECK_EQ(endpoint.loginProvider, "ally");
    CHECK_EQ(endpoint.streamingServiceUrl, "https://ally.cloudmatch.example.net/");
    CHECK_EQ(OPN::GameService::Shared().ProviderStreamingBaseUrl(), "https://ally.cloudmatch.example.net/");
}

}
