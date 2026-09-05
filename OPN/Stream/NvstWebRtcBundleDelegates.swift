//  libwebrtc's peer-connection and data-channel callbacks, and what the bundle does with the seat's
//  messages on them.
//

import Foundation
@preconcurrency import WebRTC

extension NvstWebRtcBundle {
    // MARK: - RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.contains("typ host"), candidate.sdp.lowercased().contains(" udp ") else { return }
        lock.withLock { hostCandidates.append(candidate) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        lock.lock()
        iceStateDescription = String(newState.rawValue)
        lock.unlock()
        logger?("NVST bundle ICE state \(newState.rawValue)")
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        logger?("NVST bundle inbound data channel '\(dataChannel.label)' id=\(dataChannel.channelId)")
        adopt(dataChannel)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    /// The seat's audio arrives as an SRTP stream muxed on the bundle port — the native stack's
    /// own socket tap shows ~200 packets a second there against a single `SETUP streamid=video/0/0`,
    /// so audio is negotiated by the bundle's SDP rather than by its own RTSP stream.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger?("NVST bundle remote stream '\(stream.streamId)' audio=\(stream.audioTracks.count) video=\(stream.videoTracks.count)")
        for track in stream.audioTracks {
            track.isEnabled = true
            // Both under the lock: this runs on libwebrtc's delegate thread while the transport
            // reads the count from its own actor.
            lock.lock()
            remoteAudioTracks.append(track)
            trackedRemoteAudioCount += 1
            lock.unlock()
            logger?("NVST bundle remote audio track '\(track.trackId)' enabled")
        }
        onRemoteAudio?(stream.audioTracks.count)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.withLock { gatheringComplete = true }
        finishHostCandidateWait()
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    // MARK: - RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger?("NVST bundle channel '\(dataChannel.label)' id=\(dataChannel.channelId) state=\(dataChannel.readyState.rawValue)")
        adopt(dataChannel)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let shouldLog: Bool = lock.withLock {
            inboundFeedbackBytes += buffer.data.count
            inboundMessagesByLabel[dataChannel.label, default: 0] += 1
            guard loggedInboundMessages < Self.maxLoggedInboundMessages else { return false }
            loggedInboundMessages += 1
            return true
        }
        // Cursor notifications and seat statistics keep arriving for the whole session, long past
        // the logging budget, so they are parsed before the log gate below — returning early here
        // used to drop them.
        let (parsedCommands, _) = NvstControlCommand.parse(buffer.data)
        for command in parsedCommands {
            dispatchInboundCommand(command)
        }

        guard shouldLog else { return }
        logInboundMessage(buffer, on: dataChannel)
    }

    /// One parsed control command, routed to whoever owns it.
    private func dispatchInboundCommand(_ command: NvstControlCommand) {
        if let stats = NvstSeatStats.from(command) {
            onSeatStats?(stats)
            return
        }
        if let haptics = NvstHapticEvent.parse(command) {
            describeHapticCommand(command, events: haptics)
            if !haptics.isEmpty { onHapticEvents?(haptics) }
            return
        }
        if let hdrMode = NvstHdrModeNotification.parse(command) {
            logger?("NVST hdr-mode notification \(hdrMode.summary) payload=\(command.payload.prefix(16).map { String(format: "%02x", $0) }.joined())")
            onHdrMode?(hdrMode)
            return
        }
        guard let cursor = NvstRemoteCursor.from(command) else {
            describeCursorCommandIfUnparsed(command)
            return
        }
        // The visibility byte's position is inferred, not captured, so the raw payload is
        // logged next to the decision it produced. "Pointer shows or hides at the wrong time"
        // cannot be told from "the seat said something we misread" without both halves.
        describeCursorCommand(command, decision: cursor.isVisible)
        onRemoteCursor?(cursor)
    }

    /// What an inbound control message logs, once it is inside the logging budget.
    private func logInboundMessage(_ buffer: RTCDataBuffer, on dataChannel: RTCDataChannel) {
        // The seat opens a conversation on `control_channel_reliable` and resets it when we never
        // answer, so what it sends is the next thing we have to understand. NVST command packets
        // start with a 16-bit code (`Command: 0x0206` and friends in Bifrost's own stats), so the
        // leading bytes identify the command.
        // The seat announces the remote-input protocol version, and input stays gated until it
        // arrives. It has been arriving on the control channel since the first capture.
        if let version = NvstRemoteInput.protocolVersion(in: buffer.data) {
            let isNew: Bool = lock.withLock {
                guard negotiatedInputProtocolVersion == nil else { return false }
                negotiatedInputProtocolVersion = version
                return true
            }
            if isNew {
                logger?("NVST bundle input protocol version \(version) from '\(dataChannel.label)'")
                onInputProtocolNegotiated?(version)
            }
        }
        let (commands, trailing) = NvstControlCommand.parse(buffer.data)
        let decoded = commands.map(\.summary).joined(separator: " | ")
        // The seat's remote-input messages are JSON, and their schema is what the client has to
        // answer in kind, so log the text rather than a truncated hex prefix.
        for command in commands where command.isTextual {
            logger?("NVST bundle inbound text \(String(format: "0x%04x", command.code.rawValue)): \(command.text(limit: 600))")
        }
        // The seat's QoS and frame-pacing messages are the only place it states its own rate
        // decision, and a 32-byte prefix cuts them off mid-record, so those two log in full.
        let hexLimit = commands.contains { $0.code == 0x0101 || $0.code == 0x0111 } ? buffer.data.count : 32
        let hex = [UInt8](buffer.data.prefix(hexLimit)).map { String(format: "%02x", $0) }.joined()
        var line = "NVST bundle inbound '\(dataChannel.label)' id=\(dataChannel.channelId)"
        line += " bytes=\(buffer.data.count) binary=\(buffer.isBinary) cmds=[\(decoded)]"
        if !trailing.isEmpty { line += " unparsed=\(trailing.count)" }
        line += " hex=\(hex)"
        logger?(line)
        for command in commands where command.terminationReason != nil {
            logger?("NVST bundle seat terminated the session: \(command.summary)")
        }
    }

    /// Enough to characterise the control conversation without flooding the log.
    static let maxLoggedInboundMessages = 40

    /// Rumble arrives at frame rate while a game vibrates the pad, so only *changes* of motor state
    /// are logged — a held rumble refreshed every 50 ms is one line — and those stop after a
    /// budget. Enough to read a game's intensity curve off the log (a "10% feels like 100%" report
    /// needs the seat's amplitudes, not a count).
    static let maxLoggedHapticChanges = 400

    func describeHapticCommand(_ command: NvstControlCommand, events: [NvstHapticEvent]) {
        let signature = events.map { "\($0.gamepadIndex):\($0.leftMotor):\($0.rightMotor)" }.joined(separator: ",")
        let (shouldLog, ordinal): (Bool, Int) = lock.withLock {
            hapticCommandCount += 1
            hapticEventCount += events.count
            let changed = signature != lastHapticSignature
            if changed { lastHapticSignature = signature; hapticChangeCount += 1 }
            return ((changed && hapticChangeCount <= Self.maxLoggedHapticChanges) || hapticCommandCount % 2000 == 0, hapticCommandCount)
        }
        guard shouldLog else { return }
        let hex = command.payload.prefix(24).map { String(format: "%02x", $0) }.joined()
        let records = events.isEmpty ? "unparsed" : events.map(\.summary).joined(separator: " | ")
        logger?("NVST haptic #\(ordinal) len=\(command.payload.count) \(records) payload=\(hex)")
    }

    /// Haptic commands seen this session, for the diagnostics summary.
    public var hapticCounters: (commands: Int, events: Int) {
        lock.withLock { (hapticCommandCount, hapticEventCount) }
    }

    /// The first channel to actually open with the feedback label is the one the seat accepted; the
    /// rest of the burst is redundant.
    func adopt(_ dataChannel: RTCDataChannel) {
        adoptControl(dataChannel)
        adoptInput(dataChannel)
        adoptCustom(dataChannel)
        adoptPartiallyReliableControl(dataChannel)
        // Match on "rtcp" rather than the exact label: the channel arrives from the seat, and its
        // name is the seat's to choose.
        guard dataChannel.label.lowercased().contains("rtcp"), dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openFeedbackChannel != nil
        if !alreadyOpen { openFeedbackChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle feedback channel open id=\(dataChannel.channelId)")
        onFeedbackChannelOpen?()
    }

    func adoptPartiallyReliableControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_partially_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openPartiallyReliableControlChannel == nil
        if isNew { openPartiallyReliableControlChannel = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle partially-reliable control channel open id=\(dataChannel.channelId)")
        onPartiallyReliableControlOpen?()
    }

    func currentPeerConnection() -> RTCPeerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return peerConnection
    }

    /// Fires when the seat's audio track lands.
    /// The seat's cursor shape/mode notifications, once `mimicRemoteCursor` is enabled.
    /// Logs one line per *change* in what the seat says about the pointer, with the bytes it said
    /// it in. Unchanged repeats are counted rather than logged: the seat repeats the same
    /// notification many times a second.
    func describeCursorCommand(_ command: NvstControlCommand, decision: Bool) {
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let key = "\(command.code.rawValue)/\(hex)/\(decision)"
        let shouldLog: Bool = lock.withLock {
            cursorNotificationCount += 1
            guard key != lastCursorNotification else { return false }
            lastCursorNotification = key
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor notify code=0x%04x len=%d visible=%@ payload=%@ seen=%d",
                       command.code.rawValue, command.payload.count, decision ? "y" : "n", hex, cursorNotificationCount))
    }

    /// A cursor-shaped command the parse refused. `0x0110` is the standing ambiguity — OpenNOW
    /// calls it a bitmap cursor, our own capture-derived table calls it video-stream-progress — and
    /// this is what tells us which, from a session where the pointer misbehaved.
    func describeCursorCommandIfUnparsed(_ command: NvstControlCommand) {
        guard command.code == NvstRemoteCursor.bitmapCursorCode else { return }
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let shouldLog: Bool = lock.withLock {
            guard hex != lastUnparsedCursorPayload else { return false }
            lastUnparsedCursorPayload = hex
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor unparsed code=0x%04x len=%d payload=%@",
                       command.code.rawValue, command.payload.count, hex))
    }




    /// Inbound audio counters straight from libwebrtc, which is the only view of whether the seat
    /// is sending audio at all: the track object exists as soon as the SDP negotiates it, so its
    /// presence proves nothing on its own.
    /// Receiving a packet and decoding it are different things: a payload the decoder rejects still
    /// counts as received, so the sample and concealment counters are what say audio is actually
    /// being produced.
    public struct AudioReception: Sendable {
        public var packets: UInt64 = 0
        /// The remote SSRC libwebrtc bound the audio receiver to, once a packet arrived.
        public var ssrc: UInt32?
        public var bytes: UInt64 = 0
        public var samples: UInt64 = 0
        public var concealed: UInt64 = 0
        public var discarded: UInt64 = 0
        /// libwebrtc's cumulative `jitterBufferDelay` (seconds) and `jitterBufferEmittedCount`;
        /// the ratio of their deltas is the mean time audio sat in the jitter buffer.
        public var jitterBufferDelaySeconds: Double = 0
        public var jitterBufferEmitted: UInt64 = 0
    }

    public func audioReception() async -> AudioReception? {
        guard let connection = currentPeerConnection() else { return nil }
        // `statistics` answers through a callback, and a continuation that is never resumed hangs
        // its caller for good — `logCounters` is awaited by teardown, so that would be a stream that
        // never tears down. `close()` nils the connection, which covers the ordinary path; this
        // covers the race where it closed after the read above.
        guard connection.signalingState != .closed else { return nil }
        let report = await withCheckedContinuation { continuation in
            connection.statistics { continuation.resume(returning: $0) }
        }
        var reception = AudioReception()
        var sawAudio = false
        for (_, statistics) in report.statistics
        where statistics.type == "inbound-rtp" && (statistics.values["kind"] as? String) == "audio" {
            sawAudio = true
            func number(_ key: String) -> UInt64 { (statistics.values[key] as? NSNumber)?.uint64Value ?? 0 }
            reception.packets += number("packetsReceived")
            reception.bytes += number("bytesReceived")
            reception.samples += number("totalSamplesReceived")
            reception.concealed += number("concealedSamples")
            reception.discarded += number("packetsDiscarded")
            reception.jitterBufferDelaySeconds += (statistics.values["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
            reception.jitterBufferEmitted += number("jitterBufferEmittedCount")
            if let ssrc = statistics.values["ssrc"] as? NSNumber { reception.ssrc = ssrc.uint32Value }
        }
        return sawAudio ? reception : nil
    }


    func adoptCustom(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label.hasPrefix("custom_message_on_sctp_private"), dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openCustomChannels[dataChannel.label] == nil
        if isNew { openCustomChannels[dataChannel.label] = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle custom channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    /// The input plane. Partially reliable, because a stale mouse delta is worse than a lost one.
    func adoptInput(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let isReliable = dataChannel.label == "input_channel_v1"
        guard isReliable || dataChannel.label == "input_channel_partially_reliable" else { return }
        lock.lock()
        let alreadyOpen = isReliable ? openReliableInputChannel != nil : openInputChannel != nil
        if !alreadyOpen {
            if isReliable { openReliableInputChannel = dataChannel } else { openInputChannel = dataChannel }
        }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle input channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    /// `control_channel_reliable` is where the seat's client-timeout is measured, so its opening is
    /// what starts the keepalive.
    func adoptControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openControlChannel != nil
        if !alreadyOpen { openControlChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle control channel open id=\(dataChannel.channelId)")
        onControlChannelOpen?()
    }
}
