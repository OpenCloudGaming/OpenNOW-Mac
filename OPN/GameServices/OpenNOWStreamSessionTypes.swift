//
//  OpenNOWStreamSessionTypes.swift
//  OpenNOW
//
//  The values the stream-session coordinator passes between its stages: a prepared launch, an
//  allocated seat session, a required ad, and where a free-tier session's clock starts.
//  Split out of OpenNOWStreamSessionCoordinator.swift.
//

import Foundation

struct PreparedStreamLaunch {
    let settings: [String: Any]
    let streamingBaseUrl: String
}

enum StreamSessionLimitStartStore {
    static let lock = NSLock()
    private static let key = "OpenNOW.Stream.SessionLimitStartedAtEpochSeconds"
    private static let maxStoredAgeSeconds: TimeInterval = 24 * 60 * 60

    static func startedAtEpochSeconds(for sessionId: String, now: Date = Date()) -> TimeInterval {
        lock.withLock {
            let nowEpoch = now.timeIntervalSince1970
            var starts = storedStarts(nowEpoch: nowEpoch)
            if let existing = starts[sessionId], existing > 0 {
                persist(starts)
                return existing
            }
            starts[sessionId] = nowEpoch
            persist(starts)
            return nowEpoch
        }
    }

    static func clear(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        lock.withLock {
            var starts = storedStarts(nowEpoch: Date().timeIntervalSince1970)
            guard starts.removeValue(forKey: sessionId) != nil else { return }
            persist(starts)
        }
    }

    private static func storedStarts(nowEpoch: TimeInterval) -> [String: TimeInterval] {
        let raw = OPNAppPreferenceStorage.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.filter { nowEpoch - $0.value <= maxStoredAgeSeconds }
    }

    private static func persist(_ starts: [String: TimeInterval]) {
        OPNAppPreferenceStorage.standard.set(starts, forKey: key)
        OPNAppPreferenceStorage.standard.synchronize()
    }
}

struct AllocatedStreamSession: Sendable {
    let sessionId: String
    let title: String
    let serverIp: String
    let signalingServer: String
    let signalingUrl: String
    let signalingQueryParameters: String
    let signalingHeaders: [String]
    let streamingBaseUrl: String
    let mediaConnectionHost: String
    let mediaConnectionPort: Int
    let deviceId: String
    let isResume: Bool
    let status: Int
    let queuePosition: Int
    let seatSetupStep: Int
    let progressState: Int
    let adsRequired: Bool
    let requiredAdGateObserved: Bool
    let remainingSessionLimitSeconds: Int
    let pendingAd: AllocatedSessionAd?
    let rawJSON: String
    let rawSessionJSON: String

    var isReady: Bool {
        (status == 2 || status == 3) && !sessionId.isEmpty && !serverIp.isEmpty
    }

    var isPendingProgress: Bool {
        if [4, 5, 6].contains(status) { return true }
        guard status == 1 else { return false }
        return adsRequired || queuePosition > 0 || seatSetupStep > 0 || [1, 2, 3, 4].contains(progressState)
    }

    init(_ info: [String: Any]) {
        sessionId = Self.string(info["sessionId"])
        title = Self.string(info["title"]).isEmpty ? "GeForce NOW" : Self.string(info["title"])
        serverIp = Self.string(info["serverIp"])
        signalingServer = Self.string(info["signalingServer"])
        signalingUrl = Self.string(info["signalingUrl"])
        signalingQueryParameters = Self.string(info["signalingQueryParameters"])
        signalingHeaders = Self.stringArray(info["signalingHeaders"])
        streamingBaseUrl = Self.string(info["streamingBaseUrl"])
        let mediaConnectionInfo = info["mediaConnectionInfo"] as? [String: Any]
        mediaConnectionHost = Self.string(mediaConnectionInfo?["ip"])
        mediaConnectionPort = Self.int(mediaConnectionInfo?["port"])
        deviceId = Self.string(info["deviceId"])
        isResume = Self.bool(info["isResume"])
        status = Self.int(info["status"])
        queuePosition = Self.int(info["queuePosition"])
        seatSetupStep = Self.int(info["seatSetupStep"])
        progressState = Self.int(info["progressState"])
        let adState = info["adState"] as? [String: Any]
        adsRequired = Self.bool(adState?["isAdsRequired"])
        requiredAdGateObserved = Self.bool(info["requiredAdGateObserved"])
        remainingSessionLimitSeconds = Self.int(info["remainingSessionLimitSeconds"])
        pendingAd = Self.pendingAd(from: adState)
        rawSessionJSON = Self.string(info["rawSessionJSON"], fallback: "{}")
        rawJSON = Self.jsonString(info)
    }

    func markingRequiredAdGateObserved() -> AllocatedStreamSession {
        guard !requiredAdGateObserved else { return self }
        var dictionary = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) as? [String: Any] ?? [:]
        dictionary["requiredAdGateObserved"] = true
        return AllocatedStreamSession(dictionary)
    }

    var reportableSession: [String: Any] {
        [
            "sessionId": sessionId,
            "serverIp": serverIp,
            "streamingBaseUrl": streamingBaseUrl,
            "deviceId": deviceId,
        ]
    }

    static func pendingAd(from adState: [String: Any]?) -> AllocatedSessionAd? {
        guard bool(adState?["isAdsRequired"]), let ads = adState?["sessionAds"] as? [[String: Any]] else { return nil }
        return ads.compactMap(AllocatedSessionAd.init(dictionary:)).first
    }

    static func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return false
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [NSString] { return values.map { $0 as String } }
        return []
    }
}

struct AllocatedSessionAd: Equatable, Sendable {
    let adId: String
    let mediaUrl: String
    let durationMs: Int
    let title: String

    var presentation: StreamSessionAdPresentation {
        StreamSessionAdPresentation(adId: adId, title: title, mediaUrl: mediaUrl, durationMs: durationMs)
    }

    init?(dictionary: [String: Any]) {
        let adId = Self.string(dictionary["adId"])
        guard !adId.isEmpty else { return nil }
        self.adId = adId
        title = Self.string(dictionary["title"])
        durationMs = Self.int(dictionary["durationMs"])
        mediaUrl = Self.bestMediaUrl(dictionary)
    }

    private static func bestMediaUrl(_ dictionary: [String: Any]) -> String {
        let mediaFiles = (dictionary["adMediaFiles"] as? [[String: Any]] ?? [])
            .compactMap { file -> (url: String, rank: Int)? in
                let url = string(file["mediaFileUrl"])
                guard !url.isEmpty else { return nil }
                return (url, mediaProfileRank(string(file["encodingProfile"])))
            }
            .sorted { $0.rank < $1.rank }
        if let url = mediaFiles.first?.url { return url }
        for key in ["mediaUrl", "videoUrl", "url", "adUrl"] {
            let url = string(dictionary[key])
            if !url.isEmpty { return url }
        }
        return ""
    }

    private static func mediaProfileRank(_ profile: String) -> Int {
        switch profile {
        case "mp4deinterlaced720p": return 0
        case "hlsadaptive": return 1
        case "webm": return 2
        default: return 100
        }
    }

    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}

public enum OpenNOWStreamSessionError: LocalizedError, Sendable {
    case activeSessionConflict(StreamSessionConflict)
    case sessionAllocationFailed(String)
    case sessionStopFailed(String)
    case signalingFailed(String)
    case signalingUnavailable

    public var errorDescription: String? {
        switch self {
        case .activeSessionConflict(let conflict):
            conflict.isResumable
                ? "A GeForce NOW session is already active. Resume it or end it before launching another game."
                : "A GeForce NOW session is already active. End it before launching another game."
        case .sessionAllocationFailed(let message), .sessionStopFailed(let message), .signalingFailed(let message):
            message
        case .signalingUnavailable:
            "Signaling is not connected."
        }
    }
}
