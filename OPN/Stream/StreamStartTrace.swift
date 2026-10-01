//  Per-step elapsed timing for one native NVST stream start, as signposts and telemetry.

import Foundation
import os

extension StreamLaunchStep {
    /// Stable metric key for this step; `title` is user-facing copy and may be reworded.
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

/// How a stream start ended. A cancelled start is not the same signal as a seat refusing the session.
enum StreamStartOutcome: String, Sendable {
    case connected
    case failed
    case cancelled
}

/// One stream start's timeline: a duration per step plus the total, emitted on every exit path.
final class StreamStartTrace {
    /// The whole start, on the same Instruments track as the per-step intervals.
    static let totalSignpostName: StaticString = "StreamStart.total"
    /// One log line per start carrying every step, so a diagnostics log has the breakdown too.
    static let timelineEventName = "nvst.path.start.timeline"
    static let stepMetricKey = "nvst.path.start.step_ms"
    static let totalMetricKey = "nvst.path.start.total_ms"
    static let signpostCategory = "Stream"

    private struct OpenStep {
        let step: StreamLaunchStep
        let startedAt: ContinuousClock.Instant
        let interval: OSSignpostIntervalState
    }

    private struct MeasuredStep {
        let step: StreamLaunchStep
        let duration: Duration
    }

    private let applicationID: String
    private let sink: any StreamTelemetrySink
    private let signposter: OSSignposter
    private let startedAt: ContinuousClock.Instant
    private var openStep: OpenStep?
    private var stepDurations: [StreamLaunchStep: Duration] = [:]
    private var outcome: StreamStartOutcome?
    private var totalInterval: OSSignpostIntervalState?
    private var isFinished = false

    /// `sink` defaults to the app's configured stream telemetry sink; a caller injects one to observe
    /// a start without touching process-wide state.
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

    /// Opens the next step. The previous one closes at the same instant, so the durations tile.
    func begin(_ step: StreamLaunchStep) {
        let boundary = ContinuousClock.now
        closeOpenStep(at: boundary)
        openStep = OpenStep(
            step: step,
            startedAt: boundary,
            interval: signposter.beginInterval(step.signpostName)
        )
    }

    /// Marks the launch as having reached the ready state.
    func markConnected() {
        closeOpenStep(at: .now)
        outcome = .connected
    }

    /// Ends any open step and emits the timeline exactly once, so a `defer` cannot double-count.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        let stoppedStep = openStep?.step
        closeOpenStep(at: .now)
        endTotalInterval()
        let resolved = resolveOutcome()
        emitTimeline(
            outcome: resolved,
            failedStep: failedStep(for: resolved, stoppedAt: stoppedStep),
            total: startedAt.duration(to: .now)
        )
    }

    private func closeOpenStep(at instant: ContinuousClock.Instant) {
        guard let openStep else { return }
        self.openStep = nil
        signposter.endInterval(openStep.step.signpostName, openStep.interval)
        stepDurations[openStep.step] = openStep.startedAt.duration(to: instant)
    }

    private func endTotalInterval() {
        guard let totalInterval else { return }
        signposter.endInterval(Self.totalSignpostName, totalInterval)
        self.totalInterval = nil
    }

    private func resolveOutcome() -> StreamStartOutcome {
        if let outcome { return outcome }
        guard Task.isCancelled else { return .failed }
        return .cancelled
    }

    /// A start that reached ready has no failing step; one that stopped reports the step it stopped in.
    private func failedStep(for outcome: StreamStartOutcome, stoppedAt step: StreamLaunchStep?) -> StreamLaunchStep? {
        guard outcome != .connected else { return nil }
        return step
    }

    private func measuredSteps() -> [MeasuredStep] {
        StreamLaunchStep.allCases.compactMap { step in
            guard let duration = stepDurations[step] else { return nil }
            return MeasuredStep(step: step, duration: duration)
        }
    }

    private func emitTimeline(outcome: StreamStartOutcome, failedStep: StreamLaunchStep?, total: Duration) {
        let steps = measuredSteps()
        let attributes = timelineAttributes(outcome: outcome, failedStep: failedStep)
        for measured in steps {
            sink.record(StreamTelemetryMetric(
                key: Self.stepMetricKey,
                kind: .distribution,
                value: Self.milliseconds(measured.duration),
                unit: "millisecond",
                attributes: [
                    "step": measured.step.traceKey,
                    "outcome": outcome.rawValue,
                    "applicationID": applicationID
                ]
            ))
        }
        sink.record(StreamTelemetryMetric(
            key: Self.totalMetricKey,
            kind: .distribution,
            value: Self.milliseconds(total),
            unit: "millisecond",
            attributes: attributes
        ))
        sink.capture(StreamTelemetryEvent(
            name: Self.timelineEventName,
            level: timelineLevel(for: outcome),
            message: timelineMessage(outcome: outcome, steps: steps, total: total),
            attributes: attributes
        ))
    }

    private func timelineAttributes(outcome: StreamStartOutcome, failedStep: StreamLaunchStep?) -> [String: String] {
        var attributes = ["applicationID": applicationID, "outcome": outcome.rawValue]
        guard let failedStep else { return attributes }
        attributes["failedStep"] = failedStep.traceKey
        return attributes
    }

    private func timelineLevel(for outcome: StreamStartOutcome) -> StreamTelemetryLevel {
        guard outcome == .failed else { return .info }
        return .warning
    }

    private func timelineMessage(outcome: StreamStartOutcome, steps: [MeasuredStep], total: Duration) -> String {
        let stepSummary = steps.map { "\($0.step.traceKey)=\(Self.roundedMilliseconds($0.duration))ms" }
        let measured = (stepSummary + ["total=\(Self.roundedMilliseconds(total))ms"]).joined(separator: " ")
        return "Stream start \(outcome.rawValue): \(measured)"
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private static func roundedMilliseconds(_ duration: Duration) -> Int {
        Int(milliseconds(duration).rounded())
    }
}

/// The default sink, resolving the app's configured stream telemetry sink at emission time rather
/// than capturing it: the app configures that sink during launch.
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
