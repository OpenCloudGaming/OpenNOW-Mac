#include "OPNLibWebRTCStreamSession.h"
#include "OPNLibWebRTCSessionImpl.h"
#include "OPNWebRTCDataChannelUtils.h"

#if defined(OPN_HAVE_LIBWEBRTC)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop
#endif

#include <algorithm>

@interface OPNInputProtocolEncoder : NSObject
- (void)setProtocolVersion:(uint16_t)version;
- (NSData *)encodeHeartbeat;
- (NSData *)encodeKeyWithKeycode:(uint16_t)keycode scancode:(uint16_t)scancode modifiers:(uint16_t)modifiers timestampUs:(uint64_t)timestampUs down:(BOOL)down;
- (NSData *)encodeMouseMoveWithDx:(int16_t)dx dy:(int16_t)dy timestampUs:(uint64_t)timestampUs;
- (NSData *)encodeMouseButtonWithButton:(uint8_t)button timestampUs:(uint64_t)timestampUs down:(BOOL)down;
- (NSData *)encodeMouseWheelWithDelta:(int16_t)delta timestampUs:(uint64_t)timestampUs;
- (NSData *)encodeUtf8Text:(NSString *)text;
- (NSData *)encodeGamepadStateWithControllerId:(uint16_t)controllerId
                                       buttons:(uint16_t)buttons
                                   leftTrigger:(uint8_t)leftTrigger
                                  rightTrigger:(uint8_t)rightTrigger
                                    leftStickX:(int16_t)leftStickX
                                    leftStickY:(int16_t)leftStickY
                                   rightStickX:(int16_t)rightStickX
                                   rightStickY:(int16_t)rightStickY
                                   timestampUs:(uint64_t)timestampUs
                                        bitmap:(uint16_t)bitmap
                             partiallyReliable:(BOOL)partiallyReliable;
+ (uint64_t)timestampUs;
@end

namespace OPN {

static constexpr uint32_t OPNInputUtf8Text = 23;
static constexpr int OPNPartialReliableInputLifetimeMs = 5;
[[maybe_unused]] static constexpr uint64_t OPNPartialReliableInputBacklogLimitBytes = 16 * 1024;
[[maybe_unused]] static constexpr uint64_t OPNLowLatencyInputBacklogLimitBytes = 4 * 1024;

#if defined(OPN_HAVE_LIBWEBRTC)
static OPNLibWebRTCSessionImpl *OPNImplFromOpaque(void *opaque) {
    return (__bridge OPNLibWebRTCSessionImpl *)opaque;
}
#endif

static OPNInputProtocolEncoder *OPNInputEncoder(void *opaque) {
    return (__bridge OPNInputProtocolEncoder *)opaque;
}

static void OPNSendData(LibWebRTCStreamSession *session, NSData *data, bool partiallyReliable) {
    if (!data || data.length == 0) return;
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    if (partiallyReliable) {
        session->SendInputPartiallyReliable(bytes, data.length);
    } else {
        session->SendInput(bytes, data.length);
    }
}

void LibWebRTCStreamSession::SendInput(const uint8_t *data, size_t len) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.reliableInputChannel || impl.reliableInputChannel.readyState != RTCDataChannelStateOpen || !data || len == 0) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:payload isBinary:YES];
    [impl.reliableInputChannel sendData:buffer];
#else
    (void)data;
    (void)len;
#endif
}

void LibWebRTCStreamSession::SendInputPartiallyReliable(const uint8_t *data, size_t len) {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.partialInputChannel || impl.partialInputChannel.readyState != RTCDataChannelStateOpen || !data || len == 0) return;
    uint64_t backlogLimit = m_settings.lowLatencyMode ? OPNLowLatencyInputBacklogLimitBytes : OPNPartialReliableInputBacklogLimitBytes;
    if (impl.partialInputChannel.bufferedAmount > backlogLimit) return;
    NSData *payload = [NSData dataWithBytes:data length:len];
    RTCDataBuffer *buffer = [[RTCDataBuffer alloc] initWithData:payload isBinary:YES];
    [impl.partialInputChannel sendData:buffer];
#else
    (void)data;
    (void)len;
#endif
}

void LibWebRTCStreamSession::CreateInputChannel() {
#if defined(OPN_HAVE_LIBWEBRTC)
    OPNLibWebRTCSessionImpl *impl = OPNImplFromOpaque(m_impl);
    if (!impl.peerConnection || impl.reliableInputChannel || impl.partialInputChannel) return;

    RTCDataChannelConfiguration *reliableConfig = [[RTCDataChannelConfiguration alloc] init];
    reliableConfig.isOrdered = YES;
    reliableConfig.maxRetransmits = -1;
    reliableConfig.maxPacketLifeTime = -1;
    impl.reliableInputChannel = [impl.peerConnection dataChannelForLabel:@"input_channel_v1" configuration:reliableConfig];
    impl.reliableInputChannel.delegate = impl;

    RTCDataChannelConfiguration *partialConfig = [[RTCDataChannelConfiguration alloc] init];
    partialConfig.isOrdered = NO;
    partialConfig.maxRetransmits = -1;
    partialConfig.maxPacketLifeTime = OPNPartialReliableInputLifetimeMs;
    impl.partialInputChannel = [impl.peerConnection dataChannelForLabel:@"input_channel_partially_reliable" configuration:partialConfig];
    impl.partialInputChannel.delegate = impl;
#endif
}

bool LibWebRTCStreamSession::InputReady() const {
    return m_inputReady;
}

void LibWebRTCStreamSession::SendKeyEvent(uint16_t keycode, uint16_t scancode, uint16_t modifiers, bool down) {
    uint64_t timestampUs = [OPNInputProtocolEncoder timestampUs];
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeKeyWithKeycode:keycode scancode:scancode modifiers:modifiers timestampUs:timestampUs down:down ? YES : NO];
    OPNSendData(this, encoded, false);
}

void LibWebRTCStreamSession::SendMouseMove(int16_t dx, int16_t dy) {
    uint64_t timestampUs = [OPNInputProtocolEncoder timestampUs];
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeMouseMoveWithDx:dx dy:dy timestampUs:timestampUs];
    OPNSendData(this, encoded, true);
}

void LibWebRTCStreamSession::SendMouseButton(uint8_t button, bool down) {
    uint64_t timestampUs = [OPNInputProtocolEncoder timestampUs];
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeMouseButtonWithButton:button timestampUs:timestampUs down:down ? YES : NO];
    OPNSendData(this, encoded, false);
}

void LibWebRTCStreamSession::SendMouseWheel(int16_t delta) {
    uint64_t timestampUs = [OPNInputProtocolEncoder timestampUs];
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeMouseWheelWithDelta:delta timestampUs:timestampUs];
    OPNSendData(this, encoded, false);
}

void LibWebRTCStreamSession::SendUtf8Text(const std::string &text) {
    NSString *inputText = [NSString stringWithUTF8String:text.c_str()] ?: @"";
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeUtf8Text:inputText];
    OPNSendData(this, encoded, false);
}

void LibWebRTCStreamSession::SendGamepadState(const Input::GamepadState &state, uint16_t bitmap) {
    NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeGamepadStateWithControllerId:state.controllerId
                                                                                   buttons:state.buttons
                                                                               leftTrigger:state.leftTrigger
                                                                              rightTrigger:state.rightTrigger
                                                                                leftStickX:state.leftStickX
                                                                                leftStickY:state.leftStickY
                                                                               rightStickX:state.rightStickX
                                                                               rightStickY:state.rightStickY
                                                                               timestampUs:state.timestampUs
                                                                                    bitmap:bitmap
                                                                         partiallyReliable:YES];
    OPNSendData(this, encoded, true);
}

void LibWebRTCStreamSession::HandleDataChannelState(const std::string &label, bool open) {
    if (label == "input_channel_v1") {
        m_reliableOpen = open;
    } else if (label == "input_channel_partially_reliable") {
        m_partialOpen = open;
    }
    if (!open) {
        m_inputReady = false;
        StopInputHeartbeat();
    }
}

void LibWebRTCStreamSession::HandleDataChannelMessage(const std::string &label, const uint8_t *data, size_t len) {
    if (label != "input_channel_v1" || !data || len < 2) return;

    if (m_inputReady) {
        std::string clipboardText;
        const uint8_t *payload = data;
        size_t payloadLength = len;
        if (len > 10 && data[0] == 0x23 && data[9] == 0x22) {
            payload = data + 10;
            payloadLength = len - 10;
        } else if (len > 12 && data[0] == 0x23 && data[9] == 0x21) {
            uint16_t wrappedLength = ((uint16_t)data[10] << 8) | (uint16_t)data[11];
            if (wrappedLength > 0 && wrappedLength <= len - 12) {
                payload = data + 12;
                payloadLength = wrappedLength;
            }
        }
        if (payloadLength >= 8 && OPNReadU32LE(payload) == OPNInputUtf8Text) {
            uint32_t textLength = OPNReadU32LE(payload + 4);
            if (textLength > 0 && textLength <= payloadLength - 8) {
                clipboardText = OPNValidUtf8StringFromBytes(payload + 8, textLength);
            }
        }
        if (clipboardText.empty() && payloadLength > 0 && (payload[0] == '{' || payload[0] == '[')) {
            NSData *jsonData = [NSData dataWithBytes:payload length:payloadLength];
            clipboardText = OPNClipboardTextFromJsonData(jsonData);
        }
        if (!clipboardText.empty() && m_onClipboardText) {
            m_onClipboardText(clipboardText);
            OPNLogInfo(@"[LibWebRTC] remote clipboard text received bytes=%zu", len);
        }
        return;
    }

    const uint16_t firstWord = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
    uint16_t version = 2;
    if (firstWord == 526) {
        if (len >= 4) version = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
        OPNLogInfo(@"[LibWebRTC] input handshake detected firstWord=526 version=%u", version);
    } else if (data[0] == 0x0e) {
        version = firstWord;
        OPNLogInfo(@"[LibWebRTC] input handshake detected byte[0]=0x0e version=%u", version);
    } else {
        OPNLogInfo(@"[LibWebRTC] input channel message before handshake len=%zu firstWord=0x%04x", len, firstWord);
        return;
    }

    [OPNInputEncoder(m_inputEncoder) setProtocolVersion:version];
    m_inputReady = m_reliableOpen && m_partialOpen;
    SendInput(data, len);
    StartInputHeartbeat();
    OPNLogInfo(@"[LibWebRTC] input handshake complete protocol=v%u inputReady=%d", version, m_inputReady);
}

void LibWebRTCStreamSession::StartInputHeartbeat() {
    if (m_inputHeartbeat) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) return;
    m_inputHeartbeat = (__bridge_retained void *)timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!m_inputReady) return;
        NSData *encoded = [OPNInputEncoder(m_inputEncoder) encodeHeartbeat];
        OPNSendData(this, encoded, false);
    });
    dispatch_resume(timer);
}

void LibWebRTCStreamSession::StopInputHeartbeat() {
    if (!m_inputHeartbeat) return;
    dispatch_source_t timer = (__bridge_transfer dispatch_source_t)m_inputHeartbeat;
    dispatch_source_cancel(timer);
    m_inputHeartbeat = nullptr;
}

}
