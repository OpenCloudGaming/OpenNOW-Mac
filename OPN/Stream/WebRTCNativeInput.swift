import Foundation

@preconcurrency import WebRTC

@objc(OPNLibWebRTCInput)
final class OPNLibWebRTCInput: NSObject, @unchecked Sendable {
    private weak var owner: OPNLibWebRTCStreamSession?
    private let encoder = OPNInputProtocolEncoder()
    private let encoderLock = NSLock()
    private let stateLock = NSLock()
    private var inputReady = false
    private var reliableOpen = false
    private var partialOpen = false
    private var handshakeComplete = false
    private var inputConfiguration = NVSTInputTransportConfiguration.fallback
    private var heartbeat: DispatchSourceTimer?
    private weak var sessionImpl: OPNLibWebRTCSessionImpl?

    @objc(initWithOwner:)
    init(owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        super.init()
    }

    @objc(sendInputData:partiallyReliable:sessionImpl:)
    func sendInput(data: Data, partiallyReliable: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard !data.isEmpty else { return }
        let usePartial = partiallyReliable && inputConfiguration.partialReliableEnabled
        let channel = usePartial ? sessionImpl?.partialInputChannel : sessionImpl?.reliableInputChannel
        guard let channel, channel.readyState == .open else { return }
        if usePartial {
            guard channel.bufferedAmount <= GeronimoInputChannel.partialReliableInputBacklogLimitBytes else { return }
        }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func configureInput(_ configuration: NVSTInputTransportConfiguration) {
        stateLock.withLock { inputConfiguration = configuration }
    }

    @objc(createInputChannelWithSessionImpl:)
    func createInputChannel(sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard let sessionImpl, let peerConnection = sessionImpl.peerConnection else { return }
        guard sessionImpl.reliableInputChannel == nil, sessionImpl.partialInputChannel == nil else { return }
        self.sessionImpl = sessionImpl

        let reliableConfig = RTCDataChannelConfiguration()
        reliableConfig.isOrdered = true
        reliableConfig.maxRetransmits = -1
        reliableConfig.maxPacketLifeTime = -1
        sessionImpl.reliableInputChannel = peerConnection.dataChannel(forLabel: GeronimoInputChannel.reliableLabel, configuration: reliableConfig)
        sessionImpl.reliableInputChannel?.delegate = sessionImpl

        let configuration = stateLock.withLock { inputConfiguration }
        guard configuration.partialReliableEnabled else { return }
        let partialConfig = RTCDataChannelConfiguration()
        partialConfig.isOrdered = false
        partialConfig.maxRetransmits = -1
        partialConfig.maxPacketLifeTime = Int32(max(0, min(Int(Int32.max), configuration.partialReliableThresholdMs)))
        sessionImpl.partialInputChannel = peerConnection.dataChannel(forLabel: GeronimoInputChannel.partiallyReliableLabel, configuration: partialConfig)
        sessionImpl.partialInputChannel?.delegate = sessionImpl
    }

    @objc var isInputReady: Bool { stateLock.withLock { inputReady } }

    @objc(sendKeyWithKeycode:scancode:modifiers:down:sessionImpl:)
    func sendKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, down: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoderLock.withLock { encoder.encodeKey(keycode: keycode, scancode: scancode, modifiers: modifiers, timestampUs: OPNInputProtocolEncoder.timestampUs(), down: down) }
        sendInput(data: encoded, partiallyReliable: false, sessionImpl: sessionImpl)
    }

    @objc(sendMouseMoveWithDx:dy:sessionImpl:)
    func sendMouseMove(dx: Int16, dy: Int16, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let usePartial = shouldSendHIDPartiallyReliable()
        if usePartial {
            guard let channel = sessionImpl?.partialInputChannel,
                  channel.readyState == .open,
                  channel.bufferedAmount <= GeronimoInputChannel.mouseInputBacklogLimitBytes else { return }
        }
        let encoded = encoderLock.withLock { encoder.encodeMouseMove(dx: dx, dy: dy, timestampUs: OPNInputProtocolEncoder.timestampUs()) }
        sendInput(data: encoded, partiallyReliable: usePartial, sessionImpl: sessionImpl)
    }

    @objc(sendMouseButtonWithButton:down:sessionImpl:)
    func sendMouseButton(button: UInt8, down: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoderLock.withLock { encoder.encodeMouseButton(button: button, timestampUs: OPNInputProtocolEncoder.timestampUs(), down: down) }
        sendInput(data: encoded, partiallyReliable: false, sessionImpl: sessionImpl)
    }

    @objc(sendMouseWheelWithDelta:sessionImpl:)
    func sendMouseWheel(delta: Int16, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoderLock.withLock { encoder.encodeMouseWheel(delta: delta, timestampUs: OPNInputProtocolEncoder.timestampUs()) }
        sendInput(data: encoded, partiallyReliable: false, sessionImpl: sessionImpl)
    }

    @objc(sendUtf8Text:sessionImpl:)
    func sendUtf8Text(_ text: String, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoderLock.withLock { encoder.encodeUtf8Text(text) }
        sendInput(data: encoded, partiallyReliable: false, sessionImpl: sessionImpl)
    }

    @objc(sendGamepadStateWithControllerId:buttons:leftTrigger:rightTrigger:leftStickX:leftStickY:rightStickX:rightStickY:timestampUs:bitmap:sessionImpl:)
    func sendGamepadState(controllerId: UInt16,
                          buttons: UInt16,
                          leftTrigger: UInt8,
                          rightTrigger: UInt8,
                          leftStickX: Int16,
                          leftStickY: Int16,
                          rightStickX: Int16,
                          rightStickY: Int16,
                          timestampUs: UInt64,
                          bitmap: UInt16,
                          sessionImpl: OPNLibWebRTCSessionImpl?) {
        let usePartial = shouldSendGamepadPartiallyReliable(controllerId: controllerId)
        if usePartial {
            guard let channel = sessionImpl?.partialInputChannel,
                  channel.readyState == .open,
                  channel.bufferedAmount <= GeronimoInputChannel.gamepadInputBacklogLimitBytes else { return }
        }
        let encoded = encoderLock.withLock { encoder.encodeGamepadState(controllerId: controllerId,
                                                                        buttons: buttons,
                                                                        leftTrigger: leftTrigger,
                                                                        rightTrigger: rightTrigger,
                                                                        leftStickX: leftStickX,
                                                                        leftStickY: leftStickY,
                                                                        rightStickX: rightStickX,
                                                                        rightStickY: rightStickY,
                                                                        timestampUs: timestampUs,
                                                                        bitmap: bitmap,
                                                                        partiallyReliable: usePartial) }
        sendInput(data: encoded, partiallyReliable: usePartial, sessionImpl: sessionImpl)
    }

    @objc(handleDataChannelStateWithLabel:open:)
    func handleDataChannelState(label: String, open: Bool) {
        let shouldStopHeartbeat = stateLock.withLock { () -> Bool in
            if label == GeronimoInputChannel.reliableLabel {
                reliableOpen = open
            } else if label == GeronimoInputChannel.partiallyReliableLabel {
                partialOpen = open
            }
            inputReady = handshakeComplete && reliableOpen && (!inputConfiguration.partialReliableEnabled || partialOpen)
            if !open {
                inputReady = false
                return true
            }
            return false
        }
        if shouldStopHeartbeat {
            stopHeartbeat()
        }
    }

    @objc(handleDataChannelMessageWithLabel:data:sessionImpl:)
    func handleDataChannelMessage(label: String, data: Data, sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard label == GeronimoInputChannel.reliableLabel, data.count >= 2 else { return }

        if isInputReady {
            handleReadyMessage(data)
            return
        }

        let firstWord = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let version: UInt16
        if firstWord == GeronimoInputHandshake.littleEndianVersionMarker {
            version = data.count >= 4 ? UInt16(data[2]) | (UInt16(data[3]) << 8) : 2
            WebRTCMediaTelemetry.capture("webrtc.native.input.handshake", level: .debug, message: "Input handshake detected.", attributes: ["version": String(version), "shape": "firstWord526"])
        } else if data[0] == GeronimoInputHandshake.leadingVersionByte {
            version = firstWord
            WebRTCMediaTelemetry.capture("webrtc.native.input.handshake", level: .debug, message: "Input handshake detected.", attributes: ["version": String(version), "shape": "byte0x0e"])
        } else {
            WebRTCMediaTelemetry.capture("webrtc.native.input.before_handshake", level: .debug, message: "Input channel message received before handshake.", attributes: ["bytes": String(data.count), "firstWord": String(firstWord)])
            return
        }

        encoderLock.withLock { encoder.setProtocolVersion(version) }
        stateLock.withLock {
            handshakeComplete = true
            inputReady = handshakeComplete && reliableOpen && (!inputConfiguration.partialReliableEnabled || partialOpen)
        }
        sendInput(data: data, partiallyReliable: false, sessionImpl: sessionImpl)
        startHeartbeat(sessionImpl: sessionImpl)
        WebRTCMediaTelemetry.capture("webrtc.native.input.ready", level: .debug, message: "Input handshake complete.", attributes: ["version": String(version), "inputReady": String(isInputReady)])
    }

    @objc(stop)
    func stop() {
        stopHeartbeat()
        stateLock.withLock {
            inputReady = false
            reliableOpen = false
            partialOpen = false
            handshakeComplete = false
            inputConfiguration = .fallback
        }
        sessionImpl = nil
    }

    private func shouldSendHIDPartiallyReliable() -> Bool {
        stateLock.withLock { inputConfiguration.partialReliableEnabled && inputConfiguration.partiallyReliableHIDMask != 0 }
    }

    private func shouldSendGamepadPartiallyReliable(controllerId: UInt16) -> Bool {
        let index = min(Int(controllerId & 0x03), 31)
        return stateLock.withLock { inputConfiguration.partialReliableEnabled && (inputConfiguration.partiallyReliableGamepadMask & UInt32(1 << index)) != 0 }
    }

    private func handleReadyMessage(_ data: Data) {
        let payload = unwrappedPayload(from: data)
        var clipboardText = ""
        if payload.count >= 8, payload.readUInt32LE(at: 0) == GeronimoInputEventType.utf8Text.rawValue {
            let textLength = Int(payload.readUInt32LE(at: 4))
            if textLength > 0, textLength <= payload.count - 8 {
                clipboardText = String(data: payload.subdata(in: 8..<(8 + textLength)), encoding: .utf8) ?? ""
            }
        }
        if clipboardText.isEmpty, let first = payload.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            clipboardText = clipboardTextFromJSON(payload)
        }
        if !clipboardText.isEmpty {
            owner?.handleClipboardText(clipboardText)
            WebRTCMediaTelemetry.capture("webrtc.native.input.clipboard", level: .debug, message: "Remote clipboard text received.", attributes: ["bytes": String(data.count)])
        }
    }

    private func unwrappedPayload(from data: Data) -> Data {
        if data.count > 10, data[0] == GeronimoInputEnvelope.headerByte, data[9] == GeronimoInputEnvelope.singleReliablePayloadTag {
            return data.subdata(in: 10..<data.count)
        }
        if data.count > 12, data[0] == GeronimoInputEnvelope.headerByte, data[9] == GeronimoInputEnvelope.lengthPrefixedPayloadTag {
            let wrappedLength = Int(UInt16(data[10]) << 8 | UInt16(data[11]))
            if wrappedLength > 0, wrappedLength <= data.count - 12 {
                return data.subdata(in: 12..<(12 + wrappedLength))
            }
        }
        return data
    }

    private func clipboardTextFromJSON(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        for key in ["clipboard", "text", "content", "payload"] {
            if let value = json[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private func startHeartbeat(sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard heartbeat == nil else { return }
        self.sessionImpl = sessionImpl
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.isInputReady else { return }
            let heartbeat = self.encoderLock.withLock { self.encoder.encodeHeartbeat() }
            self.sendInput(data: heartbeat, partiallyReliable: false, sessionImpl: self.sessionImpl)
        }
        heartbeat = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
