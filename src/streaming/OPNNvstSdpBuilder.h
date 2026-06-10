#pragma once

#include "OPNStreamTypes.h"
#include "OPNWebRTCSdpUtils.h"

#include <string>

namespace OPN {

std::string OPNBuildNvstSdp(const StreamSettings &settings, const OPNLibWebRTCIceCredentials &credentials);

}
