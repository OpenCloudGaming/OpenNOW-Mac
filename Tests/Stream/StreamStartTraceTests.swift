//  The per-step stream-start timings are asserted through the injectable telemetry sink, so the five
//  steps, the total, and the step an aborted launch stopped in are all pinned without touching the
//  process-wide sink the app configures.

import Foundation
import Testing
@testable import OpenNOW

private final class RecordingStreamStartSink: StreamTelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamTelemetryEvent] = []
    private var metrics: [StreamTelemetryMetric] = []

    func capture(_ event: StreamTelemetryEvent) {
        lock.withLock { events.append(event) }
    }

    func record(_ metric: StreamTelemetryMetric) {
        lock.withLock { metrics.append(metric) }
    }

    var captured: [StreamTelemetryEvent] { lock.withLock { events } }
    var recorded: [StreamTelemetryMetric] { lock.withLock { metrics } }

    var timeline: StreamTelemetryEvent? {
        captured.first { $0.name == StreamStartTrace.timelineEventName }
    }

    var stepNames: [String] {
        recorded
            .filter { $0.key == StreamStartTrace.stepMetricKey }
            .compactMap { $0.attributes["step"] }
    }

    var totals: [StreamTelemetryMetric] {
        recorded.filter { $0.key == StreamStartTrace.totalMetricKey }
    }
}

@Suite("Stream start timing")
struct StreamStartTraceTests {
    @Test("every step and the total are emitted, in launch order, on a connected start")
    func connectedStartEmitsEveryStepAndTotal() {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        for step in StreamLaunchStep.allCases { trace.begin(step) }
        trace.markConnected()
        trace.finish()

        #expect(sink.stepNames == StreamLaunchStep.allCases.map(\.traceKey))
        #expect(sink.totals.count == 1)
        #expect(sink.totals.first?.unit == "millisecond")
        #expect(sink.timeline?.level == .info)
        #expect(sink.timeline?.attributes["outcome"] == StreamStartOutcome.connected.rawValue)
        #expect(sink.timeline?.attributes["failedStep"] == nil)
        #expect(sink.timeline?.message.contains("total=") == true)
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
        #expect(sink.totals.first?.attributes["failedStep"] == "connect-transport")
    }

    @Test("a start stopped before its first step still emits a total")
    func startStoppedBeforeItsFirstStepEmitsATotal() {
        let sink = RecordingStreamStartSink()

        let trace = StreamStartTrace(applicationID: "100", sink: sink)
        trace.finish()

        #expect(sink.stepNames.isEmpty)
        #expect(sink.totals.count == 1)
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
        #expect(sink.totals.count == 1)
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
        #expect(sink.totals.count == 1)
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

        do {
            _ = try await path.start(configuration: launchConfiguration)
            Issue.record("Expected the connection to fail")
        } catch {
            #expect(error as? NativeNVSTError == .transportFailed("Connection rejected"))
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
