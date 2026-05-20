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
#include "../src/streaming/OPNStreamPreferences.h"
#include "../src/auth/OPNAuthService.h"
#include "../src/common/OPNAuthTypes.h"

namespace {

constexpr int kOAuthCallbackPorts[] = {2259, 6460, 7119, 8870, 9096};

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
    return gMockURLHandler && [request.URL.host isEqualToString:@"login.nvidia.com"];
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
    NSString *state = QueryValue(workspace.LastURL(), @"state");
    REQUIRE(state.length > 0);
    std::string request = "GET /?code=auth-code&state=" + std::string([state UTF8String]) + " HTTP/1.1\r\nHost: localhost\r\n\r\n";
    SendOAuthCallbackRequest(callbackPort, request);
    CHECK(WaitUntil([&] { return done; }));
    CHECK(success);
    CHECK_EQ(session.accessToken, "oauth-callback-access");
    CHECK_EQ(session.refreshToken, "oauth-callback-refresh");
    CHECK_EQ(session.clientToken, "oauth-callback-client");
    CHECK_EQ(error, "");
    CHECK_EQ(callIndex, 2);
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

}
