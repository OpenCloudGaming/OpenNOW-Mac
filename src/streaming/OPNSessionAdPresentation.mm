#include "OPNSessionAdPresentation.h"

namespace OPN {

bool SessionAdPresentation::Visible() const {
    return kind != SessionAdPresentationKind::None;
}

bool SessionAdPresentation::HasPlayableAd() const {
    return kind == SessionAdPresentationKind::PlayableAd && ad != nullptr;
}

static std::string MessageOrFallback(const SessionAdState &state, const std::string &fallback) {
    return state.message.empty() ? fallback : state.message;
}

SessionAdPresentation SessionAdPresentationForState(const SessionAdState &state) {
    SessionAdPresentation presentation;
    if (!state.isAdsRequired) return presentation;

    if (!state.sessionAds.empty()) {
        const SessionAdInfo &ad = state.sessionAds.front();
        presentation.kind = SessionAdPresentationKind::PlayableAd;
        presentation.chipText = state.isQueuePaused ? "Queue Paused" : "Ad Queue";
        presentation.title = ad.title.empty() ? "Ad playback required" : ad.title;
        presentation.message = MessageOrFallback(state, "Finish this ad to keep your free-tier session moving.");
        presentation.ad = &ad;
        return presentation;
    }

    if (state.isQueuePaused) {
        presentation.kind = SessionAdPresentationKind::QueuePaused;
        presentation.chipText = "Queue Paused";
        presentation.title = "Queue paused for ads";
        presentation.message = MessageOrFallback(state, state.gracePeriodSeconds > 0
            ? "Resume ads before the grace period ends to keep your queue position."
            : "Resume ads to keep your free-tier queue position.");
        return presentation;
    }

    presentation.kind = SessionAdPresentationKind::WaitingForAd;
    presentation.chipText = "Ad Queue";
    presentation.title = "Waiting for ad availability";
    presentation.message = MessageOrFallback(state, state.serverSentEmptyAds
        ? "GeForce NOW has not returned a playable ad yet. OpenNOW will continue waiting for the next queue update."
        : "GeForce NOW requires ads before this session can continue. Waiting for the next queue update.");
    return presentation;
}

}
