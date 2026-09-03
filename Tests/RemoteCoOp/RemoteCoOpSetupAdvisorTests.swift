//  The decision table behind the setup interview.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite struct RemoteCoOpSetupAdvisorTests {
    private func advise(_ location: OPNRemoteCoOpGuestLocation,
                        _ client: OPNRemoteCoOpGuestClient = .browser,
                        tailscale: Bool = false) -> OPNRemoteCoOpSetupAdvice {
        OPNRemoteCoOpSetupAdvisor.advise(location: location, client: client, tailscaleDetected: tailscale)
    }

    @Test func aGuestOnYourOwnNetworkNeedsNothing() throws {
        let advice = advise(.sameNetwork)
        #expect(advice.needsNothing)
        // Direct rather than automatic: a LAN guest already has a route, so STUN would reveal the
        // host's public address to them for no gain.
        #expect(advice.transportMode == .directOnly)
    }

    @Test func aBrowserGuestElsewhereNeedsATunnelButNotARelay() throws {
        let advice = advise(.anotherNetwork, .browser)
        #expect(advice.needsTunnel)
        #expect(!advice.needsRelay)
        #expect(advice.transportMode == .automatic)
    }

    /// A native guest can be handed a tailnet address, which is a real route - no tunnel, no relay.
    @Test func aTailnetCoversANativeGuestElsewhere() throws {
        let advice = advise(.anotherNetwork, .nativeApp, tailscale: true)
        #expect(advice.needsNothing)
        #expect(advice.transportMode == .directOnly)
    }

    /// A browser cannot use a tailnet address usefully: it meets a self-signed certificate, and that
    /// warning is where a guest gives up. So detection must not talk a host out of the tunnel.
    @Test func aTailnetDoesNotReplaceATunnelForABrowserGuest() throws {
        let advice = advise(.anotherNetwork, .browser, tailscale: true)
        #expect(advice.needsTunnel)
    }

    /// The advisor predates Hosted Signaling and never mentioned it, so every "you need a tunnel"
    /// answer pointed a host at running one even when this Mac cannot - the exact case the feature
    /// was built for. Pinned so a future rewrite of these reasons cannot drop it silently again.
    @Test func aTunnelRecommendationMentionsHostedSignalingAsAnAlternative() throws {
        let anotherNetwork = advise(.anotherNetwork, .browser)
        #expect(anotherNetwork.needsTunnel)
        #expect(anotherNetwork.reasons.contains { $0.localizedCaseInsensitiveContains("Hosted Signaling") })

        let restricted = advise(.restrictedNetwork, .browser)
        #expect(restricted.needsTunnel)
        #expect(restricted.reasons.contains { $0.localizedCaseInsensitiveContains("Hosted Signaling") })
    }

    @Test func aRestrictedNetworkNeedsBoth() throws {
        let advice = advise(.restrictedNetwork, .browser)
        #expect(advice.needsTunnel)
        #expect(advice.needsRelay)
    }

    /// "Not sure" has to resolve to the most capable setup. Guessing low fails silently - the guest
    /// simply never connects, with nothing indicating which piece was missing.
    @Test func notSureResolvesToTheHardestCase() throws {
        let unsure = advise(.unsure, .unsure)
        let restricted = advise(.restrictedNetwork, .browser)
        #expect(unsure.needsTunnel == restricted.needsTunnel)
        #expect(unsure.needsRelay == restricted.needsRelay)
        #expect(unsure.transportMode == restricted.transportMode)
        #expect(unsure.headline != restricted.headline)
    }

    /// Every answer combination has to produce advice, including the ones where the host admits they
    /// do not know: a wizard that cannot answer is worse than no wizard.
    @Test func everyCombinationProducesAdvice() throws {
        for location in OPNRemoteCoOpGuestLocation.allCases {
            for client in OPNRemoteCoOpGuestClient.allCases {
                for tailscale in [true, false] {
                    let advice = advise(location, client, tailscale: tailscale)
                    #expect(!advice.headline.isEmpty)
                    #expect(!advice.reasons.isEmpty)
                    #expect(advice.reasons.allSatisfy { !$0.isEmpty })
                    // A relay without a tunnel is not a reachable configuration: the relay carries
                    // media, but the guest still has to reach the host to negotiate it at all.
                    if advice.needsRelay { #expect(advice.needsTunnel) }
                }
            }
        }
    }

    @Test func outstandingStepsDropWhatIsAlreadyConfigured() throws {
        let advice = advise(.restrictedNetwork, .browser)
        #expect(OPNRemoteCoOpSetupAdvisor.outstandingSteps(for: advice, hasTunnel: false, hasRelay: false).count == 2)
        #expect(OPNRemoteCoOpSetupAdvisor.outstandingSteps(for: advice, hasTunnel: true, hasRelay: false).count == 1)
        #expect(OPNRemoteCoOpSetupAdvisor.outstandingSteps(for: advice, hasTunnel: true, hasRelay: true).isEmpty)
    }

    @Test func nothingIsOutstandingForASetupThatNeedsNothing() throws {
        let advice = advise(.sameNetwork)
        #expect(OPNRemoteCoOpSetupAdvisor.outstandingSteps(for: advice, hasTunnel: false, hasRelay: false).isEmpty)
    }

    /// Tailscale is offered as the free alternative wherever it genuinely is one, and never on the
    /// same network, where suggesting a VPN would be noise.
    @Test func tailscaleIsOfferedOnlyWhereItHelps() throws {
        #expect(!advise(.sameNetwork).tailscaleAlternative)
        #expect(advise(.anotherNetwork, .browser).tailscaleAlternative)
        #expect(advise(.restrictedNetwork, .browser).tailscaleAlternative)
    }
}
