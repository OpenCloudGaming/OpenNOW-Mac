import Testing
import Foundation
@testable import OpenNOW

@Test func launchAppIdRejectsZeroAndInvalidValues() {
    #expect(OPNLaunchAppId.resolve("0") == nil)
    #expect(OPNLaunchAppId.resolve(" 0 ") == nil)
    #expect(OPNLaunchAppId.resolve("") == nil)
    #expect(OPNLaunchAppId.resolve("GFN-PC") == nil)
    #expect(OPNLaunchAppId.resolve("123")?.stringValue == "123")
    #expect(OPNLaunchAppId.resolve("123")?.intValue == 123)
}

@Test func catalogLocaleUsesUSForEnglishRegionalVariants() {
    #expect(OPNLocale.gfnCatalogLocale(for: "en_CA") == "en_US")
    #expect(OPNLocale.gfnCatalogLocale(for: "en-GB") == "en_US")
    #expect(OPNLocale.gfnCatalogLocale(for: "fr_CA") == "fr_CA")
    #expect(OPNLocale.gfnCatalogLocale(for: "") == "en_US")
}

@Test func providerInfoParsesAndSelectsDigevoEndpoint() {
    let digevoIdpId = "IsvVBA3Aj8KZ7gwwuRUhB6-tOF2o2F1wncD-XjYv100"
    let providerInfo = OPNGameService.shared.parseGameProviderInfo([
        "gfnServiceInfo": [
            "defaultProvider": "NVIDIA",
            "loggedInProvider": "NVIDIA",
            "loginRequired": false,
            "loginPreferredProviders": ["NVIDIA"],
            "gfnServiceEndpoints": [
                [
                    "loginProviderDisplayName": "NVIDIA",
                    "streamingServiceUrl": "https://prod.cloudmatchbeta.nvidiagrid.net/",
                    "idpId": "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg",
                    "redeemRedirectUrl": "https://www.nvidia.com/content/drivers/redirect.asp?page=gfn_pc_redeem_activation_code",
                    "loginProvider": "NVIDIA",
                    "loginProviderCode": "NVIDIA",
                    "loginProviderPriority": 1,
                ],
                [
                    "loginProviderDisplayName": "Digevo",
                    "streamingServiceUrl": "https://prod.DIG.geforcenow.nvidiagrid.net",
                    "idpId": digevoIdpId,
                    "redeemRedirectUrl": "",
                    "loginProvider": "Digevo",
                    "loginProviderCode": "DIG",
                    "loginProviderPriority": 10,
                ],
            ],
        ],
    ])
    let selected = OPNGameService.shared.selectGameProviderEndpoint(providerInfo, idpId: digevoIdpId)

    #expect(providerInfo.endpoints.count == 2)
    #expect(selected.loginProviderDisplayName == "Digevo")
    #expect(selected.loginProvider == "Digevo")
    #expect(selected.loginProviderCode == "DIG")
    #expect(selected.idpId == digevoIdpId)
    #expect(selected.streamingServiceUrl == "https://prod.DIG.geforcenow.nvidiagrid.net/")
}

@Test func streamCoordinatorRejectsZeroApplicationIdBeforeNetworkWork() async {
    let coordinator = OpenNOWStreamSessionCoordinator()
    let configuration = StreamLaunchConfiguration(
        title: "Invalid Launch",
        applicationID: "0",
        accessToken: "token",
        accountLinked: true,
        selectedStore: "Steam"
    )

    do {
        _ = try await coordinator.startSession(configuration: configuration)
        Issue.record("Expected coordinator to reject appId 0 before session allocation")
    } catch let error as OpenNOWStreamSessionError {
        #expect(error.errorDescription == "This game does not include a launchable GeForce NOW app id.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func streamCoordinatorNativeNVSTRejectsZeroApplicationIdBeforeNetworkWork() async {
    let coordinator = OpenNOWStreamSessionCoordinator()
    let configuration = StreamLaunchConfiguration(
        title: "Invalid Native Launch",
        applicationID: "0",
        accessToken: "token",
        accountLinked: true,
        selectedStore: "Steam"
    )

    do {
        _ = try await coordinator.startNativeNVSTSession(configuration: configuration)
        Issue.record("Expected native NVST coordinator to reject appId 0 before session allocation")
    } catch let error as OpenNOWStreamSessionError {
        #expect(error.errorDescription == "This game does not include a launchable GeForce NOW app id.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func streamCoordinatorNativeNVSTRequiresNVSTTransportSelectionBeforeNetworkWork() async {
    let originalTransportModeIndex = OPNStreamPreferences.loadProfile().transportModeIndex
    OPNStreamPreferences.saveNVSTTransportEnabled(false)
    defer { OPNStreamPreferences.saveTransportModeIndex(originalTransportModeIndex) }

    let coordinator = OpenNOWStreamSessionCoordinator()
    let configuration = StreamLaunchConfiguration(
        title: "WebRTC Selected",
        applicationID: "987654321",
        accessToken: "",
        accountLinked: true,
        selectedStore: "Steam"
    )

    do {
        _ = try await coordinator.startNativeNVSTSession(configuration: configuration)
        Issue.record("Expected native NVST coordinator to reject WebRTC transport selection")
    } catch let error as OpenNOWStreamSessionError {
        #expect(error.errorDescription == "Native NVST session requested while WebRTC transport is selected.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func streamPreferencesFetchesNumericServerTypeFromServerInfo() async {
    await networkTestIsolationLock.withLock {
        let host = "native-server-type.example.test"
        SessionManagerURLProtocol.install(host: host) { request in
            #expect(request.url?.path == "/v2/serverInfo")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
            #expect(request.value(forHTTPHeaderField: "nv-client-type") == "NATIVE")
            #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "NVIDIA-CLASSIC")
            return SessionManagerURLProtocol.response(json: ["serverType": 5])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let serverType = try? await OPNStreamPreferences.fetchServerType(token: "token", streamingBaseUrl: "https://\(host)")

        #expect(serverType == 5)
        #expect(SessionManagerURLProtocol.recordedRequests(host: host).count == 1)
    }
}

@Test func streamPreferencesRejectsNonnumericServerTypeFromServerInfo() async {
    await networkTestIsolationLock.withLock {
        let host = "invalid-native-server-type.example.test"
        SessionManagerURLProtocol.install(host: host) { _ in
            SessionManagerURLProtocol.response(json: ["serverType": "prod"])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        do {
            let serverType = try await OPNStreamPreferences.fetchServerType(token: "token", streamingBaseUrl: "https://\(host)")
            #expect(serverType == nil)
        } catch {
            Issue.record("Unexpected server-info request failure: \(error)")
        }
    }
}

@Test func streamCoordinatorFinishSessionReportsUDSEndOfSession() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "uds.geforcenow.com" {
                #expect(request.url?.path == "/v1/uds/session/reports")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                #expect(request.value(forHTTPHeaderField: "NV-Device-ID")?.isEmpty == false)
                return SessionManagerURLProtocol.response(json: ["reports": []])
            }
            if request.httpMethod == "GET" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["statusCode": 1], "sessions": []])
            }
            #expect(request.url?.path == "/v2/session/session-report")
            #expect(request.httpMethod == "DELETE")
            return SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(
            id: "session-report",
            applicationID: "123",
            serverAddress: "stop.example.test",
            title: "Report Game",
            metadata: ["accessToken": "token", "startedAtEpochSeconds": String(Date().timeIntervalSince1970 - 10)]
        )

        try await coordinator.finishSession(session, reason: .completed)

        let requests = SessionManagerURLProtocol.recordedRequests(host: host)
        let udsRequest = try #require(requests.first { $0.url?.host == "uds.geforcenow.com" })
        let body = try #require(SessionManagerURLProtocol.bodyData(from: udsRequest))
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["source"] as? String == "EndOfSession")
        #expect(json["sessionId"] as? String == "session-report")
        #expect((json["sessionDurationInSeconds"] as? Int ?? -1) >= 0)
    }
}

@Test func streamCoordinatorFinishSessionIgnoresUDSFailure() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { request in
            if request.url?.host == "uds.geforcenow.com" {
                return SessionManagerURLProtocol.response(json: ["error": "auth"], status: 401)
            }
            if request.httpMethod == "GET" {
                return SessionManagerURLProtocol.response(json: ["requestStatus": ["statusCode": 1], "sessions": []])
            }
            return SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(id: "session-report", applicationID: "123", serverAddress: "stop.example.test", title: "Report Game", metadata: ["accessToken": "token"])

        try await coordinator.finishSession(session, reason: .userRequested)
        #expect(SessionManagerURLProtocol.recordedRequests(host: host).contains { $0.url?.host == "uds.geforcenow.com" })
    }
}

@Test func streamCoordinatorFinishSessionSkipsUDSWithoutAccessToken() async throws {
    try await networkTestIsolationLock.withLock {
        let host = "*"
        SessionManagerURLProtocol.install(host: host) { _ in
            SessionManagerURLProtocol.response(json: [:])
        }
        defer { SessionManagerURLProtocol.uninstall(host: host) }

        let coordinator = OpenNOWStreamSessionCoordinator()
        let session = StreamSessionDescriptor(id: "session-report", applicationID: "123", serverAddress: "stop.example.test", title: "Report Game")

        try await coordinator.finishSession(session, reason: .completed)
        #expect(!SessionManagerURLProtocol.recordedRequests(host: host).contains { $0.url?.host == "uds.geforcenow.com" })
    }
}

@Test func sessionManagerRejectsZeroBeforeTokenValidation() async {
    let (success, _, error) = await OPNSessionManager.shared.createSession(appId: "0", internalTitle: "Invalid Launch", settings: [:])
    let result = (success, error)

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func sessionManagerRejectsZeroClaimBeforeTokenValidation() async {
    let result = await withCheckedContinuation { continuation in
        OPNSessionManager.shared.claimSession(sessionId: "session", serverIp: "server", appId: "0", settings: [:], recoveryMode: false) { success, _, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "This game does not include a launchable GeForce NOW app id.")
}

@Test func gameLaunchBridgePrefersIdTokenForCloudMatchLaunch() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "*"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT id-token")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 1,
                "statusDescription": "SUCCESS",
            ],
            "sessions": [],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let game = OPNCatalogGameObject()
            game.launchAppId = "123"
            game.title = "Regression Game"
            game.isInLibrary = true
            OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", idpId: "idp", variantIndex: -1) { success, message, plan in
                continuation.resume(returning: (success, message, plan))
            }
        }
    }

    let request = try #require(SessionManagerURLProtocol.recordedRequests(host: host).first)
    let plan = try #require(result.2)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT id-token")
    #expect(result.0 == true)
    #expect(result.1 == "Launching Regression Game...")
    if case let .ready(configuration) = plan {
        #expect(configuration.apiToken == "id-token")
        #expect(configuration.appId == "123")
        #expect(configuration.metadata["userId"] == "user")
        #expect(configuration.metadata["idpId"] == "idp")
    } else {
        Issue.record("Expected a ready launch plan")
    }
    }
}

@Test func gameLaunchBridgePromptsBeforeReusingMatchingActiveSession() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "*"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 1,
                "statusDescription": "SUCCESS",
            ],
            "sessions": [[
                "sessionId": "active-session",
                "status": 2,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": "control.example.test"],
                "connectionInfo": [[
                    "usage": 14,
                    "ip": "signaling.example.test",
                    "port": 443,
                    "resourcePath": "/nvst/",
                ]],
            ]],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let game = OPNCatalogGameObject()
            game.launchAppId = "123"
            game.title = "Regression Game"
            game.isInLibrary = true
            OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", idpId: "idp", variantIndex: -1) { success, message, plan in
                continuation.resume(returning: (success, message, plan))
            }
        }
    }

    let plan = try #require(result.2)
    #expect(result.0 == true)
    #expect(result.1 == "A GeForce NOW session is already active for Regression Game.")
    if case let .activeSession(active, resume, replacement) = plan {
        #expect(active.id == "active-session")
        #expect(active.appId == 123)
        #expect(active.title == "Regression Game")
        #expect(resume.resumeSessionId == "active-session")
        #expect(resume.resumeServer == "control.example.test")
        #expect(replacement.resumeSessionId.isEmpty)
        #expect(replacement.appId == "123")
    } else {
        Issue.record("Expected an active session plan")
    }
    }
}

@Test func gameLaunchBridgeDoesNotOfferResumeForInitializingSession() async throws {
    try await networkTestIsolationLock.withLock {
    let host = "*"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v2/session")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 1,
                "statusDescription": "SUCCESS",
            ],
            "sessions": [[
                "sessionId": "initializing-session",
                "status": 1,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": "control.example.test"],
            ]],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        Task { @MainActor in
            let game = OPNCatalogGameObject()
            game.launchAppId = "123"
            game.title = "Regression Game"
            game.isInLibrary = true
            OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", idpId: "idp", variantIndex: -1) { success, message, plan in
                continuation.resume(returning: (success, message, plan))
            }
        }
    }

    let plan = try #require(result.2)
    #expect(result.0 == true)
    if case let .activeSession(active, resume, replacement) = plan {
        #expect(active.id == "initializing-session")
        #expect(resume.resumeSessionId.isEmpty)
        #expect(resume.resumeServer.isEmpty)
        #expect(replacement.appId == "123")
    } else {
        Issue.record("Expected an active session plan")
    }
    }
}

@Test func activeSessionServiceRejectsVendorStopFailure() async {
    await networkTestIsolationLock.withLock {
    let host = "stop-vendor-failure.example.test"
    SessionManagerURLProtocol.install(host: host) { request in
        #expect(request.httpMethod == "DELETE")
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": [
                "statusCode": 4,
                "statusDescription": "INTERNAL_ERROR_STATUS",
            ],
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result = await withCheckedContinuation { continuation in
        OPNActiveSessionService.stopSession(accessToken: "token", sessionId: "active-session", serverIp: host, streamingBaseUrl: "https://\(host)") { success, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "API error 4: INTERNAL_ERROR_STATUS")
    #expect(SessionManagerURLProtocol.recordedRequests(host: host).count == 1)
    }
}

@Test func activeSessionServiceWaitsForSessionTermination() async {
    await networkTestIsolationLock.withLock {
    let host = "stop-confirmation.example.test"
    let lock = NSLock()
    nonisolated(unsafe) var activeSessionPollCount = 0
    SessionManagerURLProtocol.install(host: host) { request in
        if request.httpMethod == "DELETE" {
            return SessionManagerURLProtocol.response(json: ["requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS"]])
        }
        lock.withLock { activeSessionPollCount += 1 }
        let sessions: [[String: Any]] = lock.withLock {
            activeSessionPollCount == 1 ? [[
                "sessionId": "active-session",
                "status": 2,
                "sessionRequestData": ["appId": 123],
                "sessionControlInfo": ["ip": host],
            ]] : []
        }
        return SessionManagerURLProtocol.response(json: [
            "requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS"],
            "sessions": sessions,
        ])
    }
    defer { SessionManagerURLProtocol.uninstall(host: host) }

    let result = await withCheckedContinuation { continuation in
        OPNActiveSessionService.stopSession(accessToken: "token", sessionId: "active-session", serverIp: host, streamingBaseUrl: "https://\(host)") { success, error in
            continuation.resume(returning: (success, error))
        }
    }

    #expect(result.0 == true)
    #expect(result.1.isEmpty)
    #expect(SessionManagerURLProtocol.recordedRequests(host: host).map(\.httpMethod) == ["DELETE", "GET", "GET"])
    }
}

@Test @MainActor func gameLaunchBridgeBlocksPatchingGamesBeforeNetworkWork() async throws {
    let game = OPNCatalogGameObject()
    game.launchAppId = "123"
    game.title = "Patching Game"
    game.isPatching = true

    let result: (Bool, String, OPNGameLaunchPlan?) = await withCheckedContinuation { continuation in
        OPNGameLaunchBridge.shared.prepareLaunchPlan(game: game, accessToken: "access-token", idToken: "id-token", userId: "user", variantIndex: -1) { success, message, plan in
            continuation.resume(returning: (success, message, plan))
        }
    }

    #expect(result.0 == false)
    #expect(result.1 == "GeForce NOW is patching this game. Try again after patching finishes.")
    #expect(result.2 == nil)
}
