import AVFoundation
import Foundation

public actor NativeNVSTBifrostTransport: NativeNVSTTransport {
    static let geronimoPumpFramesPerSecond = 60.0
    static let geronimoPumpInterval = 1.0 / geronimoPumpFramesPerSecond
    static let geronimoPumpRunLoopMode = RunLoop.Mode.default

    static let geronimoStartFailureMessage = "Native NVST streaming did not reach Geronimo readiness. Open diagnostics for the native phase and sanitized error."

    static func geronimoCallbackFailureMessage(resultCode: Int32, resultName: String?) -> String {
        if resultName == "NVB_R_SESSION_LIMIT_REACHED" {
            return "GeForce NOW refused the stream because the active session limit was reached. End another session and try again."
        }
        if let resultName, !resultName.isEmpty {
            return "Native NVST callback reported \(resultName) (\(resultCode))."
        }
        return "Native NVST callback reported failure \(resultCode)."
    }

    static func geronimoCallbackError(resultCode: Int32, resultName: String?) -> NativeNVSTError {
        if resultName == "NVB_R_SESSION_LIMIT_REACHED" { return .sessionLimitReached }
        return .transportFailed(geronimoCallbackFailureMessage(resultCode: resultCode, resultName: resultName))
    }

    private let bridgeConfiguration: NVSTNativeBridgeConfiguration
    private let inputEncoder: NativeNVSTInputEncoder
    private let nativeVideoSurfaceHandle: UInt?
    private let cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var prepareVideoSurfaceForShutdown: (@MainActor @Sendable () -> Void)?
    private let terminationChannel = NativeNVSTTerminationChannel()
    private var bridge: NVSTNativeBridge?
    private var activeConnection: NativeNVSTTransportConnection?
    private var connectingAttemptID: UUID?
    private var connectingEventSink: NativeNVSTGeronimoEventSink?
    private var geronimoSessionAddress: UInt?
    private var geronimoEventSink: NativeNVSTGeronimoEventSink?
    private var geronimoPump: NativeNVSTGeronimoPumpDriver?

    public init(bridgeConfiguration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration(),
                inputEncoder: NativeNVSTInputEncoder = NativeNVSTInputEncoder(),
                nativeVideoSurfaceHandle: UInt? = nil,
                cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)? = nil,
                prepareVideoSurfaceForShutdown: (@MainActor @Sendable () -> Void)? = nil) {
        self.bridgeConfiguration = bridgeConfiguration
        self.inputEncoder = inputEncoder
        self.nativeVideoSurfaceHandle = nativeVideoSurfaceHandle
        self.cursorVisibilityHandler = cursorVisibilityHandler
        self.prepareVideoSurfaceForShutdown = prepareVideoSurfaceForShutdown
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
        guard activeConnection == nil, connectingAttemptID == nil else { throw NativeNVSTError.alreadyRunning }
        let attemptID = UUID()
        connectingAttemptID = attemptID
        defer {
            if connectingAttemptID == attemptID {
                connectingAttemptID = nil
                connectingEventSink = nil
            }
        }
        terminationChannel.reset()
        let status: NVSTNativeBridgeStatus
        do {
            status = try await prepare()
        } catch {
            if connectingAttemptID == attemptID { connectingAttemptID = nil }
            throw error
        }
        guard connectingAttemptID == attemptID, !Task.isCancelled else {
            if connectingAttemptID == attemptID { connectingAttemptID = nil }
            throw CancellationError()
        }
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
        let eventSink = NativeNVSTGeronimoEventSink(
            sessionId: allocation.session.id,
            telemetryAttributes: ["sessionId": allocation.session.id],
            cursorVisibilityHandler: cursorVisibilityHandler,
            terminationHandler: { [terminationChannel] termination in terminationChannel.send(termination) }
        )
        connectingEventSink = eventSink
        let started: (connection: NativeNVSTTransportConnection, sessionAddress: UInt, pump: NativeNVSTGeronimoPumpDriver)
        do {
            started = try await withTaskCancellationHandler {
                try await Self.startGeronimoOnMainActor(
                    allocation: allocation,
                    status: status,
                    nativeVideoSurfaceHandle: nativeVideoSurfaceHandle,
                    eventSink: eventSink
                )
            } onCancel: {
                eventSink.cancel()
            }
        } catch {
            if connectingAttemptID == attemptID {
                connectingAttemptID = nil
                connectingEventSink = nil
            }
            throw error
        }
        guard connectingAttemptID == attemptID, !Task.isCancelled else {
            await started.pump.stop()
            await Self.destroyGeronimoOnMainActor(sessionAddress: started.sessionAddress)
            if connectingAttemptID == attemptID {
                connectingAttemptID = nil
                connectingEventSink = nil
            }
            throw CancellationError()
        }
        let connection = started.connection
        connectingAttemptID = nil
        connectingEventSink = nil
        geronimoSessionAddress = started.sessionAddress
        geronimoEventSink = eventSink
        geronimoPump = started.pump
        activeConnection = connection
        return connection
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeConnection != nil else { throw NativeNVSTError.notRunning }
        guard let encoded = inputEncoder.encode(event) else { return }
        guard let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try Self.sendGeronimoInput(sessionAddress: sessionAddress, encoded: encoded)
    }

    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard activeConnection != nil, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try Self.sendGeronimoAbsoluteMouse(sessionAddress: sessionAddress, event: event)
    }

    public func togglePerformanceOverlay() async throws {
        guard activeConnection != nil, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.toggleGeronimoPerformanceOverlayOnMainActor(sessionAddress: sessionAddress)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard activeConnection != nil, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.setGeronimoMicrophoneEnabledOnMainActor(enabled, sessionAddress: sessionAddress)
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard activeConnection != nil, let sessionAddress = geronimoSessionAddress else { return nil }
        return Self.copyGeronimoPerformanceSnapshot(sessionAddress: sessionAddress)
    }

    public func disconnect() async {
        connectingAttemptID = nil
        connectingEventSink?.cancel()
        connectingEventSink = nil
        let pump = geronimoPump
        let sessionAddress = geronimoSessionAddress
        let eventSink = geronimoEventSink
        geronimoPump = nil
        geronimoSessionAddress = nil
        geronimoEventSink = nil
        activeConnection = nil
        if sessionAddress != nil {
            await prepareGeronimoVideoSurfaceForShutdown()
        } else {
            prepareVideoSurfaceForShutdown = nil
        }
        if let sessionAddress, let eventSink {
            if !eventSink.hasDeliveredTerminal {
                eventSink.beginStop()
                let stopResult = await Self.stopGeronimoOnMainActor(sessionAddress: sessionAddress)
                if stopResult == 0 {
                    try? await eventSink.waitForStop(timeoutNanoseconds: 3_000_000_000)
                } else {
                    eventSink.cancelStop()
                }
            }
        }
        if let pump { await pump.stop() }
        if let sessionAddress {
            await Self.destroyGeronimoOnMainActor(sessionAddress: sessionAddress)
        }
    }

    public func pause() async throws {
        guard let sessionAddress = geronimoSessionAddress,
              let eventSink = geronimoEventSink else { throw NativeNVSTError.notRunning }
        eventSink.beginPause()
        do {
            try await Self.requestPauseGeronimoOnMainActor(sessionAddress: sessionAddress)
            try await eventSink.waitForPause(timeoutNanoseconds: 5_000_000_000)
        } catch {
            eventSink.cancelPause()
            throw error
        }
        guard geronimoSessionAddress == sessionAddress else { throw CancellationError() }
        let pump = geronimoPump
        geronimoPump = nil
        geronimoSessionAddress = nil
        geronimoEventSink = nil
        activeConnection = nil
        await prepareGeronimoVideoSurfaceForShutdown()
        if let pump { await pump.stop() }
        await Self.destroyGeronimoOnMainActor(sessionAddress: sessionAddress)
    }

    public func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        terminationChannel.stream()
    }

    private func prepareGeronimoVideoSurfaceForShutdown() async {
        guard let prepareVideoSurfaceForShutdown else { return }
        self.prepareVideoSurfaceForShutdown = nil
        await prepareVideoSurfaceForShutdown()
    }

    @MainActor private static func startGeronimoOnMainActor(allocation: NativeNVSTSessionAllocation, status: NVSTNativeBridgeStatus, nativeVideoSurfaceHandle: UInt?, eventSink: NativeNVSTGeronimoEventSink) async throws -> (connection: NativeNVSTTransportConnection, sessionAddress: UInt, pump: NativeNVSTGeronimoPumpDriver) {
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
        let microphoneMode = Self.string(settings["microphoneMode"], fallback: "disabled")
        let microphoneRequested = microphoneMode.caseInsensitiveCompare("disabled") != .orderedSame
        let microphoneAvailable = await Self.resolveMicrophoneCaptureAccess(requested: microphoneRequested)
        let microphoneEnabled = microphoneAvailable && (Self.bool(settings["microphoneEnabled"]) || microphoneMode.caseInsensitiveCompare("voice-activity") == .orderedSame)
        startAttributes["operation"] = allocation.isResume ? "resume" : "start"
        startAttributes["microphoneRequested"] = String(microphoneRequested)
        startAttributes["microphoneAvailable"] = String(microphoneAvailable)
        startAttributes["microphoneEnabled"] = String(microphoneEnabled)
        startAttributes["videoSurfaceType"] = "NSWindow"
        WebRTCMediaTelemetry.capture("nvst.geronimo.start.prepare", level: .info, message: allocation.isResume ? "Preparing Geronimo native NVST resume request." : "Preparing Geronimo native NVST start request.", attributes: startAttributes)
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
        eventSink.updateTelemetryAttributes(startAttributes)
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
        guard let nativeVideoSurfaceHandle, let nativeVideoSurface = UnsafeMutableRawPointer(bitPattern: nativeVideoSurfaceHandle) else {
            let message = "Native Geronimo requires an AppKit video surface."
            WebRTCMediaTelemetry.capture("nvst.geronimo.video_surface.failed", level: .error, message: message, attributes: startAttributes)
            OpenNOWNativeNVSTGeronimoDestroy(session)
            throw NativeNVSTError.privateABIUnavailable(message)
        }
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
        var pump: NativeNVSTGeronimoPumpDriver?
        do {
            let result = geronimoSessionJSON.withCString { rawSessionPointer in
                streamingProfileJSON.withCString { profilePointer in
                    gameLanguage.withCString { languagePointer in
                        clientVersion.withCString { versionPointer in
                            gameLanguage.withCString { localePointer in
                                launchPayload.prepare.traceParent.withCString { traceParentPointer in
                                    allocation.authTokenType.withCString { authTokenTypePointer in
                                        allocation.authToken.withCString { authTokenPointer in
                                            allocation.rawSessionJSON.withCString { cloudSessionPointer in
                                                if allocation.isResume {
                                                    OpenNOWNativeNVSTGeronimoResume(session, rawSessionPointer, profilePointer, cloudSessionPointer, languagePointer, versionPointer, localePointer, traceParentPointer, authTokenTypePointer, authTokenPointer, microphoneAvailable ? 1 : 0, microphoneEnabled ? 1 : 0, errorBuffer, 1024)
                                                } else {
                                                    OpenNOWNativeNVSTGeronimoStart(session, rawSessionPointer, profilePointer, cloudSessionPointer, languagePointer, versionPointer, localePointer, traceParentPointer, authTokenTypePointer, authTokenPointer, microphoneAvailable ? 1 : 0, microphoneEnabled ? 1 : 0, errorBuffer, 1024)
                                                }
                                            }
                                        }
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
            WebRTCMediaTelemetry.capture("nvst.geronimo.start.accepted", level: .info, message: "Geronimo accepted native NVST start request; waiting for native start delivery.", attributes: attributes)
            let activePump = NativeNVSTGeronimoPumpDriver(sessionAddress: sessionAddress, eventSink: eventSink, telemetryAttributes: attributes)
            activePump.start()
            pump = activePump
            do {
                try await eventSink.waitForStartDelivered(timeoutNanoseconds: 30_000_000_000)
                WebRTCMediaTelemetry.capture("nvst.geronimo.start.delivered", level: .info, message: "Geronimo delivered native NVST start; waiting for StreamerConnected callback.", attributes: attributes)
                try await eventSink.waitForStreamerConnected(timeoutNanoseconds: 20_000_000_000)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var failureAttributes = attributes
                failureAttributes.merge(eventSink.readinessDiagnosticAttributes()) { _, new in new }
                let localizedMessage = (error as? LocalizedError)?.errorDescription
                failureAttributes["error"] = localizedMessage?.isEmpty == false ? localizedMessage : error.localizedDescription
                WebRTCMediaTelemetry.capture("nvst.geronimo.readiness.failed", level: .error, message: "Geronimo did not reach native NVST readiness.", attributes: failureAttributes)
                throw error
            }
            WebRTCMediaTelemetry.capture("nvst.geronimo.stream.connected", level: .info, message: "Geronimo reported StreamerConnected for native NVST.", attributes: attributes)
            return (NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: status), sessionAddress, activePump)
        } catch {
            pump?.stop()
            OpenNOWNativeNVSTGeronimoDestroy(session)
            throw error
        }
    }

    @MainActor private static func destroyGeronimoOnMainActor(sessionAddress: UInt) {
        OpenNOWNativeNVSTGeronimoDestroy(UnsafeMutableRawPointer(bitPattern: sessionAddress))
    }

    @MainActor private static func resolveMicrophoneCaptureAccess(requested: Bool) async -> Bool {
        if let resolvedAccess = microphoneCaptureAccess(requested: requested, authorizationStatus: AVCaptureDevice.authorizationStatus(for: .audio)) {
            return resolvedAccess
        }
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func microphoneCaptureAccess(requested: Bool, authorizationStatus: AVAuthorizationStatus) -> Bool? {
        guard requested else { return false }
        switch authorizationStatus {
        case .authorized: return true
        case .notDetermined: return nil
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    @MainActor private static func requestPauseGeronimoOnMainActor(sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = OpenNOWNativeNVSTGeronimoPause(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "Native Geronimo pause failed with result \(result)."))
        }
    }

    @MainActor private static func toggleGeronimoPerformanceOverlayOnMainActor(sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = OpenNOWNativeNVSTGeronimoTogglePerformanceOverlay(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo performance overlay failed with result \(result)."))
        }
    }

    @MainActor private static func setGeronimoMicrophoneEnabledOnMainActor(_ enabled: Bool, sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = OpenNOWNativeNVSTGeronimoSetMicrophoneEnabled(UnsafeMutableRawPointer(bitPattern: sessionAddress), enabled ? 1 : 0, errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "Native Geronimo microphone update failed with result \(result)."))
        }
    }

    private static func copyGeronimoPerformanceSnapshot(sessionAddress: UInt) -> NativeNVSTPerformanceSnapshot? {
        var nativeStatsBytes = [UInt8](repeating: 0, count: NativeNVSTGeronimoPerformanceStats.byteCount)
        var serverLocation = [CChar](repeating: 0, count: 128)
        let result = nativeStatsBytes.withUnsafeMutableBytes { statsBuffer in
            serverLocation.withUnsafeMutableBufferPointer { locationBuffer in
                OpenNOWNativeNVSTGeronimoCopyPerformanceStats(
                    UnsafeMutableRawPointer(bitPattern: sessionAddress),
                    statsBuffer.baseAddress,
                    statsBuffer.count,
                    locationBuffer.baseAddress,
                    locationBuffer.count,
                    nil,
                    0
                )
            }
        }
        guard result == 0, let nativeStats = NativeNVSTGeronimoPerformanceStats(bytes: nativeStatsBytes) else { return nil }
        let resolution: String
        if nativeStats.frameWidth > 0, nativeStats.frameHeight > 0 {
            resolution = "\(nativeStats.frameWidth)x\(nativeStats.frameHeight)"
        } else {
            resolution = ""
        }
        let resolvedServerLocation = serverLocation.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return "" }
            return String(cString: baseAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return NativeNVSTPerformanceSnapshot(
            available: nativeStats.available != 0,
            gameFramesPerSecond: nativeStats.gameFramesPerSecond,
            streamFramesPerSecond: Double(nativeStats.streamFramesPerSecond),
            latencyMilliseconds: nativeStats.latencyMilliseconds,
            jitterMilliseconds: nativeStats.jitterMilliseconds,
            frameLoss: UInt64(nativeStats.frameLoss),
            totalFrameLoss: UInt64(nativeStats.totalFrameLoss),
            packetLoss: UInt64(nativeStats.packetLoss),
            totalPacketLoss: UInt64(nativeStats.totalPacketLoss),
            bitrateMegabitsPerSecond: nativeStats.bitrateMegabitsPerSecond,
            bandwidthUtilizationPercent: nativeStats.bandwidthUtilizationPercent,
            resolution: resolution,
            codec: nativeCodecName(nativeStats.codec),
            serverLocation: resolvedServerLocation
        )
    }

    private static func nativeCodecName(_ codec: UInt32) -> String {
        switch codec {
        case 1: "H264"
        case 2: "H265"
        case 4: "AV1"
        default: ""
        }
    }

    @MainActor private static func stopGeronimoOnMainActor(sessionAddress: UInt) -> Int32 {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        return "OpenNOW native NVST disconnect".withCString { reason in
            OpenNOWNativeNVSTGeronimoStopWithResult(UnsafeMutableRawPointer(bitPattern: sessionAddress), reason, 0, errorBuffer, 1024)
        }
    }

    private static func sendGeronimoInput(sessionAddress: UInt, encoded: NativeNVSTEncodedInputEvent) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result: Int32
        switch encoded.nativePayload {
        case .event(let payload):
            result = payload.withUnsafeBytes { buffer in
                OpenNOWNativeNVSTGeronimoSendInput(UnsafeMutableRawPointer(bitPattern: sessionAddress), buffer.bindMemory(to: UInt8.self).baseAddress, payload.count, errorBuffer, 1024)
            }
        case .text(let payload):
            result = payload.withUnsafeBytes { buffer in
                OpenNOWNativeNVSTGeronimoSendText(UnsafeMutableRawPointer(bitPattern: sessionAddress), buffer.bindMemory(to: UInt8.self).baseAddress, payload.count, errorBuffer, 1024)
            }
        }
        guard result == 0 else {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo input send failed with result \(result)."))
        }
    }

    private static func sendGeronimoAbsoluteMouse(sessionAddress: UInt, event: NativeNVSTAbsoluteMouseEvent) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = OpenNOWNativeNVSTGeronimoSendAbsoluteMouse(
            UnsafeMutableRawPointer(bitPattern: sessionAddress),
            event.x,
            event.y,
            event.timestamp.nanoseconds,
            errorBuffer,
            1024
        )
        if result != 0 {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo absolute mouse input failed with result \(result)."))
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
        return geronimoModeSelectionJSON(string)
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
        let networkSessionId = firstNonEmpty(string(rawSession["networkSessionId"], fallback: ""), string(requestData["networkSessionId"], fallback: ""), sessionId)
        let bifrostSessionId = firstNonEmpty(string(rawSession["bifrostSessionId"], fallback: ""), string(rawSession["session"], fallback: ""), sessionId)
        let deviceId = firstNonEmpty(string(requestData["deviceHashId"], fallback: ""), string(rawSession["deviceId"], fallback: ""), OPNDeviceIdentity.stableCloudmatchDeviceId())
        let serverAddress = firstNonEmpty(string(rawSession["serverAddress"], fallback: ""), zoneAddress)
        let rawServerPort = int(rawSession["port"])
        let serverPort = int(sessionControlInfo["port"]) > 0 ? int(sessionControlInfo["port"]) : (rawServerPort > 0 ? rawServerPort : 443)
        let applicationHeaders = jsonArray(from: rawSession["applicationHeaders"]).isEmpty ? jsonArray(from: requestData["applicationHeaders"]) : jsonArray(from: rawSession["applicationHeaders"])
        let supportedControls = jsonArray(from: rawSession["supportedControls"]).isEmpty ? jsonArray(from: requestData["supportedControls"]) : jsonArray(from: rawSession["supportedControls"])
        let contentRating = jsonArray(from: rawSession["contentRating"]).isEmpty ? jsonArray(from: requestData["contentRating"]) : jsonArray(from: rawSession["contentRating"])
        let metadata = requestData["metaData"] as? [String: Any] ?? rawSession["metaData"] as? [String: Any] ?? [:]
        let summaryStatsValue = firstValue(in: rawSession, requestData, keys: ["summaryStatsEnabled"])
        let rawFrameLossWarningTimeout = int(firstValue(in: rawSession, requestData, keys: ["frameLossWarningTimeout"]))
        let rawFrameLossErrorTimeout = int(firstValue(in: rawSession, requestData, keys: ["frameLossErrorTimeout"]))
        var normalized: [String: Any] = [
            "sessionId": sessionId,
            "bifrostSessionId": bifrostSessionId,
            "networkSessionId": networkSessionId,
            "subSessionId": string(rawSession["subSessionId"], fallback: ""),
            "address": serverAddress,
            "serverAddress": serverAddress,
            "port": serverPort,
            "appId": int(requestData["appId"]) > 0 ? int(requestData["appId"]) : int(rawSession["appId"]),
            "appName": firstNonEmpty(string(requestData["appName"], fallback: ""), string(rawSession["appName"], fallback: ""), allocation.session.title),
            "appLaunchMode": geronimoAppLaunchMode(firstValue(in: requestData, rawSession, keys: ["appLaunchMode"])),
            "serverType": allocation.serverType > 0 ? allocation.serverType : (int(rawSession["serverType"]) > 0 ? int(rawSession["serverType"]) : int(requestData["serverType"])),
            "state": int(rawSession["state"]) > 0 ? int(rawSession["state"]) : int(rawSession["status"]),
            "frameStatsEnabled": bool(firstValue(in: rawSession, requestData, keys: ["frameStatsEnabled"])),
            "summaryStatsEnabled": summaryStatsValue == nil ? true : bool(summaryStatsValue),
            "zoneAddress": zoneAddress,
            "zoneName": zoneName,
            "deviceId": deviceId,
            "gpuType": string(rawSession["gpuType"], fallback: ""),
            "gameShortName": firstNonEmpty(string(requestData["gameShortName"], fallback: ""), string(rawSession["gameShortName"], fallback: "")),
            "maxLocalPlayers": max(int(firstValue(in: requestData, rawSession, keys: ["maxLocalPlayers"])), 1),
            "advancedLatencyOptimization": bool(firstValue(in: requestData, rawSession, keys: ["advancedLatencyOptimization"])),
            "streamingProfile": streamingProfile,
            "monitorSettings": monitorSettings,
            "connectionInfo": connectionInfo,
            "finalizedStreamingFeatures": normalizedStreamingFeatures(rawSession: rawSession, requestData: requestData, streamingProfileJSON: streamingProfileJSON),
            "metaData": metadata,
            "frameLossWarningTimeout": rawFrameLossWarningTimeout > 0 ? rawFrameLossWarningTimeout : 500,
            "frameLossErrorTimeout": rawFrameLossErrorTimeout > 0 ? rawFrameLossErrorTimeout : 30_000,
            "resumeType": int(rawSession["resumeType"]),
            "keyboardLayout": string(settings["keyboardLayout"], fallback: ""),
            "locale": firstNonEmpty(string(settings["gameLanguage"], fallback: ""), string(rawSession["locale"], fallback: "")),
            "digitalStore": firstNonEmpty(string(rawSession["digitalStore"], fallback: ""), string(requestData["digitalStore"], fallback: "")),
            "audioModeFormat": firstNonEmpty(string(rawSession["audioModeFormat"], fallback: ""), string(requestData["audioModeFormat"], fallback: ""), string(settings["audioModeFormat"], fallback: ""), "stereo"),
            "networkPacketCaptureEnabled": bool(firstValue(in: rawSession, requestData, keys: ["networkPacketCaptureEnabled"])),
            "partnerCustomData": firstNonEmpty(string(rawSession["partnerCustomData"], fallback: ""), string(requestData["partnerCustomData"], fallback: "")),
            "allowKeyboardLayoutChange": bool(firstValue(in: rawSession, requestData, settings, keys: ["allowKeyboardLayoutChange"])),
            "accountLinked": bool(firstValue(in: rawSession, requestData, settings, keys: ["accountLinked"])),
            "persistingInGameSettings": bool(firstValue(in: rawSession, requestData, settings, keys: ["persistingInGameSettings"])),
            "supportedControls": supportedControls,
            "contentRating": contentRating,
            "heroImage": firstNonEmpty(string(rawSession["heroImage"], fallback: ""), string(requestData["heroImage"], fallback: "")),
            "gameDisplayOwnRating": bool(firstValue(in: rawSession, requestData, keys: ["gameDisplayOwnRating"])),
            "storeName": firstNonEmpty(string(rawSession["storeName"], fallback: ""), string(requestData["storeName"], fallback: "")),
            "subscriptionLongDesc": firstNonEmpty(string(rawSession["subscriptionLongDesc"], fallback: ""), string(requestData["subscriptionLongDesc"], fallback: "")),
            "providerName": firstNonEmpty(string(rawSession["providerName"], fallback: ""), string(requestData["providerName"], fallback: ""), "NVIDIA"),
            "userAge": int(rawSession["userAge"]) > 0 ? int(rawSession["userAge"]) : int(requestData["userAge"]),
            "serverLocation": firstNonEmpty(string(rawSession["serverLocation"], fallback: ""), string(requestData["serverLocation"], fallback: ""), zoneName),
            "gpuNameMap": firstValue(in: rawSession, requestData, keys: ["gpuNameMap"]) ?? [:],
            "streamingDisplayDataInfo": firstValue(in: requestData, rawSession, keys: ["streamingDisplayDataInfo"]) ?? [:],
            "currentPhysicalResolution": firstValue(in: requestData, rawSession, sessionInfo, keys: ["currentPhysicalResolution"]) ?? [:],
            "spanData": firstValue(in: requestData, rawSession, keys: ["spanData"]) ?? [:],
            "applicationHeaders": applicationHeaders,
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

    private static func geronimoModeSelectionJSON(_ json: String) -> String {
        let pattern = "(\\\"(?:denoiseLevel|scxQpDelta)\\\"\\s*:\\s*)(-?\\d+)([},])"
        return json.replacingOccurrences(of: pattern, with: "$1$2.0$3", options: .regularExpression)
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

    private static func firstValue(in dictionaries: [String: Any]..., keys: [String]) -> Any? {
        for key in keys {
            for dictionary in dictionaries {
                if let value = nestedValue(in: dictionary, keyPath: key), !isEmptyProfileValue(value) { return value }
            }
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

@MainActor
private final class NativeNVSTGeronimoPumpDriver {
    private let sessionAddress: UInt
    private let eventSink: NativeNVSTGeronimoEventSink
    private let telemetryAttributes: [String: String]
    private var errorBuffer = [CChar](repeating: 0, count: 1024)
    private var timer: Timer?
    private var isRunning = false

    init(sessionAddress: UInt, eventSink: NativeNVSTGeronimoEventSink, telemetryAttributes: [String: String]) {
        self.sessionAddress = sessionAddress
        self.eventSink = eventSink
        self.telemetryAttributes = telemetryAttributes
    }

    isolated deinit {
        timer?.invalidate()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        pumpOnce()
        guard isRunning else { return }
        let interval = NativeNVSTBifrostTransport.geronimoPumpInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpOnce() }
        }
        timer.tolerance = interval * 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: NativeNVSTBifrostTransport.geronimoPumpRunLoopMode)
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func pumpOnce() {
        guard isRunning else { return }
        let result = errorBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            baseAddress.pointee = 0
            return OpenNOWNativeNVSTGeronimoPump(UnsafeMutableRawPointer(bitPattern: sessionAddress), 0, baseAddress, buffer.count)
        }
        guard result != 0 else { return }
        stop()
        guard result < 0 else { return }
        let message = errorBuffer.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return "Native Geronimo event pump failed with result \(result)." }
            let value = String(cString: baseAddress)
            return value.isEmpty ? "Native Geronimo event pump failed with result \(result)." : value
        }
        var attributes = telemetryAttributes
        attributes["result"] = String(result)
        attributes["error"] = message
        WebRTCMediaTelemetry.capture("nvst.geronimo.pump.failed", level: .error, message: message, attributes: attributes)
        eventSink.fail(NativeNVSTError.transportFailed(message))
    }
}

private final class NativeNVSTTerminationChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<NativeNVSTTransportTermination>.Continuation] = [:]
    private var pending: NativeNVSTTransportTermination?

    func stream() -> AsyncStream<NativeNVSTTransportTermination> {
        let id = UUID()
        let pair = AsyncStream<NativeNVSTTransportTermination>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pending: NativeNVSTTransportTermination?
        lock.lock()
        continuations[id] = pair.continuation
        pending = self.pending
        lock.unlock()
        if let pending { pair.continuation.yield(pending) }
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return pair.stream
    }

    func send(_ termination: NativeNVSTTransportTermination) {
        let continuations: [AsyncStream<NativeNVSTTransportTermination>.Continuation]
        lock.lock()
        pending = termination
        continuations = Array(self.continuations.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield(termination)
        }
    }

    func reset() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

private final class NativeNVSTGeronimoEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionId: String
    private let terminationHandler: @Sendable (NativeNVSTTransportTermination) -> Void
    private let cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private var telemetryAttributes: [String: String]
    private var startResult: Result<Void, Error>?
    private var startCompletion: CheckedContinuation<Void, Error>?
    private var readinessResult: Result<Void, Error>?
    private var readinessCompletion: CheckedContinuation<Void, Error>?
    private var pausePending = false
    private var pauseResult: Result<Void, Error>?
    private var pauseCompletion: CheckedContinuation<Void, Error>?
    private var stopPending = false
    private var stopResult: Result<Void, Error>?
    private var stopCompletion: CheckedContinuation<Void, Error>?
    private var terminalDelivered = false
    private var observedPhases: Set<Int32> = []
    private var lastPhase: Int32?
    private var lastCallbackType: UInt32?
    private var lastClientEvent: UInt32?
    private var lastNotification: UInt32?
    private var lastResultCode: Int32?

    init(sessionId: String,
         telemetryAttributes: [String: String],
         cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?,
         terminationHandler: @escaping @Sendable (NativeNVSTTransportTermination) -> Void) {
        self.sessionId = sessionId
        self.telemetryAttributes = telemetryAttributes
        self.cursorVisibilityHandler = cursorVisibilityHandler
        self.terminationHandler = terminationHandler
    }

    func updateTelemetryAttributes(_ attributes: [String: String]) {
        lock.lock()
        telemetryAttributes.merge(attributes) { _, new in new }
        lock.unlock()
    }

    func handle(phase: Int32, callbackType: UInt32, clientEvent: UInt32, notification: UInt32, resultCode: Int32, resultName: String?) {
        lock.lock()
        observedPhases.insert(phase)
        lastPhase = phase
        lastCallbackType = callbackType
        lastClientEvent = clientEvent
        lastNotification = notification
        lastResultCode = resultCode
        var attributes = telemetryAttributes
        let pausePending = self.pausePending
        lock.unlock()
        attributes["sessionId"] = sessionId
        attributes["phase"] = String(phase)
        attributes["callbackType"] = String(callbackType)
        attributes["clientEvent"] = String(clientEvent)
        attributes["notification"] = String(notification)
        attributes["resultCode"] = String(resultCode)
        if let resultName, !resultName.isEmpty { attributes["resultName"] = resultName }
        WebRTCMediaTelemetry.capture("nvst.geronimo.callback", level: .info, message: "Geronimo native callback observed.", attributes: attributes)

        if phase == 80, notification == 1 || notification == 2 {
            let visible = notification == 1
            Task { @MainActor [cursorVisibilityHandler] in cursorVisibilityHandler?(visible) }
            return
        }

        if phase == 40 {
            resolveStart(.success(()))
        }
        if callbackType == 2, clientEvent == 14, notification == 1 {
            resolveReadiness(.success(()))
            return
        }
        if callbackType == 2, clientEvent == 14, (50...200).contains(notification) {
            let message = "Native NVST streaming ended with notification \(notification)."
            let error = NativeNVSTError.transportFailed(message)
            let wasReady = hasReachedReadiness
            resolveStart(.failure(error))
            resolveReadiness(.failure(error))
            resolvePause(.failure(error))
            resolveStop(.failure(error))
            if wasReady { deliverTerminal(.remoteStopped(message)) }
            return
        }
        if phase == 30, resultCode != 0 {
            fail(NativeNVSTError.transportFailed("Native NVST prepare failed with result \(resultCode)."))
            return
        }
        if phase == 50 {
            resolvePause(resultCode == 0 ? .success(()) : .failure(NativeNVSTError.transportFailed("Native NVST pause failed with result \(resultCode).")))
            return
        }
        if phase == 70, pausePending {
            resolvePause(.failure(NativeNVSTError.transportFailed("Native NVST pause failed with result \(resultCode).")))
            return
        }
        if phase == 60 {
            resolveStop(resultCode == 0 ? .success(()) : .failure(NativeNVSTError.transportFailed("Native NVST stop failed with result \(resultCode).")))
            resolveStart(.failure(NativeNVSTError.transportFailed("Native NVST stopped before Geronimo delivered start.")))
            resolveReadiness(.failure(NativeNVSTError.transportFailed("Native NVST stopped before Geronimo reported readiness.")))
            return
        }
        if phase == 61 {
            let message = resultCode == 0 ? "Native NVST stream ended remotely." : "Native NVST stream ended remotely with result \(resultCode)."
            let error = NativeNVSTError.transportFailed(message)
            let wasReady = hasReachedReadiness
            resolveStart(.failure(error))
            resolveStop(resultCode == 0 ? .success(()) : .failure(NativeNVSTError.transportFailed(message)))
            resolveReadiness(.failure(error))
            resolvePause(.failure(error))
            if wasReady { deliverTerminal(.remoteStopped(message)) }
            return
        }
        if phase == 62 {
            let message = resultCode == 0
                ? "Native NVST streaming ended with reason \(notification)."
                : "Native NVST streaming ended with reason \(notification) and result \(resultCode)."
            let error = NativeNVSTError.transportFailed(message)
            let wasReady = hasReachedReadiness
            resolveStart(.failure(error))
            resolveReadiness(.failure(error))
            resolvePause(.failure(error))
            resolveStop(.failure(error))
            if wasReady { deliverTerminal(.remoteStopped(message)) }
            return
        }
        if phase == 70 {
            fail(NativeNVSTBifrostTransport.geronimoCallbackError(resultCode: resultCode, resultName: resultName))
        }
    }

    func readinessDiagnosticAttributes() -> [String: String] {
        lock.lock()
        let phases = observedPhases.sorted()
        let lastPhase = self.lastPhase
        let lastCallbackType = self.lastCallbackType
        let lastClientEvent = self.lastClientEvent
        let lastNotification = self.lastNotification
        let lastResultCode = self.lastResultCode
        lock.unlock()

        var attributes = [
            "observedPhases": phases.map(String.init).joined(separator: ","),
            "startEventDelivered": String(phases.contains(40)),
            "streamingBegan": String(phases.contains(44)),
            "setupSucceeded": String(phases.contains(46)),
            "connectedEventDelivered": String(phases.contains(45)),
        ]
        if let lastPhase { attributes["lastPhase"] = String(lastPhase) }
        if let lastCallbackType { attributes["lastCallbackType"] = String(lastCallbackType) }
        if let lastClientEvent { attributes["lastClientEvent"] = String(lastClientEvent) }
        if let lastNotification { attributes["lastNotification"] = String(lastNotification) }
        if let lastResultCode { attributes["lastResultCode"] = String(lastResultCode) }
        return attributes
    }

    func waitForStreamerConnected(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let readinessResult {
                    lock.unlock()
                    continuation.resume(with: readinessResult)
                    return
                }
                readinessCompletion = continuation
                lock.unlock()

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolveReadiness(.failure(NativeNVSTError.transportFailed(NativeNVSTBifrostTransport.geronimoStartFailureMessage)))
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func waitForStartDelivered(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let startResult {
                    lock.unlock()
                    continuation.resume(with: startResult)
                    return
                }
                startCompletion = continuation
                lock.unlock()

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolveStart(.failure(NativeNVSTError.transportFailed("Native NVST local setup did not deliver Geronimo start within 30 seconds.")))
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func fail(_ error: Error) {
        let wasReady = hasReachedReadiness
        resolveStart(.failure(error))
        resolveReadiness(.failure(error))
        resolvePause(.failure(error))
        resolveStop(.failure(error))
        if wasReady { deliverTerminal(.failed(Self.message(for: error))) }
    }

    func cancel() {
        resolveStart(.failure(CancellationError()))
        resolveReadiness(.failure(CancellationError()))
        resolvePause(.failure(CancellationError()))
        resolveStop(.failure(CancellationError()))
    }

    func beginPause() {
        lock.lock()
        pausePending = true
        pauseResult = nil
        pauseCompletion = nil
        lock.unlock()
    }

    func waitForPause(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pauseResult {
                    lock.unlock()
                    continuation.resume(with: pauseResult)
                    return
                }
                pauseCompletion = continuation
                lock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolvePause(.failure(NativeNVSTError.transportFailed("Native NVST pause callback timed out.")))
                }
            }
        } onCancel: { [weak self] in
            self?.cancelPause()
        }
    }

    func cancelPause() {
        resolvePause(.failure(CancellationError()))
    }

    func beginStop() {
        lock.lock()
        stopPending = true
        stopResult = nil
        stopCompletion = nil
        lock.unlock()
    }

    func waitForStop(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let stopResult {
                    lock.unlock()
                    continuation.resume(with: stopResult)
                    return
                }
                stopCompletion = continuation
                lock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolveStop(.failure(NativeNVSTError.transportFailed("Native NVST stop callback timed out.")))
                }
            }
        } onCancel: { [weak self] in
            self?.cancelStop()
        }
    }

    func cancelStop() {
        resolveStop(.failure(CancellationError()))
    }

    private var hasReachedReadiness: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let readinessResult else { return false }
        if case .success = readinessResult { return true }
        return false
    }

    var hasDeliveredTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalDelivered
    }

    private func resolveReadiness(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if readinessResult != nil {
            lock.unlock()
            return
        }
        readinessResult = result
        continuation = readinessCompletion
        readinessCompletion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        if startResult != nil {
            lock.unlock()
            return
        }
        startResult = result
        continuation = startCompletion
        startCompletion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func resolvePause(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        guard pausePending else {
            lock.unlock()
            return
        }
        pausePending = false
        pauseResult = result
        continuation = pauseCompletion
        pauseCompletion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func resolveStop(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        guard stopPending else {
            lock.unlock()
            return
        }
        stopPending = false
        stopResult = result
        continuation = stopCompletion
        stopCompletion = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func deliverTerminal(_ termination: NativeNVSTTransportTermination) {
        lock.lock()
        guard !terminalDelivered else {
            lock.unlock()
            return
        }
        terminalDelivered = true
        lock.unlock()
        terminationHandler(termination)
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST transport failed." : error.localizedDescription
    }
}

private func nativeNVSTGeronimoEventCallback(_ context: UnsafeMutableRawPointer?, _ phase: Int32, _ callbackType: UInt32, _ clientEvent: UInt32, _ notification: UInt32, _ resultCode: Int32, _ resultName: UnsafePointer<CChar>?) {
    guard let context else { return }
    let sink = Unmanaged<NativeNVSTGeronimoEventSink>.fromOpaque(context).takeUnretainedValue()
    sink.handle(phase: phase, callbackType: callbackType, clientEvent: clientEvent, notification: notification, resultCode: resultCode, resultName: resultName.map { String(cString: $0) })
}

private typealias NativeNVSTGeronimoEventHandler = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32, UInt32, Int32, UnsafePointer<CChar>?) -> Void

private struct NativeNVSTGeronimoPerformanceStats {
    static let byteCount = 0x50

    let available: UInt32
    let frameWidth: UInt32
    let frameHeight: UInt32
    let streamFramesPerSecond: UInt32
    let codec: UInt32
    let frameLoss: UInt32
    let totalFrameLoss: UInt32
    let packetLoss: UInt32
    let totalPacketLoss: UInt32
    let gameFramesPerSecond: Double
    let latencyMilliseconds: Double
    let jitterMilliseconds: Double
    let bitrateMegabitsPerSecond: Double
    let bandwidthUtilizationPercent: Double

    init?(bytes: [UInt8]) {
        guard
            bytes.count == Self.byteCount,
            let available = Self.load(UInt32.self, from: bytes, at: 0x00),
            let frameWidth = Self.load(UInt32.self, from: bytes, at: 0x04),
            let frameHeight = Self.load(UInt32.self, from: bytes, at: 0x08),
            let streamFramesPerSecond = Self.load(UInt32.self, from: bytes, at: 0x0c),
            let codec = Self.load(UInt32.self, from: bytes, at: 0x10),
            let frameLoss = Self.load(UInt32.self, from: bytes, at: 0x14),
            let totalFrameLoss = Self.load(UInt32.self, from: bytes, at: 0x18),
            let packetLoss = Self.load(UInt32.self, from: bytes, at: 0x1c),
            let totalPacketLoss = Self.load(UInt32.self, from: bytes, at: 0x20),
            let gameFramesPerSecond = Self.load(Double.self, from: bytes, at: 0x28),
            let latencyMilliseconds = Self.load(Double.self, from: bytes, at: 0x30),
            let jitterMilliseconds = Self.load(Double.self, from: bytes, at: 0x38),
            let bitrateMegabitsPerSecond = Self.load(Double.self, from: bytes, at: 0x40),
            let bandwidthUtilizationPercent = Self.load(Double.self, from: bytes, at: 0x48)
        else { return nil }
        self.available = available
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.streamFramesPerSecond = streamFramesPerSecond
        self.codec = codec
        self.frameLoss = frameLoss
        self.totalFrameLoss = totalFrameLoss
        self.packetLoss = packetLoss
        self.totalPacketLoss = totalPacketLoss
        self.gameFramesPerSecond = gameFramesPerSecond
        self.latencyMilliseconds = latencyMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.bitrateMegabitsPerSecond = bitrateMegabitsPerSecond
        self.bandwidthUtilizationPercent = bandwidthUtilizationPercent
    }

    private static func load<Value>(_ type: Value.Type, from bytes: [UInt8], at offset: Int) -> Value? {
        guard offset >= 0, offset + MemoryLayout<Value>.size <= bytes.count else { return nil }
        return bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return baseAddress.advanced(by: offset).loadUnaligned(as: type)
        }
    }
}

@_silgen_name("OpenNOWNativeNVSTGeronimoCreate")
private func OpenNOWNativeNVSTGeronimoCreate(_ frameworksPath: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> UnsafeMutableRawPointer?

@_silgen_name("OpenNOWNativeNVSTGeronimoSetEventHandler")
private func OpenNOWNativeNVSTGeronimoSetEventHandler(_ session: UnsafeMutableRawPointer?, _ eventHandler: NativeNVSTGeronimoEventHandler?, _ eventContext: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSetVideoSurface")
private func OpenNOWNativeNVSTGeronimoSetVideoSurface(_ session: UnsafeMutableRawPointer?, _ nativeHandle: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoStart")
private func OpenNOWNativeNVSTGeronimoStart(_ session: UnsafeMutableRawPointer?, _ rawSessionJSON: UnsafePointer<CChar>?, _ streamingProfileJSON: UnsafePointer<CChar>?, _ cloudSessionJSON: UnsafePointer<CChar>?, _ gameLanguage: UnsafePointer<CChar>?, _ clientAppVersion: UnsafePointer<CChar>?, _ clientLocale: UnsafePointer<CChar>?, _ traceParent: UnsafePointer<CChar>?, _ authTokenType: UnsafePointer<CChar>?, _ authToken: UnsafePointer<CChar>?, _ microphoneAvailable: Int32, _ microphoneEnabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoResume")
private func OpenNOWNativeNVSTGeronimoResume(_ session: UnsafeMutableRawPointer?, _ rawSessionJSON: UnsafePointer<CChar>?, _ streamingProfileJSON: UnsafePointer<CChar>?, _ cloudSessionJSON: UnsafePointer<CChar>?, _ gameLanguage: UnsafePointer<CChar>?, _ clientAppVersion: UnsafePointer<CChar>?, _ clientLocale: UnsafePointer<CChar>?, _ traceParent: UnsafePointer<CChar>?, _ authTokenType: UnsafePointer<CChar>?, _ authToken: UnsafePointer<CChar>?, _ microphoneAvailable: Int32, _ microphoneEnabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSetMicrophoneEnabled")
private func OpenNOWNativeNVSTGeronimoSetMicrophoneEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoPump")
private func OpenNOWNativeNVSTGeronimoPump(_ session: UnsafeMutableRawPointer?, _ waitTimeoutMilliseconds: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoPause")
private func OpenNOWNativeNVSTGeronimoPause(_ session: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSendInput")
private func OpenNOWNativeNVSTGeronimoSendInput(_ session: UnsafeMutableRawPointer?, _ inputEventBytes: UnsafePointer<UInt8>?, _ inputEventByteCount: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSendAbsoluteMouse")
private func OpenNOWNativeNVSTGeronimoSendAbsoluteMouse(_ session: UnsafeMutableRawPointer?, _ windowX: Int32, _ windowY: Int32, _ timestampNanoseconds: UInt64, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoTogglePerformanceOverlay")
private func OpenNOWNativeNVSTGeronimoTogglePerformanceOverlay(_ session: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoCopyPerformanceStats")
private func OpenNOWNativeNVSTGeronimoCopyPerformanceStats(_ session: UnsafeMutableRawPointer?, _ performanceStatsBytes: UnsafeMutableRawPointer?, _ performanceStatsByteCount: Int, _ serverLocationBuffer: UnsafeMutablePointer<CChar>?, _ serverLocationBufferLength: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoSendText")
private func OpenNOWNativeNVSTGeronimoSendText(_ session: UnsafeMutableRawPointer?, _ utf8Bytes: UnsafePointer<UInt8>?, _ utf8ByteCount: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoStopWithResult")
private func OpenNOWNativeNVSTGeronimoStopWithResult(_ session: UnsafeMutableRawPointer?, _ reason: UnsafePointer<CChar>?, _ code: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("OpenNOWNativeNVSTGeronimoDestroy")
private func OpenNOWNativeNVSTGeronimoDestroy(_ session: UnsafeMutableRawPointer?)
