import Darwin
import Darwin
import Foundation
import OpenNOWTelemetry

public final class NVSTWebSocketSignalingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public var onOffer: ((NVSTSessionOffer) -> Void)?
    public var onIceCandidate: ((NVSTIceCandidate) -> Void)?
    public var onClosed: ((Bool, String) -> Void)?

    private let configuration: NVSTSignalingConfiguration
    private var peerId = 0
    private var remotePeerId = 1
    private var ackCounter = 0
    private var peerName = ""
    private var peerResolution = "1920x1080"
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var heartbeatSource: DispatchSourceTimer?
    private var connectionGeneration = 0
    private var didOpen = false
    private var connectCompletion: ((Bool, String) -> Void)?
    private var activeURL: URL?

    public init(configuration: NVSTSignalingConfiguration) {
        self.configuration = configuration
        super.init()
    }

    public convenience init(signalingServer: String, sessionId: String, signalingUrl: String) {
        self.init(configuration: NVSTSignalingConfiguration(signalingServer: signalingServer, sessionID: sessionId, signalingURL: signalingUrl))
    }

    public var isConnected: Bool {
        webSocketTask?.state == .running
    }

    public func setPeerResolution(_ resolution: String) {
        if !resolution.isEmpty {
            peerResolution = resolution
        }
    }

    public func connect(_ completion: @escaping (Bool, String) -> Void) {
        if webSocketTask != nil {
            completion(true, "")
            return
        }

        peerName = "peer-\(UInt32.random(in: 0..<1_000_000_000))"
        didOpen = false
        guard let url = configuration.signInURL(peerName: peerName) else {
            completion(false, "Failed to build signaling URL")
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        activeURL = url
        connectCompletion = completion

        let urlConfiguration = URLSessionConfiguration.default
        let session = URLSession(configuration: urlConfiguration, delegate: self, delegateQueue: singleThreadedDelegateQueue())
        var request = URLRequest(url: url)
        request.setValue(configuration.webSocketSubprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(configuration.origin, forHTTPHeaderField: "Origin")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")

        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        OPNNetworkLog.webSocketEvent("connect", url: url)
        task.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            if self.webSocketTask != nil && !self.didOpen {
                OPNNetworkLog.webSocketEvent("timeout", url: self.activeURL)
                let timeoutCompletion = self.connectCompletion
                self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
                self.disconnect()
                timeoutCompletion?(false, "Signaling connection timeout")
            }
        }
    }

    public func disconnect() {
        OPNNetworkLog.webSocketEvent("disconnect", url: activeURL)
        connectionGeneration += 1
        clearHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectCompletion = nil
    }

    public func sendAnswerSdp(_ sdp: String, nvstSdp: String) {
        var answer: [String: Any] = [
            "type": "answer",
            "sdp": sdp,
        ]
        if !nvstSdp.isEmpty {
            answer["nvstSdp"] = nvstSdp
        }
        sendPeerMessage(answer)
    }

    public func sendIceCandidate(_ candidate: NVSTIceCandidate) {
        sendPeerMessage(candidate.dictionary)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            self.didOpen = true
            OPNNetworkLog.webSocketEvent("open", url: self.activeURL, detail: "protocol=\(`protocol` ?? "none")")
            self.sendPeerInfo()
            self.setupHeartbeat()
            let completion = self.connectCompletion
            self.connectCompletion = nil
            completion?(true, "")
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.webSocketTask === task else { return }
            if self.didOpen {
                let nsError = error as NSError
                if self.isSocketNotConnectedError(nsError) {
                    OPNNetworkLog.webSocketEvent("complete", url: self.activeURL, detail: "clean=true")
                    self.onClosed?(true, "")
                } else {
                    OPNNetworkLog.webSocketError("complete", url: self.activeURL, error: nsError)
                    self.onClosed?(false, nsError.localizedDescription)
                }
                return
            }
            let message = self.signalingConnectionErrorDescription(error as NSError)
            OPNNetworkLog.webSocketError("connectFailed", url: self.activeURL, error: error)
            let completion = self.connectCompletion
            self.connectCompletion = nil
            completion?(false, message)
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.webSocketTask === webSocketTask else { return }
            OPNNetworkLog.webSocketEvent("close", url: self.activeURL, detail: "code=\(closeCode.rawValue) reasonLength=\(reasonText.count)")
            self.clearHeartbeat()
            self.webSocketTask = nil
            if self.didOpen {
                let clean = closeCode == .normalClosure || closeCode == .goingAway
                self.onClosed?(clean, reasonText)
            }
        }
    }

    private func singleThreadedDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private func setupHeartbeat() {
        clearHeartbeat()
        rearmReceiveHandler()
        let generation = connectionGeneration
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.connectionGeneration != generation {
                timer.cancel()
                return
            }
            self.sendJson("{\"hb\":1}")
        }
        heartbeatSource = timer
        timer.resume()
    }

    private func clearHeartbeat() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
    }

    private func rearmReceiveHandler() {
        guard let task = webSocketTask else { return }
        let generation = connectionGeneration
        task.receive { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.connectionGeneration == generation else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    self.rearmReceiveHandler()
                case .failure(let error):
                    let nsError = error as NSError
                    if self.isSocketNotConnectedError(nsError) {
                        OPNNetworkLog.webSocketEvent("receiveStopped", url: self.activeURL)
                    } else {
                        OPNNetworkLog.webSocketError("receive", url: self.activeURL, error: nsError)
                    }
                }
            }
        }
    }

    private func sendJson(_ json: String) {
        guard let task = webSocketTask else { return }
        task.send(.string(json)) { _ in }
    }

    private func sendPeerInfo() {
        ackCounter += 1
        let info = NVSTPeerInfo(id: peerId, name: peerName, resolution: peerResolution)
        sendJSONObject(NVSTSignalingMessageParser.peerInfoEnvelope(peerInfo: info, ackID: ackCounter))
    }

    private func handleMessage(_ text: String) {
        guard let parsed = NVSTSignalingMessageParser.parse(text: text, peerName: peerName, currentPeerID: peerId) else { return }
        if let assignedPeerID = parsed.assignedPeerID {
            peerId = assignedPeerID
            OPNNetworkLog.webSocketEvent("peerAssigned", url: activeURL, detail: "peerId=\(peerId)")
        }
        if let ackIDToSend = parsed.ackIDToSend {
            sendJson("{\"ack\":\(ackIDToSend)}")
        }
        if parsed.acknowledgedID != nil {
            return
        }
        if parsed.shouldRespondToHeartbeat {
            sendJson("{\"hb\":1}")
            return
        }
        if !parsed.error.isEmpty {
            onClosed?(false, parsed.error)
            return
        }
        if let remotePeerID = parsed.remotePeerID {
            remotePeerId = remotePeerID
        }
        if let offer = parsed.offer {
            OPNNetworkLog.webSocketEvent("offerReceived", url: activeURL, detail: "sdpLength=\(offer.sdp.count) nvstSdpLength=\(offer.nvstSdp.count)")
            onOffer?(offer)
            return
        }
        if let candidate = parsed.iceCandidate {
            OPNNetworkLog.webSocketEvent("iceCandidateReceived", url: activeURL, detail: "mid=\(candidate.sdpMid.isEmpty ? "none" : candidate.sdpMid) mline=\(candidate.sdpMLineIndex) candidateLength=\(candidate.candidate.count)")
            onIceCandidate?(candidate)
        }
    }

    private func sendPeerMessage(_ payload: [String: Any]) {
        ackCounter += 1
        guard let peerMessage = NVSTSignalingMessageParser.peerMessageEnvelope(payload: payload, from: peerId, to: remotePeerId, ackID: ackCounter) else { return }
        sendJSONObject(peerMessage)
    }

    private func sendJSONObject(_ object: [String: Any]) {
        guard let text = NVSTSignalingMessageParser.jsonString(object) else { return }
        sendJson(text)
    }

    private func sanitizedSignalingURLString() -> String {
        guard let activeURL, var components = URLComponents(url: activeURL, resolvingAgainstBaseURL: false) else {
            return activeURL?.host ?? ""
        }
        components.query = nil
        return components.string ?? activeURL.host ?? ""
    }

    private func signalingConnectionErrorDescription(_ error: NSError) -> String {
        let urlString = sanitizedSignalingURLString()
        let handshakeReason = error.userInfo["_NSURLErrorWebSocketHandshakeFailureReasonKey"].map { " handshakeReason=\($0)" } ?? ""
        let failingURLValue = error.userInfo[NSURLErrorFailingURLErrorKey]
        let failingURL = (failingURLValue as? URL)?.absoluteString ?? urlString
        var failingComponents = URLComponents(string: failingURL)
        failingComponents?.query = nil
        let safeFailingURL = failingComponents?.string ?? urlString
        return "Signaling connect failed: domain=\(error.domain) code=\(error.code) url=\(urlString) failingURL=\(safeFailingURL)\(handshakeReason) description=\(error.localizedDescription)"
    }

    private func isSocketNotConnectedError(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == ENOTCONN { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isSocketNotConnectedError(underlying)
        }
        return false
    }
}
