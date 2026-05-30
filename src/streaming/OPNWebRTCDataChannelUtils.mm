#include "OPNWebRTCDataChannelUtils.h"

namespace OPN {

uint32_t OPNReadU32LE(const uint8_t *data) {
    return (uint32_t)data[0] | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);
}

std::string OPNValidUtf8StringFromBytes(const uint8_t *data, size_t len) {
    if (!data || len == 0) return "";
    NSString *string = [[NSString alloc] initWithBytes:data length:len encoding:NSUTF8StringEncoding];
    return string.length > 0 ? std::string(string.UTF8String ?: "") : std::string();
}

std::string OPNClipboardTextFromJsonData(NSData *data) {
    if (!data) return "";
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *dict = [json isKindOfClass:NSDictionary.class] ? (NSDictionary *)json : nil;
    if (!dict) return "";
    for (NSString *key in @[@"clipboard", @"text", @"content", @"payload"]) {
        NSString *value = [dict[key] isKindOfClass:NSString.class] ? dict[key] : nil;
        if (value.length > 0) return std::string(value.UTF8String ?: "");
    }
    return "";
}

}
