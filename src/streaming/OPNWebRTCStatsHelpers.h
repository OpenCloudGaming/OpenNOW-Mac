#pragma once

#if defined(OPN_HAVE_LIBWEBRTC)
#import <Foundation/Foundation.h>
@class RTCStatisticsReport;

namespace OPN {

NSNumber *OPNRTCStatsNumberForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key);
NSString *OPNRTCStatsStringForKey(NSDictionary<NSString *, NSObject *> *values, NSString *key);
double OPNMicrophoneLevelFromStatsReport(RTCStatisticsReport *report);

}
#endif
