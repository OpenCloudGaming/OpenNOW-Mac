//  Turns two questions a host can answer into the setup they actually need.
//
//  The settings page asks the opposite way round: it offers a transport mode, a tunnel and a relay,
//  and expects the host to know which of them their situation calls for. Most do not, and the cost of
//  guessing is asymmetric - guess too little and the guest simply never connects, with no indication
//  which of the three was missing.
//
//  Kept separate from the view because it is the part worth testing. What a host is asked, and what
//  gets recommended, is a decision table; rendering it is not.
//

import Foundation

public enum OPNRemoteCoOpGuestLocation: String, CaseIterable, Codable, Sendable {
    case sameNetwork
    case anotherNetwork
    case restrictedNetwork
    case unsure

    public var label: String {
        switch self {
        case .sameNetwork: "On my network"
        case .anotherNetwork: "At their own place"
        case .restrictedNetwork: "School, work, cafe or hotel"
        case .unsure: "I am not sure"
        }
    }

    public var detail: String {
        switch self {
        case .sameNetwork: "Same Wi-Fi or the same house as this Mac."
        case .anotherNetwork: "A different home network, on ordinary home internet."
        case .restrictedNetwork: "A managed network. These commonly block the traffic game video travels on."
        case .unsure: "Or it varies. Set up for the hardest case and every easier one works too."
        }
    }
}

public enum OPNRemoteCoOpGuestClient: String, CaseIterable, Codable, Sendable {
    case browser
    case nativeApp
    case unsure

    public var label: String {
        switch self {
        case .browser: "A web browser"
        case .nativeApp: "OpenNOW on their Mac"
        case .unsure: "I am not sure"
        }
    }

    public var detail: String {
        switch self {
        case .browser: "They install nothing. Works from any machine, including a PC."
        case .nativeApp: "Lower latency, and they can reach you over a VPN by address."
        case .unsure: "Assumes a browser, which needs the most from your side."
        }
    }
}

public struct OPNRemoteCoOpSetupAdvice: Equatable, Sendable {
    public let transportMode: OPNRemoteCoOpTransportMode
    public let needsTunnel: Bool
    public let needsRelay: Bool
    /// A tailnet covers this case for free, if every guest is willing to install Tailscale.
    public let tailscaleAlternative: Bool
    public let headline: String
    public let reasons: [String]

    public var needsNothing: Bool { !needsTunnel && !needsRelay }
}

public enum OPNRemoteCoOpSetupAdvisor {
    /// `tailscaleDetected` comes from this Mac having a tailnet address, so the wizard can state what
    /// is already true rather than asking a host whether they run a VPN.
    public static func advise(location: OPNRemoteCoOpGuestLocation,
                              client: OPNRemoteCoOpGuestClient,
                              tailscaleDetected: Bool) -> OPNRemoteCoOpSetupAdvice {
        switch location {
        case .sameNetwork:
            return sameNetworkAdvice()
        case .anotherNetwork:
            return anotherNetworkAdvice(client: client, tailscaleDetected: tailscaleDetected)
        case .restrictedNetwork, .unsure:
            return restrictedNetworkAdvice(hedging: location == .unsure, tailscaleDetected: tailscaleDetected)
        }
    }

    private static func sameNetworkAdvice() -> OPNRemoteCoOpSetupAdvice {
        OPNRemoteCoOpSetupAdvice(
            transportMode: .directOnly,
            needsTunnel: false,
            needsRelay: false,
            tailscaleAlternative: false,
            headline: "Nothing to set up",
            reasons: [
                "A guest on your own network reaches this Mac directly. No tunnel, no relay.",
                "Direct transport keeps it that way and shares nothing about your public address.",
            ]
        )
    }

    /// A native guest can be handed a tailnet address, which is a real route and needs neither a
    /// tunnel nor a relay. A browser cannot be handed one usefully: it would meet a self-signed
    /// certificate, and the warning is where a guest gives up.
    private static func anotherNetworkAdvice(client: OPNRemoteCoOpGuestClient,
                                             tailscaleDetected: Bool) -> OPNRemoteCoOpSetupAdvice {
        if tailscaleDetected && client == .nativeApp {
                return OPNRemoteCoOpSetupAdvice(
                    transportMode: .directOnly,
                    needsTunnel: false,
                    needsRelay: false,
                    tailscaleAlternative: true,
                    headline: "Your tailnet already covers this",
                    reasons: [
                        "This Mac is on Tailscale, so a guest running OpenNOW connects by tailnet address with nothing else set up.",
                        "Direct transport is the right choice over a tailnet: the address is already routable, and STUN would reveal your public address for nothing.",
                    ]
                )
            }
            return OPNRemoteCoOpSetupAdvice(
                transportMode: .automatic,
                needsTunnel: true,
                needsRelay: false,
                tailscaleAlternative: true,
                headline: "You need a tunnel",
                reasons: [
                    "An invite link only resolves on your own network unless this Mac has a public address. A tunnel gives it one, and a certificate the guest's browser already trusts.",
                    "A relay is not needed: an ordinary home network lets a direct connection through once the guest can find you.",
                    tailscaleDetected
                        ? "Alternatively, a guest who installs Tailscale can skip the tunnel entirely, since this Mac is already on one."
                        : "Alternatively, Tailscale on both machines replaces the tunnel for free, if your guest is willing to install it.",
                "Or skip running a tunnel at all: Hosted Signaling (below, in Settings) gets an invite to resolve without one, if this Mac cannot run one or you would rather not.",
            ]
        )
    }

    private static func restrictedNetworkAdvice(hedging: Bool,
                                                tailscaleDetected: Bool) -> OPNRemoteCoOpSetupAdvice {
        OPNRemoteCoOpSetupAdvice(
                transportMode: .automatic,
                needsTunnel: true,
                needsRelay: true,
                tailscaleAlternative: true,
                headline: hedging ? "Set up both, and every case works" : "You need a tunnel and a relay",
                reasons: [
                    hedging
                        ? "Without knowing where your guests will be, the safe answer is the setup that covers the hardest case. It costs a guest on your own network nothing."
                        : "Managed networks filter the traffic video travels on, so finding this Mac is not enough on its own.",
                    "The tunnel makes this Mac reachable; the relay carries the video when the guest's network refuses a direct connection. They solve different halves and a blocked guest needs both.",
                    "Only guests who genuinely cannot connect directly use the relay, so everyone else costs nothing against the free tier.",
                    tailscaleDetected
                        ? "Alternatively, a guest who installs Tailscale gets through the same block for free, since this Mac is already on a tailnet."
                        : "Alternatively, Tailscale on both machines gets through the same block for free, if your guest is willing to install it.",
                    "The relay is still needed either way, but Hosted Signaling (below, in Settings) can stand in for the tunnel half if this Mac cannot run one or you would rather not.",
            ]
        )
    }

    /// What is still outstanding, given what is already configured. Ordered as a host would do them.
    public static func outstandingSteps(for advice: OPNRemoteCoOpSetupAdvice,
                                        hasTunnel: Bool,
                                        hasRelay: Bool) -> [String] {
        var steps: [String] = []
        if advice.needsTunnel && !hasTunnel {
            steps.append("Run a tunnel and paste its address into the Tunnel card.")
        }
        if advice.needsRelay && !hasRelay {
            steps.append("Set up the Cloudflare relay.")
        }
        return steps
    }
}
