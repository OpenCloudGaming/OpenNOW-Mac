import Foundation

import Foundation

public struct NVSTSessionOffer: Equatable, Sendable {
    public var sdp: String
    public var nvstSdp: String
    public var nvstServerOverrides: String

    public init(sdp: String, nvstSdp: String = "", nvstServerOverrides: String = "") {
        self.sdp = sdp
        self.nvstSdp = nvstSdp
        self.nvstServerOverrides = nvstServerOverrides
    }
}

public struct NVSTIceCandidate: Equatable, Sendable {
    public var candidate: String
    public var sdpMid: String
    public var sdpMLineIndex: Int
    public var usernameFragment: String

    public init(candidate: String, sdpMid: String = "", sdpMLineIndex: Int = 0, usernameFragment: String = "") {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }

    public var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "candidate": candidate,
            "sdpMLineIndex": sdpMLineIndex,
        ]
        payload["sdpMid"] = sdpMid.isEmpty ? NSNull() : sdpMid
        if !usernameFragment.isEmpty {
            payload["usernameFragment"] = usernameFragment
        }
        return payload
    }
}

public struct NVSTPeerInfo: Equatable, Sendable {
    public var browser: String
    public var browserVersion: String
    public var connected: Bool
    public var id: Int
    public var name: String
    public var peerRole: Int
    public var resolution: String
    public var version: Int

    public init(browser: String = "Chrome",
                browserVersion: String = "131",
                connected: Bool = true,
                id: Int,
                name: String,
                peerRole: Int = 0,
                resolution: String,
                version: Int = 2) {
        self.browser = browser
        self.browserVersion = browserVersion
        self.connected = connected
        self.id = id
        self.name = name
        self.peerRole = peerRole
        self.resolution = resolution
        self.version = version
    }

    public var dictionary: [String: Any] {
        [
            "browser": browser,
            "browserVersion": browserVersion,
            "connected": connected,
            "id": id,
            "name": name,
            "peerRole": peerRole,
            "resolution": resolution,
            "version": version,
        ]
    }
}

public struct NVSTSignalingParseResult: Equatable, Sendable {
    public var assignedPeerID: Int?
    public var ackIDToSend: Int?
    public var acknowledgedID: Int?
    public var shouldRespondToHeartbeat: Bool
    public var remotePeerID: Int?
    public var offer: NVSTSessionOffer?
    public var iceCandidate: NVSTIceCandidate?
    public var error: String

    public init(assignedPeerID: Int? = nil,
                ackIDToSend: Int? = nil,
                acknowledgedID: Int? = nil,
                shouldRespondToHeartbeat: Bool = false,
                remotePeerID: Int? = nil,
                offer: NVSTSessionOffer? = nil,
                iceCandidate: NVSTIceCandidate? = nil,
                error: String = "") {
        self.assignedPeerID = assignedPeerID
        self.ackIDToSend = ackIDToSend
        self.acknowledgedID = acknowledgedID
        self.shouldRespondToHeartbeat = shouldRespondToHeartbeat
        self.remotePeerID = remotePeerID
        self.offer = offer
        self.iceCandidate = iceCandidate
        self.error = error
    }
}

public enum NVSTSignalingMessageParser {
    public static func parse(text: String, peerName: String, currentPeerID: Int) -> NVSTSignalingParseResult? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var result = NVSTSignalingParseResult()
        if let peerInfo = json["peer_info"] as? [String: Any],
           let pid = intValue(peerInfo["id"]),
           stringValue(peerInfo["name"]) == peerName {
            result.assignedPeerID = pid
        }

        if let ackID = intValue(json["ackid"]) {
            let peerInfo = json["peer_info"] as? [String: Any]
            let ourPID = intValue(peerInfo?["id"])
            if ourPID == nil || ourPID != currentPeerID {
                result.ackIDToSend = ackID
            }
        }
        if let ack = intValue(json["ack"]) {
            result.acknowledgedID = ack
            return result
        }
        if json["hb"] != nil {
            result.shouldRespondToHeartbeat = true
            return result
        }
        if let error = stringValue(json["error"]), !error.isEmpty {
            result.error = error
            return result
        }

        guard let peerMessage = json["peer_msg"] as? [String: Any],
              let messageText = stringValue(peerMessage["msg"]) else { return result }
        result.remotePeerID = intValue(peerMessage["from"])

        guard let messageData = messageText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
            if messageText == "BYE" {
                result.error = "peerRemoved"
            }
            return result
        }

        if stringValue(payload["type"]) == "offer", let sdp = stringValue(payload["sdp"]) {
            result.offer = NVSTSessionOffer(
                sdp: sdp,
                nvstSdp: stringValue(payload["nvstSdp"]) ?? "",
                nvstServerOverrides: stringValue(payload["nvstServerOverrides"]) ?? ""
            )
            return result
        }

        if let candidate = stringValue(payload["candidate"]), !candidate.isEmpty {
            result.iceCandidate = NVSTIceCandidate(
                candidate: candidate,
                sdpMid: stringValue(payload["sdpMid"]) ?? "",
                sdpMLineIndex: intValue(payload["sdpMLineIndex"]) ?? 0,
                usernameFragment: stringValue(payload["usernameFragment"]) ?? stringValue(payload["ufrag"]) ?? ""
            )
        }
        return result
    }

    public static func peerInfoEnvelope(peerInfo: NVSTPeerInfo, ackID: Int) -> [String: Any] {
        [
            "ackid": ackID,
            "peer_info": peerInfo.dictionary,
        ]
    }

    public static func peerMessageEnvelope(payload: [String: Any], from: Int, to: Int, ackID: Int) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: payloadData, encoding: .utf8) else { return nil }
        return [
            "peer_msg": [
                "from": from,
                "to": to,
                "msg": message,
            ],
            "ackid": ackID,
        ]
    }

    public static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSString { return value as String }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
    return false
}
