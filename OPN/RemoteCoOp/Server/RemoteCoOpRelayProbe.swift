//  Asks the configured relay for an allocation and reports whether it gave one.
//
//  Relay credentials fail silently. A wrong password, a URL with no TLS variant, a provider that has
//  not activated the account - all of them look identical from the host's side, which is a working
//  session where one particular guest never connects. And that guest is by definition the one on a
//  network you cannot test from.
//
//  The check is the real thing rather than a reachability ping: a peer connection restricted to
//  `relay` candidates gathers nothing at all unless a TURN server accepts the credentials and
//  allocates. A relay candidate coming back is proof the whole path works, and it costs one
//  allocation rather than a session.
//

@preconcurrency import WebRTC
import Foundation

public struct OPNRemoteCoOpRelayProbeResult: Equatable, Sendable {
    /// How well the relay would survive a filtering network, which is the only question that matters
    /// once it allocates at all.
    public enum Reach: Equatable, Sendable {
        /// TLS on 443. Indistinguishable from HTTPS, so it survives deep packet inspection.
        case tls
        /// Plain TCP, usually on 443 or 80. Gets through a network that blocks UDP, but a firewall
        /// inspecting protocol rather than port can still tell it is not HTTPS.
        case tcp
        /// UDP only, which is exactly what the networks this feature exists for block.
        case udpOnly
    }

    public let relayCandidates: Int
    /// The TURN URLs that actually produced a candidate, so a host can see *which* of several worked
    /// rather than only that one did.
    public let workingURLs: [String]
    /// Everything that was offered to ICE. The difference from `workingURLs` is the actionable half:
    /// a relay reachable only over UDP is usually a TCP URL that was never added, or one that was
    /// added and silently refused, and those need opposite fixes.
    public let attemptedURLs: [String]
    /// Time to the first relay candidate, not to the end of gathering: a slow or dead URL in the list
    /// holds gathering open long after the working one has answered, and reporting that as the
    /// relay's latency is simply wrong.
    public let firstCandidateElapsed: TimeInterval
    public let elapsed: TimeInterval
    public let failure: String?

    public var succeeded: Bool { relayCandidates > 0 }

    public var hasTLSCandidate: Bool { workingURLs.contains { $0.lowercased().hasPrefix("turns:") } }

    public var reach: Reach {
        if hasTLSCandidate { return .tls }
        // `?transport=tcp` is the difference between a relay that survives a UDP block and one that
        // does not, and it is carried in the URL rather than in the candidate.
        if workingURLs.contains(where: { $0.lowercased().contains("transport=tcp") }) { return .tcp }
        return .udpOnly
    }

    /// Offered but never allocated. Named rather than counted, because the URL itself is the fix.
    public var failedURLs: [String] { attemptedURLs.filter { !workingURLs.contains($0) } }

    private var failureDetail: String {
        guard !failedURLs.isEmpty else { return "" }
        return " Did not allocate: \(failedURLs.joined(separator: ", "))."
    }

    public var summary: String {
        if let failure { return failure }
        guard succeeded else {
            return "No relay candidate from \(attemptedURLs.count) URL\(attemptedURLs.count == 1 ? "" : "s")."
                + " Check the username and password first - wrong credentials fail exactly like this."
                + failureDetail
        }
        let plural = relayCandidates == 1 ? "" : "s"
        let scope = attemptedURLs.count > 1 ? " from \(workingURLs.count) of \(attemptedURLs.count) URLs" : ""
        let base = "Relay works: \(relayCandidates) candidate\(plural)\(scope), first in \(Int(firstCandidateElapsed * 1000)) ms."
        switch reach {
        case .tls:
            return base + " Over turns:, which looks like ordinary HTTPS - this is the one that gets through a filtering network."
        case .tcp:
            return base + " Over TCP, which survives a network that blocks UDP. Only a firewall inspecting the protocol itself would refuse it." + failureDetail
        case .udpOnly:
            return base + " UDP only - that covers an ordinary home network, but not the school or cafe networks a relay is for."
                + (attemptedURLs.count == workingURLs.count
                   ? " Add a URL on port 443 or 80 to get a TCP candidate."
                   : failureDetail + " A TCP candidate is what these networks need.")
        }
    }
}

public enum OPNRemoteCoOpRelayProbe {
    /// Gathers with `iceTransportPolicy = .relay`, so any candidate that arrives came from the TURN
    /// server. Host and server-reflexive candidates are excluded by the policy, which is what makes
    /// the result unambiguous.
    public static func run(iceServers: [OPNRemoteCoOpICEServer],
                           timeout: TimeInterval = 10) async -> OPNRemoteCoOpRelayProbeResult {
        let started = Date()
        let attemptedURLs = iceServers.flatMap(\.urls)
        guard !attemptedURLs.isEmpty else {
            return OPNRemoteCoOpRelayProbeResult(relayCandidates: 0, workingURLs: [], attemptedURLs: [], firstCandidateElapsed: 0, elapsed: 0, failure: "No relay is configured.")
        }

        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        configuration.iceTransportPolicy = .relay
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let collector = RelayProbeCollector()
        guard let connection = factory.peerConnection(with: configuration, constraints: constraints, delegate: collector) else {
            return OPNRemoteCoOpRelayProbeResult(relayCandidates: 0, workingURLs: [], attemptedURLs: attemptedURLs, firstCandidateElapsed: 0, elapsed: 0, failure: "Could not create a peer connection to test with.")
        }
        // A data channel is enough to make gathering happen; no media is captured or sent.
        _ = connection.dataChannel(forLabel: "relay-probe", configuration: RTCDataChannelConfiguration())

        do {
            let offer = try await connection.offer(for: constraints)
            try await connection.setLocalDescription(offer)
        } catch {
            connection.close()
            return OPNRemoteCoOpRelayProbeResult(relayCandidates: 0, workingURLs: [], attemptedURLs: attemptedURLs, firstCandidateElapsed: 0, elapsed: Date().timeIntervalSince(started), failure: "Could not start the test: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        // Polled rather than continuation-driven: gathering can complete with zero candidates, which
        // is itself the answer, so there is no single event that always arrives.
        //
        // A dead URL in the list keeps gathering open until libwebrtc gives up on it, which is most
        // of a ten second timeout for a relay that answered in 300 ms. Once candidates have stopped
        // arriving there is nothing left to learn, so the settle window ends the wait.
        while Date() < deadline {
            if await collector.finished { break }
            if await collector.settled(for: 2.5) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let candidates = await collector.relayCandidates
        let workingURLs = await collector.workingURLs
        let firstAt = await collector.firstCandidateAt
        connection.close()

        return OPNRemoteCoOpRelayProbeResult(
            relayCandidates: candidates,
            workingURLs: workingURLs,
            attemptedURLs: attemptedURLs,
            firstCandidateElapsed: firstAt.map { $0.timeIntervalSince(started) } ?? Date().timeIntervalSince(started),
            elapsed: Date().timeIntervalSince(started),
            failure: nil
        )
    }
}

private final class RelayProbeCollector: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    private let state = RelayProbeState()

    var relayCandidates: Int { get async { await state.relayCandidates } }
    var workingURLs: [String] { get async { await state.workingURLs } }
    var finished: Bool { get async { await state.finished } }
    var firstCandidateAt: Date? { get async { await state.firstCandidateAt } }

    func settled(for interval: TimeInterval) async -> Bool { await state.settled(for: interval) }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.contains(" typ relay") else { return }
        // `serverUrl` names the TURN URL this candidate was allocated from, which the SDP itself does
        // not carry - and it is the only way to tell a turns: allocation from a turn: one.
        Task { await state.record(serverURL: candidate.serverUrl ?? "") }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { await state.finish() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private actor RelayProbeState {
    private(set) var relayCandidates = 0
    private(set) var workingURLs: [String] = []
    private(set) var finished = false
    private(set) var firstCandidateAt: Date?
    private var lastCandidateAt: Date?

    func record(serverURL: String) {
        relayCandidates += 1
        let now = Date()
        if firstCandidateAt == nil { firstCandidateAt = now }
        lastCandidateAt = now
        guard !serverURL.isEmpty, !workingURLs.contains(serverURL) else { return }
        workingURLs.append(serverURL)
    }

    /// Only meaningful once something has arrived: no candidates yet means the servers are still
    /// being tried, not that they are done.
    func settled(for interval: TimeInterval) -> Bool {
        guard let lastCandidateAt else { return false }
        return Date().timeIntervalSince(lastCandidateAt) > interval
    }

    func finish() { finished = true }
}
