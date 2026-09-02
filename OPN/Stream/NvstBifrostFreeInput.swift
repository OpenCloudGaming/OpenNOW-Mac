//
//  NvstBifrostFreeInput.swift
//  OpenNOW
//
//  Input, text and the runtime session controls the client can change mid-stream.
//  Split out of NvstBifrostFreeTransport.swift.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

extension NvstBifrostFreeTransport {
    // MARK: - Input, text, and session controls

    public func send(_ event: UserInputEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet (channels open: \(bundle?.isInputChannelOpen == true), protocol: \(bundle?.inputProtocolVersion.map(String.init) ?? "none")).")
        }
        // Gamepad state is its own command on the input channel, not an envelope on the control
        // channel, so it never reaches the remote-input packet builder.
        if case .gamepad(let state) = event {
            // The seat rejects any id >= 4 outright, so a caller that hands us a fifth player is a
            // bug upstream, not something to silently fold onto the host's pad.
            let padIndex = state.playerIndex
            guard (0..<4).contains(padIndex) else {
                throw NativeNVSTError.transportFailed("NVST has no gamepad slot \(padIndex); the seat allows 0...3.")
            }
            // Only pads the seat has actually been told about may send state. Announcing one here
            // instead would resurrect a Remote Co-Op guest who has just been removed: their input
            // is coalesced on a queue, so packets can still drain after the topology dropped them,
            // and each one would re-add the slot the host just took away.
            //
            // `updateGamepadTopology` owns this set, and `presentStream` publishes a topology as
            // soon as the session connects, so a pad that is genuinely present is only unannounced
            // for the moment between being plugged in and the view reporting it.
            guard connectedGamepadIndices.contains(padIndex) else {
                gamepadPacketsDroppedForUnannouncedPad += 1
                return
            }
            let bitmap = NvstGamepadPacket.connectedBitmap(for: connectedGamepadIndices)
            if registeredGamepadBitmap != bitmap {
                sendGamepadRegistration(bitmap: bitmap, bundle: bundle, reason: "pad \(padIndex) input")
            }
            let sequence = (gamepadSequences[UInt16(padIndex)] ?? 0) &+ 1
            gamepadSequences[UInt16(padIndex)] = sequence
            // Resting analog sticks are not exactly centred (~2% drift, seen jittering every poll).
            // A real XInput pad drifts too and the game applies XINPUT_*_THUMB_DEADZONE; this title
            // does not, so the drift reads as a held direction and the jitter floods on-change
            // sends. Apply the standard radial deadzone here instead.
            let (lx, ly) = Self.deadzoned(state.leftStickX, state.leftStickY, Self.leftStickDeadzone)
            let (rx, ry) = Self.deadzoned(state.rightStickX, state.rightStickY, Self.rightStickDeadzone)
            let packet = NvstGamepadPacket(
                sequence: sequence,
                timestampMicroseconds: sessionElapsedMicroseconds(),
                buttons: Self.wireButtons(state.buttons),
                leftTrigger: NvstGamepadPacket.trigger(state.leftTrigger),
                rightTrigger: NvstGamepadPacket.trigger(state.rightTrigger),
                leftStickX: NvstGamepadPacket.axis(lx),
                leftStickY: NvstGamepadPacket.axis(ly),
                rightStickX: NvstGamepadPacket.axis(rx),
                rightStickY: NvstGamepadPacket.axis(ry),
                gamepadIndex: UInt16(padIndex),
                connectedBitmap: bitmap
            )
            // Gamepad state goes on the input channel (SCTP stream 10), matching the vendored
            // client's captured traffic. Both channels were tried while the packet itself was
            // malformed and both were dead, which proved nothing about the channel; sid 10 is what
            // the official client uses, so that is what we send.
            let padSendStart = DispatchTime.now().uptimeNanoseconds
            let delivered = (try? packet.command.encoded).map(bundle.sendInput) ?? false
            noteInputSend(from: padSendStart)
            if delivered { gamepadPacketsSent += 1 } else { gamepadSendFailures += 1 }
            guard delivered else {
                throw NativeNVSTError.transportFailed("The NVST input channel rejected the gamepad state.")
            }
            inputEventsSent += 1
            return
        }
        // Text has no recovered encoding, so it is typed instead. The stream view sends it for IME
        // composition, Option-modified and non-ASCII characters, and for paste — which would
        // otherwise vanish into the `try?` at the call site.
        if case .text(_, let value, _) = event {
            try sendAsUtf8Text(value)
            return
        }
        guard let packet = Self.remoteInputPacket(for: event) else {
            // Keyboard, text and gamepad encodings are not recovered yet; failing loudly beats
            // sending a packet whose shape is a guess.
            throw NativeNVSTError.transportFailed("No NVST remote-input encoding for \(event) yet.")
        }
        try sendFramedRemoteInput(packet)
    }

    /// Frames one remote-input packet in the session's timestamp envelope and writes it to the
    /// control channel as command `0x206`, counting the event and the write's cost. Microseconds
    /// since the session began, not since the epoch: the captured client sends ~25.9 s into a
    /// 26 s session, and an epoch timestamp is ~1.7e15 — a seat that sanity-checks it against
    /// session time discards the packet.
    func sendFramedRemoteInput(_ packet: Data) throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        inputSequence &+= 1
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: inputSequence,
                                            timestampMicroseconds: sessionElapsedMicroseconds())
        let sendStart = DispatchTime.now().uptimeNanoseconds
        let accepted = bundle.sendControl(NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed))
        noteInputSend(from: sendStart)
        guard accepted else {
            throw NativeNVSTError.transportFailed("The NVST control channel rejected the input packet.")
        }
        inputEventsSent += 1
    }

    /// Every input write is a blocking proxy call into libwebrtc's network thread, made while this
    /// actor is held — so a slow one delays every video frame queued behind it. Tracked to tell
    /// that apart from a decode stall.
    func noteInputSend(from start: UInt64) {
        let end = DispatchTime.now().uptimeNanoseconds
        let milliseconds = end > start ? Double(end - start) / 1_000_000 : 0
        inputSendTotalMs += milliseconds
        if milliseconds > inputSendPeakMs { inputSendPeakMs = milliseconds }
    }


    /// The channel and framing the seat honours, now settled by measurement rather than by
    /// walking candidates: remote input goes out as command `0x206`, envelope-framed, on
    /// `control_channel_reliable` (SCTP stream 0). Our packets are byte-identical to the native
    /// stack's, and the seat's reaction to them is too — see `NvstInputActivationTests`.
    ///
    /// The set of candidate channel/framing combinations this used to walk is gone: rotating
    /// between them sent half of every session's events to a channel the seat ignores, which is
    /// part of why input looked broken for so long.
    enum InputDestination: String, CaseIterable {
        case control
    }

    /// These exist on the vendored transports and are called at runtime — the host applies a
    /// maximum-bitrate change through `setMaximumBitrateKbps`, and the stream view pushes controller
    /// topology through `updateGamepadTopology`. Without them the protocol's default throws
    /// `notRunning`, which reads as "no session" and sent me looking in the wrong place once
    /// already with `sendAbsoluteMouseMove`. They still fail, but they now say why.
    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        throw NativeNVSTError.transportFailed(
            "Changing the maximum bitrate mid-session is not implemented on the Bifrost-free path; "
            + "the announced cap comes from the negotiated session profile.")
    }

    /// Feeds both the on-screen overlay and `NativeNVSTStreamHealthMonitor` from the receive path's
    /// own counters.
    ///
    /// This was nil for a while: returning a snapshot arms the monitor, and the monitor then checks
    /// `nativeNVSTRendererSurfaceReady`, which used to be tied to the vendored NVST Metal view this
    /// path never attaches — so it tore down a healthy stream. That readiness signal now reports
    /// our own renderer, so the snapshot is safe to return, and without it the overlay shows only
    /// dashes.
    ///
    /// `streamFramesPerSecond` is the rate over the last poll interval, not the session average:
    /// the monitor uses it for stall detection, and an average would mask a real stall late in a
    /// long session.
    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard let receiver, let started = sessionStartedAt else { return nil }
        let counters = receiver.feedbackCounters
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(started))

        let interval = lastSnapshotAt.map { max(0.001, now.timeIntervalSince($0)) } ?? elapsed
        let framesSinceLast = counters.framesEmitted &- lastSnapshotFrames
        let bytesSinceLast = counters.bytesReceived &- lastSnapshotBytes
        let instantFps = Double(framesSinceLast) / interval
        let instantMbps = Double(bytesSinceLast) * 8 / interval / 1_000_000
        lastSnapshotAt = now
        lastSnapshotFrames = counters.framesEmitted
        lastSnapshotBytes = counters.bytesReceived

        // Loss over the interval, computed the way the WebRTC path computes it, so the two HUDs
        // report the same quantity rather than one percent and one running count.
        let stats = receiver.stats
        let packetsNow = stats.authenticatedPackets
        let lostNow = UInt64(stats.lastCumulativeLost)
        let packetsDelta = packetsNow >= lastSnapshotPackets ? packetsNow - lastSnapshotPackets : 0
        let lostDelta = lostNow >= lastSnapshotLost ? lostNow - lastSnapshotLost : 0
        lastSnapshotPackets = packetsNow
        lastSnapshotLost = lostNow
        let lossPercent = packetsDelta + lostDelta > 0
            ? Double(lostDelta) * 100 / Double(packetsDelta + lostDelta)
            : 0

        // The seat's round trip, from libwebrtc's own ICE candidate pair — the same source the
        // WebRTC transport's HUD reads. Requested here rather than on a timer of its own: the HUD
        // polls this method about once a second, which is the rate the sample is wanted at.
        bundle?.refreshTransportStatistics()
        let roundTrip = bundle?.roundTripMilliseconds ?? -1
        let video = videoPipeline?.snapshot
        let decodeMilliseconds = (video?.framesHandled ?? 0) > 0
            ? (video?.total.decode ?? 0) / Double(video?.framesHandled ?? 1)
            : -1

        // The seat's own 0x0101 statistics carry the game render rate — the number the vendored
        // client showed and this path had hardcoded to "--". (Its float at +40 looked like a
        // latency at first and is NOT one: live calibration showed it drifting 98→393 ms while
        // the path sat at single-digit RTT. It stays in the calibration log only.)
        let seatStats = latestSeatStats
        // ICE candidate-pair RTT stays the preferred latency source, but this seat never answers
        // libwebrtc's connectivity checks, so it is normally -1 here. Fallbacks, most direct
        // first: the Mjolnir socket's own STUN round trip on the media path (measured only if the
        // seat answers, which it may not — it acts as a STUN client, not a server), then the
        // control connection's WebSocket ping/pong, which the seat answers mandatorily.
        var mjolnirRoundTrip = receiver.roundTripMilliseconds
        if mjolnirRoundTrip < 0, let session {
            mjolnirRoundTrip = await session.controlRoundTripMilliseconds()
        }
        return NativeNVSTPerformanceSnapshot(
            available: counters.framesEmitted > 0,
            gameFramesPerSecond: seatStats?.gameFramesPerSecond ?? -1,
            streamFramesPerSecond: instantFps,
            // Network round trip, not client decode cost — the decode number has its own field.
            latencyMilliseconds: roundTrip >= 0 ? roundTrip : mjolnirRoundTrip,
            jitterMilliseconds: Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate),
            frameLoss: stats.abandonedFrames,
            totalFrameLoss: stats.abandonedFrames + UInt64(video?.missingParameterSetFrames ?? 0),
            packetLoss: UInt64(stats.lastCumulativeLost),
            totalPacketLoss: stats.droppedPackets,
            packetLossPercent: lossPercent,
            decodeMilliseconds: decodeMilliseconds,
            bitrateMegabitsPerSecond: instantMbps,
            bandwidthUtilizationPercent: 0,
            // What the decoder actually produced, falling back to the negotiated string until the
            // first frame lands. A seat that ignored the requested geometry shows up here.
            resolution: decoder?.decodedResolution ?? negotiatedResolution ?? "",
            codec: negotiatedCodec ?? lastHandoff.map { String(describing: $0.codec) } ?? "",
            // The CloudMatch session's human server name ("np-tyo-01" style), the way the vendored
            // transport reported it; the video peer IP is only the fallback for a session that
            // carries no name.
            serverLocation: sessionServerLocation ?? lastHandoff?.videoPeerIP ?? ""
        )
    }
    // Session-peak tracker for the NVST SESSION SUMMARY line (see logCounters).

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        throw NativeNVSTError.transportFailed("Dynamic streaming mode is not implemented on the Bifrost-free path.")
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        throw NativeNVSTError.transportFailed("L4S toggling is not implemented on the Bifrost-free path.")
    }

    /// Announces exactly the pads in `topology`. This is how a Remote Co-Op guest becomes player 2
    /// and how they stop being one: the descriptor's bitmap is the whole truth, so re-sending it
    /// with a pad missing is the disconnect.
    ///
    /// Callers are expected to have already sent a neutral state for any pad they are dropping —
    /// once it is out of the bitmap the seat will not accept one, and the game keeps whatever was
    /// held down at the moment it vanished.
    public func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws {
        // The requested set is recorded before the readiness check, and this ordering is
        // load-bearing.
        //
        // `presentStream` publishes the local topology as soon as the session connects, but input
        // is negotiated separately and `activateInput` may not have run yet. Recording only on
        // success meant a host with two controllers plugged in at launch lost the second one for
        // the whole session: the announce threw, the caller swallowed it with `try?`, activation
        // then seeded pad 0 alone, and `send` drops state for a pad that was never announced.
        // Nothing re-announced it either, because `onTopologyChanged` only fires when the topology
        // *changes* and it had not. Keeping the intent means activation announces the real set.
        //
        // An empty topology still leaves the seat believing in pad 0: the activation descriptor
        // announced it, and `connectedBitmap(for:)` falls back to it rather than announcing no
        // devices at all. Normalising here keeps this set equal to what was actually announced, so
        // `send`'s membership check cannot disagree with the bitmap on the wire.
        let indices = Set(topology.playerIndices).isEmpty ? Set([0]) : Set(topology.playerIndices)
        connectedGamepadIndices = indices
        // A pad that leaves must not keep its counter: the seat tracks the sequence per gamepad,
        // so a slot reused by the next guest would resume mid-stream and its first packets would
        // look stale.
        gamepadSequences = gamepadSequences.filter { indices.contains(Int($0.key)) }
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let bitmap = NvstGamepadPacket.connectedBitmap(for: indices)
        guard registeredGamepadBitmap != bitmap else { return }
        sendGamepadRegistration(bitmap: bitmap, bundle: bundle, reason: "topology \(indices.sorted())")
    }

    /// Sends the `0x20d` device descriptor and records what the seat was told. Recorded even when
    /// the write fails, so a failed announce is visible in `padReg` rather than retried on every
    /// single state packet at 250 Hz.
    func sendGamepadRegistration(bitmap: UInt16, bundle: NvstWebRtcBundle, reason: String) {
        let registered = bundle.sendControl(NvstInputActivation.deviceDescriptor(
            timestampMicroseconds: sessionElapsedMicroseconds(),
            connectedBitmap: bitmap))
        registeredGamepadBitmap = bitmap
        logger?("NVST gamepad registration bitmap=0x\(String(bitmap, radix: 16)) reason=\(reason) sent=\(registered) inputReady=\(bundle.isInputReady) inputChannelOpen=\(bundle.isInputChannelOpen)")
    }

    /// Accepts the configuration and does nothing with it, which is what the protocol's own default
    /// did. Throwing here broke every stream: the host applies the microphone configuration
    /// *before* `start`, in the same `do` block, so a thrown error meant `start` was never reached
    /// and no session was ever requested — a launch that died right after "Launch plan ready".
    ///
    /// There is nothing to configure on a path with no microphone, so this is genuinely satisfied
    /// rather than silently swallowed. Actually *enabling* capture is what fails, below.
    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {}

    /// There is no seat-side pause primitive on this path — RTSP TEARDOWN always ends the local
    /// media session, same as `disconnect()`. What makes this a "pause" instead of a full end is
    /// the caller: `NativeNVSTStreamingPath.pause` separately tells CloudMatch to keep the cloud
    /// seat alive (`sessionProvider.finishSession(reason: .paused)`) so it can be resumed later.
    public func pause() async throws {
        recorder.stop()
        await teardown(reason: "pause")
    }

    /// Sends `text` as raw UTF-8 text packets (RI type 23), chunked at code point boundaries —
    /// the encoding the official client's `sendUnicodeEvent` uses for IME commits and pastes. It
    /// replaces the old virtual-keystroke fallback, which could not represent anything a US
    /// layout cannot type.
    func sendAsUtf8Text(_ text: String) throws {
        let (packets, droppedBytes) = NvstRemoteInput.utf8TextPackets(forText: text)
        guard !packets.isEmpty else {
            throw NativeNVSTError.transportFailed(
                "No NVST encoding for text \"\(text.prefix(16))\": it produced no UTF-8 bytes.")
        }
        if droppedBytes > 0 {
            textBytesDropped += droppedBytes
            logger?("NVST text dropped \(droppedBytes) unchunkable UTF-8 byte(s); sending the rest")
        }
        for packet in packets {
            try sendFramedRemoteInput(packet)
        }
        textCharactersTyped += text.count
    }

    /// The absolute cursor position. This never arrives as a `UserInputEvent` — the stream view
    /// routes it through its own call — and the protocol default for it throws, so before this
    /// existed every pointer move in absolute cursor mode was silently dropped while clicks still
    /// went out, landing wherever the remote cursor happened to be.
    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let packet = NvstRemoteInput.absoluteMouseMove(
            x: UInt16(clamping: event.x),
            y: UInt16(clamping: event.y),
            viewportWidth: UInt16(clamping: event.viewportWidth),
            viewportHeight: UInt16(clamping: event.viewportHeight)
        )
        try sendFramedRemoteInput(packet)
    }

    /// Our button set as XInput's mask, which is what the wire carries.
    /// Inner radial deadzone as a fraction of full scale. This SC2 stick's resting drift spikes to
    /// ~8% on Y, so 8% leaked a phantom "up"; the pad reaches full ±1.0, so XInput's own standard
    /// deadzones (7849/32767 left, 8689/32767 right) fit and are what games are calibrated for.
    static let leftStickDeadzone: Float = 0.2395
    static let rightStickDeadzone: Float = 0.2651

    /// A radial deadzone: inside `deadzone` the stick reads centred; outside, the remaining range is
    /// rescaled to the full 0...1 so the edge still reaches the extremes.
    static func deadzoned(_ x: Float, _ y: Float, _ deadzone: Float) -> (Float, Float) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadzone else { return (0, 0) }
        let scale = ((magnitude - deadzone) / (1 - deadzone)) / magnitude
        return (x * scale, y * scale)
    }

    static func wireButtons(_ buttons: GamepadButtons) -> UInt16 {
        var mask: UInt16 = 0
        let mapping: [(GamepadButtons, UInt16)] = [
            (.south, NvstGamepadPacket.Button.a),
            (.east, NvstGamepadPacket.Button.b),
            (.west, NvstGamepadPacket.Button.x),
            (.north, NvstGamepadPacket.Button.y),
            (.leftShoulder, NvstGamepadPacket.Button.leftShoulder),
            (.rightShoulder, NvstGamepadPacket.Button.rightShoulder),
            (.select, NvstGamepadPacket.Button.back),
            (.start, NvstGamepadPacket.Button.start),
            (.dpadUp, NvstGamepadPacket.Button.dPadUp),
            (.dpadDown, NvstGamepadPacket.Button.dPadDown),
            (.dpadLeft, NvstGamepadPacket.Button.dPadLeft),
            (.dpadRight, NvstGamepadPacket.Button.dPadRight),
            (.leftStick, NvstGamepadPacket.Button.leftThumb),
            (.rightStick, NvstGamepadPacket.Button.rightThumb),
            // Guide/Xbox/PS. Was dropped entirely, so the button did nothing in games that use it.
            // On the Steam Controller `.mode` is also the chord key for the client-side grip and
            // guide-cursor combos; those are consumed before this point, and anything that reaches
            // here is a plain Guide press the seat should see.
            (.mode, NvstGamepadPacket.Button.guide),
        ]
        for (ours, theirs) in mapping where buttons.contains(ours) { mask |= theirs }
        return mask
    }

    /// Translates the app's input model into an RI packet. Returns nil for events whose encoding
    /// has not been recovered.
    static func remoteInputPacket(for event: UserInputEvent) -> Data? {
        switch event {
        case .mouse(.moved(_, let deltaX, let deltaY, _)):
            NvstRemoteInput.mouseMove(deltaX: deltaX, deltaY: deltaY)
        case .mouse(.button(_, let button, let isPressed, _)):
            NvstRemoteInput.mouseButton(Self.wireButton(button), isPressed: isPressed)
        case .keyboard(let event):
            NvstRemoteInput.keyboard(
                virtualKey: NativeWebRTCTransport.keyboardCodes(forMacKeyCode: event.keyCode).keyCode,
                modifiers: event.modifiers.rawValue & 0x000f,
                isPressed: event.isPressed
            )
        case .mouse(.wheel(_, let delta, _)):
            NvstRemoteInput.mouseWheel(delta: delta)
        case .text, .gamepad:
            nil
        }
    }

    /// The app orders mouse buttons right=2/middle=3; the wire orders them middle=2/right=3.
    static func wireButton(_ button: MouseButton) -> NvstRemoteInput.Button {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .back: .extra1
        case .forward: .extra2
        }
    }

    /// Turning the microphone *off* is already true, so it succeeds; turning it on is a request this
    /// path cannot honour and has to be reported.
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard enabled else { return }
        throw NativeNVSTError.transportFailed(
            "Microphone capture is not implemented on the Bifrost-free path yet.")
    }

    public func togglePerformanceOverlay() async throws {
        throw NativeNVSTError.notRunning
    }

    /// Local speaker output only - what a Remote Co-Op guest receives is untouched, since the audio
    /// relay taps its own source rather than this playback path.
    ///
    /// NVST audio rides the ICE/DTLS bundle, so the bundle's remote tracks are the whole of local
    /// playback. There used to be a second, socket-owned playback path here; it never worked and is
    /// gone.
    public func setLocalAudioPlaybackMuted(_ muted: Bool) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        bundle.setRemoteAudioMuted(muted)
    }
}
