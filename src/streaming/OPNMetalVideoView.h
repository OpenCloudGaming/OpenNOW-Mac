#pragma once

#if defined(OPN_HAVE_LIBWEBRTC)
#import <Cocoa/Cocoa.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-umbrella"
#import <WebRTC/WebRTC.h>
#pragma clang diagnostic pop

namespace OPN {
class LibWebRTCStreamSession;
}

@interface OPNMetalVideoView : NSView <RTCVideoRenderer>
- (instancetype)initWithFrame:(NSRect)frame targetFps:(int)targetFps owner:(void *)owner;
@end
#endif
