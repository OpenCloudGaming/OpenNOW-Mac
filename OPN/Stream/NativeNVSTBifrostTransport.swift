import AppKit
import AVFoundation
import Darwin
import Foundation

public actor NativeNVSTBifrostTransport: NativeNVSTTransport {
    static let geronimoPumpFramesPerSecond = 60.0
    static let geronimoPumpInterval = 1.0 / geronimoPumpFramesPerSecond
    static let geronimoPumpRunLoopMode = RunLoop.Mode.default

    /// SDL's Cocoa pump drains the NSApp event queue. While the local overlay
    /// owns pointer input (HUD sidebar, quit menu, network-recovery panel) or
    /// AppKit runs an event-tracking loop (control mouse tracking, title-bar
    /// drags, menus), draining steals the pending mouse events those consumers
    /// are waiting on, so overlay buttons press but never fire. GridApp
    /// callback delivery stays live on every tick; only SDL event processing
    /// yields.
    static func geronimoPumpProcessesSDLEvents(inRunLoopMode mode: RunLoop.Mode?, localOverlayCapturesInput: Bool) -> Bool {
        !localOverlayCapturesInput && mode != .eventTracking
    }

    static let geronimoStartFailureMessage = "Native NVST streaming did not reach Geronimo readiness. Open diagnostics for the native phase and sanitized error."
    static let geronimoStopTimeoutMessage = "Native NVST stop callback timed out."

    /// `NVB_R_SESSION_NOT_ACTIVE`. Geronimo reports it when the session the stop
    /// request names is already gone server-side, which is the state a stop asks
    /// for, so the stop succeeded. Treating it as a failure poisoned teardown.
    static let geronimoSessionNotActiveResultCode: Int32 = 301

    /// Native destruction runs synchronously on the main thread because SDL and
    /// GridApp both require it. Anything slower than this is worth a report.
    static let geronimoDestroyWarningSeconds: Double = 3

    static let bitrateCorrectionInitialDelayNanoseconds: UInt64 = 5_000_000_000
    static let bitrateCorrectionRetryDelayNanoseconds: UInt64 = 5_000_000_000
    static let bitrateCorrectionMaxAttempts = 5

    /// GFN under-finalizes `maxBitrateKbps` when the session negotiation does not advertise the
    /// desired bitrate, leaving Geronimo on its 35000 Kbps default cap. When the negotiated mode
    /// selection came back below the user's requested bitrate, the cap is raised at runtime via
    /// feature control `0x10` once the session is stable.
    /// The Settings bitrate picker is authoritative for native NVST. GFN finalizes
    /// `maxBitrateKbps` from the resolution tier it granted, so honoring the server value
    /// pins every stream to a resolution-derived cap and makes the picker inert. The
    /// negotiated value is only used when the user expressed no cap at all; when the server
    /// finalized below the requested cap, `scheduleBitrateCorrectionIfNeeded` raises it at
    /// runtime through feature control `0x10`.
    static func resolvedMaxBitrateKbps(requestedKbps: Int, negotiatedKbps: Int) -> Int {
        requestedKbps > 0 ? requestedKbps : max(0, negotiatedKbps)
    }

    static func requestedMaxBitrateKbps(_ settings: [String: Any]) -> Int {
        min(max(0, int(settings["maxBitrateMbps"])), 1_000) * 1_000
    }

    /// The bitrate cap GFN itself finalized for the session, independent of what the mode
    /// selection asks for. Drives the runtime correction decision.
    static func negotiatedMaxBitrateKbps(rawSessionJSON: String, sessionInfoJSON: String) -> Int {
        let rawSession = jsonObject(from: rawSessionJSON)
        let sessionInfo = jsonObject(from: sessionInfoJSON)
        let sources = [
            rawSession["finalizedStreamingFeatures"] as? [String: Any],
            rawSession["streamingProfile"] as? [String: Any],
            rawSession["negotiatedStreamProfile"] as? [String: Any],
            sessionInfo["streamingProfile"] as? [String: Any],
            sessionInfo["negotiatedStreamProfile"] as? [String: Any],
        ].compactMap { $0 }
        for source in sources {
            let value = int(firstValue(in: source, keys: ["maxBitrateKbps", "bitrateKbps"]))
            if value > 0 { return value }
        }
        return 0
    }

    static func bitrateCorrectionTargetKbps(requestedKbps: Int, appliedKbps: Int) -> UInt32? {
        guard requestedKbps > 0, appliedKbps > 0, appliedKbps < requestedKbps else { return nil }
        return UInt32(requestedKbps)
    }

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

    static func transportFailure(resultCode: Int32, resultName: String?, message: String) -> NativeNVSTTransportFailure {
        let result = NativeNVSTTerminationValue(code: resultCode, name: resultName)
        return NativeNVSTTransportFailure(
            message: message,
            result: result,
            recoveryClassification: NativeNVSTRecoveryPolicy.isTransient(result) ? .transientNetwork : .permanent
        )
    }

    private let bridgeConfiguration: NVSTNativeBridgeConfiguration
    private let inputEncoder: NativeNVSTInputEncoder
    private let nativeVideoSurfaceHandle: UInt?
    private let cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)?
    private let prepareVideoSurfaceForShutdown: (@MainActor @Sendable () -> Void)?
    private let restoreVideoSurfaceAfterRecovery: (@MainActor @Sendable () -> Void)?
    private let hapticHandler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)?
    private let hapticResetHandler: (@MainActor @Sendable () -> Void)?
    private let localInputCaptureHandler: (@MainActor @Sendable () -> Bool)?
    private let authRefreshHandler: @Sendable (UInt32) async throws -> String
    private let terminationChannel = NativeNVSTTerminationChannel()
    private var bridge: NVSTNativeBridge?
    private var activeConnection: NativeNVSTTransportConnection?
    private var connectingAttemptID: UUID?
    private var connectingEventSink: NativeNVSTGeronimoEventSink?
    private var connectingAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var geronimoSessionAddress: UInt?
    private var geronimoEventSink: NativeNVSTGeronimoEventSink?
    private var geronimoPump: NativeNVSTGeronimoPumpDriver?
    private var runtimeHandlers: NativeNVSTRuntimeHandlers?
    private var nativeLifecycleOperationInProgress = false
    private var nativeLifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var bitrateCorrectionTask: Task<Void, Never>?
    private var videoSurfaceNeedsRecovery = false
    private var microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: 1, mode: "disabled")
    private var lastDiagnosticMetadata: [String: String] = [:]
    private var inputErrorBuffer = [CChar](repeating: 0, count: 1024)

    public init(bridgeConfiguration: NVSTNativeBridgeConfiguration = NVSTNativeBridgeConfiguration(),
                inputEncoder: NativeNVSTInputEncoder = NativeNVSTInputEncoder(),
                nativeVideoSurfaceHandle: UInt? = nil,
                cursorVisibilityHandler: (@MainActor @Sendable (Bool) -> Void)? = nil,
                prepareVideoSurfaceForShutdown: (@MainActor @Sendable () -> Void)? = nil,
                restoreVideoSurfaceAfterRecovery: (@MainActor @Sendable () -> Void)? = nil,
                hapticHandler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)? = nil,
                hapticResetHandler: (@MainActor @Sendable () -> Void)? = nil,
                localInputCaptureHandler: (@MainActor @Sendable () -> Bool)? = nil,
                authRefreshHandler: @escaping @Sendable (UInt32) async throws -> String = { authType in
                    try await NativeNVSTAuthRefreshCoordinator.productionToken(authType: authType, sessionRefresher: OPNAuthService.shared)
                }) {
        self.bridgeConfiguration = bridgeConfiguration
        self.inputEncoder = inputEncoder
        self.nativeVideoSurfaceHandle = nativeVideoSurfaceHandle
        self.cursorVisibilityHandler = cursorVisibilityHandler
        self.prepareVideoSurfaceForShutdown = prepareVideoSurfaceForShutdown
        self.restoreVideoSurfaceAfterRecovery = restoreVideoSurfaceAfterRecovery
        self.hapticHandler = hapticHandler
        self.hapticResetHandler = hapticResetHandler
        self.localInputCaptureHandler = localInputCaptureHandler
        self.authRefreshHandler = authRefreshHandler
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
        guard activeConnection == nil, connectingAttemptID == nil, !nativeLifecycleOperationInProgress else { throw NativeNVSTError.alreadyRunning }
        bitrateCorrectionTask?.cancel()
        bitrateCorrectionTask = nil
        let attemptID = UUID()
        connectingAttemptID = attemptID
        lastDiagnosticMetadata = [
            "nvstAttemptID": attemptID.uuidString,
            "nvstAllocationMode": allocation.isResume ? "resume" : "fresh",
            "nvstOperation": "resume",
            "nvstSessionIDPresent": String(!allocation.session.id.isEmpty),
        ]
        defer {
            if connectingAttemptID == attemptID {
                connectingAttemptID = nil
                connectingEventSink = nil
            }
            let waiters = connectingAttemptWaiters
            connectingAttemptWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        terminationChannel.reset()
        let status: NVSTNativeBridgeStatus
        do {
            status = try await prepare()
        } catch {
            throw error
        }
        guard connectingAttemptID == attemptID, !nativeLifecycleOperationInProgress, !Task.isCancelled else {
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
        let started: (connection: NativeNVSTTransportConnection, sessionAddress: UInt, pump: NativeNVSTGeronimoPumpDriver, runtimeHandlers: NativeNVSTRuntimeHandlers, requestedMaxBitrateKbps: Int, appliedMaxBitrateKbps: Int)
        do {
            started = try await withTaskCancellationHandler {
                try await Self.startGeronimoOnMainActor(
                    allocation: allocation,
                    status: status,
                    nativeVideoSurfaceHandle: nativeVideoSurfaceHandle,
                    eventSink: eventSink,
                    hapticHandler: hapticHandler,
                    hapticResetHandler: hapticResetHandler,
                    localInputCaptureHandler: localInputCaptureHandler,
                    authRefreshHandler: authRefreshHandler,
                    microphoneConfiguration: microphoneConfiguration
                )
            } onCancel: {
                eventSink.cancel()
            }
        } catch {
            lastDiagnosticMetadata.merge(eventSink.readinessDiagnosticAttributes()) { _, new in new }
            lastDiagnosticMetadata["nvstFailure"] = Self.message(for: error)
            throw error
        }
        guard connectingAttemptID == attemptID, !nativeLifecycleOperationInProgress, !Task.isCancelled else {
            await started.runtimeHandlers.cancel()
            await started.pump.stop()
            await destroyGeronimo(sessionAddress: started.sessionAddress, operation: "connect-cancelled")
            await prepareGeronimoVideoSurfaceForShutdown()
            throw CancellationError()
        }
        let connection = started.connection
        geronimoSessionAddress = started.sessionAddress
        geronimoEventSink = eventSink
        geronimoPump = started.pump
        runtimeHandlers = started.runtimeHandlers
        activeConnection = connection
        scheduleBitrateCorrectionIfNeeded(requestedKbps: started.requestedMaxBitrateKbps, appliedKbps: started.appliedMaxBitrateKbps, sessionId: allocation.session.id)
        if videoSurfaceNeedsRecovery {
            await restoreVideoSurfaceAfterRecovery?()
            videoSurfaceNeedsRecovery = false
        }
        lastDiagnosticMetadata.merge(eventSink.readinessDiagnosticAttributes()) { _, new in new }
        return connection
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress else { throw NativeNVSTError.notRunning }
        guard let encoded = inputEncoder.encode(event) else { return }
        guard let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try sendGeronimoInput(sessionAddress: sessionAddress, encoded: encoded)
    }

    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.sendGeronimoAbsoluteMouseOnMainActor(sessionAddress: sessionAddress, event: event)
    }

    public func togglePerformanceOverlay() async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.toggleGeronimoPerformanceOverlayOnMainActor(sessionAddress: sessionAddress)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.setGeronimoMicrophoneEnabledOnMainActor(enabled, sessionAddress: sessionAddress)
    }

    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {
        guard !nativeLifecycleOperationInProgress else { throw NativeNVSTError.notRunning }
        if let sessionAddress = geronimoSessionAddress {
            try await Self.setGeronimoMicrophoneConfigurationOnMainActor(configuration, sessionAddress: sessionAddress)
        }
        microphoneConfiguration = configuration
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { return nil }
        return Self.copyGeronimoPerformanceSnapshot(sessionAddress: sessionAddress)
    }

    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.applyRuntimeNetworkControlOnMainActor(sessionAddress: sessionAddress, fallback: "Native NVST bitrate update failed.") { session, errorBuffer, length in
            MacForceNowNativeNVSTGeronimoSetStreamingMaxBitrate(session, bitrateKbps, errorBuffer, length)
        }
    }

    private func scheduleBitrateCorrectionIfNeeded(requestedKbps: Int, appliedKbps: Int, sessionId: String) {
        bitrateCorrectionTask?.cancel()
        bitrateCorrectionTask = nil
        guard let targetKbps = Self.bitrateCorrectionTargetKbps(requestedKbps: requestedKbps, appliedKbps: appliedKbps) else { return }
        WebRTCMediaTelemetry.capture("nvst.network.bitrate_correction.scheduled", level: .info, message: "Native NVST negotiated bitrate is below the requested cap; scheduling a runtime correction.", attributes: ["sessionId": sessionId, "requestedKbps": String(requestedKbps), "appliedKbps": String(appliedKbps), "targetKbps": String(targetKbps)])
        bitrateCorrectionTask = Task { [weak self] in
            for attempt in 1...Self.bitrateCorrectionMaxAttempts {
                let delayNanoseconds = attempt == 1 ? Self.bitrateCorrectionInitialDelayNanoseconds : Self.bitrateCorrectionRetryDelayNanoseconds
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.setMaximumBitrateKbps(targetKbps)
                    WebRTCMediaTelemetry.capture("nvst.network.bitrate_correction.applied", level: .info, message: "Native NVST runtime bitrate cap raised to the requested value.", attributes: ["sessionId": sessionId, "targetKbps": String(targetKbps), "attempt": String(attempt)])
                    return
                } catch is CancellationError {
                    return
                } catch {
                    WebRTCMediaTelemetry.capture("nvst.network.bitrate_correction.retry", level: .warning, message: Self.message(for: error), attributes: ["sessionId": sessionId, "targetKbps": String(targetKbps), "attempt": String(attempt)])
                }
            }
            WebRTCMediaTelemetry.capture("nvst.network.bitrate_correction.exhausted", level: .warning, message: "Native NVST runtime bitrate correction was rejected; keeping the negotiated cap.", attributes: ["sessionId": sessionId, "targetKbps": String(targetKbps)])
        }
    }

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.applyRuntimeNetworkControlOnMainActor(sessionAddress: sessionAddress, fallback: "Native NVST dynamic streaming update failed.") { session, errorBuffer, length in
            MacForceNowNativeNVSTGeronimoSetDynamicStreamingMode(session, mode.rawValue, errorBuffer, length)
        }
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.applyRuntimeNetworkControlOnMainActor(sessionAddress: sessionAddress, fallback: "Native NVST L4S update failed.") { session, errorBuffer, length in
            MacForceNowNativeNVSTGeronimoSetL4SState(session, enabled ? 1 : 0, errorBuffer, length)
        }
    }

    public func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws {
        guard activeConnection != nil, !nativeLifecycleOperationInProgress, let sessionAddress = geronimoSessionAddress else { throw NativeNVSTError.notRunning }
        try await Self.applyRuntimeNetworkControlOnMainActor(sessionAddress: sessionAddress, fallback: "Native NVST gamepad topology update failed.") { session, errorBuffer, length in
            MacForceNowNativeNVSTGeronimoUpdateGamepadTopology(session, topology.connectedPlayerBitmap, topology.hapticPlayerBitmap, errorBuffer, length)
        }
    }

    public func disconnect() async {
        bitrateCorrectionTask?.cancel()
        bitrateCorrectionTask = nil
        await beginNativeLifecycleOperation()
        defer {
            geronimoPump = nil
            geronimoSessionAddress = nil
            geronimoEventSink = nil
            runtimeHandlers = nil
            activeConnection = nil
            endNativeLifecycleOperation()
        }
        connectingEventSink?.cancel()
        await waitForConnectingAttemptToFinish()
        let pump = geronimoPump
        let sessionAddress = geronimoSessionAddress
        let eventSink = geronimoEventSink
        let runtimeHandlers = self.runtimeHandlers
        await runtimeHandlers?.cancel()
        if sessionAddress != nil { videoSurfaceNeedsRecovery = true }
        if let sessionAddress, let eventSink {
            if !eventSink.hasDeliveredTerminal {
                eventSink.beginStop()
                let stopRequest = await Self.stopGeronimoOnMainActor(sessionAddress: sessionAddress)
                if stopRequest.result == 0 {
                    do {
                        try await eventSink.waitForStop(timeoutNanoseconds: 3_000_000_000)
                        recordStopOutcome("callback-succeeded", message: nil)
                    } catch {
                        let message = Self.message(for: error)
                        recordStopOutcome(message == Self.geronimoStopTimeoutMessage ? "callback-timed-out" : "callback-failed", message: message)
                    }
                } else {
                    let message = stopRequest.message ?? "Native NVST stop request failed with result \(stopRequest.result)."
                    eventSink.failStop(NativeNVSTError.transportFailed(message))
                    recordStopOutcome("request-failed", message: message)
                }
            }
        }
        if let pump { await pump.stop() }
        if let sessionAddress {
            await destroyGeronimo(sessionAddress: sessionAddress, operation: "disconnect")
            await prepareGeronimoVideoSurfaceForShutdown()
        }
    }

    /// Wraps native destruction with a watchdog: the call itself is synchronous on the
    /// main thread, so if Geronimo ever stalls again the report lands while the app is
    /// still stuck instead of having to be reconstructed from a sample afterwards.
    private func destroyGeronimo(sessionAddress: UInt, operation: String) async {
        var attributes = lastDiagnosticMetadata
        attributes["destroyOperation"] = operation
        let watchdog = Task.detached(priority: .utility) { [attributes] in
            try? await Task.sleep(nanoseconds: UInt64(Self.geronimoDestroyWarningSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            WebRTCMediaTelemetry.capture(
                "nvst.geronimo.destroy.stalled",
                level: .error,
                message: "Native NVST teardown is still running on the main thread.",
                attributes: attributes
            )
        }
        await Self.destroyGeronimoOnMainActor(sessionAddress: sessionAddress, attributes: attributes)
        watchdog.cancel()
    }

    public func resetForRecovery() async {
        bitrateCorrectionTask?.cancel()
        bitrateCorrectionTask = nil
        await beginNativeLifecycleOperation()
        defer {
            geronimoPump = nil
            geronimoSessionAddress = nil
            geronimoEventSink = nil
            runtimeHandlers = nil
            activeConnection = nil
            endNativeLifecycleOperation()
        }
        connectingEventSink?.cancel()
        await waitForConnectingAttemptToFinish()
        let pump = geronimoPump
        let sessionAddress = geronimoSessionAddress
        let runtimeHandlers = self.runtimeHandlers
        geronimoEventSink?.cancel()
        await runtimeHandlers?.cancel()
        if sessionAddress != nil { videoSurfaceNeedsRecovery = true }
        if let pump { await pump.stop() }
        if let sessionAddress {
            await destroyGeronimo(sessionAddress: sessionAddress, operation: "recovery-reset")
            await prepareGeronimoVideoSurfaceForShutdown()
        }
    }

    public func pause() async throws {
        bitrateCorrectionTask?.cancel()
        bitrateCorrectionTask = nil
        await beginNativeLifecycleOperation()
        defer { endNativeLifecycleOperation() }
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
        let runtimeHandlers = self.runtimeHandlers
        videoSurfaceNeedsRecovery = true
        if let pump { await pump.stop() }
        await runtimeHandlers?.cancel()
        await destroyGeronimo(sessionAddress: sessionAddress, operation: "pause")
        await prepareGeronimoVideoSurfaceForShutdown()
        geronimoPump = nil
        geronimoSessionAddress = nil
        geronimoEventSink = nil
        self.runtimeHandlers = nil
        activeConnection = nil
    }

    public func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        terminationChannel.stream()
    }

    public func diagnosticMetadata() async -> [String: String] {
        var metadata = lastDiagnosticMetadata
        if let geronimoEventSink {
            metadata.merge(geronimoEventSink.readinessDiagnosticAttributes()) { _, new in new }
        } else if let connectingEventSink {
            metadata.merge(connectingEventSink.readinessDiagnosticAttributes()) { _, new in new }
        }
        return metadata
    }

    /// Detaches the Geronimo-owned Metal view from the stream window. This MUST run
    /// after native destruction, never before it: hiding and reparenting the layer while
    /// Geronimo still holds in-flight presents leaves `renderLoop` waiting on drawables
    /// that an off-screen layer never completes, so `setRenderLoopMode`'s
    /// `dispatch_group_wait` never returns and `SDLWindow::~SDLWindow` deadlocks the main
    /// thread inside its `dispatch_sync` onto the render-setup queue.
    private func prepareGeronimoVideoSurfaceForShutdown() async {
        guard let prepareVideoSurfaceForShutdown else { return }
        await prepareVideoSurfaceForShutdown()
    }

    private func beginNativeLifecycleOperation() async {
        while nativeLifecycleOperationInProgress {
            await withCheckedContinuation { continuation in
                nativeLifecycleWaiters.append(continuation)
            }
        }
        nativeLifecycleOperationInProgress = true
    }

    private func endNativeLifecycleOperation() {
        nativeLifecycleOperationInProgress = false
        let waiters = nativeLifecycleWaiters
        nativeLifecycleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForConnectingAttemptToFinish() async {
        guard connectingAttemptID != nil else { return }
        await withCheckedContinuation { continuation in
            if connectingAttemptID == nil {
                continuation.resume()
            } else {
                connectingAttemptWaiters.append(continuation)
            }
        }
    }

    private func recordStopOutcome(_ outcome: String, message: String?) {
        lastDiagnosticMetadata["nvstStopOutcome"] = outcome
        if let message { lastDiagnosticMetadata["nvstStopFailure"] = message }
        var attributes = lastDiagnosticMetadata
        attributes["outcome"] = outcome
        WebRTCMediaTelemetry.capture(
            "nvst.geronimo.stop.completed",
            level: message == nil ? .info : .error,
            message: message ?? "Native NVST stop callback completed.",
            attributes: attributes
        )
    }

    @MainActor private static func startGeronimoOnMainActor(allocation: NativeNVSTSessionAllocation,
                                                            status: NVSTNativeBridgeStatus,
                                                            nativeVideoSurfaceHandle: UInt?,
                                                            eventSink: NativeNVSTGeronimoEventSink,
                                                            hapticHandler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)?,
                                                            hapticResetHandler: (@MainActor @Sendable () -> Void)?,
                                                            localInputCaptureHandler: (@MainActor @Sendable () -> Bool)?,
                                                            authRefreshHandler: @escaping @Sendable (UInt32) async throws -> String,
                                                            microphoneConfiguration: NativeNVSTMicrophoneConfiguration) async throws -> (connection: NativeNVSTTransportConnection, sessionAddress: UInt, pump: NativeNVSTGeronimoPumpDriver, runtimeHandlers: NativeNVSTRuntimeHandlers, requestedMaxBitrateKbps: Int, appliedMaxBitrateKbps: Int) {
        guard let frameworksPath = status.libraryURL.deletingLastPathComponent().path.cString(using: .utf8) else {
            throw NativeNVSTError.runtimeUnavailable("Native Geronimo frameworks path could not be encoded.")
        }
        let settings = Self.jsonObject(from: allocation.settingsJSON)
        let nativeWindow = nativeVideoSurfaceHandle
            .flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            .flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? NSWindow }
        let streamScreen = nativeWindow?.parent?.screen ?? nativeWindow?.screen
        let presentationCapabilities = OPNStreamPreferences.loadDeviceCapabilities(screen: streamScreen)
        let streamingProfileJSON = try Self.streamingProfileJSON(
            rawSessionJSON: allocation.rawSessionJSON,
            sessionInfoJSON: allocation.sessionInfoJSON,
            settingsJSON: allocation.settingsJSON,
            presentationCapabilities: presentationCapabilities
        )
        let selectedProfile = Self.jsonObject(from: streamingProfileJSON)
        let selectedFeatures = selectedProfile["selectedFeatures"] as? [String: Any] ?? [:]
        let selectedCodec = Self.selectedCodec(rawSessionJSON: allocation.rawSessionJSON, sessionInfoJSON: allocation.sessionInfoJSON, settingsJSON: allocation.settingsJSON)
        let presentationCapability = OPNStreamPreferences.presentationCapability(codec: selectedCodec, capabilities: presentationCapabilities)
        if let nativeWindow {
            NativeWebRTCStreamView.configureNativeNVSTPresentation(
                window: nativeWindow,
                requestedHDR: Self.bool(selectedFeatures["hdr"]),
                codecSupportsHDR: presentationCapability.supportsHDR
            )
        }
        let launchPayload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: streamingProfileJSON, clientAppVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "MacForceNow")
        try launchPayload.validate()
        let geronimoSessionJSON = try Self.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
        var startAttributes = Self.geronimoStartAttributes(allocation: allocation, streamingProfileJSON: streamingProfileJSON, geronimoSessionJSON: geronimoSessionJSON)
        startAttributes.merge(launchPayload.telemetryAttributes) { _, new in new }
        let microphoneRequested = microphoneConfiguration.captureRequested
        let microphoneAvailable = await Self.resolveMicrophoneCaptureAccess(requested: microphoneRequested)
        let microphoneEnabled = microphoneAvailable && microphoneConfiguration.initiallyEnabled
        startAttributes["allocationMode"] = allocation.isResume ? "resume" : "fresh"
        startAttributes["operation"] = "resume"
        startAttributes["microphoneRequested"] = String(microphoneRequested)
        startAttributes["microphoneAvailable"] = String(microphoneAvailable)
        startAttributes["microphoneEnabled"] = String(microphoneEnabled)
        startAttributes["videoSurfaceType"] = "NSWindow"
        WebRTCMediaTelemetry.capture("nvst.geronimo.start.prepare", level: .info, message: "Preparing Geronimo native NVST session attachment.", attributes: startAttributes)
        let gameLanguage = Self.string(settings["gameLanguage"], fallback: "en_US")
        let clientVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "MacForceNow"
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        guard let session = frameworksPath.withUnsafeBufferPointer({ pathBuffer in
            MacForceNowNativeNVSTGeronimoCreate(pathBuffer.baseAddress, errorBuffer, 1024)
        }) else {
            let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo session could not be created.")
            var attributes = startAttributes
            attributes["error"] = message
            WebRTCMediaTelemetry.capture("nvst.geronimo.create.failed", level: .error, message: message, attributes: attributes)
            throw NativeNVSTError.runtimeUnavailable(message)
        }
        do {
            try setGeronimoMicrophoneConfigurationOnMainActor(microphoneConfiguration, session: session)
        } catch {
            MacForceNowNativeNVSTGeronimoDestroy(session)
            throw error
        }
        eventSink.updateTelemetryAttributes(startAttributes)
        let eventContext = Unmanaged.passUnretained(eventSink).toOpaque()
        let callbackResult = MacForceNowNativeNVSTGeronimoSetEventHandler(session, nativeNVSTGeronimoEventCallback, eventContext, errorBuffer, 1024)
        guard callbackResult == 0 else {
            let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo callback registration failed with result \(callbackResult).")
            var attributes = startAttributes
            attributes["result"] = String(callbackResult)
            attributes["error"] = message
            WebRTCMediaTelemetry.capture("nvst.geronimo.callback.failed", level: .error, message: message, attributes: attributes)
            MacForceNowNativeNVSTGeronimoDestroy(session)
            throw NativeNVSTError.privateABIUnavailable(message)
        }
        let runtimeHandlers = NativeNVSTRuntimeHandlers(
            expectedAuthType: NativeNVSTAuthRefreshCoordinator.authType(for: allocation.authTokenType),
            authRefreshHandler: authRefreshHandler,
            hapticHandler: hapticHandler,
            hapticResetHandler: hapticResetHandler
        )
        let hapticResult = MacForceNowNativeNVSTGeronimoSetHapticHandler(session, nativeNVSTGeronimoHapticCallback, runtimeHandlers.hapticContext)
        let authRefreshResult = MacForceNowNativeNVSTGeronimoSetAuthRefreshHandler(session, nativeNVSTGeronimoAuthRefreshCallback, runtimeHandlers.authRefreshContext)
        guard hapticResult == 0, authRefreshResult == 0 else {
            await runtimeHandlers.cancel()
            MacForceNowNativeNVSTGeronimoDestroy(session)
            throw NativeNVSTError.privateABIUnavailable("Native Geronimo runtime handler registration failed.")
        }
        guard let nativeVideoSurfaceHandle, let nativeVideoSurface = UnsafeMutableRawPointer(bitPattern: nativeVideoSurfaceHandle) else {
            let message = "Native Geronimo requires an AppKit video surface."
            WebRTCMediaTelemetry.capture("nvst.geronimo.video_surface.failed", level: .error, message: message, attributes: startAttributes)
            await runtimeHandlers.cancel()
            MacForceNowNativeNVSTGeronimoDestroy(session)
            throw NativeNVSTError.privateABIUnavailable(message)
        }
        let surfaceResult = MacForceNowNativeNVSTGeronimoSetVideoSurface(session, nativeVideoSurface, errorBuffer, 1024)
        guard surfaceResult == 0 else {
            let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo video surface binding failed with result \(surfaceResult).")
            var attributes = startAttributes
            attributes["result"] = String(surfaceResult)
            attributes["error"] = message
            WebRTCMediaTelemetry.capture("nvst.geronimo.video_surface.failed", level: .error, message: message, attributes: attributes)
            await runtimeHandlers.cancel()
            MacForceNowNativeNVSTGeronimoDestroy(session)
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
                                                // allocateSession() always creates or claims the CloudMatch session over HTTP
                                                // before native start, so a real sessionId already exists here in every case.
                                                // GeronimoStart's native-creates-its-own-session semantics would issue a second,
                                                // independent session creation that collides with the one we already hold —
                                                // GeronimoResume attaches to the existing session instead.
                                                MacForceNowNativeNVSTGeronimoResume(session, rawSessionPointer, profilePointer, cloudSessionPointer, languagePointer, versionPointer, localePointer, traceParentPointer, authTokenTypePointer, authTokenPointer, microphoneAvailable ? 1 : 0, microphoneEnabled ? 1 : 0, errorBuffer, 1024)
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
                let message = Self.errorMessage(errorBuffer, fallback: "Native Geronimo session attachment failed with result \(result).")
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
            let activePump = NativeNVSTGeronimoPumpDriver(sessionAddress: sessionAddress, eventSink: eventSink, telemetryAttributes: attributes, localInputCaptureHandler: localInputCaptureHandler)
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
            let requestedMaxBitrateKbps = Self.requestedMaxBitrateKbps(settings)
            let appliedMaxBitrateKbps = Self.negotiatedMaxBitrateKbps(rawSessionJSON: allocation.rawSessionJSON, sessionInfoJSON: allocation.sessionInfoJSON)
            return (NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: status), sessionAddress, activePump, runtimeHandlers, requestedMaxBitrateKbps, appliedMaxBitrateKbps)
        } catch {
            pump?.stop()
            await runtimeHandlers.cancel()
            MacForceNowNativeNVSTGeronimoDestroy(session)
            throw error
        }
    }

    /// Native destruction has to run on the main thread (SDL owns the video subsystem
    /// and GridApp expects its own pump thread), so it is the one teardown step that can
    /// still freeze the UI. The shim now abandons a session instead of joining wedged
    /// Geronimo threads; this reports which outcome happened and how long it took.
    @MainActor private static func destroyGeronimoOnMainActor(sessionAddress: UInt, attributes: [String: String] = [:]) {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let outcome = MacForceNowNativeNVSTGeronimoDestroyWithResult(UnsafeMutableRawPointer(bitPattern: sessionAddress))
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        var destroyAttributes = attributes
        destroyAttributes["outcome"] = geronimoDestroyOutcomeName(outcome)
        destroyAttributes["elapsedSeconds"] = String(format: "%.3f", elapsedSeconds)
        let abandoned = outcome != 0
        WebRTCMediaTelemetry.capture(
            "nvst.geronimo.destroy.completed",
            level: abandoned || elapsedSeconds >= geronimoDestroyWarningSeconds ? .error : .info,
            message: abandoned
                ? "Native NVST session abandoned during teardown; the native session was leaked to keep the app responsive."
                : "Native NVST session destroyed.",
            attributes: destroyAttributes
        )
    }

    private static func geronimoDestroyOutcomeName(_ outcome: Int32) -> String {
        switch outcome {
        case 0: "destroyed"
        case 1: "abandoned-callbacks-in-flight"
        case 2: "abandoned-audio-capturer"
        case 3: "abandoned-microphone-route"
        default: "abandoned-\(outcome)"
        }
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
        let result = MacForceNowNativeNVSTGeronimoPause(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "Native Geronimo pause failed with result \(result)."))
        }
    }

    @MainActor private static func toggleGeronimoPerformanceOverlayOnMainActor(sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = MacForceNowNativeNVSTGeronimoTogglePerformanceOverlay(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo performance overlay failed with result \(result)."))
        }
    }

    @MainActor private static func setGeronimoMicrophoneEnabledOnMainActor(_ enabled: Bool, sessionAddress: UInt) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = MacForceNowNativeNVSTGeronimoSetMicrophoneEnabled(UnsafeMutableRawPointer(bitPattern: sessionAddress), enabled ? 1 : 0, errorBuffer, 1024)
        guard result == 0 else {
            throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "Native Geronimo microphone update failed with result \(result)."))
        }
    }

    @MainActor private static func setGeronimoMicrophoneConfigurationOnMainActor(_ configuration: NativeNVSTMicrophoneConfiguration, sessionAddress: UInt) throws {
        try setGeronimoMicrophoneConfigurationOnMainActor(configuration, session: UnsafeMutableRawPointer(bitPattern: sessionAddress))
    }

    @MainActor private static func setGeronimoMicrophoneConfigurationOnMainActor(_ configuration: NativeNVSTMicrophoneConfiguration, session: UnsafeMutableRawPointer?) throws {
        let volumeResult = MacForceNowNativeNVSTGeronimoSetMicrophoneVolume(session, configuration.volume)
        let vadResult = MacForceNowNativeNVSTGeronimoSetVoiceActivityEnabled(session, configuration.voiceActivityEnabled ? 1 : 0)
        guard volumeResult == 0, vadResult == 0 else {
            throw NativeNVSTError.privateABIUnavailable("Native Geronimo microphone processing configuration failed.")
        }
    }

    @MainActor private static func applyRuntimeNetworkControlOnMainActor(sessionAddress: UInt, fallback: String, operation: (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, Int) -> Int32) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = operation(UnsafeMutableRawPointer(bitPattern: sessionAddress), errorBuffer, 1024)
        guard result == 0 else { throw NativeNVSTError.transportFailed(errorMessage(errorBuffer, fallback: "\(fallback) Result \(result).")) }
    }

    private static func copyGeronimoPerformanceSnapshot(sessionAddress: UInt) -> NativeNVSTPerformanceSnapshot? {
        var nativeStatsBytes = [UInt8](repeating: 0, count: NativeNVSTGeronimoPerformanceStats.byteCount)
        var serverLocation = [CChar](repeating: 0, count: 128)
        let result = nativeStatsBytes.withUnsafeMutableBytes { statsBuffer in
            serverLocation.withUnsafeMutableBufferPointer { locationBuffer in
                MacForceNowNativeNVSTGeronimoCopyPerformanceStats(
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

    @MainActor private static func stopGeronimoOnMainActor(sessionAddress: UInt) -> (result: Int32, message: String?) {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = "MacForce Now native NVST disconnect".withCString { reason in
            MacForceNowNativeNVSTGeronimoStopWithResult(UnsafeMutableRawPointer(bitPattern: sessionAddress), reason, 0, errorBuffer, 1024)
        }
        return (result, result == 0 ? nil : errorMessage(errorBuffer, fallback: "Native NVST stop request failed with result \(result)."))
    }

    private func sendGeronimoInput(sessionAddress: UInt, encoded: NativeNVSTEncodedInputEvent) throws {
        let result: Int32 = inputErrorBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            baseAddress.pointee = 0
            switch encoded.nativePayload {
            case .event(let payload):
                return payload.withUnsafeBytes { bytes in
                    MacForceNowNativeNVSTGeronimoSendInput(UnsafeMutableRawPointer(bitPattern: sessionAddress), bytes.bindMemory(to: UInt8.self).baseAddress, payload.count, baseAddress, buffer.count)
                }
            case .text(let payload):
                return payload.withUnsafeBytes { bytes in
                    MacForceNowNativeNVSTGeronimoSendText(UnsafeMutableRawPointer(bitPattern: sessionAddress), bytes.bindMemory(to: UInt8.self).baseAddress, payload.count, baseAddress, buffer.count)
                }
            }
        }
        guard result == 0 else {
            let message = inputErrorBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return "Native Geronimo input send failed with result \(result)." }
                let value = String(cString: baseAddress)
                return value.isEmpty ? "Native Geronimo input send failed with result \(result)." : value
            }
            throw NativeNVSTError.privateABIUnavailable(message)
        }
    }

    // Geronimo's SDLWindow::convertPointToVideoFrame resolves the window's screen and
    // content-view geometry through AppKit, which is main-thread-only. Route through the
    // main actor like every other Geronimo call that touches the video window; the plain
    // input path (sendGeronimoInput) stays on the transport actor since GridApp::sendInput
    // never touches AppKit.
    @MainActor private static func sendGeronimoAbsoluteMouseOnMainActor(sessionAddress: UInt, event: NativeNVSTAbsoluteMouseEvent) throws {
        let errorBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { errorBuffer.deallocate() }
        errorBuffer.initialize(repeating: 0, count: 1024)
        let result = MacForceNowNativeNVSTGeronimoSendAbsoluteMouse(
            UnsafeMutableRawPointer(bitPattern: sessionAddress),
            event.x,
            event.y,
            event.timestamp.nanoseconds,
            errorBuffer,
            1024
        )
        guard result == 0 else {
            throw NativeNVSTError.privateABIUnavailable(errorMessage(errorBuffer, fallback: "Native Geronimo absolute mouse input failed with result \(result)."))
        }
    }

    static func streamingProfileJSON(rawSessionJSON: String,
                                     sessionInfoJSON: String,
                                     settingsJSON: String = "{}",
                                     presentationCapabilities: OPNStreamDeviceCapabilities? = nil) throws -> String {
        let rawSession = jsonObject(from: rawSessionJSON)
        let sessionInfo = jsonObject(from: sessionInfoJSON)
        let settings = jsonObject(from: settingsJSON)
        let requestData = rawSession["sessionRequestData"] as? [String: Any] ?? [:]
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
        let maxBitrateKbps = resolvedMaxBitrateKbps(
            requestedKbps: requestedMaxBitrateKbps(settings),
            negotiatedKbps: int(firstValue(in: profile, keys: ["maxBitrateKbps", "bitrateKbps"]))
        )
        if maxBitrateKbps > 0 { profile["maxBitrateKbps"] = maxBitrateKbps }
        let measuredMaxPacketSize = int(settings["maxPacketSize"])
        if measuredMaxPacketSize >= 512, measuredMaxPacketSize <= Int(UInt16.max) {
            profile["maxPacketSize"] = measuredMaxPacketSize
        }
        guard !profile.isEmpty,
              let dimensions = videoDimensions(from: profile),
              int(profile["fps"]) > 0,
              !string(profile["codec"], fallback: "").isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session is missing a complete streaming profile.")
        }
        let finalizedFeatures = rawSession["finalizedStreamingFeatures"] as? [String: Any] ?? [:]
        let requestedFeatures = requestData["requestedStreamingFeatures"] as? [String: Any] ?? [:]
        let modeSelection = modeSelectionProfile(
            from: profile,
            dimensions: dimensions,
            finalizedFeatures: finalizedFeatures,
            requestedFeatures: requestedFeatures,
            settings: settings,
            presentationCapability: presentationCapabilities.map {
                OPNStreamPreferences.presentationCapability(codec: string(profile["codec"], fallback: "H264"), capabilities: $0)
            }
        )
        guard JSONSerialization.isValidJSONObject(modeSelection),
              let data = try? JSONSerialization.data(withJSONObject: modeSelection),
              let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session is missing a complete streaming profile.")
        }
        return geronimoModeSelectionJSON(string)
    }

    static func geronimoSessionJSON(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String) throws -> String {
        let source = NativeNVSTNormalizedSessionSource(allocation: allocation)
        let rawSession = source.rawSession
        let sessionInfo = source.sessionInfo
        let settings = source.settings
        let requestData = source.requestData
        let connectionInfo = normalizedConnectionInfo(rawSession: rawSession, sessionInfo: sessionInfo, allocation: allocation)
        let monitorSettings = normalizedMonitorSettings(rawSession: rawSession, requestData: requestData, settings: settings, streamingProfileJSON: streamingProfileJSON)
        let streamingProfile = normalizedNativeStreamingProfile(rawSession: rawSession, sessionInfo: sessionInfo, settings: settings, allocation: allocation, streamingProfileJSON: streamingProfileJSON)
        let sessionControlInfo = rawSession["sessionControlInfo"] as? [String: Any] ?? [:]
        let zoneAddress = firstNonEmpty(string(sessionControlInfo["ip"], fallback: ""), string(rawSession["zoneAddress"], fallback: ""), allocation.session.serverAddress)
        let zoneName = firstNonEmpty(string(rawSession["zoneName"], fallback: ""), zoneAddress.split(separator: ".").first.map { String($0).uppercased() } ?? "")
        let sessionId = firstNonEmpty(string(rawSession["sessionId"], fallback: ""), allocation.session.id)
        let bifrostSessionId = firstNonEmpty(string(rawSession["bifrostSessionId"], fallback: ""), string(rawSession["session"], fallback: ""), sessionId)
        let deviceId = firstNonEmpty(string(requestData["deviceHashId"], fallback: ""), string(rawSession["deviceId"], fallback: ""), OPNDeviceIdentity.stableCloudmatchDeviceId())
        let serverAddress = firstNonEmpty(string(rawSession["serverAddress"], fallback: ""), zoneAddress)
        let rawServerPort = int(rawSession["port"])
        let serverPort = int(sessionControlInfo["port"]) > 0 ? int(sessionControlInfo["port"]) : (rawServerPort > 0 ? rawServerPort : 443)
        let applicationHeaders = source.applicationHeaders(allocation: allocation)
        let supportedControls = jsonArray(from: rawSession["supportedControls"]).isEmpty ? jsonArray(from: requestData["supportedControls"]) : jsonArray(from: rawSession["supportedControls"])
        let contentRating = jsonArray(from: rawSession["contentRating"]).isEmpty ? jsonArray(from: requestData["contentRating"]) : jsonArray(from: rawSession["contentRating"])
        let summaryStatsValue = firstValue(in: rawSession, requestData, keys: ["summaryStatsEnabled"])
        let rawFrameLossWarningTimeout = int(firstValue(in: rawSession, requestData, keys: ["frameLossWarningTimeout"]))
        let rawFrameLossErrorTimeout = int(firstValue(in: rawSession, requestData, keys: ["frameLossErrorTimeout"]))
        var normalized: [String: Any] = [
            "sessionId": sessionId,
            "bifrostSessionId": bifrostSessionId,
            "networkSessionId": source.networkSessionId,
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
            "metaData": source.metadata,
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
            "persistingInGameSettings": source.persistingInGameSettings,
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
        if let remoteControllersBitmap = normalizedRemoteControllersBitmap(firstValue(in: rawSession, requestData, settings, keys: ["remoteControllersBitmap"])) {
            normalized["remoteControllersBitmap"] = remoteControllersBitmap
        }
        if let externalAppId = requestData["externalAppId"] { normalized["externalAppId"] = externalAppId }
        if !sessionId.isEmpty { normalized["sessionControlUrl"] = "/v2/session/\(sessionId)" }
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized),
              let string = String(data: data, encoding: .utf8), !string.isEmpty else {
            throw NativeNVSTError.invalidSession("Native NVST session could not be normalized for Geronimo.")
        }
        return string
    }

    private static func modeSelectionProfile(from profile: [String: Any], dimensions: (width: Int, height: Int), finalizedFeatures: [String: Any], requestedFeatures: [String: Any], settings: [String: Any], presentationCapability: OPNStreamPresentationCapability?) -> [String: Any] {
        let fps = int(profile["fps"])
        let scaleFactor = max(int(firstValue(in: profile, keys: ["scaleFactor", "selectedVideoMode.scaleFactor"])), 1)
        let colorQuality = string(profile["colorQuality"], fallback: "")
        let selectedFeatures = selectedFeatures(from: profile, colorQuality: colorQuality, finalizedFeatures: finalizedFeatures, requestedFeatures: requestedFeatures, settings: settings, presentationCapability: presentationCapability)
        let selectedVideoMode = ["width": dimensions.width, "height": dimensions.height, "fps": fps, "scaleFactor": scaleFactor]
        let selectedEncodeMode = ["width": dimensions.width, "height": dimensions.height, "fps": fps]
        var selection: [String: Any] = [
            "selectedVideoMode": selectedVideoMode,
            "selectedFeatures": selectedFeatures,
            "selectedEncodeMode": selectedEncodeMode,
        ]
        let maxPacketSize = int(profile["maxPacketSize"])
        if maxPacketSize >= 512, maxPacketSize <= Int(UInt16.max) { selection["maxPacketSize"] = maxPacketSize }
        return selection
    }

    private static func selectedFeatures(from profile: [String: Any], colorQuality: String, finalizedFeatures: [String: Any], requestedFeatures: [String: Any], settings: [String: Any], presentationCapability: OPNStreamPresentationCapability?) -> [String: Any] {
        let profileFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        let sources = [finalizedFeatures, requestedFeatures, profileFeatures, profile, settings]
        let explicitHDR = featureValue(in: sources, keys: ["hdr", "trueHdr", "enableHdr"])
        let explicitBitDepth = featureValue(in: sources, keys: ["bitDepth"])
        let explicitChromaFormat = featureValue(in: sources, keys: ["chromaFormat"])
        let requestedHDR = explicitHDR == nil ? colorQuality.localizedCaseInsensitiveContains("hdr") : bool(explicitHDR)
        let hdr = presentationCapability.map { requestedHDR && $0.supportsHDR } ?? requestedHDR
        let requestedBitDepth = normalizedFeatureBitDepth(explicitBitDepth, colorQuality: colorQuality)
        let bitDepth = presentationCapability.map { $0.supportsTenBit ? requestedBitDepth : 8 } ?? requestedBitDepth
        return [
            "vvsync": bool(featureValue(in: sources, keys: ["vvsync"])),
            "vsync": int(featureValue(in: sources, keys: ["vsync"])),
            "hdr": hdr,
            "trueHdr": hdr,
            "audioChannelCount": max(int(featureValue(in: sources, keys: ["audioChannelCount", "channels"])), 2),
            "reflex": bool(featureValue(in: sources, keys: ["reflex", "enableReflex"])),
            "bitDepth": bitDepth,
            "cloudGsync": bool(featureValue(in: sources, keys: ["cloudGsync", "enableCloudGsync"])),
            "l4s": bool(featureValue(in: sources, keys: ["l4s", "enabledL4S", "enableL4S"])),
            "hdr10PlusGaming": bool(featureValue(in: sources, keys: ["hdr10PlusGaming"])),
            "supportedHidDevices": int(featureValue(in: sources, keys: ["supportedHidDevices"])),
            "hidDevices": featureValue(in: sources, keys: ["hidDevices"]) ?? [],
            "profile": int(featureValue(in: sources, keys: ["profile", "streamingQualityProfile"])),
            "chromaFormat": explicitChromaFormat == nil ? chromaFormat(from: colorQuality) : int(explicitChromaFormat),
            "fallbackToLogicalResolution": bool(featureValue(in: sources, keys: ["fallbackToLogicalResolution"])),
            "maxBitrateKbps": resolvedMaxBitrateKbps(
                requestedKbps: requestedMaxBitrateKbps(settings),
                negotiatedKbps: int(featureValue(in: sources, keys: ["maxBitrateKbps", "bitrateKbps", "bitrate"]))
            ),
            "dynamicStreamingMode": int(featureValue(in: sources, keys: ["dynamicStreamingMode"])),
            "prefilterParams": prefilterParams(from: sources),
            "hudStreamingParams": hudStreamingParams(from: sources),
        ]
    }

    private static func prefilterParams(from sources: [[String: Any]]) -> [String: Any] {
        [
            "mode": int(featureValue(in: sources, keys: ["prefilterParams.mode", "prefilterMode"])),
            "denoiseLevel": double(featureValue(in: sources, keys: ["prefilterParams.denoiseLevel", "prefilterNoiseReduction", "prefilterDenoise"])),
            "sharpnessLevel": int(featureValue(in: sources, keys: ["prefilterParams.sharpnessLevel", "prefilterSharpness"])),
            "model": int(featureValue(in: sources, keys: ["prefilterParams.model", "prefilterModel"])),
        ]
    }

    private static func hudStreamingParams(from sources: [[String: Any]]) -> [String: Any] {
        [
            "mode": int(featureValue(in: sources, keys: ["hudStreamingParams.mode", "hudStreamingMode"])),
            "scxQpDelta": double(featureValue(in: sources, keys: ["hudStreamingParams.scxQpDelta"])),
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
        if !rawConnections.isEmpty { return rawConnections }
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
        let selectedMaxBitrateKbps = int(selectedFeatures["maxBitrateKbps"])
        if selectedMaxBitrateKbps > 0 { profile["maxBitrateKbps"] = selectedMaxBitrateKbps }
        if profile["colorQuality"] == nil {
            profile["colorQuality"] = int(selectedFeatures["bitDepth"]) >= 10 ? "10bit_420" : "8bit_420"
        }
        return profile
    }

    private static func openNOWStreamingProfileGuid(allocation: NativeNVSTSessionAllocation, streamingProfileJSON: String) -> String {
        let signature = "\(allocation.session.applicationID)|\(streamingProfileJSON)"
        let key = "MacForceNow.NativeNVST.StreamingProfileGuid.\(stableProfileHash(signature))"
        let defaults = OPNAppPreferenceStorage.standard
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
        var connection = source
        connection["usage"] = int(source["usage"])
        connection["ip"] = string(source["ip"], fallback: "")
        connection["port"] = int(source["port"])
        connection["protocol"] = connectionProtocol(source["protocol"])
        connection["resourcePath"] = string(source["resourcePath"], fallback: "")
        connection["appLevelProtocol"] = int(source["appLevelProtocol"])
        return connection
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
        let profile = jsonObject(from: streamingProfileJSON)
        let selectedMode = profile["selectedVideoMode"] as? [String: Any] ?? [:]
        let selectedFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        let rawMonitorSettings = jsonArray(from: rawSession["monitorSettings"])
        if !rawMonitorSettings.isEmpty { return rawMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any], selectedFeatures: selectedFeatures) } }
        let requestMonitorSettings = jsonArray(from: requestData["clientRequestMonitorSettings"])
        if !requestMonitorSettings.isEmpty { return requestMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any], selectedFeatures: selectedFeatures) } }
        let settingsMonitorSettings = jsonArray(from: settings["clientRequestMonitorSettings"])
        if !settingsMonitorSettings.isEmpty { return settingsMonitorSettings.compactMap { normalizedMonitorSetting($0 as? [String: Any], selectedFeatures: selectedFeatures) } }
        return [[
            "monitorId": 0,
            "positionX": 0,
            "positionY": 0,
            "widthInPixels": int(selectedMode["width"]),
            "heightInPixels": int(selectedMode["height"]),
            "framesPerSecond": int(selectedMode["fps"]),
            "sdrHdrMode": bool(selectedFeatures["hdr"]) ? 1 : 0,
            "dpi": int(selectedMode["scaleFactor"]),
            "maxBitrateKbps": int(selectedFeatures["maxBitrateKbps"]),
            "dynamicStreamingMode": int(selectedFeatures["dynamicStreamingMode"]),
            "chromaFormat": int(selectedFeatures["chromaFormat"]),
            "displayData": defaultDisplayData(),
            "hdr10PlusGamingData": defaultHDR10PlusGamingData(),
        ]]
    }

    private static func normalizedMonitorSetting(_ source: [String: Any]?, selectedFeatures: [String: Any] = [:]) -> [String: Any]? {
        guard let source else { return nil }
        // GFN's own client puts the bitrate cap on every monitor entry alongside the geometry
        // (`monitorSettings[].maxBitrateKbps`); Geronimo's stream settings come from here, and
        // an absent cap leaves BifrostSDKExecutor on its 35000 Kbps built-in default.
        let maxBitrateKbps = int(source["maxBitrateKbps"]) > 0 ? int(source["maxBitrateKbps"]) : int(selectedFeatures["maxBitrateKbps"])
        return [
            "monitorId": int(source["monitorId"]),
            "positionX": int(source["positionX"]),
            "positionY": int(source["positionY"]),
            "widthInPixels": int(source["widthInPixels"]),
            "heightInPixels": int(source["heightInPixels"]),
            "framesPerSecond": int(source["framesPerSecond"]),
            "sdrHdrMode": int(source["sdrHdrMode"]),
            "dpi": int(source["dpi"]),
            "maxBitrateKbps": maxBitrateKbps,
            "dynamicStreamingMode": int(source["dynamicStreamingMode"]) > 0 ? int(source["dynamicStreamingMode"]) : int(selectedFeatures["dynamicStreamingMode"]),
            "chromaFormat": int(source["chromaFormat"]) > 0 ? int(source["chromaFormat"]) : int(selectedFeatures["chromaFormat"]),
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
        let profile = jsonObject(from: streamingProfileJSON)
        let selectedFeatures = profile["selectedFeatures"] as? [String: Any] ?? [:]
        var normalized = (rawSession["finalizedStreamingFeatures"] as? [String: Any])
            ?? (requestData["requestedStreamingFeatures"] as? [String: Any])
            ?? [:]
        normalized.merge([
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
        ]) { _, selected in selected }
        normalized["hdr"] = bool(selectedFeatures["hdr"])
        // Geronimo reads the cap from the session's finalized features as well as from the mode
        // selection; leaving the server's resolution-derived value here re-pins the stream.
        let selectedMaxBitrateKbps = int(selectedFeatures["maxBitrateKbps"])
        if selectedMaxBitrateKbps > 0 { normalized["maxBitrateKbps"] = selectedMaxBitrateKbps }
        return normalized
    }

    private static func selectedCodec(rawSessionJSON: String, sessionInfoJSON: String, settingsJSON: String) -> String {
        let rawSession = jsonObject(from: rawSessionJSON)
        let sessionInfo = jsonObject(from: sessionInfoJSON)
        let settings = jsonObject(from: settingsJSON)
        for value in [
            (rawSession["streamingProfile"] as? [String: Any])?["codec"],
            (rawSession["negotiatedStreamProfile"] as? [String: Any])?["codec"],
            (sessionInfo["streamingProfile"] as? [String: Any])?["codec"],
            (sessionInfo["negotiatedStreamProfile"] as? [String: Any])?["codec"],
            settings["codec"],
        ] {
            let codec = normalizedCodec(string(value, fallback: ""))
            if !codec.isEmpty { return codec }
        }
        return "H264"
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

    private static func normalizedFeatureBitDepth(_ value: Any?, colorQuality: String) -> Int {
        guard let value else { return bitDepth(from: nil, colorQuality: colorQuality) }
        let numeric = int(value)
        if numeric == 0 { return 8 }
        if numeric == 1 { return 10 }
        return bitDepth(from: value, colorQuality: colorQuality)
    }

    private static func chromaFormat(from colorQuality: String) -> Int {
        colorQuality.localizedCaseInsensitiveContains("444") ? 2 : 0
    }

    static func normalizedRemoteControllersBitmap(_ value: Any?) -> UInt64? {
        guard !(value is Bool) else { return nil }
        let numeric: UInt64?
        switch value {
        case let value as UInt64:
            numeric = value
        case let value as UInt32:
            numeric = UInt64(value)
        case let value as UInt:
            numeric = UInt64(value)
        case let value as Int where value >= 0:
            numeric = UInt64(value)
        case let value as NSNumber:
            let doubleValue = value.doubleValue
            numeric = doubleValue.isFinite && doubleValue >= 0 && doubleValue.rounded(.towardZero) == doubleValue ? UInt64(exactly: doubleValue) : nil
        case let value as String:
            numeric = UInt64(value)
        default:
            numeric = nil
        }
        guard let numeric, numeric <= UInt64(UInt32.max) else { return nil }
        return numeric
    }

    private static func featureValue(in sources: [[String: Any]], keys: [String]) -> Any? {
        for source in sources {
            for key in keys {
                if let value = nestedValue(in: source, keyPath: key), !isEmptyProfileValue(value) { return value }
            }
        }
        return nil
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

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST transport failed." : error.localizedDescription
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
            "profileMaxPacketSize": String(int(profile["maxPacketSize"])),
            "profileMaxBitrateKbps": String(int(selectedFeatures["maxBitrateKbps"])),
            "geronimoNegotiatedMaxBitrateKbps": String(negotiatedMaxBitrateKbps(rawSessionJSON: allocation.rawSessionJSON, sessionInfoJSON: allocation.sessionInfoJSON)),
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
    private let localInputCaptureHandler: (@MainActor @Sendable () -> Bool)?
    private var errorBuffer = [CChar](repeating: 0, count: 1024)
    private var timer: Timer?
    private var isRunning = false

    init(sessionAddress: UInt, eventSink: NativeNVSTGeronimoEventSink, telemetryAttributes: [String: String], localInputCaptureHandler: (@MainActor @Sendable () -> Bool)? = nil) {
        self.sessionAddress = sessionAddress
        self.eventSink = eventSink
        self.telemetryAttributes = telemetryAttributes
        self.localInputCaptureHandler = localInputCaptureHandler
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
        let localOverlayCapturesInput = MainActor.assumeIsolated { localInputCaptureHandler?() ?? false }
        let processSDLEvents: Int32 = NativeNVSTBifrostTransport.geronimoPumpProcessesSDLEvents(
            inRunLoopMode: RunLoop.main.currentMode,
            localOverlayCapturesInput: localOverlayCapturesInput
        ) ? 1 : 0
        let result = errorBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            baseAddress.pointee = 0
            return MacForceNowNativeNVSTGeronimoPump(UnsafeMutableRawPointer(bitPattern: sessionAddress), 0, processSDLEvents, baseAddress, buffer.count)
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
    private var lock = os_unfair_lock_s()
    private var continuations: [UUID: AsyncStream<NativeNVSTTransportTermination>.Continuation] = [:]
    private var pending: NativeNVSTTransportTermination?

    func stream() -> AsyncStream<NativeNVSTTransportTermination> {
        let id = UUID()
        let pair = AsyncStream<NativeNVSTTransportTermination>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pending: NativeNVSTTransportTermination?
        os_unfair_lock_lock(&lock)
        continuations[id] = pair.continuation
        pending = self.pending
        os_unfair_lock_unlock(&lock)
        if let pending { pair.continuation.yield(pending) }
        pair.continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return pair.stream
    }

    func send(_ termination: NativeNVSTTransportTermination) {
        let continuations: [AsyncStream<NativeNVSTTransportTermination>.Continuation]
        os_unfair_lock_lock(&lock)
        pending = termination
        continuations = Array(self.continuations.values)
        os_unfair_lock_unlock(&lock)
        for continuation in continuations {
            continuation.yield(termination)
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        pending = nil
        os_unfair_lock_unlock(&lock)
    }

    private func remove(_ id: UUID) {
        os_unfair_lock_lock(&lock)
        continuations[id] = nil
        os_unfair_lock_unlock(&lock)
    }
}

final class NativeNVSTGeronimoEventSink: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private let cursorDeliveryLock = NSRecursiveLock()
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
    private var observedPhaseSequence: [Int32] = []
    private var lastPhase: Int32?
    private var lastCallbackType: UInt32?
    private var lastClientEvent: UInt32?
    private var lastNotification: UInt32?
    private var lastResultCode: Int32?
    private var cursorUpdateGeneration: UInt = 0
    private var acceptsCursorUpdates = true

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
        os_unfair_lock_lock(&lock)
        telemetryAttributes.merge(attributes) { _, new in new }
        os_unfair_lock_unlock(&lock)
    }

    func handle(phase: Int32,
                callbackType: UInt32,
                clientEvent: UInt32,
                notification: UInt32,
                resultCode: Int32,
                resultName: String?,
                resumable: Bool,
                sessionAlive: Bool,
                reasonName: String?) {
        os_unfair_lock_lock(&lock)
        observedPhases.insert(phase)
        if observedPhaseSequence.count == 128 { observedPhaseSequence.removeFirst() }
        observedPhaseSequence.append(phase)
        lastPhase = phase
        lastCallbackType = callbackType
        lastClientEvent = clientEvent
        lastNotification = notification
        lastResultCode = resultCode
        let cursorGeneration: UInt?
        if acceptsCursorUpdates, phase == 80, notification == 1 || notification == 2 {
            cursorUpdateGeneration &+= 1
            cursorGeneration = cursorUpdateGeneration
        } else {
            cursorGeneration = nil
        }
        var attributes = telemetryAttributes
        let pausePending = self.pausePending
        os_unfair_lock_unlock(&lock)
        attributes["sessionId"] = sessionId
        attributes["phase"] = String(phase)
        attributes["callbackType"] = String(callbackType)
        attributes["clientEvent"] = String(clientEvent)
        attributes["notification"] = String(notification)
        attributes["resultCode"] = String(resultCode)
        if let resultName, !resultName.isEmpty { attributes["resultName"] = resultName }
        if phase == 62 {
            attributes["resumable"] = String(resumable)
            attributes["sessionAlive"] = String(sessionAlive)
            if let reasonName, !reasonName.isEmpty { attributes["reasonName"] = reasonName }
        }
        WebRTCMediaTelemetry.capture("nvst.geronimo.callback", level: .info, message: "Geronimo native callback observed.", attributes: attributes)

        if phase == 60 || phase == 61 || phase == 62 { invalidateCursorUpdates() }

        if phase == 80, notification == 1 || notification == 2 {
            let visible = notification == 1
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let cursorGeneration else { return }
                    deliverCursorUpdate(visible: visible, generation: cursorGeneration, handler: cursorVisibilityHandler)
                }
            } else {
                Task { @MainActor [weak self, cursorVisibilityHandler] in
                    guard let self, let cursorGeneration else { return }
                    self.deliverCursorUpdate(visible: visible, generation: cursorGeneration, handler: cursorVisibilityHandler)
                }
            }
            return
        }

        if phase == 40 {
            resolveStart(.success(()))
        }
        if callbackType == 2, clientEvent == 14, notification == 1 {
            resolveReadiness(.success(()))
            return
        }
        if callbackType == 2, clientEvent == 14, notification == NativeNVSTTerminationReason.pausedByUser {
            // NVB_SN_PAUSED_BY_USER: the pause completed. Geronimo delivers it on the same
            // notification channel as terminations, but the cloud session stays alive, so
            // reporting a termination here would make the client stop the session and quit
            // the game. Resolve the pending pause instead; a pause nobody asked for (paused
            // from another client) is surfaced as a pause termination, never a stream end.
            resolvePause(.success(()))
            if !pausePending {
                deliverTerminal(.sessionTerminated(NativeNVSTSessionTermination(
                    reason: NativeNVSTTerminationReason(rawValue: notification, resultName: reasonName),
                    extendedResult: NativeNVSTTerminationValue(code: resultCode, name: resultName),
                    isResumable: true,
                    isSessionAlive: true,
                    message: "Native NVST stream paused."
                )))
            }
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
            if wasReady {
                deliverTerminal(.sessionTerminated(NativeNVSTSessionTermination(
                    reason: NativeNVSTTerminationReason(rawValue: notification),
                    extendedResult: NativeNVSTTerminationValue(code: resultCode, name: resultName),
                    isResumable: false,
                    isSessionAlive: false,
                    message: message
                )))
            }
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
            let sessionAlreadyInactive = resultCode == NativeNVSTBifrostTransport.geronimoSessionNotActiveResultCode
            if sessionAlreadyInactive {
                WebRTCMediaTelemetry.capture(
                    "nvst.geronimo.stop.session_inactive",
                    level: .info,
                    message: "Native NVST stop reported the session was already inactive.",
                    attributes: attributes
                )
            }
            resolveStop(resultCode == 0 || sessionAlreadyInactive ? .success(()) : .failure(NativeNVSTError.transportFailed("Native NVST stop failed with result \(resultCode).")))
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
            if wasReady {
                deliverTerminal(.sessionTerminated(NativeNVSTSessionTermination(
                    reason: NativeNVSTTerminationReason(rawValue: 0),
                    extendedResult: NativeNVSTTerminationValue(code: resultCode, name: resultName),
                    isResumable: false,
                    isSessionAlive: false,
                    message: message
                )))
            }
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
            if wasReady {
                deliverTerminal(.sessionTerminated(NativeNVSTSessionTermination(
                    reason: NativeNVSTTerminationReason(rawValue: notification, resultName: reasonName),
                    extendedResult: NativeNVSTTerminationValue(code: resultCode, name: resultName),
                    isResumable: resumable,
                    isSessionAlive: sessionAlive,
                    message: message
                )))
            }
            return
        }
        if phase == 70 {
            let error = NativeNVSTBifrostTransport.geronimoCallbackError(resultCode: resultCode, resultName: resultName)
            fail(error, transportFailure: NativeNVSTBifrostTransport.transportFailure(resultCode: resultCode, resultName: resultName, message: Self.message(for: error)))
        }
    }

    @MainActor private func deliverCursorUpdate(visible: Bool,
                                                generation: UInt,
                                                handler: (@MainActor @Sendable (Bool) -> Void)?) {
        cursorDeliveryLock.lock()
        defer { cursorDeliveryLock.unlock() }
        os_unfair_lock_lock(&lock)
        guard acceptsCursorUpdates, cursorUpdateGeneration == generation else {
            os_unfair_lock_unlock(&lock)
            return
        }
        os_unfair_lock_unlock(&lock)
        handler?(visible)
    }

    private func invalidateCursorUpdates() {
        cursorDeliveryLock.lock()
        defer { cursorDeliveryLock.unlock() }
        os_unfair_lock_lock(&lock)
        acceptsCursorUpdates = false
        cursorUpdateGeneration &+= 1
        os_unfair_lock_unlock(&lock)
    }

    func readinessDiagnosticAttributes() -> [String: String] {
        os_unfair_lock_lock(&lock)
        let phases = observedPhases.sorted()
        let phaseSequence = observedPhaseSequence
        let lastPhase = self.lastPhase
        let lastCallbackType = self.lastCallbackType
        let lastClientEvent = self.lastClientEvent
        let lastNotification = self.lastNotification
        let lastResultCode = self.lastResultCode
        os_unfair_lock_unlock(&lock)

        var attributes = [
            "observedPhases": phases.map(String.init).joined(separator: ","),
            "observedPhaseSequence": phaseSequence.map(String.init).joined(separator: ","),
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
                os_unfair_lock_lock(&lock)
                if let readinessResult {
                    os_unfair_lock_unlock(&lock)
                    continuation.resume(with: readinessResult)
                    return
                }
                readinessCompletion = continuation
                os_unfair_lock_unlock(&lock)

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
                os_unfair_lock_lock(&lock)
                if let startResult {
                    os_unfair_lock_unlock(&lock)
                    continuation.resume(with: startResult)
                    return
                }
                startCompletion = continuation
                os_unfair_lock_unlock(&lock)

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolveStart(.failure(NativeNVSTError.transportFailed("Native NVST local setup did not deliver Geronimo start within 30 seconds.")))
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func fail(_ error: Error, transportFailure: NativeNVSTTransportFailure? = nil) {
        invalidateCursorUpdates()
        let wasReady = hasReachedReadiness
        resolveStart(.failure(error))
        resolveReadiness(.failure(error))
        resolvePause(.failure(error))
        resolveStop(.failure(error))
        if wasReady {
            deliverTerminal(.transportFailed(transportFailure ?? NativeNVSTTransportFailure(
                message: Self.message(for: error),
                recoveryClassification: .permanent
            )))
        }
    }

    func cancel() {
        invalidateCursorUpdates()
        resolveStart(.failure(CancellationError()))
        resolveReadiness(.failure(CancellationError()))
        resolvePause(.failure(CancellationError()))
        resolveStop(.failure(CancellationError()))
    }

    func beginPause() {
        os_unfair_lock_lock(&lock)
        pausePending = true
        pauseResult = nil
        pauseCompletion = nil
        os_unfair_lock_unlock(&lock)
    }

    func waitForPause(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                os_unfair_lock_lock(&lock)
                if let pauseResult {
                    os_unfair_lock_unlock(&lock)
                    continuation.resume(with: pauseResult)
                    return
                }
                pauseCompletion = continuation
                os_unfair_lock_unlock(&lock)
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
        os_unfair_lock_lock(&lock)
        stopPending = true
        stopResult = nil
        stopCompletion = nil
        os_unfair_lock_unlock(&lock)
    }

    func waitForStop(timeoutNanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                os_unfair_lock_lock(&lock)
                if let stopResult {
                    os_unfair_lock_unlock(&lock)
                    continuation.resume(with: stopResult)
                    return
                }
                stopCompletion = continuation
                os_unfair_lock_unlock(&lock)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolveStop(.failure(NativeNVSTError.transportFailed(NativeNVSTBifrostTransport.geronimoStopTimeoutMessage)))
                }
            }
        } onCancel: { [weak self] in
            self?.cancelStop()
        }
    }

    func cancelStop() {
        resolveStop(.failure(CancellationError()))
    }

    func failStop(_ error: Error) {
        resolveStop(.failure(error))
    }

    private var hasReachedReadiness: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let readinessResult else { return false }
        if case .success = readinessResult { return true }
        return false
    }

    var hasDeliveredTerminal: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return terminalDelivered
    }

    private func resolveReadiness(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        os_unfair_lock_lock(&lock)
        if readinessResult != nil {
            os_unfair_lock_unlock(&lock)
            return
        }
        readinessResult = result
        continuation = readinessCompletion
        readinessCompletion = nil
        os_unfair_lock_unlock(&lock)
        continuation?.resume(with: result)
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        os_unfair_lock_lock(&lock)
        if startResult != nil {
            os_unfair_lock_unlock(&lock)
            return
        }
        startResult = result
        continuation = startCompletion
        startCompletion = nil
        os_unfair_lock_unlock(&lock)
        continuation?.resume(with: result)
    }

    private func resolvePause(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        os_unfair_lock_lock(&lock)
        guard pausePending else {
            os_unfair_lock_unlock(&lock)
            return
        }
        pausePending = false
        pauseResult = result
        continuation = pauseCompletion
        pauseCompletion = nil
        os_unfair_lock_unlock(&lock)
        continuation?.resume(with: result)
    }

    private func resolveStop(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Void, Error>?
        os_unfair_lock_lock(&lock)
        guard stopPending else {
            os_unfair_lock_unlock(&lock)
            return
        }
        stopPending = false
        stopResult = result
        continuation = stopCompletion
        stopCompletion = nil
        os_unfair_lock_unlock(&lock)
        continuation?.resume(with: result)
    }

    private func deliverTerminal(_ termination: NativeNVSTTransportTermination) {
        invalidateCursorUpdates()
        os_unfair_lock_lock(&lock)
        guard !terminalDelivered else {
            os_unfair_lock_unlock(&lock)
            return
        }
        terminalDelivered = true
        os_unfair_lock_unlock(&lock)
        terminationHandler(termination)
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST transport failed." : error.localizedDescription
    }
}

public final class NativeNVSTAuthRefreshCoordinator: @unchecked Sendable {
    public typealias Handler = @Sendable (UInt32) async throws -> String

    private let expectedAuthType: UInt32?
    private let timeout: DispatchTimeInterval
    private let handler: Handler
    private var lock = os_unfair_lock_s()
    private var requests: [UUID: NativeNVSTAuthRefreshRequest] = [:]
    private var cancelled = false

    public init(expectedAuthType: UInt32?, timeout: DispatchTimeInterval = .milliseconds(250), handler: @escaping Handler) {
        self.expectedAuthType = expectedAuthType
        self.timeout = timeout
        self.handler = handler
    }

    public static func authType(for tokenType: String) -> UInt32? {
        switch tokenType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "7", "JARVIS", "NVB_AUTH_JARVIS": 7
        case "8", "JWT", "NVB_AUTH_JWT": 8
        case "9", "JWT_GFN", "JWT-GFN", "NVB_AUTH_JWT_GFN": 9
        default: nil
        }
    }

    public static func productionToken(authType: UInt32, sessionRefresher: any SessionTokenRefreshing) async throws -> String {
        let session = try await sessionRefresher.refreshSession(forceRefresh: true)
        let token = token(from: session, authType: authType)
        guard (7...9).contains(authType), !token.isEmpty else {
            throw NativeNVSTError.invalidSession("Forced session refresh did not return the required authentication token.")
        }
        return token
    }

    static func token(from session: OPNAuthSession, authType: UInt32) -> String {
        authType == 8 ? session.idToken : session.accessToken
    }

    public func copyRefreshedToken(authType: UInt32, response: UnsafeMutablePointer<CChar>, capacity: Int) {
        guard capacity > 0 else { return }
        response[0] = 0
        guard capacity > 1 else { return }
        guard expectedAuthType == nil || expectedAuthType == authType else { return }
        let id = UUID()
        let request = NativeNVSTAuthRefreshRequest()
        os_unfair_lock_lock(&lock)
        guard !cancelled else {
            os_unfair_lock_unlock(&lock)
            return
        }
        requests[id] = request
        os_unfair_lock_unlock(&lock)
        let handler = self.handler
        request.setTask(Task.detached(priority: .userInitiated) {
            do {
                request.complete(with: Data(try await handler(authType).utf8))
            } catch {
                request.complete(with: nil)
            }
        })
        let data = request.wait(timeout: timeout)
        os_unfair_lock_lock(&lock)
        requests.removeValue(forKey: id)
        os_unfair_lock_unlock(&lock)
        guard let data else {
            request.cancel()
            return
        }
        let byteCount = min(data.count, capacity - 1)
        data.copyBytes(to: UnsafeMutableRawBufferPointer(start: response, count: byteCount), count: byteCount)
        response[byteCount] = 0
    }

    public func cancel() {
        os_unfair_lock_lock(&lock)
        cancelled = true
        let activeRequests = Array(requests.values)
        requests.removeAll()
        os_unfair_lock_unlock(&lock)
        activeRequests.forEach { $0.cancel() }
    }
}

private final class NativeNVSTAuthRefreshRequest: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private let semaphore = DispatchSemaphore(value: 0)
    private var task: Task<Void, Never>?
    private var result: Data?
    private var completed = false

    func setTask(_ task: Task<Void, Never>) {
        os_unfair_lock_lock(&lock)
        if completed {
            os_unfair_lock_unlock(&lock)
            task.cancel()
            return
        }
        self.task = task
        os_unfair_lock_unlock(&lock)
    }

    func complete(with result: Data?) {
        os_unfair_lock_lock(&lock)
        guard !completed else {
            os_unfair_lock_unlock(&lock)
            return
        }
        completed = true
        self.result = result
        task = nil
        os_unfair_lock_unlock(&lock)
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Data? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        os_unfair_lock_lock(&lock)
        let result = self.result
        os_unfair_lock_unlock(&lock)
        return result
    }

    func cancel() {
        os_unfair_lock_lock(&lock)
        guard !completed else {
            os_unfair_lock_unlock(&lock)
            return
        }
        completed = true
        let task = self.task
        self.task = nil
        os_unfair_lock_unlock(&lock)
        task?.cancel()
        semaphore.signal()
    }
}

private final class NativeNVSTHapticSink: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var handler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)?
    private var resetHandler: (@MainActor @Sendable () -> Void)?

    init(handler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)?, resetHandler: (@MainActor @Sendable () -> Void)?) {
        self.handler = handler
        self.resetHandler = resetHandler
    }

    func receive(_ command: NativeNVSTHapticCommand) {
        os_unfair_lock_lock(&lock)
        let handler = self.handler
        os_unfair_lock_unlock(&lock)
        guard let handler else { return }
        Task { @MainActor in handler(command) }
    }

    func cancel() async {
        let resetHandler = detach()
        if let resetHandler { await MainActor.run { resetHandler() } }
    }

    private func detach() -> (@MainActor @Sendable () -> Void)? {
        os_unfair_lock_lock(&lock)
        let resetHandler = self.resetHandler
        handler = nil
        self.resetHandler = nil
        os_unfair_lock_unlock(&lock)
        return resetHandler
    }
}

private final class NativeNVSTRuntimeHandlers: @unchecked Sendable {
    let authRefresh: NativeNVSTAuthRefreshCoordinator
    let haptic: NativeNVSTHapticSink

    init(expectedAuthType: UInt32?,
         authRefreshHandler: @escaping NativeNVSTAuthRefreshCoordinator.Handler,
         hapticHandler: (@MainActor @Sendable (NativeNVSTHapticCommand) -> Void)?,
         hapticResetHandler: (@MainActor @Sendable () -> Void)?) {
        authRefresh = NativeNVSTAuthRefreshCoordinator(expectedAuthType: expectedAuthType, handler: authRefreshHandler)
        haptic = NativeNVSTHapticSink(handler: hapticHandler, resetHandler: hapticResetHandler)
    }

    var authRefreshContext: UnsafeMutableRawPointer { Unmanaged.passUnretained(authRefresh).toOpaque() }
    var hapticContext: UnsafeMutableRawPointer { Unmanaged.passUnretained(haptic).toOpaque() }

    func cancel() async {
        authRefresh.cancel()
        await haptic.cancel()
    }
}

private func nativeNVSTGeronimoHapticCallback(_ context: UnsafeMutableRawPointer?, _ player: UInt16, _ lowFrequency: UInt16, _ highFrequency: UInt16, _ durationMilliseconds: UInt16) {
    guard let context else { return }
    Unmanaged<NativeNVSTHapticSink>.fromOpaque(context).takeUnretainedValue().receive(NativeNVSTHapticCommand(
        playerIndex: Int(player),
        lowFrequency: lowFrequency,
        highFrequency: highFrequency,
        durationMilliseconds: durationMilliseconds
    ))
}

private func nativeNVSTGeronimoAuthRefreshCallback(_ context: UnsafeMutableRawPointer?, _ authType: UInt32, _ response: UnsafeMutablePointer<CChar>?, _ capacity: Int) {
    guard let context, let response else { return }
    Unmanaged<NativeNVSTAuthRefreshCoordinator>.fromOpaque(context).takeUnretainedValue().copyRefreshedToken(authType: authType, response: response, capacity: capacity)
}

private func nativeNVSTGeronimoEventCallback(_ context: UnsafeMutableRawPointer?, _ phase: Int32, _ callbackType: UInt32, _ clientEvent: UInt32, _ notification: UInt32, _ resultCode: Int32, _ resultName: UnsafePointer<CChar>?, _ resumable: UInt32, _ sessionAlive: UInt32, _ reasonName: UnsafePointer<CChar>?) {
    guard let context else { return }
    let sink = Unmanaged<NativeNVSTGeronimoEventSink>.fromOpaque(context).takeUnretainedValue()
    sink.handle(
        phase: phase,
        callbackType: callbackType,
        clientEvent: clientEvent,
        notification: notification,
        resultCode: resultCode,
        resultName: resultName.map { String(cString: $0) },
        resumable: resumable != 0,
        sessionAlive: sessionAlive != 0,
        reasonName: reasonName.map { String(cString: $0) }
    )
}

private typealias NativeNVSTGeronimoEventHandler = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, UInt32, UInt32, Int32, UnsafePointer<CChar>?, UInt32, UInt32, UnsafePointer<CChar>?) -> Void
private typealias NativeNVSTGeronimoHapticHandler = @convention(c) (UnsafeMutableRawPointer?, UInt16, UInt16, UInt16, UInt16) -> Void
private typealias NativeNVSTGeronimoAuthRefreshHandler = @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<CChar>?, Int) -> Void

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

@_silgen_name("MacForceNowNativeNVSTGeronimoCreate")
private func MacForceNowNativeNVSTGeronimoCreate(_ frameworksPath: UnsafePointer<CChar>?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> UnsafeMutableRawPointer?

@_silgen_name("MacForceNowNativeNVSTGeronimoSetEventHandler")
private func MacForceNowNativeNVSTGeronimoSetEventHandler(_ session: UnsafeMutableRawPointer?, _ eventHandler: NativeNVSTGeronimoEventHandler?, _ eventContext: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetHapticHandler")
private func MacForceNowNativeNVSTGeronimoSetHapticHandler(_ session: UnsafeMutableRawPointer?, _ handler: NativeNVSTGeronimoHapticHandler?, _ context: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetAuthRefreshHandler")
private func MacForceNowNativeNVSTGeronimoSetAuthRefreshHandler(_ session: UnsafeMutableRawPointer?, _ handler: NativeNVSTGeronimoAuthRefreshHandler?, _ context: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetVideoSurface")
private func MacForceNowNativeNVSTGeronimoSetVideoSurface(_ session: UnsafeMutableRawPointer?, _ nativeHandle: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

// Currently unused: the transport always drives GeronimoResume because allocateSession
// already creates the CloudMatch session before the native phase runs. Kept as the
// reference binding for the GridApp::start entry point (and its shim implementation) in
// case a future first-party allocation path needs to start rather than resume a session.
@_silgen_name("MacForceNowNativeNVSTGeronimoStart")
private func MacForceNowNativeNVSTGeronimoStart(_ session: UnsafeMutableRawPointer?, _ rawSessionJSON: UnsafePointer<CChar>?, _ streamingProfileJSON: UnsafePointer<CChar>?, _ cloudSessionJSON: UnsafePointer<CChar>?, _ gameLanguage: UnsafePointer<CChar>?, _ clientAppVersion: UnsafePointer<CChar>?, _ clientLocale: UnsafePointer<CChar>?, _ traceParent: UnsafePointer<CChar>?, _ authTokenType: UnsafePointer<CChar>?, _ authToken: UnsafePointer<CChar>?, _ microphoneAvailable: Int32, _ microphoneEnabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoResume")
private func MacForceNowNativeNVSTGeronimoResume(_ session: UnsafeMutableRawPointer?, _ rawSessionJSON: UnsafePointer<CChar>?, _ streamingProfileJSON: UnsafePointer<CChar>?, _ cloudSessionJSON: UnsafePointer<CChar>?, _ gameLanguage: UnsafePointer<CChar>?, _ clientAppVersion: UnsafePointer<CChar>?, _ clientLocale: UnsafePointer<CChar>?, _ traceParent: UnsafePointer<CChar>?, _ authTokenType: UnsafePointer<CChar>?, _ authToken: UnsafePointer<CChar>?, _ microphoneAvailable: Int32, _ microphoneEnabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetMicrophoneEnabled")
private func MacForceNowNativeNVSTGeronimoSetMicrophoneEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetMicrophoneVolume")
private func MacForceNowNativeNVSTGeronimoSetMicrophoneVolume(_ session: UnsafeMutableRawPointer?, _ volume: Double) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetVoiceActivityEnabled")
private func MacForceNowNativeNVSTGeronimoSetVoiceActivityEnabled(_ session: UnsafeMutableRawPointer?, _ enabled: Int32) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoPump")
private func MacForceNowNativeNVSTGeronimoPump(_ session: UnsafeMutableRawPointer?, _ waitTimeoutMilliseconds: Int32, _ processSDLEvents: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoPause")
private func MacForceNowNativeNVSTGeronimoPause(_ session: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSendInput")
private func MacForceNowNativeNVSTGeronimoSendInput(_ session: UnsafeMutableRawPointer?, _ inputEventBytes: UnsafePointer<UInt8>?, _ inputEventByteCount: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSendAbsoluteMouse")
private func MacForceNowNativeNVSTGeronimoSendAbsoluteMouse(_ session: UnsafeMutableRawPointer?, _ windowX: Int32, _ windowY: Int32, _ timestampNanoseconds: UInt64, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoTogglePerformanceOverlay")
private func MacForceNowNativeNVSTGeronimoTogglePerformanceOverlay(_ session: UnsafeMutableRawPointer?, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

/// Enables recording of Geronimo's decoded frames for pillarbox blur fill. Kept off
/// unless a zoom/mirror fill mode is selected. Module-internal so the client-side
/// overlay renderer can drive it.
@_silgen_name("MacForceNowNativeNVSTGeronimoSetFrameCaptureActive")
func MacForceNowNativeNVSTGeronimoSetFrameCaptureActive(_ active: Bool)

/// Copies the most recently captured decoded frame, retained (+1). Wrap the result
/// with `Unmanaged<CVPixelBuffer>.fromOpaque(_:).takeRetainedValue()`. NULL when no
/// frame has been captured or capture is inactive.
@_silgen_name("MacForceNowNativeNVSTGeronimoCopyLatestVideoFrame")
func MacForceNowNativeNVSTGeronimoCopyLatestVideoFrame() -> OpaquePointer?

/// -1 when the capture hook failed to install, else count of frames captured.
@_silgen_name("MacForceNowNativeNVSTGeronimoFrameCaptureCount")
func MacForceNowNativeNVSTGeronimoFrameCaptureCount() -> Int64

/// Latest captured frame size packed as (width << 32 | height), 0 if none.
@_silgen_name("MacForceNowNativeNVSTGeronimoLatestVideoFrameSize")
func MacForceNowNativeNVSTGeronimoLatestVideoFrameSize() -> UInt64

/// Install progress: 0 not-attempted, 1 branch-reached, 2 dlsym-avfp-failed,
/// 3 cv-target-failed, 4 slot-not-found, 5 slot-bad, 6 cas-failed, 7 installed.
@_silgen_name("MacForceNowNativeNVSTGeronimoFrameCaptureInstallStatus")
func MacForceNowNativeNVSTGeronimoFrameCaptureInstallStatus() -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetStreamingMaxBitrate")
private func MacForceNowNativeNVSTGeronimoSetStreamingMaxBitrate(_ session: UnsafeMutableRawPointer?, _ bitrateKbps: UInt32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetDynamicStreamingMode")
private func MacForceNowNativeNVSTGeronimoSetDynamicStreamingMode(_ session: UnsafeMutableRawPointer?, _ mode: UInt32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSetL4SState")
private func MacForceNowNativeNVSTGeronimoSetL4SState(_ session: UnsafeMutableRawPointer?, _ enabled: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoUpdateGamepadTopology")
private func MacForceNowNativeNVSTGeronimoUpdateGamepadTopology(_ session: UnsafeMutableRawPointer?, _ connectedPlayerBitmap: UInt8, _ hapticPlayerBitmap: UInt8, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoCopyPerformanceStats")
private func MacForceNowNativeNVSTGeronimoCopyPerformanceStats(_ session: UnsafeMutableRawPointer?, _ performanceStatsBytes: UnsafeMutableRawPointer?, _ performanceStatsByteCount: Int, _ serverLocationBuffer: UnsafeMutablePointer<CChar>?, _ serverLocationBufferLength: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoSendText")
private func MacForceNowNativeNVSTGeronimoSendText(_ session: UnsafeMutableRawPointer?, _ utf8Bytes: UnsafePointer<UInt8>?, _ utf8ByteCount: Int, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoStopWithResult")
private func MacForceNowNativeNVSTGeronimoStopWithResult(_ session: UnsafeMutableRawPointer?, _ reason: UnsafePointer<CChar>?, _ code: Int32, _ errorBuffer: UnsafeMutablePointer<CChar>?, _ errorBufferLength: Int) -> Int32

@_silgen_name("MacForceNowNativeNVSTGeronimoDestroy")
private func MacForceNowNativeNVSTGeronimoDestroy(_ session: UnsafeMutableRawPointer?)

@_silgen_name("MacForceNowNativeNVSTGeronimoDestroyWithResult")
private func MacForceNowNativeNVSTGeronimoDestroyWithResult(_ session: UnsafeMutableRawPointer?) -> Int32
