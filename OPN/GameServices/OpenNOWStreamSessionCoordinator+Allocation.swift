//  Getting a seat: creating or claiming the CloudMatch session, waiting for it to come up,
//  playing any required ad, and the launch settings that go with it. Split out of
//  OpenNOWStreamSessionCoordinator.swift.
//

import Foundation

extension OpenNOWStreamSessionCoordinator {
    func allocateSession(configuration: StreamLaunchConfiguration, launch: PreparedStreamLaunch) async throws -> AllocatedStreamSession {
        sessionManager.setAccessToken(configuration.accessToken)
        sessionManager.setStreamingBaseUrl(launch.streamingBaseUrl)

        if configuration.resumesExistingSession {
            let claimed = try await claimSession(configuration: configuration, settings: launch.settings)
            return try await waitForReadySession(claimed, configuration: configuration)
        }

        let created = try await createSession(configuration: configuration, settings: launch.settings)
        do {
            return try await waitForReadySession(created, configuration: configuration)
        } catch {
            let descriptor = streamDescriptor(sessionInfo: created, configuration: configuration)
            try? await finishSession(descriptor, reason: Task.isCancelled ? .userRequested : .failed)
            throw error
        }
    }

    func createSession(configuration: StreamLaunchConfiguration, settings: [String: Any]) async throws -> AllocatedStreamSession {
        let (success, info, error) = await sessionManager.createSession(appId: configuration.applicationID, internalTitle: configuration.title.isEmpty ? "OpenNOW" : configuration.title, settings: settings)
        if success {
            return AllocatedStreamSession(info)
        } else if info["isSessionLimitConflict"] as? Bool == true {
            let applicationID = self.string(info["appId"])
            throw OpenNOWStreamSessionError.activeSessionConflict(StreamSessionConflict(
                sessionID: self.string(info["sessionId"]),
                applicationID: applicationID.isEmpty ? configuration.applicationID : applicationID,
                serverAddress: self.string(info["serverIp"]),
                isResumable: self.bool(info["isResumable"])
            ))
        } else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to allocate stream session." : error)
        }
    }

    func claimSession(configuration: StreamLaunchConfiguration, settings: [String: Any]) async throws -> AllocatedStreamSession {
        try await withCheckedThrowingContinuation { continuation in
            sessionManager.claimSession(sessionId: configuration.resumeSessionID, serverIp: configuration.resumeServer, appId: configuration.applicationID, settings: settings, recoveryMode: false) { success, info, error in
                if success {
                    continuation.resume(returning: AllocatedStreamSession(info))
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to resume stream session." : error))
                }
            }
        }
    }

    func waitForReadySession(_ initial: AllocatedStreamSession, configuration: StreamLaunchConfiguration) async throws -> AllocatedStreamSession {
        if initial.isReady { return initial }
        guard !initial.sessionId.isEmpty, !initial.serverIp.isEmpty else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Cloud session is missing session id or server address.")
        }

        var attempts = 0
        var lastPollWasPendingProgress = initial.isPendingProgress
        var latest = initial
        var requiredAdGateObserved = initial.requiredAdGateObserved
        var completedAdIds: Set<String> = []
        publishAllocationProgress(latest, configuration: configuration)
        while !latest.isReady {
            try Task.checkCancellation()
            if let ad = latest.pendingAd, !completedAdIds.contains(ad.adId) {
                requiredAdGateObserved = true
                latest = latest.markingRequiredAdGateObserved()
                publishAllocationProgress(latest, configuration: configuration, overrideMessage: "Playing sponsored message before your free-tier session continues...")
                latest = try await playRequiredAd(ad, session: latest)
                latest = latest.markingRequiredAdGateObserved()
                completedAdIds.insert(ad.adId)
                attempts = 0
                lastPollWasPendingProgress = latest.isPendingProgress
                publishAllocationProgress(latest, configuration: configuration)
                continue
            }
            if attempts >= 60, !lastPollWasPendingProgress {
                throw OpenNOWStreamSessionError.sessionAllocationFailed("Session poll timeout")
            }
            if attempts >= 60, lastPollWasPendingProgress { attempts = 0 }
            attempts += 1
            try await Task.sleep(nanoseconds: pollDelayNanoseconds(attempt: attempts))
            latest = try await pollSession(sessionId: initial.sessionId, serverIp: initial.serverIp)
            if latest.status > 3, ![4, 5, 6].contains(latest.status) {
                throw OpenNOWStreamSessionError.sessionAllocationFailed("Session in terminal error state")
            }
            if requiredAdGateObserved { latest = latest.markingRequiredAdGateObserved() }
            lastPollWasPendingProgress = latest.isPendingProgress
            publishAllocationProgress(latest, configuration: configuration)
        }
        if requiredAdGateObserved { latest = latest.markingRequiredAdGateObserved() }
        return latest
    }

    func playRequiredAd(_ ad: AllocatedSessionAd, session: AllocatedStreamSession) async throws -> AllocatedStreamSession {
        guard !ad.mediaUrl.isEmpty else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("GeForce NOW requires an ad before launch, but no playable ad media was returned.")
        }
        guard let adPresenter else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("GeForce NOW requires an ad before launch, but the loading screen ad player is not available.")
        }
        let startedSession = try await reportSessionAd(session: session, ad: ad, action: "start", watchedTimeInMs: -1, cancelReason: "")
        let playbackSession = startedSession.sessionId.isEmpty ? session : startedSession
        do {
            let watchedTimeInMs = try await adPresenter.playRequiredSessionAd(ad.presentation)
            let updated = try await reportSessionAd(session: playbackSession, ad: ad, action: "finish", watchedTimeInMs: watchedTimeInMs, cancelReason: "")
            return updated.sessionId.isEmpty ? playbackSession : updated
        } catch {
            _ = try? await reportSessionAd(session: playbackSession, ad: ad, action: "cancel", watchedTimeInMs: -1, cancelReason: "playback_failed")
            throw error
        }
    }

    func publishAllocationProgress(_ session: AllocatedStreamSession, configuration: StreamLaunchConfiguration, overrideMessage: String = "") {
        guard let progressHandler else { return }
        progressHandler(StreamProgress(
            title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title,
            message: overrideMessage.isEmpty ? allocationProgressMessage(session) : overrideMessage,
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: session.isReady,
            queuePosition: session.queuePosition > 0 ? session.queuePosition : nil
        ))
    }

    func allocationProgressMessage(_ session: AllocatedStreamSession) -> String {
        if session.queuePosition > 0 { return "Queue position: \(session.queuePosition)" }
        if session.adsRequired { return "Preparing sponsored message before your free-tier session continues..." }
        if session.seatSetupStep > 0 { return "Setting up your cloud gaming rig..." }
        return "Allocating cloud session..."
    }

    func reportSessionAd(session: AllocatedStreamSession, ad: AllocatedSessionAd, action: String, watchedTimeInMs: Int, cancelReason: String) async throws -> AllocatedStreamSession {
        let (success, info, error) = await sessionManager.reportSessionAd(session: session.reportableSession, adId: ad.adId, action: action, watchedTimeInMs: watchedTimeInMs, pausedTimeInMs: -1, cancelReason: cancelReason)
        if success {
            return AllocatedStreamSession(info)
        } else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to update required ad state." : error)
        }
    }

    func pollSession(sessionId: String, serverIp: String) async throws -> AllocatedStreamSession {
        let (success, info, error) = await sessionManager.pollSession(sessionId: sessionId, serverIp: serverIp)
        if success {
            return AllocatedStreamSession(info)
        } else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to poll stream session." : error)
        }
    }

    func pollDelayNanoseconds(attempt: Int) -> UInt64 {
        if attempt <= 12 { return 300_000_000 }
        if attempt <= 20 { return 500_000_000 }
        return 1_000_000_000
    }

    func prepareLaunch(configuration: StreamLaunchConfiguration) async -> PreparedStreamLaunch {
        let baseSettings = makeSettings(configuration: configuration)
        let cloudVariables = await fetchCloudVariables(configuration: configuration)
        var settings = settingsByApplyingCloudVariables(baseSettings, variables: cloudVariables)
        let requestedMaxBitrateMbps = int(settings["maxBitrateMbps"])
        let preflight = await runNetworkPreflight(token: configuration.accessToken, requestedMaxBitrateMbps: requestedMaxBitrateMbps)
        if preflight.serverReportedWarning || !preflight.continueRecommended || !preflight.warningMessage.isEmpty {
            OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .networkTest, parameters: [
                "status": "warning",
                "continued": "true",
                "message": preflight.warningMessage.isEmpty ? "Network preflight reported a warning. Launch will continue." : preflight.warningMessage,
            ]))
        }
        settings["networkTestSessionId"] = preflight.networkTestSessionId
        settings["networkType"] = preflight.networkType
        settings["networkLatencyMs"] = preflight.latencyMs >= 0 ? String(preflight.latencyMs) : "Unknown"
        if preflight.maxPacketSize >= 512 { settings["maxPacketSize"] = preflight.maxPacketSize }
        if preflight.recommendedMaxBitrateMbps > 0 {
            settings["maxBitrateMbps"] = min(int(settings["maxBitrateMbps"]), preflight.recommendedMaxBitrateMbps)
        }
        let streamingBaseUrl = preflight.streamingBaseUrl.isEmpty ? OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: configuration.applicationID) : preflight.streamingBaseUrl
        return PreparedStreamLaunch(settings: settings, streamingBaseUrl: streamingBaseUrl)
    }

    func fetchCloudVariables(configuration: StreamLaunchConfiguration) async -> OPNStreamCloudVariables {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.fetchCloudVariables(token: configuration.accessToken, userId: configuration.metadata["userId"] ?? "", idpId: configuration.metadata["idpId"] ?? "") { variables in
                continuation.resume(returning: variables)
            }
        }
    }

    func runNetworkPreflight(token: String, requestedMaxBitrateMbps: Int) async -> OPNStreamNetworkPreflightResult {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.runNetworkPreflight(
                token: token,
                providerStreamingBaseUrl: OPNGameService.shared.providerStreamingBaseURL(),
                requestedMaxBitrateMbps: requestedMaxBitrateMbps,
                completion: { preflight in continuation.resume(returning: preflight) }
            )
        }
    }

    func settingsByApplyingCloudVariables(_ settings: [String: Any], variables: OPNStreamCloudVariables) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: settings),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: variables)
        )
        var result = settings
        result.merge(resolved.dictionary(gameLanguage: string(settings["gameLanguage"], fallback: OPNLocale.currentGFNLocale()), accountLinked: bool(settings["accountLinked"], fallback: true), selectedStore: string(settings["selectedStore"]))) { _, new in new }
        return result
    }
}
