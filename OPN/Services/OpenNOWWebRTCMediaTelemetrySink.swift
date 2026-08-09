import Foundation

struct OpenNOWWebRTCMediaTelemetrySink: WebRTCMediaTelemetrySink {
    func capture(_ event: WebRTCMediaTelemetryEvent) {
        let suffix = event.attributes.isEmpty ? "" : " " + event.attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let level = Self.sentryLevel(for: event)
        let message = OPNSentry.formattedLogMessage(level: level.rawValue, area: "WebRTC", message: "\(event.name): \(event.message)\(suffix)")
        switch level {
        case .debug:
            OPNSentry.logDebugMessage(message)
        case .info:
            OPNSentry.logInfoMessage(message)
        case .warning:
            OPNSentry.logWarningMessage(message)
        case .error:
            OPNSentry.logErrorMessage(message)
        }
    }

    private static func sentryLevel(for event: WebRTCMediaTelemetryEvent) -> WebRTCMediaTelemetryLevel {
        guard event.level == .error else { return event.level }
        if event.name == "webrtc.path.session_provider.error" { return .warning }
        return event.level
    }

    func record(_ metric: WebRTCMediaTelemetryMetric) {
        let attributes = metric.attributes as [String: Any]
        switch metric.kind {
        case .counter:
            _ = OPNSentry.recordCounterMetric(key: metric.key, value: Int64(max(0, metric.value.rounded())), attributes: attributes)
        case .gauge:
            _ = OPNSentry.recordGaugeMetric(key: metric.key, value: metric.value, unit: metric.unit, attributes: attributes)
        case .distribution:
            _ = OPNSentry.recordDistributionMetric(key: metric.key, value: metric.value, unit: metric.unit, attributes: attributes)
        }
    }
}
