//  Streaming session models: the negotiated media profile, session progress and ads, and the JSON
//  parser that reads them off the wire. Split out of OPNModels.swift.
//

import Foundation

public struct OPNIceServer: Equatable, Sendable {
    public var urls: [String] = []
    public var username = ""
    public var credential = ""
}

public struct OPNMediaConnectionInfo: Equatable, Sendable {
    public var ip = ""
    public var port = 0
}

public struct OPNNegotiatedStreamProfile: Equatable, Sendable {
    public var resolution = ""
    public var fps = 0
    public var codec = ""
    public var colorQuality = ""
    public var bitDepth = -1
    public var chromaFormat = -1
    public var prefilterMode = -1
    public var prefilterSharpness = -1
    public var prefilterDenoise = -1
    public var prefilterModel = -1
}

@objcMembers
public final class OPNParsedNegotiatedStreamProfile: NSObject {
    public let resolution: String
    public let fps: Int
    public let codec: String
    public let colorQuality: String
    public let bitDepth: Int
    public let chromaFormat: Int
    public let prefilterMode: Int
    public let prefilterSharpness: Int
    public let prefilterDenoise: Int
    public let prefilterModel: Int

    public init(profile: OPNNegotiatedStreamProfile) {
        resolution = profile.resolution
        fps = profile.fps
        codec = profile.codec
        colorQuality = profile.colorQuality
        bitDepth = profile.bitDepth
        chromaFormat = profile.chromaFormat
        prefilterMode = profile.prefilterMode
        prefilterSharpness = profile.prefilterSharpness
        prefilterDenoise = profile.prefilterDenoise
        prefilterModel = profile.prefilterModel
    }
}

@objcMembers
public final class OPNParsedSessionProgress: NSObject {
    public let queuePosition: Int
    public let seatSetupStep: Int
    public let progressState: Int
    public let remainingPlaytimeHours: Double
    public let remainingPlaytimeAvailable: Bool
    public let remainingSessionLimitSeconds: Int

    public init(queuePosition: Int, seatSetupStep: Int, progressState: OPNSessionProgressState, remainingPlaytimeHours: Double, remainingPlaytimeAvailable: Bool, remainingSessionLimitSeconds: Int) {
        self.queuePosition = queuePosition
        self.seatSetupStep = seatSetupStep
        self.progressState = progressState.rawValue
        self.remainingPlaytimeHours = remainingPlaytimeHours
        self.remainingPlaytimeAvailable = remainingPlaytimeAvailable
        self.remainingSessionLimitSeconds = remainingSessionLimitSeconds
    }
}

@objcMembers
public final class OPNParsedSessionAdMediaFile: NSObject {
    public let mediaFileUrl: String
    public let encodingProfile: String

    public init(mediaFileUrl: String, encodingProfile: String) {
        self.mediaFileUrl = mediaFileUrl
        self.encodingProfile = encodingProfile
    }
}

@objcMembers
public final class OPNParsedSessionAd: NSObject {
    public let adId: String
    public let adState: Int
    public let adUrl: String
    public let mediaUrl: String
    public let adMediaFiles: [OPNParsedSessionAdMediaFile]
    public let clickThroughUrl: String
    public let adLengthInSeconds: Int
    public let durationMs: Int
    public let title: String
    public let adDescription: String

    public init(ad: OPNSessionAdInfo) {
        adId = ad.adId
        adState = ad.adState
        adUrl = ad.adUrl
        mediaUrl = ad.mediaUrl
        adMediaFiles = ad.adMediaFiles.map { OPNParsedSessionAdMediaFile(mediaFileUrl: $0.mediaFileUrl, encodingProfile: $0.encodingProfile) }
        clickThroughUrl = ad.clickThroughUrl
        adLengthInSeconds = ad.adLengthInSeconds
        durationMs = ad.durationMs
        title = ad.title
        adDescription = ad.description
    }
}

@objcMembers
public final class OPNParsedSessionAdState: NSObject {
    public let isAdsRequired: Bool
    public let sessionAdsRequired: Bool
    public let isQueuePaused: Bool
    public let serverSentEmptyAds: Bool
    public let gracePeriodSeconds: Int
    public let message: String
    public let sessionAds: [OPNParsedSessionAd]

    public init(adState: OPNSessionAdState) {
        isAdsRequired = adState.isAdsRequired
        sessionAdsRequired = adState.sessionAdsRequired
        isQueuePaused = adState.isQueuePaused
        serverSentEmptyAds = adState.serverSentEmptyAds
        gracePeriodSeconds = adState.gracePeriodSeconds
        message = adState.message
        sessionAds = adState.sessionAds.map(OPNParsedSessionAd.init(ad:))
    }
}

@objc(OPNSessionJSONParser)
public final class OPNSessionJSONParser: NSObject {
    @objc(parseNegotiatedStreamProfileFromSession:)
    public static func parseNegotiatedStreamProfile(from session: NSDictionary?) -> OPNParsedNegotiatedStreamProfile {
        let session = session as? [String: Any] ?? [:]
        var profile = OPNNegotiatedStreamProfile()

        if let negotiated = session["negotiatedStreamProfile"] as? [String: Any] {
            if let resolution = nonEmptyString(negotiated["resolution"]) {
                profile.resolution = resolution
            }
            if let codec = nonEmptyString(negotiated["codec"]) {
                profile.codec = codec
            }
            if let fps = intValue(negotiated["fps"]) {
                profile.fps = fps
            }
        }

        if let features = session["finalizedStreamingFeatures"] as? [String: Any] {
            if let bitDepth = intValue(features["bitDepth"]) {
                profile.bitDepth = displayBitDepth(bitDepth)
            }
            if let chromaFormat = intValue(features["chromaFormat"]) {
                profile.chromaFormat = chromaFormat
            }
            if profile.bitDepth >= 0 || profile.chromaFormat >= 0 {
                profile.colorQuality = colorQuality(bitDepth: profile.bitDepth, chromaFormat: profile.chromaFormat)
            }
            if let prefilterMode = intValue(features["prefilterMode"]) {
                profile.prefilterMode = min(max(prefilterMode, 0), 2)
            }
            if let prefilterSharpness = intValue(features["prefilterSharpness"]) {
                profile.prefilterSharpness = min(max(prefilterSharpness, 0), 10)
            }
            if let prefilterDenoise = intValue(features["prefilterNoiseReduction"]) {
                profile.prefilterDenoise = min(max(prefilterDenoise, 0), 10)
            }
            if let prefilterModel = intValue(features["prefilterModel"]) {
                profile.prefilterModel = max(prefilterModel, 0)
            }
        }

        return OPNParsedNegotiatedStreamProfile(profile: profile)
    }

    @objc(parseSessionProgressFromSession:)
    public static func parseSessionProgress(from session: NSDictionary?) -> OPNParsedSessionProgress {
        let session = session as? [String: Any] ?? [:]
        let seatSetupInfo = dictionary(session["seatSetupInfo"])
        let sessionProgress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let controlInfo = dictionary(session["sessionControlInfo"])

        let queuePosition = positiveInt(session["queuePosition"])
            ?? positiveInt(seatSetupInfo?["queuePosition"])
            ?? positiveInt(sessionProgress?["queuePosition"])
            ?? positiveInt(progressInfo?["queuePosition"])
            ?? 0
        let seatSetupStep = intValue(seatSetupInfo?["seatSetupStep"])
            ?? intValue(sessionProgress?["seatSetupStep"])
            ?? intValue(progressInfo?["seatSetupStep"])
            ?? 0
        let timerDataContainers = [
            dictionary(session["timerData"]),
            dictionary(sessionProgress?["timerData"]),
            dictionary(progressInfo?["timerData"]),
            dictionary(controlInfo?["timerData"]),
            dictionary(dictionary(session["message"])?["timerData"]),
            dictionary(dictionary(sessionProgress?["message"])?["timerData"]),
            dictionary(dictionary(progressInfo?["message"])?["timerData"]),
            dictionary(dictionary(controlInfo?["message"])?["timerData"]),
        ]
        let containers = [session, sessionProgress, progressInfo, controlInfo] + timerDataContainers
        let remaining = remainingPlaytime(containers: containers)

        return OPNParsedSessionProgress(
            queuePosition: queuePosition,
            seatSetupStep: seatSetupStep,
            progressState: progressState(seatSetupStep: seatSetupStep, queuePosition: queuePosition),
            remainingPlaytimeHours: remaining.hours,
            remainingPlaytimeAvailable: remaining.available,
            remainingSessionLimitSeconds: remainingSessionLimitSeconds(containers: containers)
        )
    }

    @objc(parseSessionAdStateFromSession:)
    public static func parseSessionAdState(from session: NSDictionary?) -> OPNParsedSessionAdState {
        let session = session as? [String: Any] ?? [:]
        let progress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let controlInfo = dictionary(session["sessionControlInfo"])
        let containers = [session, progress, progressInfo, controlInfo].compactMap { $0 }
        let required = containers.contains { container in
            boolValue(container["sessionAdsRequired"]) || boolValue(container["isAdsRequired"])
        }

        var adState = OPNSessionAdState()
        adState.sessionAdsRequired = required
        adState.serverSentEmptyAds = !containers.contains { !array($0["sessionAds"]).isEmpty || !array($0["ads"]).isEmpty }
        adState.sessionAds = sessionAds(from: containers)

        if let opportunity = containers.compactMap({ dictionary($0["opportunity"]) }).first {
            adState.isQueuePaused = boolValue(opportunity["queuePaused"], fallback: adState.isQueuePaused)
            adState.gracePeriodSeconds = positiveInt(opportunity["gracePeriodSeconds"]) ?? 0
            adState.message = nonEmptyString(opportunity["message"]) ?? nonEmptyString(opportunity["description"]) ?? ""
            if nonEmptyString(opportunity["state"])?.lowercased() == "graceperiodstart" {
                adState.isQueuePaused = true
            }
        }

        adState.isAdsRequired = required || !adState.sessionAds.isEmpty || adState.isQueuePaused
        return OPNParsedSessionAdState(adState: adState)
    }

    private static func sessionAds(from containers: [[String: Any]]) -> [OPNSessionAdInfo] {
        let adValues = containers.compactMap { container -> [Any]? in
            let sessionAds = array(container["sessionAds"])
            if !sessionAds.isEmpty { return sessionAds }
            let ads = array(container["ads"])
            return ads.isEmpty ? nil : ads
        }.first ?? []
        return adValues.enumerated().compactMap { index, value in
            guard let ad = dictionary(value) else { return nil }
            let parsed = parseSessionAd(ad, index: index)
            guard !isTerminalAdState(parsed.adState) else { return nil }
            guard !parsed.adId.isEmpty || !parsed.mediaUrl.isEmpty || !parsed.title.isEmpty || !parsed.description.isEmpty else { return nil }
            return parsed
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let parsed = intValue(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func boolValue(_ value: Any?, fallback: Bool = false) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    private static func adMediaProfileRank(_ profile: String) -> Int {
        switch profile {
        case "mp4deinterlaced720p": return 0
        case "hlsadaptive": return 1
        case "webm": return 2
        default: return 100
        }
    }

    private static func isTerminalAdState(_ adState: Int) -> Bool {
        adState == 5 || adState == 6
    }

    private static func parseSessionAd(_ ad: [String: Any], index: Int) -> OPNSessionAdInfo {
        var out = OPNSessionAdInfo()
        out.adId = nonEmptyString(ad["adId"]) ?? "ad-\(index + 1)"
        out.adState = intValue(ad["adState"]) ?? -1
        out.adUrl = nonEmptyString(ad["adUrl"]) ?? ""
        out.mediaUrl = nonEmptyString(ad["mediaUrl"]) ?? nonEmptyString(ad["videoUrl"]) ?? nonEmptyString(ad["url"]) ?? ""
        out.clickThroughUrl = nonEmptyString(ad["clickThroughUrl"]) ?? ""
        out.title = nonEmptyString(ad["title"]) ?? ""
        out.description = nonEmptyString(ad["description"]) ?? ""
        out.adLengthInSeconds = positiveInt(ad["adLengthInSeconds"]) ?? 0
        out.durationMs = out.adLengthInSeconds > 0 ? out.adLengthInSeconds * 1000 : positiveInt(ad["durationMs"]) ?? 0
        if out.durationMs == 0 {
            out.durationMs = positiveInt(ad["durationInMs"]) ?? 0
        }
        out.adMediaFiles = array(ad["adMediaFiles"]).compactMap { value in
            guard let file = dictionary(value) else { return nil }
            let mediaFileUrl = nonEmptyString(file["mediaFileUrl"]) ?? ""
            let encodingProfile = nonEmptyString(file["encodingProfile"]) ?? ""
            guard !mediaFileUrl.isEmpty || !encodingProfile.isEmpty else { return nil }
            return OPNSessionAdMediaFile(mediaFileUrl: mediaFileUrl, encodingProfile: encodingProfile)
        }.sorted { adMediaProfileRank($0.encodingProfile) < adMediaProfileRank($1.encodingProfile) }
        if out.mediaUrl.isEmpty {
            out.mediaUrl = out.adMediaFiles.first { !$0.mediaFileUrl.isEmpty }?.mediaFileUrl ?? ""
        }
        if out.mediaUrl.isEmpty && !out.adUrl.isEmpty {
            out.mediaUrl = out.adUrl
        }
        return out
    }

    private static func firstNumber(in container: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = valueAsDouble(container[key]) {
                return number
            }
        }
        return nil
    }

    private static func valueAsDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func progressState(seatSetupStep: Int, queuePosition: Int) -> OPNSessionProgressState {
        switch seatSetupStep {
        case 0:
            return queuePosition > 0 ? .inQueue : .connecting
        case 1:
            return .inQueue
        case 5:
            return .previousSessionCleanup
        case 6:
            return .waitingForStorage
        default:
            return .settingUp
        }
    }

    private static func remainingPlaytime(containers: [[String: Any]?]) -> (hours: Double, available: Bool) {
        for container in containers.compactMap({ $0 }) {
            if let minutes = firstNumber(in: container, keys: ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes"]) {
                return (max(0.0, minutes / 60.0), true)
            }
            if let seconds = firstNumber(in: container, keys: ["remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingTime", "timeRemaining"]) {
                return (max(0.0, seconds / 3600.0), true)
            }
            if let milliseconds = firstNumber(in: container, keys: ["remainingTimeInMs", "remainingTimeInMilliseconds", "remainingSessionTimeInMs", "sessionTimeRemainingInMs"]) {
                return (max(0.0, milliseconds / 3_600_000.0), true)
            }
        }
        return (0.0, false)
    }

    private static func remainingSessionLimitSeconds(containers: [[String: Any]?]) -> Int {
        for container in containers.compactMap({ $0 }) {
            if let milliseconds = firstNumber(in: container, keys: ["beforeEventMS", "remainingSessionLimitMs", "remainingSessionLimitMilliseconds", "sessionLimitRemainingMs", "sessionLimitRemainingMilliseconds"]) {
                let seconds = Int((milliseconds / 1000.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
            if let seconds = firstNumber(in: container, keys: ["timeRemaining", "remainingTime", "remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingSessionLimitSeconds", "sessionLimitRemainingSeconds"]) {
                let rounded = Int(seconds.rounded())
                if rounded > 0 && rounded <= 86_400 { return rounded }
            }
            if let minutes = firstNumber(in: container, keys: ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes", "remainingSessionLimitMinutes", "sessionLimitRemainingMinutes"]) {
                let seconds = Int((minutes * 60.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
        }
        return 0
    }

    private static func colorQuality(bitDepth: Int, chromaFormat: Int) -> String {
        let tenBit = bitDepth >= 10
        let fourFourFour = chromaFormat == 1
        if tenBit && fourFourFour { return "10bit_444" }
        if tenBit { return "10bit_420" }
        if fourFourFour { return "8bit_444" }
        return "8bit_420"
    }

    private static func displayBitDepth(_ value: Int) -> Int {
        switch value {
        case 0: return 8
        case 1: return 10
        default: return value
        }
    }
}

public struct OPNSessionAdMediaFile: Equatable, Sendable {
    public var mediaFileUrl = ""
    public var encodingProfile = ""
}

public struct OPNSessionAdInfo: Equatable, Sendable {
    public var adId = ""
    public var adState = -1
    public var adUrl = ""
    public var mediaUrl = ""
    public var adMediaFiles: [OPNSessionAdMediaFile] = []
    public var clickThroughUrl = ""
    public var adLengthInSeconds = 0
    public var durationMs = 0
    public var title = ""
    public var description = ""
}

public struct OPNSessionAdState: Equatable, Sendable {
    public var isAdsRequired = false
    public var sessionAdsRequired = false
    public var isQueuePaused = false
    public var serverSentEmptyAds = false
    public var gracePeriodSeconds = 0
    public var message = ""
    public var sessionAds: [OPNSessionAdInfo] = []
}

public enum OPNSessionProgressState: Int, Sendable {
    case unknown = 0
    case connecting
    case inQueue
    case previousSessionCleanup
    case waitingForStorage
    case settingUp
}

public struct OPNSessionInfo: Equatable, Sendable {
    public var sessionId = ""
    public var status = 0
    public var queuePosition = 0
    public var seatSetupStep = 0
    public var progressState = OPNSessionProgressState.unknown
    public var zone = ""
    public var streamingBaseUrl = ""
    public var serverIp = ""
    public var signalingServer = ""
    public var signalingUrl = ""
    public var gpuType = ""
    public var iceServers: [OPNIceServer] = []
    public var mediaConnectionInfo = OPNMediaConnectionInfo()
    public var negotiatedStreamProfile = OPNNegotiatedStreamProfile()
    public var adState = OPNSessionAdState()
    public var remainingPlaytimeHours = 0.0
    public var remainingPlaytimeAvailable = false
    public var remainingPlaytimeUnlimited = false
    public var clientId = ""
    public var deviceId = ""
}

public struct OPNIceCandidatePayload: Equatable, Sendable {
    public var candidate = ""
    public var sdpMid = ""
    public var sdpMLineIndex = 0
    public var usernameFragment = ""
}

public struct OPNSendAnswerRequest: Equatable, Sendable {
    public var sdp = ""
    public var nvstSdp = ""
}
