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
        presentation.chipText = state.isQueuePaused ? "Queue Paused" : "Sponsored Break";
        presentation.title = ad.title.empty() ? "Watch to continue" : ad.title;
        presentation.message = MessageOrFallback(state, "Your launch will resume automatically after the ad.");
        presentation.ad = &ad;
        return presentation;
    }

    if (state.isQueuePaused) {
        presentation.kind = SessionAdPresentationKind::QueuePaused;
        presentation.chipText = "Queue Paused";
        presentation.title = "Paused for ads";
        presentation.message = MessageOrFallback(state, state.gracePeriodSeconds > 0
            ? "Resume before the grace period ends."
            : "Resume ads to continue.");
        return presentation;
    }

    presentation.kind = SessionAdPresentationKind::WaitingForAd;
    presentation.chipText = "Ad Pending";
    presentation.title = "Waiting for an ad";
    presentation.message = MessageOrFallback(state, state.serverSentEmptyAds
        ? "GeForce NOW has not returned one yet. OpenNOW will keep checking."
        : "GeForce NOW requires an ad before launch can continue.");
    return presentation;
}

}
