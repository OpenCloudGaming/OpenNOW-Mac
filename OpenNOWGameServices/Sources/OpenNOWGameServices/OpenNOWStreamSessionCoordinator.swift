import Common
import Foundation
import SignalLinkKit
import WebRTCMedia

public final class OpenNOWStreamSessionCoordinator: StreamSessionProvider, StreamSignalingChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var signaling: OPNWebSocketSignalingClient?
    private var activeSession: StreamSessionDescriptor?
    private var iceContinuation: AsyncStream<StreamIceCandidate>.Continuation?
    private var offerContinuation: CheckedContinuation<StreamOffer, Error>?

    public init() {}

    public func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
        guard let launchAppId = OPNLaunchAppId.resolve(configuration.applicationID) else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("This game does not include a launchable GeForce NOW app id.")
        }
        let configuration = normalizedConfiguration(configuration, appId: launchAppId.stringValue)
        let launch = await prepareLaunch(configuration: configuration)
        let sessionInfo = try await allocateSession(configuration: configuration, launch: launch)
        let descriptor = streamDescriptor(sessionInfo: sessionInfo, configuration: configuration)
        activeSession = descriptor
        return try await connectSignaling(sessionInfo: sessionInfo, settings: launch.settings, descriptor: descriptor)
    }

    public func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        lock.withLock {
            signaling?.disconnect()
            signaling = nil
            iceContinuation?.finish()
            iceContinuation = nil
            offerContinuation = nil
        }
        guard reason == .userRequested || reason == .completed || reason == .remoteEnded else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            OPNActiveSessionService.stopSession(accessToken: session.metadata["accessToken"] ?? "", sessionId: session.id, serverIp: session.serverAddress) { success, error in
                if success || (session.metadata["accessToken"] ?? "").isEmpty {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionStopFailed(error.isEmpty ? "Unable to stop stream session." : error))
                }
            }
        }
    }

    public func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws {
        guard let signaling = lock.withLock({ self.signaling }) else {
            throw OpenNOWStreamSessionError.signalingUnavailable
        }
        signaling.sendAnswerSdp(answer.sdp, nvstSdp: answer.metadata["nvstSdp"] ?? "")
    }

    public func remoteIceCandidates(for session: StreamSessionDescriptor) async throws -> AsyncStream<StreamIceCandidate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            lock.withLock { iceContinuation = continuation }
        }
    }

    private func allocateSession(configuration: StreamLaunchConfiguration, launch: PreparedStreamLaunch) async throws -> AllocatedStreamSession {
        OPNSessionManager.shared.setAccessToken(configuration.accessToken)
        OPNSessionManager.shared.setStreamingBaseUrl(launch.streamingBaseUrl)

        if configuration.resumesExistingSession {
            return try await withCheckedThrowingContinuation { continuation in
                OPNSessionManager.shared.claimSession(sessionId: configuration.resumeSessionID, serverIp: configuration.resumeServer, appId: configuration.applicationID, settings: launch.settings, recoveryMode: false) { success, info, error in
                    if success {
                        continuation.resume(returning: AllocatedStreamSession(info))
                    } else {
                        continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to resume stream session." : error))
                    }
                }
            }
        }

        OPNGameService.shared.setAccessToken(configuration.accessToken)
        OPNGameService.shared.setStreamingBaseUrl(launch.streamingBaseUrl)
        return try await withCheckedThrowingContinuation { continuation in
            OPNGameService.shared.launchGame(
                appId: configuration.applicationID,
                internalTitle: configuration.title.isEmpty ? "OpenNOW" : configuration.title,
                settings: launch.settings,
                recoveryMode: false,
                progress: { _, _ in },
                completion: { success, info, _, error in
                    if success {
                        continuation.resume(returning: AllocatedStreamSession(info))
                    } else {
                        continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to allocate stream session." : error))
                    }
                }
            )
        }
    }

    private func prepareLaunch(configuration: StreamLaunchConfiguration) async -> PreparedStreamLaunch {
        let baseSettings = makeSettings(configuration: configuration)
        let cloudVariables = await fetchCloudVariables(token: configuration.accessToken)
        var settings = settingsByApplyingCloudVariables(baseSettings, variables: cloudVariables)
        let requestedMaxBitrateMbps = int(settings["maxBitrateMbps"])
        let preflight = await runNetworkPreflight(token: configuration.accessToken, requestedMaxBitrateMbps: requestedMaxBitrateMbps)
        settings["networkTestSessionId"] = preflight.networkTestSessionId
        settings["networkType"] = preflight.networkType
        settings["networkLatencyMs"] = preflight.latencyMs >= 0 ? String(preflight.latencyMs) : "Unknown"
        if preflight.recommendedMaxBitrateMbps > 0 {
            settings["maxBitrateMbps"] = min(int(settings["maxBitrateMbps"]), preflight.recommendedMaxBitrateMbps)
        }
        let streamingBaseUrl = preflight.streamingBaseUrl.isEmpty ? OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: configuration.applicationID) : preflight.streamingBaseUrl
        return PreparedStreamLaunch(settings: settings, streamingBaseUrl: streamingBaseUrl)
    }

    private func fetchCloudVariables(token: String) async -> OPNStreamCloudVariables {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.fetchCloudVariables(token: token) { variables in
                continuation.resume(returning: variables)
            }
        }
    }

    private func runNetworkPreflight(token: String, requestedMaxBitrateMbps: Int) async -> OPNStreamNetworkPreflightResult {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.runNetworkPreflight(
                token: token,
                providerStreamingBaseUrl: OPNGameService.shared.providerStreamingBaseURL(),
                requestedMaxBitrateMbps: requestedMaxBitrateMbps,
                completion: { preflight in continuation.resume(returning: preflight) }
            )
        }
    }

    private func settingsByApplyingCloudVariables(_ settings: [String: Any], variables: OPNStreamCloudVariables) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: settings),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: variables),
            libWebRTCAvailable: true
        )
        var result = settings
        result.merge(resolved.dictionary(gameLanguage: string(settings["gameLanguage"], fallback: OPNLocale.currentGFNLocale()), accountLinked: bool(settings["accountLinked"], fallback: true), selectedStore: string(settings["selectedStore"]))) { _, new in new }
        return result
    }

    private func connectSignaling(sessionInfo: AllocatedStreamSession, settings: [String: Any], descriptor: StreamSessionDescriptor) async throws -> StreamOffer {
        try await withCheckedThrowingContinuation { continuation in
            let client = OPNWebSocketSignalingClient(
                signalingServer: sessionInfo.signalingServer,
                sessionId: descriptor.id,
                signalingUrl: sessionInfo.signalingUrl
            )
            client.setPeerResolution(string(settings["resolution"], fallback: "1920x1080"))
            let settingsJSON = jsonString(settings)
            client.onOffer = { [weak self] sdp in
                guard let self else { return }
                let metadata = self.offerMetadata(sessionInfo: sessionInfo, settingsJSON: settingsJSON, descriptor: descriptor)
                let offer = StreamOffer(session: descriptor, sdp: sdp, metadata: metadata)
                self.resumeOffer(offer)
            }
            client.onIceCandidate = { [weak self] payload in
                guard let self else { return }
                _ = self.lock.withLock {
                    self.iceContinuation?.yield(StreamIceCandidate(
                        sdp: self.string(payload["candidate"]),
                        sdpMid: self.string(payload["sdpMid"]),
                        sdpMLineIndex: self.int(payload["sdpMLineIndex"])
                    ))
                }
            }
            client.onClosed = { [weak self] clean, reason in
                guard !clean else { return }
                self?.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(reason.isEmpty ? "Signaling connection closed." : reason))
            }

            lock.withLock {
                signaling = client
                offerContinuation = continuation
            }
            client.connect { [weak self] success, error in
                guard !success else { return }
                self?.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(error.isEmpty ? "Unable to connect signaling." : error))
            }
        }
    }

    private func offerMetadata(sessionInfo: AllocatedStreamSession, settingsJSON: String, descriptor: StreamSessionDescriptor) -> [String: String] {
        var metadata = descriptor.metadata
        metadata["sessionInfoJSON"] = sessionInfo.rawJSON
        metadata["settings"] = settingsJSON
        return metadata
    }

    private func streamDescriptor(sessionInfo: AllocatedStreamSession, configuration: StreamLaunchConfiguration) -> StreamSessionDescriptor {
        StreamSessionDescriptor(
            id: sessionInfo.sessionId,
            applicationID: configuration.applicationID,
            serverAddress: sessionInfo.serverIp,
            title: configuration.title,
            metadata: [
                "accessToken": configuration.accessToken,
                "signalingUrl": sessionInfo.signalingUrl,
                "streamingBaseUrl": sessionInfo.streamingBaseUrl,
            ]
        )
    }

    private func makeSettings(configuration: StreamLaunchConfiguration) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        var profile = OPNStreamPreferences.loadProfile(forGame: configuration.applicationID) ?? OPNStreamPreferences.loadProfile()
        profile = OPNStreamPreferences.effectiveProfile(profile, capabilities: capabilities)
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: profile),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables()),
            libWebRTCAvailable: true
        )
        return resolved.dictionary(gameLanguage: OPNLocale.currentGFNLocale(), accountLinked: configuration.accountLinked, selectedStore: configuration.selectedStore)
    }

    private func normalizedConfiguration(_ configuration: StreamLaunchConfiguration, appId: String) -> StreamLaunchConfiguration {
        StreamLaunchConfiguration(
            id: configuration.id,
            title: configuration.title,
            applicationID: appId,
            accessToken: configuration.accessToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: configuration.resumeSessionID,
            resumeServer: configuration.resumeServer,
            metadata: configuration.metadata
        )
    }

    private func resumeOffer(_ offer: StreamOffer) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(returning: offer)
    }

    private func resumeOffer(error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(throwing: error)
    }

    private func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }
}

private struct PreparedStreamLaunch {
    let settings: [String: Any]
    let streamingBaseUrl: String
}

private struct AllocatedStreamSession: Sendable {
    let sessionId: String
    let serverIp: String
    let signalingServer: String
    let signalingUrl: String
    let streamingBaseUrl: String
    let rawJSON: String

    init(_ info: [String: Any]) {
        sessionId = Self.string(info["sessionId"])
        serverIp = Self.string(info["serverIp"])
        signalingServer = Self.string(info["signalingServer"])
        signalingUrl = Self.string(info["signalingUrl"])
        streamingBaseUrl = Self.string(info["streamingBaseUrl"])
        rawJSON = Self.jsonString(info)
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
}

public enum OpenNOWStreamSessionError: LocalizedError, Sendable {
    case sessionAllocationFailed(String)
    case sessionStopFailed(String)
    case signalingFailed(String)
    case signalingUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionAllocationFailed(let message), .sessionStopFailed(let message), .signalingFailed(let message):
            message
        case .signalingUnavailable:
            "Signaling is not connected."
        }
    }
}
