#include "OPNWebRTCStatsHelpers.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop

#include <algorithm>
#include <cmath>

namespace OPN {
namespace {

bool OPNRTCStatsIsAudio(RTCStatistics *stat) {
    NSString *mediaType = OPNRTCStatsStringForKey(stat.values, @"mediaType");
    NSString *kind = OPNRTCStatsStringForKey(stat.values, @"kind");
    NSString *trackKind = OPNRTCStatsStringForKey(stat.values, @"trackKind");
    if ([mediaType isEqualToString:@"audio"] || [kind isEqualToString:@"audio"] || [trackKind isEqualToString:@"audio"]) return true;
    NSString *idString = [stat.id lowercaseString];
    return [idString containsString:@"audio"] || [idString containsString:@"mic"];
}

}

NSNumber *OPNRTCStatsNumberForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key) {
    NSObject *value = values[key];
    return [value isKindOfClass:NSNumber.class] ? (NSNumber *)value : nil;
}

NSString *OPNRTCStatsStringForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key) {
    NSObject *value = values[key];
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

double OPNMicrophoneLevelFromStatsReport(RTCStatisticsReport *report) {
    double bestLevel = -1.0;
    for (RTCStatistics *stat in report.statistics.allValues) {
        if (!OPNRTCStatsIsAudio(stat)) continue;
        NSNumber *audioLevel = OPNRTCStatsNumberForKey(stat.values, @"audioLevel");
        if (!audioLevel) audioLevel = OPNRTCStatsNumberForKey(stat.values, @"totalAudioEnergy");
        if (!audioLevel) continue;
        double level = audioLevel.doubleValue;
        if (level > 1.0) level = sqrt(level);
        bestLevel = std::max(bestLevel, std::max(0.0, std::min(level, 1.0)));
    }
    return bestLevel;
}

}
#endif
