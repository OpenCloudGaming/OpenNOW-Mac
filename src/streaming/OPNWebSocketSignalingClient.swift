@preconcurrency import Foundation

import Foundation

@objcMembers
@objc(OPNWebSocketSignalingClient)
final class OPNWebSocketSignalingClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOffer: ((String) -> Void)?
    var onIceCandidate: ((NSDictionary) -> Void)?
    var onClosed: ((Bool, String) -> Void)?

    private let signalingServer: String
    private let sessionId: String
    private let signalingUrl: String
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
    private var intentionallyDisconnected = false
    private var reconnecting = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var pendingAckMessages: [(ackId: Int, json: String)] = []
    private var queuedMessages: [String] = []

    init(signalingServer: String, sessionId: String, signalingUrl: String) {
        self.signalingServer = signalingServer
        self.sessionId = sessionId
        self.signalingUrl = signalingUrl
        super.init()
    }

    var isConnected: Bool {
        webSocketTask?.state == .running
    }

    func setPeerResolution(_ resolution: String) {
        if !resolution.isEmpty {
            peerResolution = resolution
        }
    }

    func connect(_ completion: @escaping (Bool, String) -> Void) {
        if webSocketTask != nil {
            completion(true, "")
            return
        }

        peerName = "peer-\(UInt32.random(in: 0..<1_000_000_000))"
        didOpen = false
        intentionallyDisconnected = false
        reconnectAttempts = 0
        pendingAckMessages.removeAll()
        queuedMessages.removeAll()
        guard let url = buildSignInURL(reconnect: false) else {
            completion(false, "Failed to build signaling URL")
            return
        }

        connectionGeneration += 1
        let generation = connectionGeneration
        activeURL = url
        connectCompletion = completion

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: singleThreadedDelegateQueue())
        var request = URLRequest(url: url)
        request.setValue("x-nv-sessionid.\(sessionId)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        task.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            if self.webSocketTask != nil && !self.didOpen {
                let timeoutCompletion = self.connectCompletion
                self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
                self.disconnect()
                timeoutCompletion?(false, "Signaling connection timeout")
            }
        }
    }

    func disconnect() {
        connectionGeneration += 1
        intentionallyDisconnected = true
        reconnecting = false
        clearHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectCompletion = nil
    }

    func sendAnswerSdp(_ sdp: String, nvstSdp: String) {
        var answer: [String: Any] = [
            "type": "answer",
            "sdp": sdp,
        ]
        if !nvstSdp.isEmpty {
            answer["nvstSdp"] = nvstSdp
        }
        sendPeerMessage(answer)
    }

    func sendIceCandidate(_ candidate: NSDictionary) {
        var payload: [String: Any] = [
            "candidate": candidate["candidate"] as? String ?? "",
            "sdpMLineIndex": candidate["sdpMLineIndex"] as? Int ?? 0,
        ]
        if let sdpMid = candidate["sdpMid"] as? String, !sdpMid.isEmpty {
            payload["sdpMid"] = sdpMid
        } else {
            payload["sdpMid"] = NSNull()
        }
        if let usernameFragment = candidate["usernameFragment"] as? String, !usernameFragment.isEmpty {
            payload["usernameFragment"] = usernameFragment
        }
        sendPeerMessage(payload)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasOpen = self.didOpen
            self.didOpen = true
            self.reconnecting = false
            self.reconnectAttempts = 0
            if wasOpen { self.flushPendingMessages() }
            else { self.sendPeerInfo(); self.flushQueuedMessages() }
            self.setupHeartbeat()
            let completion = self.connectCompletion
            self.connectCompletion = nil
            completion?(true, "")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.didOpen {
                let nsError = error as NSError
                if self.isSocketNotConnectedError(nsError) {
                    NSLog("[Signaling] Post-connection socket closed: %@", nsError.localizedDescription)
                    self.scheduleReconnect(reason: nsError.localizedDescription)
                } else {
                    NSLog("[Signaling] Post-connection error: %@", nsError)
                    self.scheduleReconnect(reason: nsError.localizedDescription)
                }
                return
            }
            let message = self.signalingConnectionErrorDescription(error as NSError)
            NSLog("[Signaling] %@", message)
            let completion = self.connectCompletion
            self.connectCompletion = nil
            completion?(false, message)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSLog("[Signaling] WebSocket closed: code=%ld, reason=%@", closeCode.rawValue, reasonText)
            self.clearHeartbeat()
            self.webSocketTask = nil
            if self.reconnecting { return }
            if self.didOpen, !self.intentionallyDisconnected {
                let clean = closeCode == .normalClosure || closeCode == .goingAway
                if clean {
                    self.onClosed?(true, reasonText)
                } else {
                    self.scheduleReconnect(reason: reasonText.isEmpty ? "Signaling socket closed" : reasonText)
                }
            }
        }
    }

    private func singleThreadedDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    private func buildSignInURL(reconnect: Bool) -> URL? {
        let baseURLString: String
        if !signalingUrl.isEmpty {
            baseURLString = signalingUrl
        } else if signalingServer.contains(":") {
            baseURLString = "wss://\(signalingServer)/nvst/"
        } else {
            baseURLString = "wss://\(signalingServer):443/nvst/"
        }

        var components = URLComponents(string: baseURLString) ?? URLComponents()
        components.scheme = "wss"
        if components.host == nil {
            components.host = signalingServer
        }
        var path = components.path.isEmpty ? "/nvst/" : components.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        components.path = path + "sign_in"
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "peer_id", value: peerName))
        items.append(URLQueryItem(name: "version", value: "2"))
        items.append(URLQueryItem(name: "peer_role", value: "1"))
        items.append(URLQueryItem(name: "pairing_id", value: sessionId))
        if reconnect { items.append(URLQueryItem(name: "reconnect", value: "1")) }
        components.queryItems = items
        return components.url
    }

    private func scheduleReconnect(reason: String) {
        guard !intentionallyDisconnected else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            onClosed?(false, reason.isEmpty ? "Signaling reconnect failed" : reason)
            return
        }
        reconnectAttempts += 1
        reconnecting = true
        clearHeartbeat()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        let attempt = reconnectAttempts
        let generation = connectionGeneration
        NSLog("[Signaling] Reconnecting socket attempt=%d reason=%@", attempt, reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(3.0, Double(attempt))) { [weak self] in
            guard let self, self.connectionGeneration == generation, !self.intentionallyDisconnected else { return }
            self.reconnectSocket()
        }
    }

    private func reconnectSocket() {
        guard let url = buildSignInURL(reconnect: true) else {
            onClosed?(false, "Failed to build reconnect signaling URL")
            return
        }
        activeURL = url
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: singleThreadedDelegateQueue())
        var request = URLRequest(url: url)
        request.setValue("x-nv-sessionid.\(sessionId)", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        task.resume()
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
                        NSLog("[Signaling] Receive stopped after socket closed: %@", nsError.localizedDescription)
                    } else {
                        NSLog("[Signaling] Receive error: %@", nsError)
                    }
                }
            }
        }
    }

    private func sendJson(_ json: String) {
        guard let task = webSocketTask, task.state == .running else {
            queuedMessages.append(json)
            if didOpen { scheduleReconnect(reason: "Signaling send queued while socket closed") }
            return
        }
        task.send(.string(json)) { [weak self] error in
            guard let self, error != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.queuedMessages.append(json)
                self?.scheduleReconnect(reason: error?.localizedDescription ?? "Signaling send failed")
            }
        }
    }

    private func sendReliableJson(_ json: String, ackId: Int) {
        pendingAckMessages.append((ackId: ackId, json: json))
        sendJson(json)
    }

    private func flushPendingMessages() {
        let pending = pendingAckMessages.map(\.json)
        let queued = queuedMessages
        queuedMessages.removeAll()
        for json in pending + queued { sendJson(json) }
    }

    private func flushQueuedMessages() {
        let queued = queuedMessages
        queuedMessages.removeAll()
        for json in queued { sendJson(json) }
    }

    private func sendPeerInfo() {
        ackCounter += 1
        let info: [String: Any] = [
            "ackid": ackCounter,
            "peer_info": [
                "browser": "Chrome",
                "browserVersion": "131",
                "connected": true,
                "id": peerId,
                "name": peerName,
                "peerRole": 0,
                "resolution": peerResolution,
                "version": 2,
            ],
        ]
        sendJSONObject(info, ackId: ackCounter)
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let peerInfo = json["peer_info"] as? [String: Any],
           let pid = peerInfo["id"] as? NSNumber,
           let name = peerInfo["name"] as? String,
           name == peerName {
            peerId = pid.intValue
            NSLog("[Signaling] Local peer id assigned: %d", peerId)
        }

        if let ack = json["ackid"] as? NSNumber {
            let peerInfo = json["peer_info"] as? [String: Any]
            let ourPid = peerInfo?["id"] as? NSNumber
            if ourPid == nil || ourPid?.intValue != peerId {
                sendJson("{\"ack\":\(ack.intValue)}")
            }
        }

        if let ack = json["ack"] as? NSNumber {
            pendingAckMessages.removeAll { $0.ackId <= ack.intValue }
            return
        }
        if json["hb"] != nil {
            sendJson("{\"hb\":1}")
            return
        }

        guard let peerMessage = json["peer_msg"] as? [String: Any],
              let messageText = peerMessage["msg"] as? String else { return }

        if let from = peerMessage["from"] as? NSNumber {
            remotePeerId = from.intValue
            NSLog("[Signaling] Remote peer id: %d", remotePeerId)
        }

        guard let messageData = messageText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else { return }

        if payload["type"] as? String == "offer" {
            guard let sdp = payload["sdp"] as? String else { return }
            NSLog("[Signaling] Offer received, sdp length=%lu", sdp.count)
            onOffer?(sdp)
            return
        }

        guard let candidate = payload["candidate"] as? String else { return }
        let sdpMid = payload["sdpMid"] as? String ?? ""
        let sdpMLineIndex = (payload["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0
        let usernameFragment = payload["usernameFragment"] as? String ?? payload["ufrag"] as? String ?? ""
        NSLog("[Signaling] Remote ICE candidate received mid=%@ mline=%d ufrag=%@ length=%lu", sdpMid.isEmpty ? "(none)" : sdpMid, sdpMLineIndex, usernameFragment.isEmpty ? "(none)" : usernameFragment, candidate.count)
        onIceCandidate?([
            "candidate": candidate,
            "sdpMid": sdpMid,
            "sdpMLineIndex": sdpMLineIndex,
            "usernameFragment": usernameFragment,
        ] as NSDictionary)
    }

    private func sendPeerMessage(_ payload: [String: Any]) {
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: payloadData, encoding: .utf8) else { return }
        ackCounter += 1
        let peerMessage: [String: Any] = [
            "peer_msg": [
                "from": peerId,
                "to": remotePeerId,
                "msg": message,
            ],
            "ackid": ackCounter,
        ]
        sendJSONObject(peerMessage, ackId: ackCounter)
    }

    private func sendJSONObject(_ object: [String: Any], ackId: Int? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        if let ackId { sendReliableJson(text, ackId: ackId) }
        else { sendJson(text) }
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
