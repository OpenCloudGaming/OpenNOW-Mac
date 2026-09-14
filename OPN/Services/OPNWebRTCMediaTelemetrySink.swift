import Foundation

struct OPNWebRTCMediaTelemetrySink: WebRTCMediaTelemetrySink {
    func capture(_ event: WebRTCMediaTelemetryEvent) {
        let suffix = event.attributes.isEmpty ? "" : " " + event.attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let level = Self.sentryLevel(for: event)
        // A pre-redacted message is passed through: the attribute suffix is built from key/value
        // pairs this module writes, so it carries nothing the redaction pass would strip.
        let message = OPNLog.Message(event.message + suffix, isRedacted: event.isRedacted && suffix.isEmpty)
        let named = OPNLog.Message("\(event.name): " + message.text, isRedacted: message.isRedacted)
        switch level {
        case .debug:
            OPNLog.debug(.stream, named)
        case .info:
            OPNLog.info(.stream, named)
        case .warning:
            OPNLog.warning(.stream, named)
        case .error:
            OPNLog.error(.stream, named)
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
