#include "OPNSessionParsing.h"

namespace OPN {

NSArray *ArrayValue(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : @[];
}

NSDictionary *DictionaryValue(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

NSString *StringValue(id value) {
    return [value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0 ? (NSString *)value : nil;
}

int PositiveIntValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        int parsed = [(NSNumber *)value intValue];
        return parsed > 0 ? parsed : 0;
    }
    if ([value isKindOfClass:[NSString class]]) {
        int parsed = [(NSString *)value intValue];
        return parsed > 0 ? parsed : 0;
    }
    return 0;
}

bool BoolValue(id value, bool fallback) {
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value boolValue];
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"1"] || [lower isEqualToString:@"yes"]) return true;
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"0"] || [lower isEqualToString:@"no"]) return false;
    }
    return fallback;
}

}
