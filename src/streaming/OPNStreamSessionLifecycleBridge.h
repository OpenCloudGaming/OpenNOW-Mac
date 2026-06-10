#pragma once

namespace OPN {
class IStreamSession;
}

bool OPNStreamSessionBackendAvailable(void);
OPN::IStreamSession *OPNCreateStreamSession(void);
void OPNReleaseStreamSessionAfterCallbacks(OPN::IStreamSession *session);
