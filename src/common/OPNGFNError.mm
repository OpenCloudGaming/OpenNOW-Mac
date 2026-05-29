#include "OPNGFNError.h"

#import <Foundation/Foundation.h>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <limits>
#include <string>

namespace OPN {

static constexpr long long kNoGFNErrorCode = std::numeric_limits<long long>::min();

static std::string ASCIILower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return (char)std::tolower(character);
    });
    return value;
}

static bool Contains(const std::string &text, const char *needle) {
    return text.find(needle) != std::string::npos;
}

static NSString *NSStringFromStdString(const std::string &value) {
    if (value.empty()) return @"";
    NSString *string = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}

static NSDictionary *JSONDictionaryFromError(const std::string &errorMessage) {
    size_t jsonStart = errorMessage.find('{');
    if (jsonStart == std::string::npos) return nil;

    std::string jsonText = errorMessage.substr(jsonStart);
    NSData *data = [[NSData alloc] initWithBytes:jsonText.data() length:jsonText.size()];
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![object isKindOfClass:NSDictionary.class]) return nil;
    return (NSDictionary *)object;
}

static NSNumber *NumberValue(id value) {
    if ([value isKindOfClass:NSNumber.class]) return (NSNumber *)value;
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = (NSString *)value;
        if (string.length == 0) return nil;
        std::string text([string UTF8String] ?: "");
        char *end = nullptr;
        long long parsed = std::strtoll(text.c_str(), &end, 0);
        if (end && *end == '\0') return @(parsed);
    }
    return nil;
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? (NSString *)value : nil;
}

static NSDictionary *DictionaryValue(id value) {
    return [value isKindOfClass:NSDictionary.class] ? (NSDictionary *)value : nil;
}

static long long ErrorCodeFromDictionary(NSDictionary *json) {
    if (!json) return kNoGFNErrorCode;

    NSDictionary *requestStatus = DictionaryValue(json[@"requestStatus"]);
    NSNumber *unifiedErrorCode = NumberValue(requestStatus[@"unifiedErrorCode"]);
    if (unifiedErrorCode && unifiedErrorCode.longLongValue != 0) return unifiedErrorCode.longLongValue;

    NSNumber *requestStatusCode = NumberValue(requestStatus[@"statusCode"]);
    if (requestStatusCode) return requestStatusCode.longLongValue;

    NSDictionary *result = DictionaryValue(json[@"result"]);
    NSNumber *resultCode = NumberValue(result[@"result"]);
    if (resultCode) return resultCode.longLongValue;

    NSNumber *statusCode = NumberValue(json[@"statusCode"]);
    if (statusCode) return statusCode.longLongValue;

    NSNumber *code = NumberValue(json[@"code"]);
    if (code) return code.longLongValue;

    NSNumber *errorCode = NumberValue(json[@"errorCode"]);
    if (errorCode) return errorCode.longLongValue;

    unifiedErrorCode = NumberValue(json[@"unifiedErrorCode"]);
    if (unifiedErrorCode && unifiedErrorCode.longLongValue != 0) return unifiedErrorCode.longLongValue;

    return kNoGFNErrorCode;
}

static NSString *ErrorDescriptionFromDictionary(NSDictionary *json) {
    if (!json) return nil;

    NSDictionary *requestStatus = DictionaryValue(json[@"requestStatus"]);
    NSString *requestDescription = StringValue(requestStatus[@"statusDescription"]);
    if (requestDescription.length > 0) return requestDescription;

    NSString *errorMessage = StringValue(json[@"errorMessage"]);
    if (errorMessage.length > 0) return errorMessage;

    NSString *message = StringValue(json[@"message"]);
    if (message.length > 0) return message;

    return nil;
}

static long long HTTPStatusCodeFromError(const std::string &lowerError) {
    size_t httpIndex = lowerError.find("http ");
    if (httpIndex == std::string::npos) return kNoGFNErrorCode;

    size_t digitIndex = httpIndex + 5;
    if (digitIndex >= lowerError.size() || !std::isdigit((unsigned char)lowerError[digitIndex])) return kNoGFNErrorCode;

    long long value = 0;
    while (digitIndex < lowerError.size() && std::isdigit((unsigned char)lowerError[digitIndex])) {
        value = (value * 10) + (lowerError[digitIndex] - '0');
        digitIndex++;
    }
    return value;
}

static long long HexErrorCodeFromError(const std::string &lowerError) {
    size_t index = lowerError.find("0x");
    size_t digitIndex = std::string::npos;
    if (index != std::string::npos) {
        digitIndex = index + 2;
        if (digitIndex >= lowerError.size() || !std::isxdigit((unsigned char)lowerError[digitIndex])) return kNoGFNErrorCode;
    } else {
        size_t scanIndex = 0;
        while (scanIndex < lowerError.size()) {
            while (scanIndex < lowerError.size() && !std::isxdigit((unsigned char)lowerError[scanIndex])) scanIndex++;
            size_t tokenStart = scanIndex;
            bool hasDigit = false;
            bool hasAlpha = false;
            while (scanIndex < lowerError.size() && std::isxdigit((unsigned char)lowerError[scanIndex])) {
                hasDigit = hasDigit || std::isdigit((unsigned char)lowerError[scanIndex]);
                hasAlpha = hasAlpha || std::isalpha((unsigned char)lowerError[scanIndex]);
                scanIndex++;
            }
            if (scanIndex - tokenStart >= 6 && hasDigit && hasAlpha) {
                digitIndex = tokenStart;
                break;
            }
        }
        if (digitIndex == std::string::npos) return kNoGFNErrorCode;
    }

    long long value = 0;
    while (digitIndex < lowerError.size() && std::isxdigit((unsigned char)lowerError[digitIndex])) {
        char character = lowerError[digitIndex];
        int digit = std::isdigit((unsigned char)character) ? character - '0' : character - 'a' + 10;
        value = (value * 16) + digit;
        digitIndex++;
    }
    return value;
}

static bool MatchesCode(long long code, const std::string &lowerError, long long expectedCode, const char *name) {
    return code == expectedCode || Contains(lowerError, name);
}

struct GFNErrorRule {
    long long code;
    const char *symbol;
    const char *needle;
    const char *message;
};

static const GFNErrorRule kStructuredGFNErrorRules[] = {
    {0xC0F5213DLL, "SRC_TOO_MANY_REQUESTS", "src_too_many", "Too many GeForce NOW launch requests were sent. Wait a few minutes, then try again."},
    {0xC0F52156LL, "SRC_INSUFFICIENT_PLAYABILITY_LEVEL", "src_insufficient_playability_level", "This stream quality is not available for your current GeForce NOW membership. Lower the streaming quality or upgrade your membership, then try again."},
    {0xC0F52147LL, "SRC_MAINTENANCE", "src_maintenance", "GeForce NOW is temporarily unavailable for maintenance. Try again later."},
    {0xC0F5213ELL, "SRC_QUEUE_LENGTH_EXCEEDED", "src_queue_length_exceeded", "The GeForce NOW queue is currently full. Try again later."},
    {0xC0F5215ALL, "SRC_STORAGE_NOT_AVAILABLE", "src_storage_not_available", "GeForce NOW cloud storage is not available for this session. Try again later."},
    {0xC0F52142LL, "SRC_GAME_BINARIES_NOT_AVAILABLE", "src_game_binaries_not_available", "This game is not available in the selected GeForce NOW region. Choose Automatic or another region, then try again."},
    {0xC0F52005LL, "SRC_SYSTEM_SLEEP", "src_system_sleep", "Session setup was interrupted by system sleep. Keep your Mac awake, then try again."},
    {0xC0F22206LL, "NVB_ICE_CONNECTION_FAILED", "ice_connection_failed", "There was a network problem connecting to GeForce NOW. Check your connection, then try again."},
    {0xC0F30002LL, "NVB_FRAME_LOSS_TIMEOUT", "frame_loss_timeout", "There was a network problem connecting to GeForce NOW. Check your connection, then try again."},
    {0x00F13001LL, "GAME_NOT_OWNED", "game_not_owned", "This game is not owned or linked on your account. Open the Store or link the required account, then try again."},
};

static const GFNErrorRule *StructuredRuleForError(long long code, const std::string &lowerError) {
    for (const GFNErrorRule &rule : kStructuredGFNErrorRules) {
        if (code == rule.code || Contains(lowerError, rule.symbol) || Contains(lowerError, rule.needle)) return &rule;
    }
    return nullptr;
}

static std::string MessageWithDetails(NSString *message, long long code, NSString *description) {
    NSMutableString *result = [NSMutableString stringWithString:message ?: @"An unknown GeForce NOW error occurred."];
    if (code != kNoGFNErrorCode) {
        [result appendFormat:@"\n\nGeForce NOW error %lld", code];
        if (description.length > 0) [result appendFormat:@": %@", description];
        [result appendString:@"."];
    } else if (description.length > 0) {
        [result appendFormat:@"\n\n%@", description];
    }
    return result.UTF8String ? result.UTF8String : "An unknown GeForce NOW error occurred.";
}

std::string UserFacingGFNErrorMessage(const std::string &errorMessage, const std::string &gameTitle) {
    if (errorMessage.empty()) return "An unknown error occurred.";

    std::string lower = ASCIILower(errorMessage);
    NSDictionary *json = JSONDictionaryFromError(errorMessage);
    long long code = ErrorCodeFromDictionary(json);
    long long httpCode = HTTPStatusCodeFromError(lower);
    long long hexCode = HexErrorCodeFromError(lower);
    NSString *description = ErrorDescriptionFromDictionary(json);

    if (code == kNoGFNErrorCode && httpCode != kNoGFNErrorCode) code = httpCode;
    if (code == kNoGFNErrorCode && hexCode != kNoGFNErrorCode) code = hexCode;

    if (Contains(lower, "gsec_") || Contains(lower, "src_gsec") || Contains(lower, "gfn_gsec")) {
        return MessageWithDetails(@"GeForce NOW reported an internal game-seat service error. Try launching again; if it keeps happening, choose another region or wait for NVIDIA to recover the service.", code, description);
    }

    const GFNErrorRule *structuredRule = StructuredRuleForError(code, lower);
    if (structuredRule) {
        NSString *message = [NSString stringWithUTF8String:structuredRule->message] ?: @"A GeForce NOW service error occurred.";
        return MessageWithDetails(message, code, description);
    }

    if (httpCode == 401 || Contains(lower, "unauthorized") || Contains(lower, "auth_err")) {
        return MessageWithDetails(@"Your NVIDIA session expired. Sign in again, then try launching the game.", code, description);
    }

    if (httpCode == 429 || MatchesCode(code, lower, 3237290301LL, "too_many") || Contains(lower, "too many requests")) {
        return MessageWithDetails(@"Too many GeForce NOW launch requests were sent. Wait a few minutes, then try again.", code, description);
    }

    if (Contains(lower, "account_link") ||
        Contains(lower, "account link") ||
        Contains(lower, "store account") ||
        Contains(lower, "link_required") ||
        Contains(lower, "link required")) {
        return MessageWithDetails(@"The store account for this game is not linked to GeForce NOW. Open the Store to link the account, then try launching again.", code, description);
    }

    if (Contains(lower, "install_to_play") ||
        Contains(lower, "install to play") ||
        Contains(lower, "install required") ||
        Contains(lower, "game installation required")) {
        return MessageWithDetails(@"This game must be installed or prepared through its store before GeForce NOW can launch it. Open the Store, finish setup, then try again.", code, description);
    }

    if (MatchesCode(code, lower, 86, "insufficient_playability_level") ||
        MatchesCode(code, lower, 3237290326LL, "insufficient_playability_level")) {
        return MessageWithDetails(@"This stream quality is not available for your current GeForce NOW membership. Lower the streaming quality or upgrade your membership, then try again.", code, description);
    }

    if (MatchesCode(code, lower, 302, "session_limit") || MatchesCode(code, lower, 11, "session_limit")) {
        NSString *title = NSStringFromStdString(gameTitle);
        NSString *message = title.length > 0
            ? [NSString stringWithFormat:@"%@ is already running in another GeForce NOW session. Close the other stream or continue from the active session.", title]
            : @"A game is already running in another GeForce NOW session. Close the other stream or continue from the active session.";
        return MessageWithDetails(message, code, description);
    }

    if (MatchesCode(code, lower, 311, "session_terminated_another_client")) {
        return MessageWithDetails(@"This GeForce NOW session ended because the game was opened from another device or client.", code, description);
    }

    if (MatchesCode(code, lower, 310, "multiple_login") || Contains(lower, "multiple login")) {
        return MessageWithDetails(@"This GeForce NOW session ended because your NVIDIA account was used on another device.", code, description);
    }

    if (MatchesCode(code, lower, 15806465LL, "game_not_owned") ||
        Contains(lower, "not entitled") ||
        Contains(lower, "not_entitled") ||
        Contains(lower, "entitlement required") ||
        Contains(lower, "ownership required") ||
        Contains(lower, "purchase required") ||
        Contains(lower, "license required")) {
        return MessageWithDetails(@"This game is not owned or linked on your account. Open the Store or link the required account, then try again.", code, description);
    }

    if (Contains(lower, "session_ads_required") ||
        Contains(lower, "isadsrequired") ||
        Contains(lower, "ad_required") ||
        Contains(lower, "ads required") ||
        Contains(lower, "queuepaused") ||
        Contains(lower, "queue paused") ||
        Contains(lower, "graceperiodstart")) {
        return MessageWithDetails(@"GeForce NOW requires ad playback before this free-tier session can continue. Wait for the ad prompt, finish the ad, then continue launching.", code, description);
    }

    if (Contains(lower, "parental") || Contains(lower, "age_restricted") || Contains(lower, "age restricted")) {
        return MessageWithDetails(@"This game is restricted by account age or parental controls. Check the NVIDIA account settings, then try again.", code, description);
    }

    if (MatchesCode(code, lower, 3237290311LL, "maintenance") ||
        Contains(lower, "maintenance") ||
        Contains(lower, "out_of_service")) {
        return MessageWithDetails(@"GeForce NOW is temporarily unavailable for maintenance. Try again later.", code, description);
    }

    if (MatchesCode(code, lower, 3237290302LL, "queue_length_exceeded") || Contains(lower, "queue length")) {
        return MessageWithDetails(@"The GeForce NOW queue is currently full. Try again later.", code, description);
    }

    if (MatchesCode(code, lower, 3237290330LL, "storage_not_available") || Contains(lower, "storage")) {
        return MessageWithDetails(@"GeForce NOW cloud storage is not available for this session. Try again later.", code, description);
    }

    if (MatchesCode(code, lower, 3237290306LL, "game_binaries_not_available") || Contains(lower, "not available in region")) {
        return MessageWithDetails(@"This game is not available in the selected GeForce NOW region. Choose Automatic or another region, then try again.", code, description);
    }

    if (MatchesCode(code, lower, 3237289989LL, "system_sleep") || Contains(lower, "sleep during session")) {
        return MessageWithDetails(@"Session setup was interrupted by system sleep. Keep your Mac awake, then try again.", code, description);
    }

    if (MatchesCode(code, lower, 57, "session_timelimit") ||
        Contains(lower, "time limit") ||
        Contains(lower, "entitlement_timeout") ||
        Contains(lower, "entitlement timeout")) {
        return MessageWithDetails(@"Your GeForce NOW session time limit has been reached. Start a new session when more play time is available.", code, description);
    }

    if (MatchesCode(code, lower, 301, "session_not_active") ||
        MatchesCode(code, lower, 308, "no_active_session") ||
        MatchesCode(code, lower, 309, "session_not_paused") ||
        Contains(lower, "stale_active_session")) {
        return MessageWithDetails(@"The previous GeForce NOW session is no longer available. Try launching the game again.", code, description);
    }

    if (MatchesCode(code, lower, 3237093894LL, "ice_connection_failed") ||
        MatchesCode(code, lower, 3237150722LL, "frame_loss_timeout") ||
        Contains(lower, "not connected to internet") ||
        Contains(lower, "network connection was lost") ||
        Contains(lower, "network error") ||
        Contains(lower, "connection lost") ||
        Contains(lower, "signaling") ||
        Contains(lower, "webrtc") ||
        Contains(lower, " ice ") ||
        Contains(lower, "ice_connection")) {
        return MessageWithDetails(@"There was a network problem connecting to GeForce NOW. Check your connection, then try again.", code, description);
    }

    if (Contains(lower, "timeout") || Contains(lower, "timed out")) {
        return MessageWithDetails(@"GeForce NOW took too long to start the session. Try launching again.", code, description);
    }

    if ((httpCode >= 500 && httpCode <= 599) || Contains(lower, "server error") || Contains(lower, "internal server error")) {
        return MessageWithDetails(@"GeForce NOW had a server problem while starting the session. Try again later.", code, description);
    }

    if (Contains(lower, "terminal error state") || Contains(lower, "session failed") || Contains(lower, "session ended")) {
        return MessageWithDetails(@"GeForce NOW ended the session before it was ready. Try launching again.", code, description);
    }

    return errorMessage;
}

}
