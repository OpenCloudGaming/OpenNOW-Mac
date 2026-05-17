#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#import <Foundation/Foundation.h>
#include "doctest.h"

#include "../src/streaming/OPNStreamBackend.h"
#include "../src/auth/OPNAuthService.h"
#include "../src/common/OPNAuthTypes.h"

TEST_SUITE("backend")

TEST_CASE("ResolveStreamWebRTCBackend") {
    OPN::StreamWebRTCBackend backend = OPN::ResolveStreamWebRTCBackend();
    CHECK(backend == OPN::StreamWebRTCBackend::LibWebRTC);
}

TEST_CASE("StreamWebRTCBackendName") {
    std::string name = OPN::StreamWebRTCBackendName(OPN::StreamWebRTCBackend::LibWebRTC);
    CHECK_EQ(name, "libwebrtc");
}

TEST_CASE("ParseQueryString") {
    NSString *query = @"access_token=abc123&refresh_token=xyz%2078&empty=&skip";
    NSDictionary *params = OPN::AuthService::parseQueryString(query);
    CHECK_EQ(static_cast<int>(params.count), 3);
    CHECK_EQ(std::string([params[@"access_token"] UTF8String]), "abc123");
    CHECK_EQ(std::string([params[@"refresh_token"] UTF8String]), "xyz 78");
    CHECK_EQ(std::string([params[@"empty"] UTF8String]), "");
}

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
