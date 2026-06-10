#pragma once

#import <Foundation/Foundation.h>

#include <stdint.h>

#include "OPNStreamStats.h"

namespace OPN {
class IStreamSession;
}

NSUInteger OPNStreamSessionMaxGamepadControllers(void);
bool OPNStreamSessionInputReady(OPN::IStreamSession *session);
void OPNSetStreamSessionMaxBitrateMbps(OPN::IStreamSession *session, int mbps);
OPN::StreamStats OPNRequestLatestStreamSessionStats(OPN::IStreamSession *session);
void OPNSetStreamSessionNativeWindow(OPN::IStreamSession *session, void *nativeWindow);
void OPNAddStreamSessionRemoteIceCandidateFromDictionary(OPN::IStreamSession *session, NSDictionary *payload);
void OPNSendStreamSessionMouseMove(OPN::IStreamSession *session, int16_t dx, int16_t dy);
void OPNSendStreamSessionGamepadState(OPN::IStreamSession *session,
                                      uint16_t controllerId,
                                      uint16_t buttons,
                                      uint8_t leftTrigger,
                                      uint8_t rightTrigger,
                                      int16_t leftStickX,
                                      int16_t leftStickY,
                                      int16_t rightStickX,
                                      int16_t rightStickY,
                                      bool connected,
                                      uint16_t bitmap,
                                      uint64_t timestampUs);
