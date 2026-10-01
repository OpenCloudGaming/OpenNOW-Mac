//  Per-step elapsed timing for one native NVST stream start.
//
//  The five launch steps are published to the UI but were never timed, so "the stream takes a while
//  to start" could not be attributed to the runtime check, the cloud allocation, transport setup or
//  the connect. Each step gets an `OSSignposter` interval on the "Stream" category - so one start
//  reads as one track in Instruments - and an elapsed duration through `OPNStreamTelemetry`, the
//  sink the rest of stream telemetry already uses.
//
//  Start-of-stream only. Nothing here is reachable from the per-frame path.

import Foundation
import os

extension StreamLaunchStep {
    /// Stable key for signpost names and metric attributes. `title` is user-facing copy and may be
    /// reworded, so it cannot key a metric that outlives the wording.
    var traceKey: String {
        switch self {
        case .checkNetworkRoute: "check-network-route"
        case .allocateCloudSession: "allocate-cloud-session"
        case .prepareTransport: "prepare-transport"
        case .connectTransport: "connect-transport"
        case .connected: "connected"
        }
    }

    /// `OSSignposter` interns names at compile time, so each step needs its own literal.
    var signpostName: StaticString {
        switch self {
        case .checkNetworkRoute: "StreamStart.check-network-route"
        case .allocateCloudSession: "StreamStart.allocate-cloud-session"
        case .prepareTransport: "StreamStart.prepare-transport"
        case .connectTransport: "StreamStart.connect-transport"
        case .connected: "StreamStart.connected"
        }
    }
}

/// How a stream start ended. A cancelled start is distinguished from a failed one: the user backing
/// out is not the same signal as the seat refusing the session.
enum StreamStartOutcome: String, Sendable {
    case connected
    case failed
    case cancelled
}

/// One stream start's timeline. Created at the top of the launch, advanced by `begin(_:)` at each
/// step boundary, and closed by `finish()` on every exit path.
final class StreamStartTrace {
    /// The whole start, in the same track as the per-step intervals.
    static let totalSignpostName: StaticString = "StreamStart.total"
    /// One log line per start carrying every step, so a diagnostics log a user sends has the
    /// breakdown even when the metrics backend does not.
    static let timelineEventName = "nvst.path.start.timeline"
    /// One distribution sample per step, and one for the total.
    static let stepMetricKey = "nvst.path.start.step_ms"
    static let totalMetricKey = "nvst.path.start.total_ms"
    static let signpostCategory = "Stream"

    private let applicationID: String
    private let sink: any StreamTelemetrySink
    private let signposter: OSSignposter
    private let startedAt: ContinuousClock.Instant
    private var stepStartedAt: ContinuousClock.Instant?
    private var stepInterval: OSSignpostIntervalState?
    private var openStep: StreamLaunchStep?
    private var stepDurations: [StreamLaunchStep: Duration] = [:]
    private var outcome: StreamStartOutcome?
    private var totalInterval: OSSignpostIntervalState?
    private var isFinished = false

    /// `sink` defaults to the app's configured stream telemetry sink. A caller injects one to
    /// observe a start without touching process-wide state.
    init(applicationID: String, sink: (any StreamTelemetrySink)? = nil) {
        self.applicationID = applicationID
        self.sink = sink ?? OPNStreamStartTraceSink()
        self.signposter = OSSignposter(
            subsystem: Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.OpenNOW",
            category: Self.signpostCategory
        )
        self.startedAt = ContinuousClock.now
        self.totalInterval = signposter.beginInterval(Self.totalSignpostName)
    }

    /// Opens the next step. The previous step closes at this boundary, so the five durations tile the
    /// start instead of overlapping.
    func begin(_ step: StreamLaunchStep) {
        closeOpenStep()
        openStep = step
        stepStartedAt = .now
        stepInterval = signposter.beginInterval(step.signpostName)
    }

    /// Marks the launch as having reached the ready state.
    func markConnected() {
        closeOpenStep()
        outcome = .connected
    }

    /// Ends whatever step is still open and emits the timeline exactly once, so the `defer` on the
    /// launch path and an explicit call cannot double-count.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        // A step still open when the launch stops is where it stopped. Its interval ends here, so
        // the failing step is visible in Instruments with the time it spent before giving up.
        let stoppedAt = openStep
        closeOpenStep()
        if let totalInterval {
            signposter.endInterval(Self.totalSignpostName, totalInterval)
            self.totalInterval = nil
        }
        let resolvedOutcome = outcome ?? (Task.isCancelled ? .cancelled : .failed)
        emit(outcome: resolvedOutcome,
             failedStep: resolvedOutcome == .connected ? nil : stoppedAt,
             total: startedAt.duration(to: .now))
    }

    private func closeOpenStep() {
        guard let openStep, let stepInterval else { return }
        signposter.endInterval(openStep.signpostName, stepInterval)
        stepDurations[openStep] = stepStartedAt.map { $0.duration(to: .now) } ?? .zero
        self.openStep = nil
        self.stepInterval = nil
        self.stepStartedAt = nil
    }

    private func emit(outcome: StreamStartOutcome, failedStep: StreamLaunchStep?, total: Duration) {
        var summary: [String] = []
        for step in StreamLaunchStep.allCases {
            guard let duration = stepDurations[step] else { continue }
            let elapsed = Self.milliseconds(duration)
            summary.append("\(step.traceKey)=\(Int(elapsed.rounded()))ms")
            sink.record(
                StreamTelemetryMetric(
                    key: Self.stepMetricKey,
                    kind: .distribution,
                    value: elapsed,
                    unit: "millisecond",
                    attributes: ["step": step.traceKey, "outcome": outcome.rawValue, "applicationID": applicationID]
                )
            )
        }
        let totalMilliseconds = Self.milliseconds(total)
        summary.append("total=\(Int(totalMilliseconds.rounded()))ms")
        var attributes = ["applicationID": applicationID, "outcome": outcome.rawValue]
        if let failedStep {
            attributes["failedStep"] = failedStep.traceKey
        }
        sink.record(
            StreamTelemetryMetric(
                key: Self.totalMetricKey,
                kind: .distribution,
                value: totalMilliseconds,
                unit: "millisecond",
                attributes: attributes
            )
        )
        sink.capture(
            StreamTelemetryEvent(
                name: Self.timelineEventName,
                level: outcome == .failed ? .warning : .info,
                message: "Stream start \(outcome.rawValue): \(summary.joined(separator: " "))",
                attributes: attributes
            )
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}

/// The default sink: resolves the app's configured stream telemetry sink at emission time rather
/// than capturing it. The app configures that sink during launch, so a snapshot taken when a trace
/// is constructed can predate it.
struct OPNStreamStartTraceSink: StreamTelemetrySink {
    func capture(_ event: StreamTelemetryEvent) {
        OPNStreamTelemetry.capture(
            event.name,
            level: event.level,
            message: event.message,
            attributes: event.attributes,
            isRedacted: event.isRedacted
        )
    }

    func record(_ metric: StreamTelemetryMetric) {
        OPNStreamTelemetry.record(
            metric.key,
            kind: metric.kind,
            value: metric.value,
            unit: metric.unit,
            attributes: metric.attributes
        )
    }
}
