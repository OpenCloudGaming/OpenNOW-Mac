//  The SDP this bundle synthesizes for a seat that is not an ICE agent, and the async bridges over
//  libwebrtc's callback API.
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
                                       peerPort: UInt16,
                                       includesMicrophone: Bool = false) -> String {
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
            "a=group:BUNDLE \(includesMicrophone ? "0 1 2" : "0 1")",
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
        if includesMicrophone {
            // With the mic section in the bundle, Opus pt 111 appears in two audio m-sections and
            // libwebrtc turns payload-type demuxing OFF for every audio section of the bundle
            // (SdpOfferAnswerHandler::UpdatePayloadTypeDemuxingState, webrtc issue 11477 — the
            // codec-collision warning it logs at sdp_offer_answer.cc:570 is the tell). The seat sets
            // no MID extension and this section had no signaled SSRC, so every downlink audio packet
            // became undemuxable and was dropped before `inbound-rtp` counted it: the "seat withholds
            // game audio whenever a mic section exists, even inactive" finding was our own demuxer.
            // Signal the seat's audio SSRC — the vendor's transport uses the deterministic 1 (captured
            // on the wire, `ssrc=0x00000001`) — so the receiver binds by SSRC instead. Only under the
            // mic section: without it payload-type demuxing works and no assumption is needed.
            lines += [
                "a=ssrc:\(seatAudioSsrc) cname:nvst-seat-audio",
            ]
        }
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
        ]
        if includesMicrophone {
            lines += Self.microphoneSectionLines(transport: transport, peerIP: peerIP, peerPort: peerPort)
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// The seat's side of the microphone send section. Shaped from `libBifrost2`'s own RTC SDP
    /// builder: the vendor serializes its mic stream for the native bundle as a plain **audio**
    /// m-section (`getRtcSdpFromConfig` converts `MicStreamConfig` into an `AudioStreamConfig`
    /// and delegates) — Opus at 48 kHz with `a=ptime:10`, rtcp-mux and the mid the mic section
    /// carries. Offered **recvonly** by the seat so our answer is sendonly and libwebrtc builds
    /// the sender into the first answer — NVST has no renegotiation, so the section must exist
    /// from `prepare()` time. Plain Opus, no RED: the seat's DESCRIBE asks for mic redundancy
    /// (`x-nv-aqos.enableRedundancyForMic:1`) but decodes plain pt-111 Opus fine — verified live
    /// with `codec=audio/opus:111` and the seat's virtual mic meter following speech.
    static func microphoneSectionLines(transport: [String], peerIP: String, peerPort: UInt16) -> [String] {
        var lines: [String] = [
            "m=audio 9 UDP/TLS/RTP/SAVPF \(opusPayloadType)",
        ]
        lines += transport
        lines += [
            "a=mid:2",
            "a=rtcp-mux",
            "a=recvonly",
            "a=rtpmap:\(opusPayloadType) opus/48000/2",
            "a=fmtp:\(opusPayloadType) minptime=5;stereo=1;sprop-stereo=1;useinbandfec=1",
            "a=ptime:10",
            "a=maxptime:120",
            "a=candidate:1 1 udp 2122260223 \(peerIP) \(peerPort) typ host",
        ]
        return lines
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
    /// The SSRC the seat's bundle game audio arrives with. Captured from the native stack's bundle
    /// socket (`pt=63, ssrc=0x00000001`) and consistent with the vendor transport's deterministic
    /// SSRC scheme (the mic sender is SSRC 1 as well). Signaled in the synthesized offer only when
    /// the mic section makes payload-type demuxing unavailable.
    static let seatAudioSsrc: UInt32 = 1
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

    /// Rewrites every `a=ssrc:` line of the mid-2 mic send section to `ssrc`, leaving the other
    /// sections untouched. libwebrtc allocates sender SSRCs while creating the answer and exposes
    /// no API to choose them (`setParameters` refuses an encoding it did not create), but it
    /// *does* honour the `a=ssrc` lines of the local description it is handed: `setLocalDescription`
    /// builds the send stream from those lines, the same seam legacy simulcast munging used for
    /// years. This is how the mic sender ends up on the vendor's deterministic SSRC 1.
    static func replacingMicrophoneSenderSsrc(in sdp: String, with ssrc: UInt32) -> String {
        var inMicrophoneSection = false
        return sdp.components(separatedBy: "\r\n").map { line -> String in
            if line.hasPrefix("m=") { inMicrophoneSection = false; return line }
            if line == "a=mid:2" { inMicrophoneSection = true; return line }
            guard inMicrophoneSection, line.hasPrefix("a=ssrc:") else { return line }
            let rest = line.dropFirst("a=ssrc:".count)
            guard let space = rest.firstIndex(of: " ") else { return "a=ssrc:\(ssrc)" }
            return "a=ssrc:\(ssrc)\(rest[space...])"
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

    /// The SSRC the mic send section (mid 2) names in the answer. The read is scoped to that
    /// section because a live session proved the recvonly downlink section can carry `a=ssrc`
    /// lines too — an unscoped "first ssrc" read advertised the seat's downlink SSRC as the mic
    /// sender. This SSRC is what ANNOUNCE advertises as `x-nv-mic.micSsrcConfig.senderSsrc`.
    static func microphoneSenderSsrc(inSdp sdp: String) -> UInt32? {
        var inMicrophoneSection = false
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") { inMicrophoneSection = false; continue }
            if line == "a=mid:2" { inMicrophoneSection = true; continue }
            guard inMicrophoneSection, line.hasPrefix("a=ssrc:") else { continue }
            let rest = line.dropFirst("a=ssrc:".count)
            let ssrcText = rest.split(separator: " ", maxSplits: 1).first ?? rest
            if let ssrc = UInt32(ssrcText.trimmingCharacters(in: .whitespaces)) { return ssrc }
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
