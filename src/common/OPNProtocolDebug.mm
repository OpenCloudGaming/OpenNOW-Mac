#include "OPNProtocolDebug.h"
#include "OPNSentry.h"

#include <atomic>
#include <cstdlib>

namespace OPN {

static std::atomic<unsigned long> gProtocolCaptureSequence{0};

static BOOL EnvironmentFlagEnabled(const char *name) {
    const char *value = std::getenv(name);
    if (!value) return NO;
    NSString *text = [[NSString stringWithUTF8String:value] lowercaseString];
    return [text isEqualToString:@"1"] || [text isEqualToString:@"true"] || [text isEqualToString:@"yes"] || [text isEqualToString:@"on"];
}

bool ProtocolDebugLoggingEnabled() {
    return EnvironmentFlagEnabled("OPN_PROTOCOL_DEBUG") ||
        EnvironmentFlagEnabled("OPN_CAPTURE_PROTOCOL") ||
        std::getenv("OPN_PROTOCOL_CAPTURE_DIR") != nullptr;
}

static NSString *ProtocolCaptureDirectory() {
    const char *value = std::getenv("OPN_PROTOCOL_CAPTURE_DIR");
    if (!value) return nil;
    NSString *path = [NSString stringWithUTF8String:value];
    path = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return path.length > 0 ? [path stringByExpandingTildeInPath] : nil;
}

static NSString *NormalizedKey(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return @"";
    NSMutableString *normalized = [[key lowercaseString] mutableCopy];
    NSCharacterSet *punctuation = [NSCharacterSet characterSetWithCharactersInString:@"_- ."];
    NSArray<NSString *> *parts = [normalized componentsSeparatedByCharactersInSet:punctuation];
    return [parts componentsJoinedByString:@""];
}

static BOOL ShouldRedactKey(NSString *key) {
    NSString *normalized = NormalizedKey(key);
    if (normalized.length == 0) return NO;
    NSArray<NSString *> *exact = @[@"authorization", @"cookie", @"setcookie", @"ip", @"email"];
    for (NSString *candidate in exact) {
        if ([normalized isEqualToString:candidate]) return YES;
    }
    NSArray<NSString *> *substrings = @[
        @"token", @"secret", @"password", @"credential", @"devicehashid", @"deviceid",
        @"userid", @"clientid", @"sessionid", @"subsessionid", @"serverip", @"clientip", @"ipaddress",
        @"resourcepath", @"signaling", @"sdp", @"candidate"
    ];
    for (NSString *candidate in substrings) {
        if ([normalized containsString:candidate]) return YES;
    }
    return NO;
}

static id SanitizedValue(id value, NSString *key) {
    if (ShouldRedactKey(key)) return @"<redacted>";
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
        NSDictionary *dict = (NSDictionary *)value;
        NSString *metadataKey = [dict[@"key"] isKindOfClass:NSString.class] ? dict[@"key"] : nil;
        for (id rawKey in dict) {
            NSString *childKey = [rawKey isKindOfClass:NSString.class] ? (NSString *)rawKey : [rawKey description];
            NSString *effectiveKey = ([childKey isEqualToString:@"value"] && metadataKey.length > 0) ? metadataKey : childKey;
            sanitized[childKey ?: @""] = SanitizedValue(dict[rawKey], effectiveKey);
        }
        return sanitized;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *sanitized = [NSMutableArray array];
        for (id item in (NSArray *)value) {
            [sanitized addObject:SanitizedValue(item, nil) ?: NSNull.null];
        }
        return sanitized;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = (NSString *)value;
        NSString *lower = [string lowercaseString];
        if ([lower hasPrefix:@"gfnjwt "] || [lower hasPrefix:@"bearer "]) return @"<redacted>";
    }
    return value ?: NSNull.null;
}

NSString *SanitizedProtocolJSONStringFromJSONObject(id object) {
    if (!object || object == NSNull.null) return @"null";
    id sanitized = SanitizedValue(object, nil);
    if (![NSJSONSerialization isValidJSONObject:sanitized]) return [sanitized description] ?: @"";
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:sanitized
                                                   options:(NSJSONWritingOptions)(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                     error:&error];
    if (error || !data) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *SanitizedProtocolJSONStringFromData(NSData *data) {
    if (!data || data.length == 0) return @"";
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (object) return SanitizedProtocolJSONStringFromJSONObject(object);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

NSString *ProtocolDebugCaptureFilename(NSString *label, unsigned long sequence) {
    NSString *raw = label.length > 0 ? [label lowercaseString] : @"payload";
    NSMutableString *safe = [NSMutableString string];
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    BOOL previousDash = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar character = [raw characterAtIndex:i];
        if ([alnum characterIsMember:character]) {
            [safe appendFormat:@"%C", character];
            previousDash = NO;
        } else if (!previousDash && safe.length > 0) {
            [safe appendString:@"-"];
            previousDash = YES;
        }
    }
    while ([safe hasSuffix:@"-"]) {
        [safe deleteCharactersInRange:NSMakeRange(safe.length - 1, 1)];
    }
    if (safe.length == 0) [safe appendString:@"payload"];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]] ?: @"capture";
    return [NSString stringWithFormat:@"%@-%06lu-%@.json", timestamp, sequence, safe];
}

static void WriteProtocolCapture(NSString *label, NSString *payload) {
    NSString *directory = ProtocolCaptureDirectory();
    if (directory.length == 0 || payload.length == 0) return;

    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        OPN::LogError(@"[ProtocolDebug] Failed to create capture directory %@: %@", directory, directoryError.localizedDescription ?: @"unknown error");
        return;
    }

    unsigned long sequence = ++gProtocolCaptureSequence;
    NSString *filename = ProtocolDebugCaptureFilename(label, sequence);
    NSString *path = [directory stringByAppendingPathComponent:filename];
    NSError *writeError = nil;
    if (![payload writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        OPN::LogError(@"[ProtocolDebug] Failed to write capture %@: %@", path, writeError.localizedDescription ?: @"unknown error");
        return;
    }
    OPN::LogInfo(@"[ProtocolDebug] Wrote sanitized capture: %@", path);
}

void LogProtocolJSONObject(NSString *label, id object) {
    if (!ProtocolDebugLoggingEnabled()) return;
    NSString *payload = SanitizedProtocolJSONStringFromJSONObject(object);
    WriteProtocolCapture(label, payload);
    OPN::LogInfo(@"[ProtocolDebug] %@: %@", label ?: @"payload", payload ?: @"");
}

void LogProtocolJSONData(NSString *label, NSData *data) {
    if (!ProtocolDebugLoggingEnabled()) return;
    NSString *payload = SanitizedProtocolJSONStringFromData(data);
    WriteProtocolCapture(label, payload);
    OPN::LogInfo(@"[ProtocolDebug] %@: %@", label ?: @"payload", payload ?: @"");
}

}
