#include "OPNStreamSessionInputBridge.h"

#include "OPNStreamSession.h"
#include "OPNStreamTypes.h"

NSUInteger OPNStreamSessionMaxGamepadControllers(void) {
    return (NSUInteger)OPN::Input::GAMEPAD_MAX_CONTROLLERS;
}

bool OPNStreamSessionInputReady(OPN::IStreamSession *session) {
    return session && session->InputReady();
}

void OPNSetStreamSessionMaxBitrateMbps(OPN::IStreamSession *session, int mbps) {
    if (!session) return;
    session->SetMaxBitrateMbps(mbps);
}

OPN::StreamStats OPNRequestLatestStreamSessionStats(OPN::IStreamSession *session) {
    OPN::StreamStats stats;
    if (!session) return stats;
    session->RequestStats();
    return session->GetLatestStats();
}

void OPNSetStreamSessionNativeWindow(OPN::IStreamSession *session, void *nativeWindow) {
    if (!session) return;
    session->SetNativeWindow(nativeWindow);
}

void OPNAddStreamSessionRemoteIceCandidateFromDictionary(OPN::IStreamSession *session, NSDictionary *payload) {
    if (!session) return;
    OPN::IceCandidatePayload candidate;
    NSString *candidateText = [payload[@"candidate"] isKindOfClass:[NSString class]] ? payload[@"candidate"] : @"";
    NSString *sdpMid = [payload[@"sdpMid"] isKindOfClass:[NSString class]] ? payload[@"sdpMid"] : @"";
    NSNumber *sdpMLineIndex = [payload[@"sdpMLineIndex"] isKindOfClass:[NSNumber class]] ? payload[@"sdpMLineIndex"] : nil;
    NSString *usernameFragment = [payload[@"usernameFragment"] isKindOfClass:[NSString class]] ? payload[@"usernameFragment"] : @"";
    candidate.candidate = candidateText.UTF8String ?: "";
    candidate.sdpMid = sdpMid.UTF8String ?: "";
    candidate.sdpMLineIndex = sdpMLineIndex ? sdpMLineIndex.intValue : 0;
    candidate.usernameFragment = usernameFragment.UTF8String ?: "";
    session->AddRemoteIceCandidate(candidate);
}

void OPNSendStreamSessionMouseMove(OPN::IStreamSession *session, int16_t dx, int16_t dy) {
    if (!session) return;
    session->SendMouseMove(dx, dy);
}

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
                                      uint64_t timestampUs) {
    if (!session) return;
    OPN::Input::GamepadState state;
    state.controllerId = controllerId;
    state.buttons = buttons;
    state.leftTrigger = leftTrigger;
    state.rightTrigger = rightTrigger;
    state.leftStickX = leftStickX;
    state.leftStickY = leftStickY;
    state.rightStickX = rightStickX;
    state.rightStickY = rightStickY;
    state.connected = connected;
    state.timestampUs = timestampUs;
    session->SendGamepadState(state, bitmap);
}
