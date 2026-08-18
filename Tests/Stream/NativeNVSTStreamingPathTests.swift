import AVFoundation
import Foundation
import Testing
@testable import OpenNOW

private struct RecordedNativeNVSTFinish: Equatable, Sendable {
    let session: StreamSessionDescriptor
    let reason: StreamEndReason
}

private actor NativeNVSTProgressRecorder {
    private(set) var steps: [StreamLaunchStep] = []

    func append(_ step: StreamLaunchStep) {
        steps.append(step)
    }
}

private actor RecordingNativeNVSTSessionProvider: NativeNVSTSessionProvider, StreamSessionStartCancellable {
    private(set) var startCount = 0
    private(set) var finished: [RecordedNativeNVSTFinish] = []
    private(set) var cancelCount = 0
    private(set) var recoveryCount = 0
    let allocation: NativeNVSTSessionAllocation
    let recoveryError: NativeNVSTError?
    let finishError: NativeNVSTError?
    let suspendsRecovery: Bool
    private var recoveryContinuation: CheckedContinuation<NativeNVSTSessionAllocation, Error>?

    init(allocation: NativeNVSTSessionAllocation = nativeAllocation(), recoveryError: NativeNVSTError? = nil, finishError: NativeNVSTError? = nil, suspendsRecovery: Bool = false) {
        self.allocation = allocation
        self.recoveryError = recoveryError
        self.finishError = finishError
        self.suspendsRecovery = suspendsRecovery
    }

    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
        startCount += 1
        return allocation
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        finished.append(RecordedNativeNVSTFinish(session: session, reason: reason))
        if let finishError { throw finishError }
    }

    func recoverNativeNVSTSession(configuration: StreamLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation {
        recoveryCount += 1
        if let recoveryError { throw recoveryError }
        if suspendsRecovery {
            return try await withCheckedThrowingContinuation { continuation in
                recoveryContinuation = continuation
            }
        }
        return allocation
    }

    func failSuspendedRecovery() {
        recoveryContinuation?.resume(throwing: NativeNVSTError.invalidSession("resume cancelled"))
        recoveryContinuation = nil
    }

    func cancelSessionStart() async {
        cancelCount += 1
    }
}

private actor RecordingNativeNVSTTransport: NativeNVSTTransport {
    enum Mode: Sendable {
        case prepareFailure
        case connectFailure
        case sessionLimitFailure
        case suspendedConnect
        case success
    }

    private(set) var prepareCount = 0
    private(set) var connectCount = 0
    private(set) var sentEvents: [UserInputEvent] = []
    private(set) var sentAbsoluteMouseEvents: [NativeNVSTAbsoluteMouseEvent] = []
    private(set) var microphoneEnabledUpdates: [Bool] = []
    private(set) var microphoneConfigurations: [NativeNVSTMicrophoneConfiguration] = []
    private(set) var disconnectCount = 0
    private(set) var pauseCount = 0
    private(set) var performanceOverlayToggleCount = 0
    private(set) var performanceSnapshotReadCount = 0
    private(set) var maximumBitrateUpdates: [UInt32] = []
    private(set) var dynamicStreamingModeUpdates: [NativeNVSTDynamicStreamingMode] = []
    private(set) var l4sUpdates: [Bool] = []
    private let mode: Mode
    private let terminalStream: AsyncStream<NativeNVSTTransportTermination>
    private let terminalContinuation: AsyncStream<NativeNVSTTransportTermination>.Continuation
    private var connectContinuation: CheckedContinuation<NativeNVSTTransportConnection, Error>?
    private var connectStartedContinuations: [CheckedContinuation<Void, Never>] = []

    init(mode: Mode) {
        self.mode = mode
        let pair = AsyncStream<NativeNVSTTransportTermination>.makeStream()
        terminalStream = pair.stream
        terminalContinuation = pair.continuation
    }

    func prepare() async throws -> NVSTNativeBridgeStatus {
        prepareCount += 1
        if case .prepareFailure = mode {
            throw NativeNVSTError.runtimeUnavailable("runtime missing")
        }
        let libraryURL = URL(fileURLWithPath: "/tmp/libBifrost2.dylib")
        return NVSTNativeBridgeStatus(libraryURL: libraryURL, bundledArtifactURLs: [libraryURL], resolvedSymbols: ["nvstCreateClient"], runtimeAvailable: true)
    }

    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        connectCount += 1
        connectStartedContinuations.forEach { $0.resume() }
        connectStartedContinuations.removeAll()
        if case .connectFailure = mode {
            throw NativeNVSTError.privateABIUnavailable("abi unavailable")
        }
        if case .sessionLimitFailure = mode {
            throw NativeNVSTError.sessionLimitReached
        }
        if case .suspendedConnect = mode {
            return try await withCheckedThrowingContinuation { continuation in
                connectContinuation = continuation
            }
        }
        await mediaReceiver.receiveVideoFrame(NativeNVSTVideoFrame(streamID: 1, codec: .h264, timestamp: MediaTimestamp(nanoseconds: 1), durationNanoseconds: 16_666_667, width: 1920, height: 1080, isKeyFrame: true, payload: Data([1, 2, 3])))
        return NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: try await prepare())
    }

    func waitForConnect() async {
        if connectCount > 0 { return }
        await withCheckedContinuation { continuation in
            connectStartedContinuations.append(continuation)
        }
    }

    func send(_ event: UserInputEvent) async throws {
        sentEvents.append(event)
    }

    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        sentAbsoluteMouseEvents.append(event)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        microphoneEnabledUpdates.append(enabled)
    }

    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {
        microphoneConfigurations.append(configuration)
    }

    func togglePerformanceOverlay() async throws {
        performanceOverlayToggleCount += 1
    }

    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        performanceSnapshotReadCount += 1
        return nativePerformanceSnapshot()
    }

    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        maximumBitrateUpdates.append(bitrateKbps)
    }

    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        dynamicStreamingModeUpdates.append(mode)
    }

    func setL4SEnabled(_ enabled: Bool) async throws {
        l4sUpdates.append(enabled)
    }

    func disconnect() async {
        disconnectCount += 1
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
    }

    func pause() async throws {
        pauseCount += 1
    }

    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        terminalStream
    }

    func sendTermination(_ termination: NativeNVSTTransportTermination) {
        terminalContinuation.yield(termination)
    }
}

@Test func nativeNVSTPathPrepareFailureDoesNotAllocateCloudSession() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .prepareFailure)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected prepare failure")
    } catch let error as NativeNVSTError {
        #expect(error == .runtimeUnavailable("runtime missing"))
    }

    #expect(await provider.startCount == 0)
    #expect(await transport.prepareCount == 1)
}

@Test func nativeNVSTPathConnectFailureFinishesAllocatedSession() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .connectFailure)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected connect failure")
    } catch let error as NativeNVSTError {
        #expect(error == .privateABIUnavailable("abi unavailable"))
    }

    #expect(await provider.startCount == 1)
    #expect(await provider.finished == [nativeFinish(.failed)])
    #expect(await transport.disconnectCount == 1)
}

@Test func nativeNVSTPathRejectsActorReentrantConcurrentStart() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .suspendedConnect)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    let firstStart = Task { try await path.start(configuration: nativeConfiguration()) }
    await transport.waitForConnect()

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected concurrent start rejection")
    } catch let error as NativeNVSTError {
        #expect(error == .alreadyRunning)
    }

    #expect(await provider.startCount == 1)
    #expect(await transport.connectCount == 1)
    firstStart.cancel()
    do {
        _ = try await firstStart.value
        Issue.record("Expected first start cancellation")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func nativeNVSTPathSessionLimitDoesNotMakeFreshAllocationResumable() async throws {
    let allocation = nativeAllocation()
    let provider = RecordingNativeNVSTSessionProvider(allocation: allocation)
    let transport = RecordingNativeNVSTTransport(mode: .sessionLimitFailure)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    do {
        _ = try await path.start(configuration: nativeConfiguration())
        Issue.record("Expected active-session conflict")
    } catch let error as OpenNOWStreamSessionError {
        guard case .activeSessionConflict(let conflict) = error else {
            Issue.record("Expected active-session conflict, received \(error)")
            return
        }
        #expect(conflict.sessionID == allocation.session.id)
        #expect(conflict.applicationID == allocation.session.applicationID)
        #expect(conflict.serverAddress == allocation.session.serverAddress)
        #expect(conflict.isResumable == false)
        #expect(error.errorDescription?.contains("Resume") == false)
        #expect(StreamSessionConflict(reportMetadata: conflict.reportMetadata) == conflict)
    }

    #expect(await provider.finished == [nativeFinish(.failed)])
    #expect(await transport.disconnectCount == 1)
}

@Test func nativeNVSTPathStartsSendsInputAndStops() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    let progressRecorder = NativeNVSTProgressRecorder()

    let session = try await path.start(configuration: nativeConfiguration()) { progress in
        if let step = StreamLaunchStep(rawValue: progress.currentStepIndex) {
            await progressRecorder.append(step)
        }
    }
    let input = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 4, scanCode: 4, isPressed: true, timestamp: MediaTimestamp(nanoseconds: 1)))
    let absoluteMouseEvent = NativeNVSTAbsoluteMouseEvent(x: 640, y: 360, timestamp: MediaTimestamp(nanoseconds: 2))
    let microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: 0.5, mode: "voice-activity")
    try await path.setMicrophoneConfiguration(microphoneConfiguration)
    try await path.send(input)
    try await path.sendAbsoluteMouseMove(absoluteMouseEvent)
    try await path.setMicrophoneEnabled(true)
    try await path.setMicrophoneEnabled(false)
    try await path.togglePerformanceOverlay()
    let report = try await path.stop(reason: .userRequested, message: "Stopped")

    #expect(session == nativeAllocation().session)
    #expect(await progressRecorder.steps.contains(.checkNetworkRoute))
    #expect(await progressRecorder.steps.contains(.allocateCloudSession))
    #expect(await progressRecorder.steps.contains(.connected))
    #expect(await transport.sentEvents == [input])
    #expect(await transport.sentAbsoluteMouseEvents == [absoluteMouseEvent])
    #expect(await transport.microphoneEnabledUpdates == [true, false])
    #expect(await transport.microphoneConfigurations == [microphoneConfiguration])
    #expect(await transport.performanceOverlayToggleCount == 1)
    #expect(await provider.finished == [nativeFinish(.userRequested)])
    #expect(report.metadata["transport"] == "nvst")
}

@Test func nativeNVSTPathStopFinalizesLocallyBeforePropagatingCloudFinishFailure() async throws {
    let finishError = NativeNVSTError.transportFailed("cloud stop failed")
    let provider = RecordingNativeNVSTSessionProvider(finishError: finishError)
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    var audioFrames = await path.audioFrames().makeAsyncIterator()
    _ = try await path.start(configuration: nativeConfiguration())

    do {
        _ = try await path.stop(reason: .userRequested, message: "Stopped locally")
        Issue.record("Expected cloud finish failure")
    } catch let error as NativeNVSTError {
        #expect(error == finishError)
    }

    #expect(await audioFrames.next() == nil)
    #expect(await provider.finished == [nativeFinish(.userRequested)])
    if case .ended(let report) = await path.currentState() {
        #expect(report.reason == .userRequested)
        #expect(report.message == "Stopped locally")
        #expect(report.metadata["cloudFinishError"] == "cloud stop failed")
    } else {
        Issue.record("Expected terminal local state after cloud finish failure")
    }
}

@Test func nativeNVSTPathRejectsPerformanceOverlayToggleWhenStopped() async throws {
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: RecordingNativeNVSTSessionProvider(), transport: transport)

    do {
        try await path.togglePerformanceOverlay()
        Issue.record("Expected stopped path to reject performance overlay toggle")
    } catch let error as NativeNVSTError {
        #expect(error == .notRunning)
    }

    #expect(await transport.performanceOverlayToggleCount == 0)
}

@Test func nativeNVSTPathRejectsMicrophoneUpdateWhenStopped() async throws {
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: RecordingNativeNVSTSessionProvider(), transport: transport)

    do {
        try await path.setMicrophoneEnabled(true)
        Issue.record("Expected stopped path to reject microphone update")
    } catch let error as NativeNVSTError {
        #expect(error == .notRunning)
    }

    #expect(await transport.microphoneEnabledUpdates.isEmpty)
}

@Test func nativeNVSTPathReadsPerformanceStatsOnlyWhileRunning() async throws {
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: RecordingNativeNVSTSessionProvider(), transport: transport)

    #expect(await path.performanceSnapshot() == nil)
    #expect(await transport.performanceSnapshotReadCount == 0)

    _ = try await path.start(configuration: nativeConfiguration())
    #expect(await path.performanceSnapshot() == nativePerformanceSnapshot())
    #expect(await transport.performanceSnapshotReadCount == 1)

    _ = try await path.stop()
    #expect(await path.performanceSnapshot() == nil)
    #expect(await transport.performanceSnapshotReadCount == 1)
}

@Test func nativeNVSTPathPausesNativeAndCloudSessions() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    _ = try await path.start(configuration: nativeConfiguration())
    let report = try await path.pause(message: "Paused")

    #expect(await transport.pauseCount == 1)
    #expect(await transport.disconnectCount == 0)
    #expect(await provider.finished == [nativeFinish(.paused)])
    #expect(report.success)
    #expect(report.reason == .paused)
}

@Test func nativeNVSTPathFinishesCloudSessionAfterRemoteTermination() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    _ = try await path.start(configuration: nativeConfiguration())
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination(isResumable: false, isSessionAlive: false, message: "Remote stop")))
    for _ in 0..<100 {
        if !(await provider.finished).isEmpty { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(await provider.finished == [nativeFinish(.remoteEnded)])
    #expect(await transport.disconnectCount == 1)
    if case .ended(let report) = await path.currentState() {
        #expect(report.success)
        #expect(report.reason == .remoteEnded)
        #expect(report.message == "Remote stop")
    } else {
        Issue.record("Expected ended state after native transport termination")
    }
}

@Test func nativeNVSTPathRecoversSameSessionWhenNativeFlagsAndResultsPermit() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport, automaticRecovery: .singleAttempt)

    _ = try await path.start(configuration: nativeConfiguration())
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    for _ in 0..<200 {
        if await transport.connectCount >= 2 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(await provider.recoveryCount == 1)
    #expect(await provider.finished.isEmpty)
    #expect(await transport.connectCount == 2)
    #expect(await path.currentState() == .running(nativeAllocation().session))
}

@Test func nativeNVSTPathDoesNotAutomaticallyRecoverByDefault() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

    _ = try await path.start(configuration: nativeConfiguration())
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    await waitForNativeNVSTFinish(provider)

    #expect(await provider.recoveryCount == 0)
    #expect(await provider.finished == [nativeFinish(.remoteEnded)])
    #expect(await transport.connectCount == 1)
}

@Test func nativeNVSTGeronimoPumpRunsInCommonRunLoopModes() {
    #expect(NativeNVSTBifrostTransport.geronimoPumpRunLoopMode == .common)
}

@Test func nativeNVSTSessionRecoveryRequiresBothFlags() {
    for isResumable in [false, true] {
        for isSessionAlive in [false, true] {
            let termination = nativeSessionTermination(isResumable: isResumable, isSessionAlive: isSessionAlive)
            #expect(termination.permitsSameSessionRecovery == (isResumable && isSessionAlive))
        }
    }
    let unknownReason = NativeNVSTSessionTermination(
        reason: NativeNVSTTerminationReason(rawValue: 99),
        extendedResult: NativeNVSTTerminationValue(code: -1, name: "NVB_R_NETWORK_ERROR"),
        isResumable: true,
        isSessionAlive: true,
        message: "unknown reason"
    )
    #expect(!unknownReason.permitsSameSessionRecovery)
}

@Test func nativeNVSTRecoveryPolicyAllowsOnlyExplicitTransientResults() {
    let retryable = [
        "NVB_R_NETWORK_ERROR",
        "NVB_R_CONNECTION_TIMEOUT",
        "NVB_R_STREAMER_NETWORK_ERROR",
        "NVB_R_DATA_RECEIVE_TIMEOUT",
    ]
    let permanent = [
        "NVB_R_AUTH_ERR_DEFUNCT_TOKEN",
        "NVB_R_INVALID_PARAM",
        "NVB_R_INVALID_VIDEO_DECODER",
        "NVB_R_SESSION_LIMIT_REACHED",
        "NVB_R_SESSION_TERMINATED_ANOTHER_CLIENT",
        "NVB_R_MEMBER_TERMINATED",
    ]

    for name in retryable {
        #expect(NativeNVSTRecoveryPolicy.isTransient(NativeNVSTTerminationValue(code: -1, name: name)))
    }
    for name in permanent {
        #expect(!NativeNVSTRecoveryPolicy.isTransient(NativeNVSTTerminationValue(code: -1, name: name)))
    }
    #expect(!NativeNVSTRecoveryPolicy.isTransient(NativeNVSTTerminationValue(code: -1)))
    #expect(!NativeNVSTRecoveryPolicy.isTransient(NativeNVSTTerminationValue(code: 0)))
    #expect(!NativeNVSTRecoveryPolicy.isTransient(NativeNVSTTerminationReason(rawValue: 0)))
    #expect(!NativeNVSTRecoveryPolicy.permitsRecovery(.transportFailed(NativeNVSTTransportFailure(
        message: "network interrupted",
        recoveryClassification: .transientNetwork
    ))))
    #expect(!NativeNVSTRecoveryPolicy.permitsRecovery(.transportFailed(NativeNVSTTransportFailure(
        message: "misclassified auth failure",
        result: NativeNVSTTerminationValue(code: -1, name: "NVB_R_AUTH_ERR_UNKNOWN"),
        recoveryClassification: .transientNetwork
    ))))
    #expect(!NativeNVSTRecoveryPolicy.permitsRecovery(.transportFailed(NativeNVSTTransportFailure(
        message: "decoder failed",
        recoveryClassification: .permanent
    ))))
}

@Test func nativeNVSTPathDoesNotRecoverPermanentSessionTermination() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    _ = try await path.start(configuration: nativeConfiguration())

    await transport.sendTermination(.sessionTerminated(nativeSessionTermination(
        resultName: "NVB_R_SESSION_LIMIT_REACHED",
        isResumable: true,
        isSessionAlive: true
    )))
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination(
        resultName: "NVB_R_SESSION_LIMIT_REACHED",
        isResumable: true,
        isSessionAlive: true
    )))
    await waitForNativeNVSTFinish(provider)

    #expect(await provider.recoveryCount == 0)
    #expect(await provider.finished == [nativeFinish(.remoteEnded)])
    #expect(await transport.disconnectCount == 1)
}

@Test func nativeNVSTPathLocalStopSuppressesConcurrentTerminalCleanup() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    _ = try await path.start(configuration: nativeConfiguration())

    _ = try await path.stop(reason: .userRequested, message: "Local stop")
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    try await Task.sleep(nanoseconds: 5_000_000)

    #expect(await provider.recoveryCount == 0)
    #expect(await provider.finished == [nativeFinish(.userRequested)])
    #expect(await transport.disconnectCount == 1)
}

@Test func nativeNVSTPathLocalStopDuringRecoveryOwnsCleanupExactlyOnce() async throws {
    let provider = RecordingNativeNVSTSessionProvider(suspendsRecovery: true)
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport, automaticRecovery: .singleAttempt)
    _ = try await path.start(configuration: nativeConfiguration())

    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    for _ in 0..<100 {
        if await provider.recoveryCount == 1 { break }
        await Task.yield()
    }
    _ = try await path.stop(reason: .userRequested, message: "Local stop during recovery")
    await provider.failSuspendedRecovery()
    try await Task.sleep(nanoseconds: 5_000_000)

    #expect(await provider.finished == [nativeFinish(.userRequested)])
    if case .ended(let report) = await path.currentState() {
        #expect(report.reason == .userRequested)
    } else {
        Issue.record("Expected local stop to retain terminal ownership")
    }
}

@Test func nativeNVSTPathFailedResumeCleansUpExactlyOnceWithoutBlanketRetry() async throws {
    let provider = RecordingNativeNVSTSessionProvider(recoveryError: .invalidSession("resume rejected"))
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport, automaticRecovery: .singleAttempt)
    _ = try await path.start(configuration: nativeConfiguration())

    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    await waitForNativeNVSTFinish(provider)

    #expect(await provider.recoveryCount == 1)
    #expect(await provider.finished == [nativeFinish(.remoteEnded)])
    guard case .ended = await path.currentState() else {
        Issue.record("Expected failed same-session resume to end the path")
        return
    }
}

@Test func nativeNVSTPathConsumesSingleSameSessionRecoveryAttempt() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport, automaticRecovery: .singleAttempt)
    _ = try await path.start(configuration: nativeConfiguration())

    await transport.sendTermination(.sessionTerminated(nativeSessionTermination()))
    for _ in 0..<200 {
        if await transport.connectCount == 2 { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    await transport.sendTermination(.sessionTerminated(nativeSessionTermination(message: "second interruption")))
    await waitForNativeNVSTFinish(provider)

    #expect(await provider.recoveryCount == 1)
    #expect(await provider.finished == [nativeFinish(.remoteEnded)])
    #expect(await transport.connectCount == 2)
}

@Test func nativeNVSTPathDoesNotRecoverUnmarkedTransportFailure() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .success)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport, automaticRecovery: .singleAttempt)
    _ = try await path.start(configuration: nativeConfiguration())

    await transport.sendTermination(.transportFailed(NativeNVSTTransportFailure(
        message: "network interrupted",
        recoveryClassification: .transientNetwork
    )))
    await waitForNativeNVSTFinish(provider)

    #expect(await provider.recoveryCount == 0)
    #expect(await provider.finished == [nativeFinish(.failed)])
    #expect(await transport.connectCount == 1)
}

@Test func nativeNVSTPathCancelsSuspendedConnectAndCloudAllocation() async throws {
    let provider = RecordingNativeNVSTSessionProvider()
    let transport = RecordingNativeNVSTTransport(mode: .suspendedConnect)
    let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
    let task = Task { try await path.start(configuration: nativeConfiguration()) }
    await transport.waitForConnect()

    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected native NVST startup cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    for _ in 0..<100 {
        if await provider.cancelCount > 0, !(await provider.finished).isEmpty { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    #expect(await provider.cancelCount == 1)
    #expect(await provider.finished == [nativeFinish(.userRequested)])
    #expect(await transport.disconnectCount >= 1)
}

@Test func nativeNVSTInputEncoderProducesVerifiedWireEvents() throws {
    let encoder = NativeNVSTInputEncoder()
    let timestamp = MediaTimestamp(nanoseconds: 1_234_000)
    let keyboard = try #require(encoder.encode(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [.shift, .command], isPressed: true, timestamp: timestamp))))
    let capsLock = try #require(encoder.encode(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 57, scanCode: 57, modifiers: [.capsLock], isPressed: true, timestamp: timestamp))))
    let mouseMove = try #require(encoder.encode(.mouse(.moved(deviceID: "mouse", deltaX: -2, deltaY: 513, timestamp: timestamp))))
    let mouseButton = try #require(encoder.encode(.mouse(.button(deviceID: "mouse", button: .right, isPressed: true, timestamp: timestamp))))
    let mouseWheel = try #require(encoder.encode(.mouse(.wheel(deviceID: "mouse", delta: 121, timestamp: timestamp))))
    let gamepad = try #require(encoder.encode(.gamepad(GamepadState(deviceID: "gamepad", playerIndex: 2, buttons: [.south, .rightShoulder, .dpadLeft], leftTrigger: 0.5, rightTrigger: 1, leftStickX: 1, leftStickY: -1, rightStickX: -1, rightStickY: 1, timestamp: timestamp))))
    let text = try #require(encoder.encode(.text(deviceID: "keyboard", value: "h\u{00e9}", timestamp: timestamp)))

    #expect(keyboard.payload.count == 0x48)
    #expect(Array(keyboard.payload[0..<32]) == [
        1, 0, 0, 0, 0, 0, 0, 0,
        0x41, 0, 0, 0, 0, 0, 9, 0,
        2, 0, 0, 0, 0, 0, 0, 0,
        0xd2, 0x04, 0, 0, 0, 0, 0, 0,
    ])
    #expect(keyboard.payload[32...].allSatisfy { $0 == 0 })
    #expect(Array(capsLock.payload[0..<12]) == [15, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0])
    #expect(Array(mouseMove.payload[0..<24]) == [
        2, 0, 0, 0, 0, 0, 0, 0,
        1, 0, 0, 0, 0, 0, 0, 0,
        0xfe, 0xff, 0xff, 0xff, 0x01, 0x02, 0, 0,
    ])
    #expect(Array(mouseMove.payload[40..<48]) == [0xd2, 0x04, 0, 0, 0, 0, 0, 0])
    #expect(Array(mouseButton.payload[24..<32]) == [3, 0, 0, 0, 2, 0, 0, 0])
    #expect(Array(mouseWheel.payload[36..<40]) == [2, 0, 0, 0])
    #expect(Array(gamepad.payload[0..<8]) == [18, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(gamepad.payload[8..<52]) == [
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 1, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 1, 0, 0, 0x80, 0, 0,
        0xff, 0x7f, 0xff, 0x7f, 0, 0x80, 0, 0x80,
        0, 0x80, 0xff, 0xff,
    ])
    #expect(Array(gamepad.payload[52..<64]) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0])
    #expect(Array(gamepad.payload[64..<72]) == [0xd2, 0x04, 0, 0, 0, 0, 0, 0])
    #expect(text.nativePayload == .text(Data([0x68, 0xc3, 0xa9])))
    #expect([keyboard, capsLock, mouseMove, mouseButton, mouseWheel, gamepad, text].allSatisfy { !$0.partiallyReliable })
}

@Test func nativeNVSTSessionPayloadExtractsVerifiedStartFieldsWithoutLoggingToken() throws {
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "serverAddress": "rtsps://native.example.test:443",
      "tokenType": "JWT",
      "token": "private-session-token",
      "session": "native-session-key",
      "sessionRequestData": { "appId": 123 },
      "streamingProfile": { "streamingProfileGuid": "profile-guid" },
      "audioModeFormat": "stereo"
    }
    """)

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.effectiveServerAddress == "rtsps://native.example.test:443")
    #expect(payload.tokenType == "JWT")
    #expect(payload.hasToken == true)
    #expect(payload.appID == "123")
    #expect(payload.sessionIdentifier == "native-session-key")
    #expect(payload.streamingProfileGUID == "profile-guid")
    #expect(payload.audioModeFormat == "stereo")
    #expect(payload.missingStartFields.isEmpty)
    #expect(payload.telemetryAttributes.values.contains("private-session-token") == false)
}

@Test func nativeNVSTSessionPayloadReportsMissingPrivateStartFields() throws {
    let allocation = nativeAllocation(rawSessionJSON: "{}")

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.effectiveServerAddress == "server.example.test")
    #expect(payload.appID == "123")
    #expect(payload.sessionIdentifier == "native-session")
    #expect(payload.missingStartFields == ["tokenType", "token", "streamingProfile.streamingProfileGuid"])
}

@Test func nativeNVSTSessionPayloadUsesAllocationAuthWithoutLoggingToken() throws {
    let allocation = nativeAllocation(rawSessionJSON: "{}", authTokenType: "JWT_GFN", authToken: "private-access-token")

    let payload = NativeNVSTSessionPayload(allocation: allocation)

    #expect(payload.tokenType == "JWT_GFN")
    #expect(payload.hasToken)
    #expect(payload.missingStartFields == ["streamingProfile.streamingProfileGuid"])
    #expect(payload.telemetryAttributes.values.contains("private-access-token") == false)
}

@Test func nativeNVSTGeronimoStartFailureMessageDoesNotExposePrivateABI() {
    let message = NativeNVSTBifrostTransport.geronimoStartFailureMessage

    #expect(message.contains("Nsk::") == false)
    #expect(message.contains("0x80f10005") == false)
    #expect(message.contains("WebRTC") == false)
    #expect(message.contains("diagnostics"))
}

@Test func nativeNVSTGeronimoSessionLimitFailureIsActionable() {
    let message = NativeNVSTBifrostTransport.geronimoCallbackFailureMessage(resultCode: 302, resultName: "NVB_R_SESSION_LIMIT_REACHED")
    let error = NativeNVSTBifrostTransport.geronimoCallbackError(resultCode: 302, resultName: "NVB_R_SESSION_LIMIT_REACHED")

    #expect(message.contains("active session limit"))
    #expect(message.contains("End another session"))
    #expect(message.contains("302") == false)
    #expect(error == .sessionLimitReached)
}

@Test @MainActor func nativeNVSTGeronimoPumpRunsDuringAppKitEventTracking() {
    #expect(NativeNVSTBifrostTransport.geronimoPumpFramesPerSecond == 60)
    #expect(abs(NativeNVSTBifrostTransport.geronimoPumpInterval - (1.0 / 60.0)) < 0.000_001)
    #expect(NativeNVSTBifrostTransport.geronimoPumpRunLoopMode == .common)
    #expect(NativeNVSTBifrostTransport.geronimoPumpRunLoopMode != .default)
}

@Test func nativeNVSTResolvesMicrophonePermissionBeforeGeronimoStartup() {
    #expect(NativeNVSTBifrostTransport.microphoneCaptureAccess(requested: false, authorizationStatus: .notDetermined) == false)
    #expect(NativeNVSTBifrostTransport.microphoneCaptureAccess(requested: true, authorizationStatus: .authorized) == true)
    #expect(NativeNVSTBifrostTransport.microphoneCaptureAccess(requested: true, authorizationStatus: .denied) == false)
    #expect(NativeNVSTBifrostTransport.microphoneCaptureAccess(requested: true, authorizationStatus: .restricted) == false)
    #expect(NativeNVSTBifrostTransport.microphoneCaptureAccess(requested: true, authorizationStatus: .notDetermined) == nil)
}

@Test func nativeNVSTPreservesMeasuredPacketSizeInGeronimoProfile() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: """
        { "maxPacketSize": 1200 }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])

    #expect(profile["maxPacketSize"] as? Int == 1_200)
}

@Test func nativeNVSTRejectsUnverifiedPacketSizeBoundsFromSettings() throws {
    for packetSize in [511, Int(UInt16.max) + 1] {
        let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
            rawSessionJSON: """
            {
              "streamingProfile": { "resolution": "1920x1080", "fps": 60, "codec": "H264" }
            }
            """,
            sessionInfoJSON: "{}",
            settingsJSON: "{\"maxPacketSize\":\(packetSize)}"
        )
        let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])

        #expect(profile["maxPacketSize"] == nil)
    }
}

@Test func nativeNVSTLaunchPayloadModelsVerifiedGeForceNOWStartFields() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264", "audioMode": "surround51" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "serverAddress": "control.example.test",
      "serverType": 4,
      "tokenType": "9",
      "token": "private-session-token",
      "networkSessionId": "network-session",
      "audioModeFormat": "surround51",
      "zoneName": "US-WEST",
      "userAge": 18,
      "summaryStatsEnabled": true,
      "enablePersistingInGameSettings": true,
      "sessionRequestData": {
        "appId": 123,
        "appName": "Game",
        "appLaunchMode": 2,
        "deviceHashId": "device-id",
        "gameShortName": "game",
        "maxLocalPlayers": 4,
        "advancedLatencyOptimization": true,
        "frameLossWarningTimeout": 500,
        "frameLossErrorTimeout": 30000,
        "supportedControls": ["KeyboardMouse", "Gamepad"],
        "contentRating": [{"system": "ESRB", "rating": "T"}],
        "metaData": [{"key": "wssignaling", "value": "1"}],
        "spanData": { "traceparent": "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" }
      }
    }
    """)

    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "2.0.87.131")

    try payload.validate()
    #expect(payload.prepare.address == "control.example.test")
    #expect(payload.prepare.tokenType == "9")
    #expect(payload.prepare.hasToken)
    #expect(payload.prepare.traceParent == "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01")
    #expect(payload.start.serverType == 5)
    #expect(payload.start.appId == 123)
    #expect(payload.start.networkSessionId == "network-session")
    #expect(payload.start.audioModeFormat == "surround51")
    #expect(payload.start.metadataCount == 1)
    #expect(payload.start.persistingInGameSettings)
    #expect(payload.start.supportedControlsCount == 2)
    #expect(payload.start.contentRatingCount == 1)
    #expect(payload.telemetryAttributes.values.contains("private-session-token") == false)
}

@Test func nativeNVSTNormalizedSessionPreservesMetadataForNativeABIValidation() {
    let valid = NativeNVSTNormalizedSessionSource(allocation: nativeAllocation(rawSessionJSON: """
    {
      "sessionRequestData": {
        "metaData": [
          {"key":" spaced ","value":"Grüße 世界"},
          {"key":"empty","value":""},
          {"key":"duplicate","value":"first"},
          {"key":"duplicate","value":"last"}
        ]
      }
    }
    """))
    let malformed = NativeNVSTNormalizedSessionSource(allocation: nativeAllocation(rawSessionJSON: """
    {"sessionRequestData":{"metaData":{"key":"not-an-array","value":"rejected-natively"}}}
    """))

    let entries = valid.metadata as? [[String: String]]
    #expect(entries?.compactMap { $0["key"] } == [" spaced ", "empty", "duplicate", "duplicate"])
    #expect(entries?.compactMap { $0["value"] } == ["Grüße 世界", "", "first", "last"])
    #expect(valid.metadataCount == 4)
    #expect((malformed.metadata as? [String: String])?["key"] == "not-an-array")
    #expect(malformed.metadataCount == 0)
}

@Test func nativeNVSTLaunchPayloadUsesAllocationServerTypeAndAuthWhenSessionOmitsFields() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(
        rawSessionJSON: """
        {
          "serverAddress": "control.example.test",
          "networkSessionId": "network-session",
          "sessionRequestData": { "appId": 123, "deviceHashId": "device-id" },
          "audioModeFormat": "stereo"
        }
        """,
        authTokenType: "JWT_GFN",
        authToken: "private-access-token"
    )

    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "2.0.87.131")

    try payload.validate()
    #expect(payload.start.serverType == 5)
    #expect(payload.prepare.tokenType == "JWT_GFN")
    #expect(payload.prepare.hasToken)
    #expect(payload.telemetryAttributes.values.contains("private-access-token") == false)
}

@Test func nativeNVSTPayloadFallsBackToRawSessionServerTypeWhenServerInfoIsUnavailable() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(
        rawSessionJSON: """
        {
          "serverType": 5,
          "sessionRequestData": { "appId": 123 }
        }
        """,
        serverType: 0,
        authTokenType: "JWT_GFN",
        authToken: "private-access-token"
    )

    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "2.0.87.131")
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: profileJSON)
    let session = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])

    try payload.validate()
    #expect(payload.start.serverType == 5)
    #expect(session["serverType"] as? Int == 5)
}

@Test func nativeNVSTLaunchPayloadRejectsMissingVerifiedStartFields() throws {
    let payload = NativeNVSTLaunchPayload(allocation: nativeAllocation(rawSessionJSON: "{}", serverType: 0), streamingProfileJSON: "{}", clientAppVersion: "OpenNOW")

    #expect(payload.missingFields.contains("serverType"))
    #expect(payload.missingFields.contains("tokenType"))
    #expect(payload.missingFields.contains("token"))
    #expect(payload.missingFields.contains("streamingProfile"))
}

@Test func nativeNVSTLaunchPayloadRejectsUnsupportedServerAndAuthTypes() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let unsupportedServer = NativeNVSTLaunchPayload(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "serverType": 52,
          "tokenType": "JWT",
          "token": "private-session-token",
          "sessionRequestData": { "appId": 123, "deviceHashId": "device-id" }
        }
        """, serverType: 52),
        streamingProfileJSON: profileJSON,
        clientAppVersion: "OpenNOW"
    )
    let unsupportedAuth = NativeNVSTLaunchPayload(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "serverType": 5,
          "tokenType": "Basic",
          "token": "private-session-token",
          "sessionRequestData": { "appId": 123, "deviceHashId": "device-id" }
        }
        """),
        streamingProfileJSON: profileJSON,
        clientAppVersion: "OpenNOW"
    )

    #expect(throws: NativeNVSTError.invalidSession("Native NVST launch payload has unsupported server type 52.")) {
        try unsupportedServer.validate()
    }
    #expect(throws: NativeNVSTError.invalidSession("Native NVST launch payload has an unsupported auth token type.")) {
        try unsupportedAuth.validate()
    }
}

@Test func nativeNVSTGeronimoSessionJSONPromotesCloudSessionFields() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "sessionId": "native-session",
          "status": 2,
          "serverType": 4,
          "gpuType": "L40",
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "1920x1080", "fps": 60, "codec": "H264" },
          "frameStatsEnabled": true,
          "summaryStatsEnabled": false,
          "applicationHeaders": ["x-existing.value"],
          "sessionRequestData": {
            "appId": 123,
            "appName": "Native Game",
            "appLaunchMode": 3,
            "deviceHashId": "device",
            "maxLocalPlayers": 4,
            "advancedLatencyOptimization": true,
            "frameLossWarningTimeout": 250,
            "frameLossErrorTimeout": 10000,
            "supportedControls": ["KeyboardMouse", "Gamepad"],
            "contentRating": [{"system": "ESRB", "rating": "T"}],
            "metaData": [
              {"key": "source", "value": "cloudmatch"},
              {"key": "wssignaling", "value": "1"}
            ],
            "enablePersistingInGameSettings": true
          },
          "sessionControlInfo": { "ip": "control.example.test", "port": 443 },
          "connectionInfo": [
            { "usage": 14, "ip": "signaling.example.test", "port": 443, "resourcePath": "/nvst/", "headers": ["x-vendor.session"], "queryParameters": "vendorToken=opaque" },
            { "usage": 2, "ip": "video.example.test", "port": 47998, "resourcePath": "" },
            { "usage": 17, "ip": "bundle.example.test", "port": 47998, "resourcePath": "" }
          ],
          "monitorSettings": [
            { "widthInPixels": 1920, "heightInPixels": 1080, "framesPerSecond": 60, "dpi": 96 }
          ],
          "finalizedStreamingFeatures": { "bitDepth": 8, "reflex": false }
        }
        """),
        streamingProfileJSON: streamingProfileJSON
    )
    let object = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])
    let streamingProfile = try #require(object["streamingProfile"] as? [String: Any])
    let monitorSettings = try #require(object["monitorSettings"] as? [[String: Any]])
    let connectionInfo = try #require(object["connectionInfo"] as? [[String: Any]])
    let features = try #require(object["finalizedStreamingFeatures"] as? [String: Any])
    let metadata = try #require(object["metaData"] as? [[String: String]])
    let applicationHeaders = try #require(object["applicationHeaders"] as? [String])

    #expect(object["sessionId"] as? String == "native-session")
    #expect(object["appId"] as? Int == 123)
    #expect(object["appName"] as? String == "Native Game")
    #expect(object["appLaunchMode"] as? Int == 2)
    #expect(object["serverType"] as? Int == 5)
    #expect(object["frameStatsEnabled"] as? Bool == true)
    #expect(object["summaryStatsEnabled"] as? Bool == false)
    #expect(object["maxLocalPlayers"] as? Int == 4)
    #expect(object["advancedLatencyOptimization"] as? Bool == true)
    #expect(object["frameLossWarningTimeout"] as? Int == 250)
    #expect(object["frameLossErrorTimeout"] as? Int == 10_000)
    #expect((object["supportedControls"] as? [String]) == ["KeyboardMouse", "Gamepad"])
    #expect((object["contentRating"] as? [[String: String]])?.count == 1)
    #expect(metadata.map { $0["key"] ?? "" } == ["source", "wssignaling"])
    #expect(object["persistingInGameSettings"] as? Bool == true)
    #expect(object["zoneAddress"] as? String == "control.example.test")
    #expect(object["zoneName"] as? String == "CONTROL")
    #expect(streamingProfile["streamingProfileGuid"] as? String == "profile-guid")
    #expect(streamingProfile["resolution"] as? String == "1920x1080")
    #expect(streamingProfile["fps"] as? Int == 60)
    #expect(monitorSettings.count == 1)
    #expect(monitorSettings[0]["widthInPixels"] as? Int == 1920)
    #expect(connectionInfo.map { $0["usage"] as? Int ?? -1 } == [14, 2, 17])
    #expect(connectionInfo.allSatisfy { $0["protocol"] as? Int == 2 })
    #expect(connectionInfo[0]["headers"] as? [String] == ["x-vendor.session"])
    #expect(connectionInfo[0]["queryParameters"] as? String == "vendorToken=opaque")
    #expect(applicationHeaders == ["x-existing.value", "x-nv-sessionid.native-session", "token=abc"])
    #expect(features["bitDepth"] as? Int == 8)
}

@Test func nativeNVSTModeSelectionUsesFinalizedThenRequestedFeaturesBeforeSettings() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "resolution": "2560x1440", "fps": 120, "codec": "H265", "colorQuality": "10bit_444" },
          "sessionRequestData": {
            "requestedStreamingFeatures": {
              "reflex": true,
              "enabledL4S": true,
              "cloudGsync": true,
              "trueHdr": true,
              "supportedHidDevices": 31,
              "profile": 4,
              "fallbackToLogicalResolution": true,
              "bitDepth": 1,
              "chromaFormat": 2,
              "prefilterMode": 2,
              "prefilterSharpness": 7,
              "prefilterNoiseReduction": 6,
              "hudStreamingMode": 2
            }
          },
          "finalizedStreamingFeatures": {
            "reflex": false,
            "enabledL4S": false,
            "trueHdr": false,
            "bitDepth": 0,
            "dynamicStreamingMode": 2,
            "prefilterSharpness": 3,
            "hudStreamingMode": 1
          }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: """
        {
          "enableReflex": true,
          "enableL4S": true,
          "enableCloudGsync": false,
          "enableHdr": true,
          "supportedHidDevices": 1,
          "streamingQualityProfile": 1,
          "fallbackToLogicalResolution": false,
          "prefilterMode": 0,
          "prefilterSharpness": 0,
          "prefilterDenoise": 0,
          "hudStreamingMode": 0,
          "colorQuality": "8bit_420"
        }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let features = try #require(profile["selectedFeatures"] as? [String: Any])
    let prefilter = try #require(features["prefilterParams"] as? [String: Any])
    let hud = try #require(features["hudStreamingParams"] as? [String: Any])

    #expect(features["reflex"] as? Bool == false)
    #expect(features["l4s"] as? Bool == false)
    #expect(features["cloudGsync"] as? Bool == true)
    #expect(features["hdr"] as? Bool == false)
    #expect(features["trueHdr"] as? Bool == false)
    #expect(features["supportedHidDevices"] as? Int == 31)
    #expect(features["profile"] as? Int == 4)
    #expect(features["fallbackToLogicalResolution"] as? Bool == true)
    #expect(features["bitDepth"] as? Int == 8)
    #expect(features["chromaFormat"] as? Int == 2)
    #expect(features["dynamicStreamingMode"] as? Int == 2)
    #expect(prefilter["mode"] as? Int == 2)
    #expect(prefilter["sharpnessLevel"] as? Int == 3)
    #expect(prefilter["denoiseLevel"] as? Double == 6)
    #expect(hud["mode"] as? Int == 1)
}

@Test func nativeNVSTDoesNotFabricateNetworkSessionIdFromCloudMatchSessionId() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: "{\"streamingProfile\":{\"resolution\":\"1920x1080\",\"fps\":60,\"codec\":\"H264\"}}",
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "sessionId": "cloudmatch-session",
      "tokenType": "JWT_GFN",
      "token": "private-token",
      "sessionRequestData": { "appId": 123 }
    }
    """)
    let payload = NativeNVSTLaunchPayload(allocation: allocation, streamingProfileJSON: profileJSON, clientAppVersion: "OpenNOW")
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: profileJSON)
    let session = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])

    #expect(payload.start.networkSessionId.isEmpty)
    #expect(payload.missingFields.contains("networkSessionId") == false)
    #expect(session["networkSessionId"] as? String == "")
}

@Test func nativeNVSTGeronimoSessionJSONGeneratesStableOpenNOWProfileGuidWhenCloudSessionOmitsOne() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: "{}",
        sessionInfoJSON: "{}",
        settingsJSON: """
        {
          "resolution": "1920x1080",
          "fps": 60,
          "codec": "H264",
          "audioModeFormat": "stereo"
        }
        """
    )
    let allocation = nativeAllocation(rawSessionJSON: """
    {
      "sessionId": "native-session",
      "appLaunchMode": 3,
      "sessionRequestData": { "appId": 123 },
      "sessionControlInfo": { "ip": "control.example.test" }
    }
    """, settingsJSON: """
    {
      "transportMode": "nvst",
      "codec": "H264",
      "audioModeFormat": "stereo"
    }
    """)
    let firstSessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
    let secondSessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: streamingProfileJSON)
    let firstObject = try #require(JSONSerialization.jsonObject(with: Data(firstSessionJSON.utf8)) as? [String: Any])
    let secondObject = try #require(JSONSerialization.jsonObject(with: Data(secondSessionJSON.utf8)) as? [String: Any])
    let firstStreamingProfile = try #require(firstObject["streamingProfile"] as? [String: Any])
    let secondStreamingProfile = try #require(secondObject["streamingProfile"] as? [String: Any])
    let generatedGuid = try #require(firstStreamingProfile["streamingProfileGuid"] as? String)

    #expect(UUID(uuidString: generatedGuid) != nil)
    #expect(secondStreamingProfile["streamingProfileGuid"] as? String == generatedGuid)
    #expect(firstStreamingProfile["resolution"] as? String == "1920x1080")
    #expect(firstStreamingProfile["fps"] as? Int == 60)
    #expect(firstStreamingProfile["codec"] as? String == "H264")
    #expect(firstStreamingProfile["audioMode"] as? String == "stereo")
    #expect((firstObject["deviceId"] as? String)?.isEmpty == false)
    #expect(firstObject["appLaunchMode"] as? Int == 2)
}

@Test func nativeNVSTGeronimoSessionJSONGeneratesMissingMonitorSettings() throws {
    let streamingProfileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "resolution": "2560x1440", "fps": 120, "codec": "H264" }
        }
        """,
        sessionInfoJSON: "{}"
    )
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(
        allocation: nativeAllocation(rawSessionJSON: """
        {
          "sessionId": "native-session",
          "sessionRequestData": { "appId": 123 },
          "sessionControlInfo": { "ip": "control.example.test" }
        }
        """),
        streamingProfileJSON: streamingProfileJSON
    )
    let object = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])
    let monitorSettings = try #require(object["monitorSettings"] as? [[String: Any]])

    #expect(monitorSettings.count == 1)
    #expect(monitorSettings[0]["widthInPixels"] as? Int == 2560)
    #expect(monitorSettings[0]["heightInPixels"] as? Int == 1440)
    #expect(monitorSettings[0]["framesPerSecond"] as? Int == 120)
}

@Test func nativeNVSTBifrostTransportUsesRawStreamingProfileWhenPresent() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": { "streamingProfileGuid": "profile-guid", "fps": 60 },
          "negotiatedStreamProfile": { "fps": 30 }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: "{\"resolution\":\"1920x1080\",\"codec\":\"H264\"}"
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(profileJSON.contains("\"denoiseLevel\":0.0"))
    #expect(profileJSON.contains("\"scxQpDelta\":0.0"))
    #expect(selectedVideoMode["width"] as? Int == 1920)
    #expect(selectedVideoMode["height"] as? Int == 1080)
    #expect(selectedVideoMode["fps"] as? Int == 60)
    #expect(selectedVideoMode["scaleFactor"] as? Int == 1)
    #expect(selectedEncodeMode["width"] as? Int == 1920)
    #expect(selectedEncodeMode["height"] as? Int == 1080)
    #expect(selectedEncodeMode["fps"] as? Int == 60)
    #expect(selectedFeatures["audioChannelCount"] as? Int == 2)
    #expect(selectedFeatures.keys.contains("prefilterParams"))
    #expect(selectedFeatures.keys.contains("hudStreamingParams"))
}

@Test func nativeNVSTBifrostTransportFallsBackToSessionInfoNegotiatedProfile() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "sessionId": "native-session",
          "status": 2
        }
        """,
        sessionInfoJSON: """
        {
          "negotiatedStreamProfile": {
            "resolution": "1920x1080",
            "fps": 60,
            "codec": "h264",
            "colorQuality": "SDR"
          }
        }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(selectedVideoMode["width"] as? Int == 1920)
    #expect(selectedVideoMode["height"] as? Int == 1080)
    #expect(selectedVideoMode["fps"] as? Int == 60)
    #expect(selectedEncodeMode["fps"] as? Int == 60)
    #expect(selectedFeatures["hdr"] as? Bool == false)
    #expect(selectedFeatures["bitDepth"] as? Int == 8)
}

@Test func nativeNVSTBifrostTransportCompletesInvalidProfileFieldsFromSettings() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": {
            "streamingProfileGuid": "profile-guid",
            "resolution": "",
            "fps": 0,
            "codec": "",
            "colorQuality": "8bit_420"
          }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: """
        {
          "resolution": "2560x1440",
          "fps": 120,
          "codec": "auto",
          "maxBitrateMbps": 35
        }
        """
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedVideoMode = try #require(profile["selectedVideoMode"] as? [String: Any])
    let selectedEncodeMode = try #require(profile["selectedEncodeMode"] as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(profileJSON.contains("\"denoiseLevel\":0.0"))
    #expect(profileJSON.contains("\"scxQpDelta\":0.0"))
    #expect(selectedVideoMode["width"] as? Int == 2560)
    #expect(selectedVideoMode["height"] as? Int == 1440)
    #expect(selectedVideoMode["fps"] as? Int == 120)
    #expect(selectedEncodeMode["width"] as? Int == 2560)
    #expect(selectedEncodeMode["height"] as? Int == 1440)
    #expect(selectedEncodeMode["fps"] as? Int == 120)
    #expect(selectedFeatures["bitDepth"] as? Int == 8)
    #expect(selectedFeatures["maxBitrateKbps"] as? Int == 35_000)
}

@Test func nativeNVSTBifrostTransportPreservesLowerServerBitrateCap() throws {
    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: """
        {
          "streamingProfile": {
            "resolution": "1920x1080",
            "fps": 60,
            "codec": "H264",
            "maxBitrateKbps": 24000
          }
        }
        """,
        sessionInfoJSON: "{}",
        settingsJSON: "{\"maxBitrateMbps\":35}"
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(profileJSON.utf8)) as? [String: Any])
    let selectedFeatures = try #require(profile["selectedFeatures"] as? [String: Any])

    #expect(selectedFeatures["maxBitrateKbps"] as? Int == 24_000)
}

@Test func nativeNVSTNormalizesVerifiedRemoteControllersBitmap() throws {
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(0) == 0)
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(UInt32.max) == UInt64(UInt32.max))
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap("15") == 15)
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(-1) == nil)
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(1.5) == nil)
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(UInt64(UInt32.max) + 1) == nil)
    #expect(NativeNVSTBifrostTransport.normalizedRemoteControllersBitmap(true) == nil)

    let profileJSON = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: "{\"streamingProfile\":{\"resolution\":\"1920x1080\",\"fps\":60,\"codec\":\"H264\"}}",
        sessionInfoJSON: "{}"
    )
    let allocation = nativeAllocation(
        rawSessionJSON: "{\"sessionId\":\"native-session\",\"remoteControllersBitmap\":9,\"sessionRequestData\":{\"appId\":123,\"remoteControllersBitmap\":3}}",
        settingsJSON: "{\"transportMode\":\"nvst\",\"remoteControllersBitmap\":1}"
    )
    let sessionJSON = try NativeNVSTBifrostTransport.geronimoSessionJSON(allocation: allocation, streamingProfileJSON: profileJSON)
    let session = try #require(JSONSerialization.jsonObject(with: Data(sessionJSON.utf8)) as? [String: Any])

    #expect((session["remoteControllersBitmap"] as? NSNumber)?.uint64Value == 9)
}

private func nativeConfiguration() -> StreamLaunchConfiguration {
    StreamLaunchConfiguration(title: "Native Test", applicationID: "123", accessToken: "token", accountLinked: true, selectedStore: "Steam")
}

private func nativeFinish(_ reason: StreamEndReason) -> RecordedNativeNVSTFinish {
    RecordedNativeNVSTFinish(session: nativeAllocation().session, reason: reason)
}

private func nativeSessionTermination(resultName: String = "NVB_R_NETWORK_ERROR",
                                      isResumable: Bool = true,
                                      isSessionAlive: Bool = true,
                                      message: String = "network interrupted") -> NativeNVSTSessionTermination {
    NativeNVSTSessionTermination(
        reason: NativeNVSTTerminationReason(rawValue: 1, resultName: resultName),
        extendedResult: NativeNVSTTerminationValue(code: -1, name: resultName),
        isResumable: isResumable,
        isSessionAlive: isSessionAlive,
        message: message
    )
}

private func waitForNativeNVSTFinish(_ provider: RecordingNativeNVSTSessionProvider) async {
    for _ in 0..<200 {
        if !(await provider.finished).isEmpty { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

private func nativePerformanceSnapshot() -> NativeNVSTPerformanceSnapshot {
    NativeNVSTPerformanceSnapshot(
        available: true,
        gameFramesPerSecond: 59.8,
        streamFramesPerSecond: 60,
        latencyMilliseconds: 31,
        jitterMilliseconds: 1.4,
        frameLoss: 0,
        totalFrameLoss: 2,
        packetLoss: 0,
        totalPacketLoss: 3,
        bitrateMegabitsPerSecond: 42.5,
        bandwidthUtilizationPercent: 64,
        resolution: "1920x1080",
        codec: "H264",
        serverLocation: "US-WEST"
    )
}

private func nativeAllocation(rawSessionJSON: String = "{\"sessionId\":\"native-session\"}", serverType: Int = 5, authTokenType: String = "", authToken: String = "", settingsJSON: String = "{\"transportMode\":\"nvst\"}") -> NativeNVSTSessionAllocation {
    let session = StreamSessionDescriptor(id: "native-session", applicationID: "123", serverAddress: "server.example.test", title: "Native Test", metadata: ["transport": "nvst"])
    return NativeNVSTSessionAllocation(
        session: session,
        signalingServer: "server.example.test:443",
        signalingURL: "wss://server.example.test/nvst/",
        signalingQueryParameters: "token=abc",
        signalingHeaders: ["x-nv-sessionid.native-session"],
        streamingBaseURL: "https://stream.example.test/",
        mediaHost: "media.example.test",
        mediaPort: 47998,
        serverType: serverType,
        authTokenType: authTokenType,
        authToken: authToken,
        settingsJSON: settingsJSON,
        sessionInfoJSON: "{\"sessionId\":\"native-session\"}",
        rawSessionJSON: rawSessionJSON
    )
}
