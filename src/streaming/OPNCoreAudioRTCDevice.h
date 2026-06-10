#pragma once

#if defined(OPN_HAVE_LIBWEBRTC)
#import <Foundation/Foundation.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/RTCAudioDevice.h>
#pragma clang diagnostic pop

namespace OPN {
class LibWebRTCStreamSession;
}

@interface OPNCoreAudioRTCDevice : NSObject <RTCAudioDevice>
@property(nonatomic, assign) OPN::LibWebRTCStreamSession *owner;
- (void)handleDefaultDeviceChange;
@end
#endif
