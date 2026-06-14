import Foundation
@preconcurrency import WebRTC

@objc(OPNLibWebRTCInput)
final class OPNLibWebRTCInput: NSObject, @unchecked Sendable {
    private enum Constants {
        static let utf8Text: UInt32 = 23
        static let partialReliableInputLifetimeMs: Int32 = 5
        static let partialReliableInputBacklogLimitBytes: UInt64 = 16 * 1024
        static let lowLatencyInputBacklogLimitBytes: UInt64 = 4 * 1024
    }

    private weak var owner: OPNLibWebRTCStreamSession?
    private let encoder = OPNInputProtocolEncoder()
    private var inputReady = false
    private var reliableOpen = false
    private var partialOpen = false
    private var heartbeat: DispatchSourceTimer?
    private weak var sessionImpl: OPNLibWebRTCSessionImpl?

    @objc(initWithOwner:)
    init(owner: OPNLibWebRTCStreamSession?) {
        self.owner = owner
        super.init()
    }

    @objc(sendInputData:partiallyReliable:lowLatencyMode:sessionImpl:)
    func sendInput(data: Data, partiallyReliable: Bool, lowLatencyMode: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard !data.isEmpty else { return }
        let channel = partiallyReliable ? sessionImpl?.partialInputChannel : sessionImpl?.reliableInputChannel
        guard let channel, channel.readyState == .open else { return }
        if partiallyReliable {
            let backlogLimit = lowLatencyMode ? Constants.lowLatencyInputBacklogLimitBytes : Constants.partialReliableInputBacklogLimitBytes
            guard channel.bufferedAmount <= backlogLimit else { return }
        }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
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
        sessionImpl.reliableInputChannel = peerConnection.dataChannel(forLabel: "input_channel_v1", configuration: reliableConfig)
        sessionImpl.reliableInputChannel?.delegate = sessionImpl

        let partialConfig = RTCDataChannelConfiguration()
        partialConfig.isOrdered = false
        partialConfig.maxRetransmits = -1
        partialConfig.maxPacketLifeTime = Constants.partialReliableInputLifetimeMs
        sessionImpl.partialInputChannel = peerConnection.dataChannel(forLabel: "input_channel_partially_reliable", configuration: partialConfig)
        sessionImpl.partialInputChannel?.delegate = sessionImpl
    }

    @objc var isInputReady: Bool { inputReady }

    @objc(sendKeyWithKeycode:scancode:modifiers:down:sessionImpl:)
    func sendKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, down: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeKey(keycode: keycode, scancode: scancode, modifiers: modifiers, timestampUs: OPNInputProtocolEncoder.timestampUs(), down: down)
        sendInput(data: encoded, partiallyReliable: false, lowLatencyMode: false, sessionImpl: sessionImpl)
    }

    @objc(sendMouseMoveWithDx:dy:lowLatencyMode:sessionImpl:)
    func sendMouseMove(dx: Int16, dy: Int16, lowLatencyMode: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeMouseMove(dx: dx, dy: dy, timestampUs: OPNInputProtocolEncoder.timestampUs())
        sendInput(data: encoded, partiallyReliable: true, lowLatencyMode: lowLatencyMode, sessionImpl: sessionImpl)
    }

    @objc(sendMouseButtonWithButton:down:sessionImpl:)
    func sendMouseButton(button: UInt8, down: Bool, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeMouseButton(button: button, timestampUs: OPNInputProtocolEncoder.timestampUs(), down: down)
        sendInput(data: encoded, partiallyReliable: false, lowLatencyMode: false, sessionImpl: sessionImpl)
    }

    @objc(sendMouseWheelWithDelta:sessionImpl:)
    func sendMouseWheel(delta: Int16, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeMouseWheel(delta: delta, timestampUs: OPNInputProtocolEncoder.timestampUs())
        sendInput(data: encoded, partiallyReliable: false, lowLatencyMode: false, sessionImpl: sessionImpl)
    }

    @objc(sendUtf8Text:sessionImpl:)
    func sendUtf8Text(_ text: String, sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeUtf8Text(text)
        sendInput(data: encoded, partiallyReliable: false, lowLatencyMode: false, sessionImpl: sessionImpl)
    }

    @objc(sendGamepadStateWithControllerId:buttons:leftTrigger:rightTrigger:leftStickX:leftStickY:rightStickX:rightStickY:timestampUs:bitmap:lowLatencyMode:sessionImpl:)
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
                          lowLatencyMode: Bool,
                          sessionImpl: OPNLibWebRTCSessionImpl?) {
        let encoded = encoder.encodeGamepadState(controllerId: controllerId,
                                                 buttons: buttons,
                                                 leftTrigger: leftTrigger,
                                                 rightTrigger: rightTrigger,
                                                 leftStickX: leftStickX,
                                                 leftStickY: leftStickY,
                                                 rightStickX: rightStickX,
                                                 rightStickY: rightStickY,
                                                 timestampUs: timestampUs,
                                                 bitmap: bitmap,
                                                 partiallyReliable: true)
        sendInput(data: encoded, partiallyReliable: true, lowLatencyMode: lowLatencyMode, sessionImpl: sessionImpl)
    }

    @objc(handleDataChannelStateWithLabel:open:)
    func handleDataChannelState(label: String, open: Bool) {
        if label == "input_channel_v1" {
            reliableOpen = open
        } else if label == "input_channel_partially_reliable" {
            partialOpen = open
        }
        if !open {
            inputReady = false
            stopHeartbeat()
        }
    }

    @objc(handleDataChannelMessageWithLabel:data:sessionImpl:)
    func handleDataChannelMessage(label: String, data: Data, sessionImpl: OPNLibWebRTCSessionImpl?) {
        guard label == "input_channel_v1", data.count >= 2 else { return }

        if inputReady {
            handleReadyMessage(data)
            return
        }

        let firstWord = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let version: UInt16
        if firstWord == 526 {
            version = data.count >= 4 ? UInt16(data[2]) | (UInt16(data[3]) << 8) : 2
            NSLog("[LibWebRTC] input handshake detected firstWord=526 version=%u", version)
        } else if data[0] == 0x0e {
            version = firstWord
            NSLog("[LibWebRTC] input handshake detected byte[0]=0x0e version=%u", version)
        } else {
            NSLog("[LibWebRTC] input channel message before handshake len=%zu firstWord=0x%04x", data.count, firstWord)
            return
        }

        encoder.setProtocolVersion(version)
        inputReady = reliableOpen && partialOpen
        sendInput(data: data, partiallyReliable: false, lowLatencyMode: false, sessionImpl: sessionImpl)
        startHeartbeat(sessionImpl: sessionImpl)
        NSLog("[LibWebRTC] input handshake complete protocol=v%u inputReady=%d", version, inputReady ? 1 : 0)
    }

    @objc(stop)
    func stop() {
        stopHeartbeat()
        inputReady = false
        reliableOpen = false
        partialOpen = false
        sessionImpl = nil
    }

    private func handleReadyMessage(_ data: Data) {
        let payload = unwrappedPayload(from: data)
        var clipboardText = ""
        if payload.count >= 8, payload.readUInt32LE(at: 0) == Constants.utf8Text {
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
            NSLog("[LibWebRTC] remote clipboard text received bytes=%zu", data.count)
        }
    }

    private func unwrappedPayload(from data: Data) -> Data {
        if data.count > 10, data[0] == 0x23, data[9] == 0x22 {
            return data.subdata(in: 10..<data.count)
        }
        if data.count > 12, data[0] == 0x23, data[9] == 0x21 {
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
            guard let self, self.inputReady else { return }
            self.sendInput(data: self.encoder.encodeHeartbeat(), partiallyReliable: false, lowLatencyMode: false, sessionImpl: self.sessionImpl)
        }
        heartbeat = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 3 < count else { return 0 }
        return UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) | (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
