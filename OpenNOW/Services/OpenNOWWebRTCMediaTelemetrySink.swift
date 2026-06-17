import Foundation
import OpenNOWTelemetry
import WebRTCMedia

struct OpenNOWWebRTCMediaTelemetrySink: WebRTCMediaTelemetrySink {
    func capture(_ event: WebRTCMediaTelemetryEvent) {
        let suffix = event.attributes.isEmpty ? "" : " " + event.attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let message = "[WebRTCMedia] \(event.name): \(event.message)\(suffix)"
        switch event.level {
        case .error:
            OPNSentry.logErrorMessage(message)
        case .warning, .info, .debug:
            OPNSentry.logInfoMessage(message)
        }
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
