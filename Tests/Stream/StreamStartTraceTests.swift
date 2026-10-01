//  The per-step stream-start timings are asserted through the injectable telemetry sink, so the five
//  steps, the total, and the step an aborted launch stopped in are all pinned without touching the
//  process-wide sink the app configures. The durations ride in the timeline log line's message: they
//  used to be Sentry distribution metrics as well, and that sink is gone with the SDK (NEC-47).

import Foundation
import Testing
@testable import OpenNOW

private final class RecordingStreamStartSink: StreamTelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamTelemetryEvent] = []

    func capture(_ event: StreamTelemetryEvent) {
        lock.withLock { events.append(event) }
    }

    var captured: [StreamTelemetryEvent] { lock.withLock { events } }

    var timeline: StreamTelemetryEvent? {
        captured.first { $0.name == StreamStartTrace.timelineEventName }
    }

    /// The steps the timeline reports a duration for, in launch order.
    var stepNames: [String] {
        guard let message = timeline?.message else { return [] }
        return StreamLaunchStep.allCases.map(\.traceKey).filter { message.contains("\($0)=") }
    }
}

@Suite("Stream start timing")
struct StreamStartTraceTests {
    @Test("every step and the total are emitted, in launch order, on a connected start")
    func connectedStartEmitsEveryStepAndTotal() throws {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        for step in StreamLaunchStep.allCases { trace.begin(step) }
        trace.markConnected()
        trace.finish()

        #expect(sink.stepNames == StreamLaunchStep.allCases.map(\.traceKey))
        #expect(sink.timeline?.level == .info)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.connected.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == nil)
        let message = try #require(sink.timeline?.message)
        #expect(message.contains("total="))
    }

    @Test("an aborted start emits the steps it reached and names the step it stopped in")
    func abortedStartNamesTheFailingStep() {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        for step in [StreamLaunchStep.checkNetworkRoute, .allocateCloudSession, .prepareTransport, .connectTransport] {
            trace.begin(step)
        }
        trace.finish()

        #expect(sink.stepNames == ["check-network-route", "allocate-cloud-session", "prepare-transport", "connect-transport"])
        #expect(sink.timeline?.level == .warning)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.failed.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == "connect-transport")
    }

    @Test("a start stopped before its first step still emits a total")
    func startStoppedBeforeItsFirstStepEmitsATotal() {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        trace.finish()

        #expect(sink.stepNames.isEmpty)
        #expect(sink.timeline?.message.contains("total=") == true)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.failed.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == nil)
    }

    @Test("a cancelled start is reported as cancelled, not failed")
    func cancelledStartIsReportedAsCancelled() async {
        let sink = RecordingStreamStartSink()

        await Task {
            let trace = StreamStartTrace(applicationID: "100", sink: sink)
            trace.begin(.checkNetworkRoute)
            trace.begin(.allocateCloudSession)
            withUnsafeCurrentTask { $0?.cancel() }
            trace.finish()
        }.value

        #expect(sink.timeline?.level == .info)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.cancelled.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == "allocate-cloud-session")
    }

    @Test("finishing twice emits the timeline once")
    func finishingTwiceEmitsOnce() {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        trace.begin(.checkNetworkRoute)
        trace.finish()
        trace.finish()

        #expect(sink.captured.filter { $0.name == StreamStartTrace.timelineEventName }.count == 1)
        #expect(sink.stepNames == ["check-network-route"])
    }

    @Test("a native launch emits a step per launch step and one total")
    func nativeLaunchEmitsEveryStep() async throws {
        let sink = RecordingStreamStartSink()
        let path = NativeNVSTStreamingPath(
            sessionProvider: RecordingNativeSessionProvider(),
            transport: RecordingNativeTransport(),
            traceSink: sink
        )

        _ = try await path.start(configuration: launchConfiguration)

        #expect(sink.stepNames == StreamLaunchStep.allCases.map(\.traceKey))
        #expect(sink.timeline?.message.contains("total=") == true)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.connected.rawValue)
        #expect(sink.timeline?.attributes["applicationID"] == "100")
    }

    @Test("a launch that fails at connect names the connect step")
    func nativeLaunchFailureNamesTheConnectStep() async {
        let sink = RecordingStreamStartSink()
        let path = NativeNVSTStreamingPath(
            sessionProvider: RecordingNativeSessionProvider(),
            transport: RecordingNativeTransport(connectionError: .transportFailed("Connection rejected")),
            traceSink: sink
        )

        await #expect(throws: NativeNVSTError.transportFailed("Connection rejected")) {
            _ = try await path.start(configuration: launchConfiguration)
        }

        #expect(sink.stepNames == ["check-network-route", "allocate-cloud-session", "prepare-transport", "connect-transport"])
        #expect(sink.timeline?.level == .warning)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.failed.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == "connect-transport")
    }

    private var launchConfiguration: StreamLaunchConfiguration {
        StreamLaunchConfiguration(title: "Game", applicationID: "100", accessToken: "token", accountLinked: true, selectedStore: "steam")
    }
}
