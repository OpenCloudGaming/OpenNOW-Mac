#pragma once

#import <Foundation/Foundation.h>

@class OPNStreamView;

namespace OPN {
class IStreamSession;
}

void OPNClearStreamSessionCallbacks(OPN::IStreamSession *session);
void OPNConfigureStreamViewSessionCallbacks(OPN::IStreamSession *session, OPNStreamView *streamView);
