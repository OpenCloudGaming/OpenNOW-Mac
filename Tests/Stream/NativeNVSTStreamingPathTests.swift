import Foundation
import Testing
@testable import OpenNOW

@Suite("NVST-only stream lifecycle", .timeLimit(.minutes(1)))
struct NativeNVSTStreamingPathTests {
    @Test("a native launch reaches ready and releases its cloud session on stop")
    func nativeLaunchReachesReady() async throws {
        let provider = RecordingNativeSessionProvider()
        let transport = RecordingNativeTransport()
        let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
        let progress = NativeLaunchProgressRecorder()

        let session = try await path.start(configuration: configuration) { await progress.append($0) }

        #expect(await transport.connectedSessionIDs == [session.id])
        #expect(await path.currentState() == .running(session))
        let updates = await progress.updates
        #expect(updates.map(\.currentStepIndex) == [0, 1, 2, 3, 4])
        #expect(updates.last?.isReady == true)
        #expect(updates.last?.steps == ["Check network route", "Allocate cloud session", "Prepare NVST transport", "Connect NVST transport", "Connected"])

        let report = try await path.stop()

        #expect(report.success)
        #expect(report.metadata["transport"] == "nvst")
        #expect(await provider.finishedReasons == [.userRequested])
        #expect(await transport.disconnectCount == 1)
        #expect(await path.currentState() == .ended(report))
    }

    @Test("a failed connection releases a new seat but preserves a resumed seat", arguments: [false, true])
    func failedConnectionReleasesOwnedSeat(isResume: Bool) async {
        let provider = RecordingNativeSessionProvider(isResume: isResume)
        let transport = RecordingNativeTransport(connectionError: .transportFailed("Connection rejected"))
        let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)

        do {
            _ = try await path.start(configuration: configuration)
            Issue.record("Expected the connection to fail")
        } catch {
            #expect(error as? NativeNVSTError == .transportFailed("Connection rejected"))
        }

        #expect(await provider.finishedReasons == [isResume ? .paused : .failed])
        #expect(await transport.disconnectCount == 1)
    }

    @Test("cancelling allocation forwards through the retained cancellation contract")
    func cancellingAllocationForwardsToProvider() async {
        let provider = RecordingNativeSessionProvider(isAllocationSuspended: true)
        let transport = RecordingNativeTransport()
        let path = NativeNVSTStreamingPath(sessionProvider: provider, transport: transport)
        let configuration = configuration
        let launch = Task { try await path.start(configuration: configuration) }
        await provider.waitForAllocation()

        await path.cancelStart()

        do {
            _ = try await launch.value
            Issue.record("Expected the cancelled allocation to fail")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await provider.cancellationCount == 1)
        #expect(await provider.finishedReasons.isEmpty)
        #expect(await transport.connectedSessionIDs.isEmpty)
        #expect(await transport.disconnectCount == 1)
    }

    private var configuration: StreamLaunchConfiguration {
        StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam")
    }
}

private actor NativeLaunchProgressRecorder {
    private(set) var updates: [StreamProgress] = []

    func append(_ progress: StreamProgress) {
        updates.append(progress)
    }
}

private actor RecordingNativeSessionProvider: NativeNVSTSessionProvider, StreamSessionStartCancellable {
    private let isResume: Bool
    private let isAllocationSuspended: Bool
    private let allocationStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var allocationContinuation: CheckedContinuation<NativeNVSTSessionAllocation, Error>?
    private(set) var finishedReasons: [StreamEndReason] = []
    private(set) var cancellationCount = 0

    init(isResume: Bool = false, isAllocationSuspended: Bool = false) {
        self.isResume = isResume
        self.isAllocationSuspended = isAllocationSuspended
    }

    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
        allocationStarted.continuation.yield(())
        allocationStarted.continuation.finish()
        if isAllocationSuspended {
            return try await withCheckedThrowingContinuation { allocationContinuation = $0 }
        }
        return NativeNVSTSessionAllocation(
            session: StreamSessionDescriptor(id: "native-session", applicationID: configuration.applicationID, serverAddress: "seat.invalid", title: configuration.title),
            isResume: isResume,
            signalingServer: "seat.invalid",
            signalingURL: "wss://seat.invalid/rtsp",
            signalingQueryParameters: "",
            signalingHeaders: [],
            streamingBaseURL: "https://seat.invalid",
            mediaHost: "seat.invalid",
            mediaPort: 48010,
            serverType: 0,
            settingsJSON: "{}",
            sessionInfoJSON: "{}",
            rawSessionJSON: "{}"
        )
    }

    func waitForAllocation() async {
        for await _ in allocationStarted.stream { return }
    }

    func cancelSessionStart() async {
        cancellationCount += 1
        allocationContinuation?.resume(throwing: CancellationError())
        allocationContinuation = nil
    }

    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        finishedReasons.append(reason)
    }
}

private actor RecordingNativeTransport: NativeNVSTTransport {
    private let connectionError: NativeNVSTError?
    private(set) var connectedSessionIDs: [String] = []
    private(set) var disconnectCount = 0

    init(connectionError: NativeNVSTError? = nil) {
        self.connectionError = connectionError
    }

    func prepare() async throws -> NVSTNativeBridgeStatus {
        NVSTNativeBridgeStatus(libraryURL: URL(fileURLWithPath: "/"), bundledArtifactURLs: [], resolvedSymbols: [], runtimeAvailable: true)
    }

    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        if let connectionError { throw connectionError }
        connectedSessionIDs.append(allocation.session.id)
        return NativeNVSTTransportConnection(session: allocation.session, runtimeStatus: try await prepare())
    }

    func disconnect() async {
        disconnectCount += 1
    }

    func send(_ event: UserInputEvent) async throws {}
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func togglePerformanceOverlay() async throws {}
    func takeScreenshot() async -> StreamScreenshotImage? { nil }
}
