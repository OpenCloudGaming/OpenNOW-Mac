import Foundation

public actor NativeNVSTBifrostTransport: NativeNVSTTransport {
    static let geronimoStartFailureMessage = "Native NVST streaming did not reach Geronimo readiness. Open diagnostics for the native phase and sanitized error."

    private let bridgeConfiguration: NVSTNativeBridgeConfiguration
    private let inputEncoder: NativeNVSTInputEncoder
    private let nativeVideoSurfaceHandle: UInt?
    private var bridge: NVSTNativeBridge?
    private var activeConnection: NativeNVSTTransportConnection?
    private var geronimoSessionAddress: UInt?
    private var geronimoEventSink: NativeNVSTGeronimoEventSink?
    private var encodedInputEvents: [NativeNVSTEncodedInputEvent] = []

    public init(bridgeConfiguration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration(),
                inputEncoder: NativeNVSTInputEncoder = NativeNVSTInputEncoder(),
                nativeVideoSurfaceHandle: UInt? = nil) {
        self.bridgeConfiguration = bridgeConfiguration
        self.inputEncoder = inputEncoder
        self.nativeVideoSurfaceHandle = nativeVideoSurfaceHandle
    }

    public func prepare() async throws -> NVSTNativeBridgeStatus {
        if let bridge { return bridge.status }
        do {
            let bridge = try NVSTNativeBridge(configuration: bridgeConfiguration)
            self.bridge = bridge
            WebRTCMediaTelemetry.capture("nvst.bifrost.runtime.ready", level: .info, message: "Bundled Bifrost runtime loaded.", attributes: ["library": bridge.status.libraryURL.lastPathComponent, "symbols": String(bridge.status.resolvedSymbols.count)])
            return bridge.status
        } catch let error as NVSTNativeBridgeError {
            throw NativeNVSTError.runtimeUnavailable(error.errorDescription ?? "Bundled native NVST runtime is unavailable.")
        } catch {
            throw NativeNVSTError.runtimeUnavailable(error.localizedDescription.isEmpty ? "Bundled native NVST runtime is unavailable." : error.localizedDescription)
        }
    }

    public func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        let status = try await prepare()
        guard !allocation.session.id.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a session id.") }
        guard !allocation.signalingURL.isEmpty || !allocation.signalingServer.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing signaling endpoint data.") }
        if let bridge {
            let sessionPayload = NativeNVSTSessionPayload(allocation: allocation)
            let endpoint = try bridge.prepareSignalingServerEndpoint(host: signalingHost(allocation), port: signalingPort(allocation))
            let videoConfig = try bridge.initializeStreamConfig(mediaType: .video, direction: .receiver)
            let audioConfig = try bridge.initializeStreamConfig(mediaType: .audio, direction: .receiver)
            var attributes = sessionPayload.telemetryAttributes
            attributes.merge([
                "sessionId": allocation.session.id,
                "endpointHost": endpoint.host,
                "endpointPort": String(endpoint.port),
                "endpointTransferProtocol": String(endpoint.transferProtocol),
                "endpointPortUsage": String(endpoint.portUsage),
                "version": bridge.runtimeVersion(),
                "videoConfigBytes": String(videoConfig.nonZeroByteCount),
                "audioConfigBytes": String(audioConfig.nonZeroByteCount),
            ]) { _, new in new }
            WebRTCMediaTelemetry.capture("nvst.bifrost.abi_probe.ready", level: .info, message: "Verified Bifrost endpoint, stream config initialization ABI, and native session payload fields.", attributes: attributes)
        }
        let started = try await Self.startGeronimoOnMainActor(allocation: allocation, status: status, nativeVideoSurfaceHandle: nativeVideoSurfaceHandle)
        let connection = started.connection
        geronimoSessionAddress = started.sessionAddress
        geronimoEventSink = started.eventSink
        activeConnection = connection
        return connection
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeConnection != nil else { throw NativeNVSTError.notRunning }
        guard let encoded = inputEncoder.encode(event) else { return }
        guard let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.sendGeronimoInputOnMainActor(sessionAddress: sessionAddress, encoded: encoded)
    }

    public func disconnect() async {
        if let geronimoSessionAddress {
            self.geronimoSessionAddress = nil
            await Self.destroyGeronimoOnMainActor(sessionAddress: geronimoSessionAddress)
        }
        geronimoEventSink = nil
        activeConnection = nil
        encodedInputEvents.removeAll()
    }

    public func pause() async throws {
        guard let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.pauseGeronimoOnMainActor(sessionAddress: sessionAddress)
    }

    @MainActor private static func startGeronimoOnMainActor(allocation: NativeNVSTSessionAllocation, status: NVSTNativeBridgeStatus, nativeVideoSurfaceHandle: UInt?) async throws -> (connection: NativeNVSTTransportConnection, sessionAddress: UInt, eventSink: NativeNVSTGeronimoEventSink) {
        guard let frameworksPath = status.libraryURL.deletingLastPathComponent().path.cString(using: .utf8) else {
            throw NativeNVSTError.runtimeUnavailable("Native Geronimo frameworks path could not be encoded.")
        }
        let settings = Self.jsonObject(from: allocation.settingsJSON)
        let streamingProfileJSON = try Self.streamingProfileJSON(rawSessionJSON: allocation.rawSessionJSON, sessionInfoJSON: allocation.sessionInfoJSON, settingsJSON: allocation.settingsJSON)
        let launchPayload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: streamingProfileJSON, clientAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "OpenNOW")
        try launchPayload.validate()
        let geronimoSessionJSON = try Self.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
        var startAttributes = Self.geronimoStartAttributes(allocation: allocation, streamingProfileJSON: streamingProfileJSON, geronimoSessionJSON: geronimoSessionJSON)
        startAttributes.merge(launchPayload.telemetryAttributes) { _, new in new }
        WebRTCMediaTelemetry.capture("nvst.geronimo.start.prepare", level: .info, message: "Preparing Geronimo native NVST start request.", attributes: startAttributes)
        let gameLanguage = Self.string(settings["gameLanguage"], fallback: "en_US")
        let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "OpenNOW"
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        guard let session = frameworksPath.withUnsafeBufferPointer({ pathBuffer in
            OpenNOWNativeNVSTGeronimoCreate(pathBuffer.baseAddress, errorBuffer, 1024)
        }) else {
            let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo session could not be created.")
            var attributes = startAttributes
            attributes["error"] = message
            WebRTCMediaTelemetry.capture("nvst.geronimo.create.failed", level: .error, message: message, attributes: attributes)
            throw NativeNVSTError.runtimeUnavailable(message)
        }
        if let nativeVideoSurfaceHandle, let nativeVideoSurface = UnsafeMutableRawPointer(bitPattern: nativeVideoSurfaceHandle) {
            let surfaceResult = OpenNOWNativeNVSTGeronimoSetVideoSurface(session, nativeVideoSurface, errorBuffer, 1024)
            guard surfaceResult == 0 else {
                let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo video surface binding failed with result \(surfaceResult).")
                var attributes = startAttributes
                attributes["result"] = String(surfaceResult)
                attributes["error"] = message
                WebRTCMediaTelemetry.capture("nvst.geronimo.video_surface.failed", level: .error, message: message, attributes: attributes)
                OpenNOWNativeNVSTGeronimoDestroy(session)
                throw NativeNVSTError.privateABIUnavailable(message)
            }
            WebRTCMediaTelemetry.capture("nvst.geronimo.video_surface.bound", level: .info, message: "Native Geronimo video surface bound for SDL window creation.", attributes: startAttributes)
        }
        let eventSink = NativeNVSTGeronimoEventSink(sessionId: allocation.session.id, telemetryAttributes: startAttributes)
        let eventContext = Unmanaged.passUnretained(eventSink).toOpaque()
        let callbackResult = OpenNOWNativeNVSTGeronimoSetEventHandler(session, nativeNVSTGeronimoEventCallback, eventContext, errorBuffer, 1024)
        guard callbackResult == 0 else {
            let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo callback registration failed with result \(callbackResult).")
            var attributes = startAttributes
            attributes["result"] = String(callbackResult)
            attributes["error"] = message
            WebRTCMediaTelemetry.capture("nvst.geronimo.callback.failed", level: .error, message: message, attributes: attributes)
            OpenNOWNativeNVSTGeronimoDestroy(session)
            throw NativeNVSTError.privateABIUnavailable(message)
        }
        do {
            let result = geronimoSessionJSON.withCString { rawSessionPointer in
                streamingProfileJSON.withCString { profilePointer in
                    gameLanguage.withCString { languagePointer in
                        clientVersion.withCString { versionPointer in
                            gameLanguage.withCString { localePointer in
                                launchPayload.prepare.traceParent.withCString { traceParentPointer in
                                    allocation.rawSessionJSON.withCString { cloudSessionPointer in
                                        OpenNOWNativeNVSTGeronimoStart(session, rawSessionPointer, profilePointer, cloudSessionPointer, languagePointer, versionPointer, localePointer, traceParentPointer, errorBuffer, 1024)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard result == 0 else {
                let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo start failed with result \(result).")
                let userMessage = Self.geronimoStartFailureMessage
                var attributes = startAttributes
                attributes["result"] = String(result)
                attributes["error"] = message
                attributes["userMessage"] = userMessage
                WebRTCMediaTelemetry.capture("nvst.geronimo.start.failed", level: .error, message: message, attributes: attributes)
                throw NativeNVSTError.transportFailed(userMessage)
            }
            let sessionAddress = UInt(bitPattern: session)
            var attributes = startAttributes
            attributes["library"] = status.libraryURL.lastPathComponent
            WebRTCMediaTelemetry.capture("nvst.geronimo.start.accepted", level: .info, message: "Geronimo accepted native NVST start request; waiting for StreamerConnected callback.", attributes: attributes)
            try await eventSink.waitForStreamerConnected(timeoutNanoseconds: 20_000_000_000)
            WebRTCMediaTelemetry.capture("nvst.geronimo.stream.connected", level: .info, message: "Geronimo reported StreamerConnected for native NVST.", attributes: attributes)
            return (NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: status), sessionAddress, eventSink)
        } catch {
            OpenNOWNativeNVSTGeronimoDestroy(session)
            throw error
        }
    }

    @MainActor private static func destroyGeronimoOnMainActor(sessionAddress: UInt) {
        let session = UnsafeMutableRawPointer(bitPattern: sessionAddress)
        _ = OpenNOWNativeNVSTGeronimoStopWithResult(session, "OpenNOW native NVST destroy", 0, nil, 0)
        OpenNOWNativeNVSTGeronimoDestroy(session)
    }

    @MainActor private static func pauseGeronimoOnMainActor(sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = OpenNOWNativeNVSTGeronimoPause(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "Native Geronimo pause failed with result \(result)."))
        }
    }

    @MainActor private static func sendGeronimoInputOnMainActor(sessionAddress: UInt, encoded: NativeNVSTEncodedInputEvent) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = encoded.payload.withUnsafeBytes { buffer in
            OpenNOWNativeNVSTGeronimoSendInput(UnsafeMutableRawPointer(bitPattern: sessionAddress), buffer.bindMemory(to: UInt8.self).baseAddress, encoded.payload.count, errorBuffer, 1024)
        }
        guard result == 0 else {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo input send failed with result \(result)."))
        }
    }

    static func streamingProfileJSON(rawSessionJSON: String, sessionInfoJSON: String, settingsJSON: String = "{}") throws -> String {
        let rawSession = jsonObject(from: rawSessionJSON)
        let sessionInfo = jsonObject(from: sessionInfoJSON)
        let settings = jsonObject(from: settingsJSON)
        let candidates = [
            rawSession["streamingProfile"],
            rawSession["negotiatedStreamProfile"],
            sessionInfo["streamingProfile"],
            sessionInfo["negotiatedStreamProfile"],
        ]
        var profile: [String: Any] = [:]
        for candidate in candidates.compactMap({ $0 as? [String: Any] }) where JSONSerialization.isValidJSONObject(candidate) {
            for (key, value) in candidate where !isEmptyProfileValue(value) {
                if shouldReplaceProfileValue(profile[key], key: key) { profile[key] = value }
            }
        }
        if string(profile["resolution"], fallback: "").isEmpty {
            let resolution = string(settings["resolution"], fallback: "")
            if !resolution.isEmpty { profile["resolution"] = resolution }
        }
        if int(profile["fps"]) <= 0 {
            let fps = firstPositiveInt(in: profile, keys: ["selectedVideoMode.fps", "selectedEncodeMode.fps"]) ?? int(settings["fps"])
            if fps > 0 { profile["fps"] = fps }
        }
        if string(profile["codec"], fallback: "").isEmpty {
            let codec = normalizedCodec(string(settings["codec"], fallback: ""))
            if !codec.isEmpty { profile["codec"] = codec }
        }
        guard !profile.isEmpty,
              let dimensions = videoDimensions(from: profile),
              int(profile["fps"]) > 0,
              !string(profile["codec"], fallback: "").isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session is missing a complete streaming profile.")
        }
        let modeSelection = modeSelectionProfile(from: profile, dimensions: dimensions)
        guard JSONSerialization.isValidJSONObject(modeSelection),
              let data = try? JSONSerialization.data(withJSONObject: modeSelection),
              let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session is missing a complete streaming profile.")
        }
        return string
    }

    static func geronimoSessionJSON(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String) throws -> String {
        let rawSession = jsonObject(from: allocation.rawSessionJSON)
        let sessionInfo = jsonObject(from: allocation.sessionInfoJSON)
        let settings = jsonObject(from: allocation.settingsJSON)
        let requestData = rawSession["sessionRequestData"] as? [String: Any] ?? [:]
        let connectionInfo = normalizedConnectionInfo(rawSession: rawSession, sessionInfo: sessionInfo, allocation: allocation)
        let monitorSettings = normalizedMonitorSettings(rawSession: rawSession, requestData: requestData, settings: settings, streamingProfileJSON: streamingProfileJSON)
        let streamingProfile = normalizedNativeStreamingProfile(rawSession: rawSession, sessionInfo: sessionInfo, settings: settings, allocation: allocation, streamingProfileJSON: streamingProfileJSON)
        let sessionControlInfo = rawSession["sessionControlInfo"] as? [String: Any] ?? [:]
        let zoneAddress = firstNonEmpty(string(sessionControlInfo["ip"], fallback: ""), string(rawSession["zoneAddress"], fallback: ""), allocation.session.serverAddress)
        let zoneName = firstNonEmpty(string(rawSession["zoneName"], fallback: ""), zoneAddress.split(separator: ".").first.map { String($0).uppercased() } ?? "")
        let sessionId = firstNonEmpty(string(rawSession["sessionId"], fallback: ""), allocation.session.id)
        var normalized: [String: Any] = [
            "sessionId": sessionId,
            "subSessionId": string(rawSession["subSessionId"], fallback: ""),
            "appId": int(requestData["appId"]) > 0 ? int(requestData["appId"]) : int(rawSession["appId"]),
            "appLaunchMode": geronimoAppLaunchMode(requestData["appLaunchMode"]),
            "state": int(rawSession["state"]) > 0 ? int(rawSession["state"]) : int(rawSession["status"]),
            "zoneAddress": zoneAddress,
            "zoneName": zoneName,
            "deviceId": string(requestData["deviceHashId"], fallback: ""),
            "gpuType": string(rawSession["gpuType"], fallback: ""),
            "streamingProfile": streamingProfile,
            "monitorSettings": monitorSettings,
            "connectionInfo": connectionInfo,
            "finalizedStreamingFeatures": normalizedStreamingFeatures(rawSession: rawSession, requestData: requestData, streamingProfileJSON: streamingProfileJSON),
            "resumeType": int(rawSession["resumeType"]),
            "keyboardLayout": string(settings["keyboardLayout"], fallback: ""),
            "locale": firstNonEmpty(string(settings["gameLanguage"], fallback: ""), string(rawSession["locale"], fallback: "")),
        ]
        if let externalAppId = requestData["externalAppId"] { normalized["externalAppId"] = externalAppId }
        if !sessionId.isEmpty { normalized["sessionControlUrl"] = "/v2/session/\(sessionId)" }
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized),
              let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session could not be normalized for Geronimo.")
        }
        return string
    }

    private static func modeSelectionProfile(from profile: [String: Any], dimensions: (width: Int, height: Int)) -> [String: Any] {
        let fps = int(profile["fps"])
        let scaleFactor = max(int(firstValue(in: profile, keys: ["scaleFactor", "selectedVideoMode.scaleFactor"])), 1)
        let colorQuality = string(profile["colorQuality"], fallback: "")
        let selectedFeatures = selectedFeatures(from: profile, colorQuality: colorQuality)
        let selectedVideoMode = ["width": dimensions.width, "height": dimensions.height, "fps": fps, "scaleFactor": scaleFactor]
        let selectedEncodeMode = ["width": dimensions.width, "height": dimensions.height, "fps": fps]
        return [
            "selectedVideoMode": selectedVideoMode,
            "selectedFeatures": selectedFeatures,
            "selectedEncodeMode": selectedEncodeMode,
        ]
    }

    private static func selectedFeatures(from profile: [String: Any], colorQuality: String) -> [String: Any] {
        let features = profile["selectedFeatures"] as? [String: Any] ?? [:]
        return [
            "vvsync": bool(firstValue(in: features, profile, keys: ["vvsync"])),
            "vsync": int(firstValue(in: features, profile, keys: ["vsync"])),
            "hdr": bool(firstValue(in: features, profile, keys: ["hdr"])) || colorQuality.localizedCaseInsensitiveContains("hdr"),
            "audioChannelCount": max(int(firstValue(in: features, profile, keys: ["audioChannelCount", "channels"])), 2),
            "reflex": bool(firstValue(in: features, profile, keys: ["reflex"])),
            "bitDepth": bitDepth(from: firstValue(in: features, profile, keys: ["bitDepth"]), colorQuality: colorQuality),
            "cloudGsync": bool(firstValue(in: features, profile, keys: ["cloudGsync"])),
            "l4s": bool(firstValue(in: features, profile, keys: ["l4s"])),
            "hdr10PlusGaming": bool(firstValue(in: features, profile, keys: ["hdr10PlusGaming"])),
            "profile": int(firstValue(in: features, profile, keys: ["profile"])),
            "chromaFormat": int(firstValue(in: features, profile, keys: ["chromaFormat"])),
            "fallbackToLogicalResolution": bool(firstValue(in: features, profile, keys: ["fallbackToLogicalResolution"])),
            "maxBitrateKbps": int(firstValue(in: features, profile, keys: ["maxBitrateKbps", "bitrateKbps", "bitrate"])),
            "dynamicStreamingMode": int(firstValue(in: features, profile, keys: ["dynamicStreamingMode"])),
            "prefilterParams": prefilterParams(from: features["prefilterParams"] as? [String: Any]),
            "hudStreamingParams": hudStreamingParams(from: features["hudStreamingParams"] as? [String: Any]),
        ]
    }

    private static func prefilterParams(from source: [String: Any]?) -> [String: Any] {
        [
            "mode": int(source?["mode"]),
            "denoiseLevel": double(source?["denoiseLevel"]),
            "sharpnessLevel": int(source?["sharpnessLevel"]),
            "model": int(source?["model"]),
        ]
    }

    private static func hudStreamingParams(from source: [String: Any]?) -> [String: Any] {
        [
            "mode": int(source?["mode"]),
            "scxQpDelta": double(source?["scxQpDelta"]),
        ]
    }

    private static func videoDimensions(from profile: [String: Any]) -> (width: Int, height: Int)? {
        if let mode = profile["selectedVideoMode"] as? [String: Any] {
            let width = int(mode["width"])
            let height = int(mode["height"])
            if width > 0 && height > 0 { return (width, height) }
        }
        let width = int(firstValue(in: profile, keys: ["width", "videoWidth"]))
        let height = int(firstValue(in: profile, keys: ["height", "videoHeight"]))
        if width > 0 && height > 0 { return (width, height) }
        return parseResolution(string(profile["resolution"], fallback: ""))
    }

    private static func parseResolution(_ value: String) -> (width: Int, height: Int)? {
        let normalized = value.lowercased().replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "x", maxSplits: 1).map(String.init)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func jsonObject(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private static func jsonArray(from value: Any?) -> [Any] {
        if let value = value as? [Any] { return value }
        if let value = value as? NSArray { return value.compactMap { $0 } }
        return []
    }

    private static func normalizedConnectionInfo(rawSession: [String: Any], sessionInfo: [String: Any], allocation: NativeNVSTSessionAllocation) -> [Any] {
        let rawConnections = jsonArray(from: rawSession["connectionInfo"]).compactMap { normalizedConnection($0 as? [String: Any]) }
        if !rawConnections.isEmpty {
            let hasVideo = rawConnections.contains { int($0["usage"]) == 2 }
            return hasVideo ? rawConnections.filter { int($0["usage"]) != 17 } : rawConnections
        }
        var connections: [[String: Any]] = []
        let signalingHost = signalingHost(sessionInfo: sessionInfo, allocation: allocation)
        if !signalingHost.isEmpty {
            connections.append([
                "usage": 14,
                "ip": signalingHost,
                "port": signalingPort(sessionInfo: sessionInfo, allocation: allocation),
                "protocol": 2,
                "resourcePath": signalingResourcePath(sessionInfo: sessionInfo),
                "appLevelProtocol": 5,
            ])
        }
        let mediaHost = firstNonEmpty(string((sessionInfo["mediaConnectionInfo"] as? [String: Any])?["ip"], fallback: ""), allocation.mediaHost)
        let mediaPort = int((sessionInfo["mediaConnectionInfo"] as? [String: Any])?["port"]) > 0 ? int((sessionInfo["mediaConnectionInfo"] as? [String: Any])?["port"]) : Int(allocation.mediaPort)
        if !mediaHost.isEmpty, mediaPort > 0 {
            connections.append(["usage": 2, "ip": mediaHost, "port": mediaPort, "protocol": 2, "resourcePath": "", "appLevelProtocol": 2])
        }
        return connections
    }

    private static func normalizedNativeStreamingProfile(rawSession: [String: Any], sessionInfo: [String: Any], settings: [String: Any], allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String) -> [String: Any] {
        let candidates = [
            rawSession["streamingProfile"],
            rawSession["negotiatedStreamProfile"],
            sessionInfo["streamingProfile"],
            sessionInfo["negotiatedStreamProfile"],
            settings["streamingProfile"],
        ]
        var profile: [String: Any] = [:]
        for candidate in candidates.compactMap({ $0 as? [String: Any] }) where JSONSerialization.isValidJSONObject(candidate) {
            for (key, value) in candidate where !isEmptyProfileValue(value) {
                if shouldReplaceProfileValue(profile[key], key: key) { profile[key] = value }
            }
        }

        let modeSelection = jsonObject(from: streamingProfileJSON)
        let selectedMode = modeSelection["selectedVideoMode"] as? [String: Any] ?? [:]
        let selectedFeatures = modeSelection["selectedFeatures"] as? [String: Any] ?? [:]
        let width = int(selectedMode["width"])
        let height = int(selectedMode["height"])
        let fps = int(selectedMode["fps"])
        if string(profile["streamingProfileGuid"], fallback: "").isEmpty {
            profile["streamingProfileGuid"] = openNOWStreamingProfileGuid(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
        }
        if string(profile["resolution"], fallback: "").isEmpty, width > 0, height > 0 { profile["resolution"] = "\(width)x\(height)" }
        if int(profile["fps"]) <= 0, fps > 0 { profile["fps"] = fps }
        if string(profile["codec"], fallback: "").isEmpty {
            let codec = normalizedCodec(string(settings["codec"], fallback: ""))
            if !codec.isEmpty { profile["codec"] = codec }
        }
        if string(profile["audioMode"], fallback: "").isEmpty {
            let audioMode = firstNonEmpty(string(rawSession["audioModeFormat"], fallback: ""), string(settings["audioModeFormat"], fallback: ""), "stereo")
            profile["audioMode"] = audioMode
        }
        if profile["bitDepth"] == nil { profile["bitDepth"] = int(selectedFeatures["bitDepth"]) }
        if profile["chromaFormat"] == nil { profile["chromaFormat"] = int(selectedFeatures["chromaFormat"]) }
        if profile["colorQuality"] == nil {
            profile["colorQuality"] = int(selectedFeatures["bitDepth"]) >= 10 ? "10bit_420" : "8bit_420"
        }
        return profile
    }

    private static func openNOWStreamingProfileGuid(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String) -> String {
        let signature = "\(allocation.session.applicationID)|\(streamingProfileJSON)"
        let key = "OpenNOW.NativeNVST.StreamingProfileGuid.\(stableProfileHash(signature))"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil { return existing.lowercased() }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: key)
        return generated
    }

    private static func stableProfileHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func normalizedConnection(_ source: [String: Any]?) -> [String: Any]? {
        guard let source else { return nil }
        return [
            "usage": int(source["usage"]),
            "ip": string(source["ip"], fallback: ""),
            "port": int(source["port"]),
            "protocol": connectionProtocol(source["protocol"]),
            "resourcePath": string(source["resourcePath"], fallback: ""),
            "appLevelProtocol": int(source["appLevelProtocol"]),
        ]
    }

    private static func connectionProtocol(_ value: Any?) -> Int {
        let numeric = int(value)
        if numeric > 0 { return numeric }
        switch string(value, fallback: "").lowercased() {
        case "tcp": return 1
        case "udp": return 2
        default: return 2
        }
    }

    private static func normalizedMonitorSettings(rawSession: [String: Any], requestData: [String: Any], settings: [String: Any], streamingProfileJSON: String) -> [Any] {
        let rawMonitorSettings = jsonArray(from: rawSession["monitorSettings"])
        if !rawMonitorSettings.isEmpty { return rawMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any]) } }
        let requestMonitorSettings = jsonArray(from: requestData["clientRequestMonitorSettings"])
        if !requestMonitorSettings.isEmpty { return requestMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any]) } }
        let settingsMonitorSettings = jsonArray(from: settings["clientRequestMonitorSettings"])
        if !settingsMonitorSettings.isEmpty { return settingsMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any]) } }
        let profile = jsonObject(from: streamingProfileJSON)
        let selectedMode = profile["selectedVideoMode"] as? [String: Any] ?? [:]
        let selectedFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        return [[
            "monitorId": 0,
            "positionX": 0,
            "positionY": 0,
            "widthInPixels": int(selectedMode["width"]),
            "heightInPixels": int(selectedMode["height"]),
            "framesPerSecond": int(selectedMode["fps"]),
            "sdrHdrMode": bool(selectedFeatures["hdr"]) ? 1 : 0,
            "dpi": int(selectedMode["scaleFactor"]),
            "displayData": defaultDisplayData(),
            "hdr10PlusGamingData": defaultHDR10PlusGamingData(),
        ]]
    }

    private static func normalizedMonitorSetting(_ source: [String: Any]?) -> [String: Any]? {
        guard let source else { return nil }
        return [
            "monitorId": int(source["monitorId"]),
            "positionX": int(source["positionX"]),
            "positionY": int(source["positionY"]),
            "widthInPixels": int(source["widthInPixels"]),
            "heightInPixels": int(source["heightInPixels"]),
            "framesPerSecond": int(source["framesPerSecond"]),
            "sdrHdrMode": int(source["sdrHdrMode"]),
            "dpi": int(source["dpi"]),
            "displayData": normalizedDisplayData(source["displayData"] as? [String: Any]),
            "hdr10PlusGamingData": normalizedHDR10PlusGamingData(source["hdr10PlusGamingData"] as? [String: Any]),
        ]
    }

    private static func normalizedDisplayData(_ source: [String: Any]?) -> [String: Any] {
        var data = defaultDisplayData()
        guard let source else { return data }
        for key in data.keys { data[key] = int(source[key]) }
        return data
    }

    private static func normalizedHDR10PlusGamingData(_ source: [String: Any]?) -> [String: Any] {
        var data = defaultHDR10PlusGamingData()
        guard let source else { return data }
        for key in data.keys { data[key] = int(source[key]) }
        return data
    }

    private static func defaultDisplayData() -> [String: Any] {
        [
            "displayPrimaryX0": 0,
            "displayPrimaryY0": 0,
            "displayPrimaryX1": 0,
            "displayPrimaryY1": 0,
            "displayPrimaryX2": 0,
            "displayPrimaryY2": 0,
            "displayWhitePointX": 0,
            "displayWhitePointY": 0,
        ]
    }

    private static func defaultHDR10PlusGamingData() -> [String: Any] {
        [
            "version": 0,
            "peakLuminanceIndex": 0,
            "peakFullFrameLuminanceIndex": 0,
        ]
    }

    private static func normalizedStreamingFeatures(rawSession: [String: Any], requestData: [String: Any], streamingProfileJSON: String) -> [String: Any] {
        if let features = rawSession["finalizedStreamingFeatures"] as? [String: Any], !features.isEmpty { return features }
        if let features = requestData["requestedStreamingFeatures"] as? [String: Any], !features.isEmpty { return features }
        let profile = jsonObject(from: streamingProfileJSON)
        let selectedFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        return [
            "reflex": bool(selectedFeatures["reflex"]),
            "bitDepth": int(selectedFeatures["bitDepth"]),
            "cloudGsync": bool(selectedFeatures["cloudGsync"]),
            "enabledL4S": bool(selectedFeatures["l4s"]),
            "mouseMovementFlags": int(selectedFeatures["mouseMovementFlags"]),
            "trueHdr": bool(selectedFeatures["trueHdr"]),
            "supportedHidDevices": int(selectedFeatures["supportedHidDevices"]),
            "profile": int(selectedFeatures["profile"]),
            "fallbackToLogicalResolution": bool(selectedFeatures["fallbackToLogicalResolution"]),
            "hidDevices": jsonArray(from: selectedFeatures["hidDevices"]),
            "chromaFormat": int(selectedFeatures["chromaFormat"]),
            "prefilter": int((selectedFeatures["prefilterParams"] as? [String: Any])?["mode"]),
            "denoise": int((selectedFeatures["prefilterParams"] as? [String: Any])?["denoiseLevel"]),
            "sharpen": int((selectedFeatures["prefilterParams"] as? [String: Any])?["sharpnessLevel"]),
            "hudStreamingMode": int((selectedFeatures["hudStreamingParams"] as? [String: Any])?["mode"]),
            "qosPolicy": int(selectedFeatures["qosPolicy"]),
            "touchSupport": bool(selectedFeatures["touchSupport"]),
        ]
    }

    private static func geronimoAppLaunchMode(_ value: Any?) -> Int {
        switch int(value) {
        case 3: return 2
        case 2: return 1
        default: return 0
        }
    }

    private static func signalingHost(sessionInfo: [String: Any], allocation: NativeNVSTSessionAllocation) -> String {
        if let host = URL(string: string(sessionInfo["signalingUrl"], fallback: ""))?.host, !host.isEmpty { return host }
        if let host = URLComponents(string: "wss://\(string(sessionInfo["signalingServer"], fallback: ""))")?.host, !host.isEmpty { return host }
        return firstNonEmpty(allocation.signalingServer.split(separator: ":").first.map(String.init) ?? "", allocation.session.serverAddress)
    }

    private static func signalingPort(sessionInfo: [String: Any], allocation: NativeNVSTSessionAllocation) -> Int {
        if let port = URL(string: string(sessionInfo["signalingUrl"], fallback: ""))?.port { return port }
        if let port = URLComponents(string: "wss://\(string(sessionInfo["signalingServer"], fallback: ""))")?.port { return port }
        let parts = allocation.signalingServer.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let port = Int(parts[1]) { return port }
        return 443
    }

    private static func signalingResourcePath(sessionInfo: [String: Any]) -> String {
        guard let url = URL(string: string(sessionInfo["signalingUrl"], fallback: "")) else { return "/nvst/" }
        return url.path.isEmpty ? "/nvst/" : url.path
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func string(_ value: Any?, fallback: String) -> String {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let string = value as? NSString {
            let trimmed = (string as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }

    private static func int(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if let string = value as? NSString { return Int((string as String).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if let string = value as? NSString { return Double((string as String).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        return 0
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "enabled": return true
            default: return false
            }
        }
        if let string = value as? NSString { return bool(string as String) }
        return false
    }

    private static func bitDepth(from value: Any?, colorQuality: String) -> Int {
        let explicit = int(value)
        if explicit > 0 { return explicit }
        return colorQuality.localizedCaseInsensitiveContains("10") ? 10 : 8
    }

    private static func firstPositiveInt(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            let value = int(nestedValue(in: dictionary, keyPath: key))
            if value > 0 { return value }
        }
        return nil
    }

    private static func firstValue(in primary: [String: Any], _ secondary: [String: Any] = [:], keys: [String]) -> Any? {
        for key in keys {
            if let value = nestedValue(in: primary, keyPath: key), !isEmptyProfileValue(value) { return value }
            if let value = nestedValue(in: secondary, keyPath: key), !isEmptyProfileValue(value) { return value }
        }
        return nil
    }

    private static func nestedValue(in dictionary: [String: Any], keyPath: String) -> Any? {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any? = dictionary
        for part in parts {
            guard let object = current as? [String: Any] else { return nil }
            current = object[part]
        }
        return current
    }

    private static func isEmptyProfileValue(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let string = value as? NSString { return (string as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }

    private static func shouldReplaceProfileValue(_ value: Any?, key: String) -> Bool {
        guard let value else { return true }
        if isEmptyProfileValue(value) { return true }
        return key == "fps" && int(value) <= 0
    }

    private static func normalizedCodec(_ value: String) -> String {
        let codec = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if codec.caseInsensitiveCompare("auto") == .orderedSame { return "H264" }
        return codec
    }

    private static func errorMessage(_ buffer: UnsafePointer<CChar>, fallback: String) -> String {
        let message = String(cString: buffer)
        return message.isEmpty ? fallback : message
    }

    private static func geronimoStartAttributes(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String, geronimoSessionJSON: String) -> [String: String] {
        let payload = NativeNVSTSessionPayload(allocation: allocation)
        let profile = jsonObject(from: streamingProfileJSON)
        let geronimoSession = jsonObject(from: geronimoSessionJSON)
        let geronimoStreamingProfile = geronimoSession["streamingProfile"] as? [String: Any] ?? [:]
        let selectedVideoMode = profile["selectedVideoMode"] as? [String: Any] ?? [:]
        let selectedFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        return [
            "sessionId": allocation.session.id,
            "nativeMissingStartFields": payload.missingStartFields.filter { $0 != "streamingProfile.streamingProfileGuid" || string(geronimoStreamingProfile["streamingProfileGuid"], fallback: "").isEmpty }.joined(separator: ","),
            "nativeHasToken": payload.hasToken ? "true" : "false",
            "nativeTokenType": payload.tokenType,
            "nativeStreamingProfileGuid": firstNonEmpty(string(geronimoStreamingProfile["streamingProfileGuid"], fallback: ""), payload.streamingProfileGUID),
            "profileWidth": String(int(selectedVideoMode["width"])),
            "profileHeight": String(int(selectedVideoMode["height"])),
            "profileFps": String(int(selectedVideoMode["fps"])),
            "profileScaleFactor": String(int(selectedVideoMode["scaleFactor"])),
            "profileHdr": bool(selectedFeatures["hdr"]) ? "true" : "false",
            "profileBitDepth": String(int(selectedFeatures["bitDepth"])),
            "geronimoSessionBytes": String(geronimoSessionJSON.utf8.count),
            "geronimoMonitorSettings": String(jsonArray(from: geronimoSession["monitorSettings"]).count),
            "geronimoConnectionInfo": String(jsonArray(from: geronimoSession["connectionInfo"]).count),
            "geronimoAppId": String(int(geronimoSession["appId"])),
        ]
    }

    private func signalingHost(_ allocation: NativeNVSTSessionAllocation) -> String {
        if let host = URL(string: allocation.signalingURL)?.host, !host.isEmpty { return host }
        if let host = URLComponents(string: "wss://\(allocation.signalingServer)")?.host, !host.isEmpty { return host }
        if !allocation.signalingServer.isEmpty { return allocation.signalingServer }
        return allocation.session.serverAddress
    }

    private func signalingPort(_ allocation: NativeNVSTSessionAllocation) -> UInt16 {
        if let url = URL(string: allocation.signalingURL), let port = url.port, let exactPort = UInt16(exactly: port) {
            return exactPort
        }
        if let port = URLComponents(string: "wss://\(allocation.signalingServer)")?.port, let exactPort = UInt16(exactly: port) {
            return exactPort
        }
        if let scheme = URL(string: allocation.signalingURL)?.scheme?.lowercased(), scheme == "http" { return 80 }
        return 443
    }
}

private final class NativeNVSTGeronimoEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionId: String
    private let telemetryAttributes: [String: String]
    private var resolvedResult: Result<Void, Error>?
    private var completion: CheckedContinuation<Void, Error>?

    init(sessionId: String, telemetryAttributes: [String: String]) {
        self.sessionId = sessionId
        self.telemetryAttributes = telemetryAttributes
    }

    func handle(phase: Int32, callbackType: UInt32, clientEvent: UInt32, notification: UInt32, resultCode: Int32) {
        var attributes = telemetryAttributes
        attributes["sessionId"] = sessionId
        attributes["phase"] = String(phase)
        attributes["callbackType"] = String(callbackType)
        attributes["clientEvent"] = String(clientEvent)
        attributes["notification"] = String(notification)
        attributes["resultCode"] = String(resultCode)
        WebRTCMediaTelemetry.capture("nvst.geronimo.callback", level: .info, message: "Geronimo native callback observed.", attributes: attributes)

        if callbackType == 2, clientEvent == 14, notification == 1 {
            resolve(.success(()))
            return
        }
        if callbackType == 2, clientEvent == 14, (50...200).contains(notification) {
            resolve(.failure(NativeNVSTError.transportFailed("Native NVST streaming ended before Geronimo reported readiness.")))
            return
        }
        if phase == 60 {
            resolve(.failure(NativeNVSTError.transportFailed("Native NVST stopped before Geronimo reported readiness.")))
        }
    }

    func waitForStreamerConnected(timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let resolvedResult {
                lock.unlock()
                continuation.resume(with: resolvedResult)
                return
            }
            completion = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.resolve(.failure(NativeNVSTError.transportFailed(NativeNVSTBifrostTransport.geronimoStartFailureMessage)))
            }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if resolvedResult != nil {
            lock.unlock()
            return
        }
        resolvedResult = result
        continuation = completion
        completion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func nativeNVSTGeronimoEventCallback(_ context: UnsafeMutableRawPointer?, _ phase: Int32, _ callbackType: UInt32, _ clientEvent: UInt32, _ notification: UInt32, _ resultCode: Int32) {
    guard let context else { return }
    let sink = Unmanaged<NativeNVSTGeronimoEventSink>.fromOpaque(context).takeUnretainedValue()
    sink.handle(phase: phase, callbackType: callbackType, clientEvent: clientEvent, notification: notification, resultCode: resultCode)
}

private typealias NativeNVSTGeronimoEventHandler = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32, UInt32, Int32) -> Void

@_silgen_name("OpenNOWNativeNVSTGeronimoCreate")
private func OpenNOWNativeNVSTGeronimoCreate(_ frameworksPath: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> UnsafeMutableRawPointer?

@_silgen_name("OpenNOWNativeNVSTGeronimoSetEventHandler")
private func OpenNOWNativeNVSTGeronimoSetEventHandler(_ session: UnsafeMutableRawPointer?, _ eventHandler: NativeNVSTGeronimoEventHandler?, _ eventContext: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSetVideoSurface")
private func OpenNOWNativeNVSTGeronimoSetVideoSurface(_ session: UnsafeMutableRawPointer?, _ nativeHandle: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoStart")
private func OpenNOWNativeNVSTGeronimoStart(_ session: UnsafeMutableRawPointer?, _ rawSessionJSON: UnsafePointer<CChar>?, _ streamingProfileJSON: UnsafePointer<CChar>?, _ cloudSessionJSON: UnsafePointer<CChar>?, _ gameLanguage: UnsafePointer<CChar>?, _ clientAppVersion: UnsafePointer<CChar>?, _ clientLocale: UnsafePointer<CChar>?, _ traceParent: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoPause")
private func OpenNOWNativeNVSTGeronimoPause(_ session: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSendInput")
private func OpenNOWNativeNVSTGeronimoSendInput(_ session: UnsafeMutableRawPointer?, _ inputEventBytes: UnsafePointer<UInt8>?, _ inputEventByteCount: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoStopWithResult")
private func OpenNOWNativeNVSTGeronimoStopWithResult(_ session: UnsafeMutableRawPointer?, _ reason: UnsafePointer<CChar>?, _ code: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoDestroy")
private func OpenNOWNativeNVSTGeronimoDestroy(_ session: UnsafeMutableRawPointer?)
