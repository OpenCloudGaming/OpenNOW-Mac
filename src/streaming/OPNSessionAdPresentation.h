#pragma once

#include "OPNStreamTypes.h"

#include <string>

namespace OPN {

enum class SessionAdPresentationKind {
    None = 0,
    WaitingForAd,
    QueuePaused,
    PlayableAd,
};

struct SessionAdPresentation {
    SessionAdPresentationKind kind = SessionAdPresentationKind::None;
    std::string chipText;
    std::string title;
    std::string message;
    const SessionAdInfo *ad = nullptr;

    bool Visible() const;
    bool HasPlayableAd() const;
};

SessionAdPresentation SessionAdPresentationForState(const SessionAdState &state);

}
