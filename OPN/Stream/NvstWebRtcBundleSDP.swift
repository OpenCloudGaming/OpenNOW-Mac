//
//  NvstWebRtcBundleSDP.swift
//  OpenNOW
//
//  The SDP this bundle synthesizes for a seat that is not an ICE agent, and the async bridges
//  over libwebrtc's callback API. Split out of NvstWebRtcBundle.swift.
//

import Foundation
@preconcurrency import WebRTC

extension NvstWebRtcBundle {
    // MARK: - SDP

    /// The seat's side of the bundle, assembled from RTSP answers. `a=setup:actpass` leaves us free
    /// to answer `active`, which is what makes libwebrtc send the ClientHello — the role the
    /// official client uses.
    /// The seat's side of the bundle, assembled from RTSP answers.
    ///
    /// Two media sections, both required:
    /// - `m=audio` because ANNOUNCE tells the seat audio rides this bundle, and the official
    ///   client's bundle really does receive it (1543 inbound RTP packets in the reference
    ///   capture). A data-channel-only bundle makes the seat reset every SCTP stream and close
    ///   DTLS 114 ms after PLAY, having nowhere to put the audio it was promised.
    /// - `m=application` for `rtcp_on_sctp_private`.
    ///
    /// `a=setup:actpass` leaves us free to answer `active`, which is what makes libwebrtc send the
    /// ClientHello — the role the official client takes.
    static func synthesizedRemoteOffer(remoteUsernameFragment: String,
                                       remotePassword: String,
                                       remoteFingerprint: String,
                                       peerIP: String,
                                       peerPort: UInt16) -> String {
        let transport = [
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:\(remoteUsernameFragment)",
            "a=ice-pwd:\(remotePassword)",
            "a=ice-options:trickle",
            "a=fingerprint:sha-256 \(remoteFingerprint)",
            "a=setup:actpass",
        ]
        var lines = [
            "v=0",
            "o=- 0 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=msid-semantic: WMS",
            // Offered as sendonly by the seat, so our answer is recvonly.
            "m=audio 9 UDP/TLS/RTP/SAVPF \(Self.audioPayloadFormatLine)",
        ]
        lines += transport
        lines += [
            "a=mid:0",
            "a=rtcp-mux",
            "a=sendonly",
        ]
        lines += Self.audioCodecLines
        lines += [
            "a=ptime:5",
            "a=maxptime:20",
            "a=candidate:1 1 udp 2122260223 \(peerIP) \(peerPort) typ host",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
        ]
        lines += transport
        lines += [
            "a=mid:1",
            "a=sctp-port:5000",
            "a=max-message-size:262144",
            "",
        ]
        return lines.joined(separator: "\r\n")
    }

    /// The wire carries bundle audio on payload type **63** — captured from the native stack's
    /// bundle socket (pt=63, ssrc=0x00000001, no extension, ~188 bytes at 200/s, against pt=101 for
    /// video on its own socket). libwebrtc demultiplexes on the payload type, so the offer must
    /// name it or every audio packet is discarded before it can be counted.
    ///
    /// 63 is WebRTC's own default type for **RED** (RFC 2198) wrapping Opus, and the seat uses the
    /// standard WebRTC audio offer, so RED is the format. An earlier reading called it plain Opus,
    /// but that was on a *silent* stream: RED's redundant copies (discarded > received) and the
    /// absence of content (audioLevel ~0) look identical to a decode that produced nothing. On real
    /// audio, declaring RED payloads as plain Opus mis-frames them and yields garbage — which is the
    /// symptom reported from a live session.
    static let redPayloadType = 63
    static let opusPayloadType = 111

    /// Lets the audio format be flipped by ear on a real session, since a silent capture cannot
    /// tell RED from plain Opus. Defaults to RED, the grounded hypothesis; `OPN_NVST_AUDIO_RED=0`
    /// or the `OPNNVSTAudioRED` default forces plain Opus for an A/B comparison.
    static var usesRedAudio: Bool {
        if ProcessInfo.processInfo.environment["OPN_NVST_AUDIO_RED"] == "0" { return false }
        if UserDefaults.standard.object(forKey: "OPNNVSTAudioRED") != nil {
            return UserDefaults.standard.bool(forKey: "OPNNVSTAudioRED")
        }
        return true
    }

    static var audioPayloadFormatLine: String {
        usesRedAudio ? "\(redPayloadType) \(opusPayloadType)" : "\(opusPayloadType)"
    }

    /// 48 kHz stereo Opus in 5 ms frames. libwebrtc decodes Opus as mono unless `stereo=1` is
    /// negotiated. Under RED, pt 63 carries generations of the pt-111 Opus payload.
    static var audioCodecLines: [String] {
        var lines: [String] = []
        if usesRedAudio {
            lines.append("a=rtpmap:\(redPayloadType) red/48000/2")
            lines.append("a=fmtp:\(redPayloadType) \(opusPayloadType)/\(opusPayloadType)")
        }
        lines.append("a=rtpmap:\(opusPayloadType) opus/48000/2")
        lines.append("a=fmtp:\(opusPayloadType) minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1")
        return lines
    }

    static func replacingIceCredentials(in sdp: String, usernameFragment: String, password: String) -> String {
        sdp.components(separatedBy: "\r\n").map { line in
            if line.hasPrefix("a=ice-ufrag:") { return "a=ice-ufrag:\(usernameFragment)" }
            if line.hasPrefix("a=ice-pwd:") { return "a=ice-pwd:\(password)" }
            return line
        }.joined(separator: "\r\n")
    }

    static func fingerprint(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=fingerprint:") {
            let parts = line.dropFirst("a=fingerprint:".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func setupRole(inSdp sdp: String) -> String? {
        for line in sdp.components(separatedBy: .newlines) where line.hasPrefix("a=setup:") {
            return String(line.dropFirst("a=setup:".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `candidate:… udp <priority> <address> <port> typ host` → the address and port to announce.
    static func hostAddress(fromCandidateLine line: String) -> (address: String, port: UInt16)? {
        var text = line
        if text.hasPrefix("a=") { text.removeFirst(2) }
        if text.hasPrefix("candidate:") { text.removeFirst("candidate:".count) }
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count >= 6, let port = UInt16(fields[5]) else { return nil }
        return (fields[4], port)
    }

    // MARK: - Async bridges

    func setRemoteDescription(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.answerFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func createAnswer(_ connection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            connection.answer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: BundleError.answerFailed(error?.localizedDescription ?? "no answer"))
                }
            }
        }
    }

    func setLocalDescription(_ connection: RTCPeerConnection, _ description: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: BundleError.localDescriptionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Waits for gathering to finish rather than taking the first candidate: the first one to
    /// arrive is frequently a bridge interface, and announcing its port arms the seat's media relay
    /// on a socket that never receives anything.
    func waitForHostCandidates() async throws -> [RTCIceCandidate] {
        if let ready = lock.withLock({ gatheringComplete ? hostCandidates : nil }), !ready.isEmpty {
            return ready
        }
        return try await withThrowingTaskGroup(of: [RTCIceCandidate].self) { group in
            group.addTask { [weak self] in
                guard let self else { throw BundleError.noHostCandidate }
                return try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if gatheringComplete, !hostCandidates.isEmpty {
                        let ready = hostCandidates
                        lock.unlock()
                        continuation.resume(returning: ready)
                        return
                    }
                    hostCandidateContinuation = continuation
                    lock.unlock()
                }
            }
            group.addTask { [weak self] in
                // Gathering on a machine with many interfaces still settles in well under a second;
                // this only bounds a stack that never reports completion.
                try await Task.sleep(for: .seconds(2))
                self?.finishHostCandidateWait()
                throw BundleError.noHostCandidate
            }
            guard let candidates = try await group.next() else {
                throw BundleError.noHostCandidate
            }
            group.cancelAll()
            return candidates
        }
    }

    /// Resumes the wait with whatever has been gathered so far.
    func finishHostCandidateWait() {
        lock.lock()
        let waiting = hostCandidateContinuation
        hostCandidateContinuation = nil
        let gathered = hostCandidates
        lock.unlock()
        guard let waiting else { return }
        if gathered.isEmpty {
            waiting.resume(throwing: BundleError.noHostCandidate)
        } else {
            waiting.resume(returning: gathered)
        }
    }

    /// The candidate on the routed interface, falling back to the first gathered one.
    static func preferredHost(among hosts: [(address: String, port: UInt16)],
                              matching preferredAddress: String?) -> (address: String, port: UInt16)? {
        if let preferredAddress, let match = hosts.first(where: { $0.address == preferredAddress }) {
            return match
        }
        return hosts.first
    }
}
