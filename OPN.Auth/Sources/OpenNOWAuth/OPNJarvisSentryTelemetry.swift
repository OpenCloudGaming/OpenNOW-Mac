import Foundation
import Jarvis
import OpenNOWTelemetry

final class OPNJarvisSentryTelemetry: JarvisTelemetry, @unchecked Sendable {
    static let shared = OPNJarvisSentryTelemetry()

    private init() {}

    func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan {
        let transaction = OPNSentry.startTransaction(name: name.isEmpty ? "Jarvis auth" : name, operation: "jarvis.auth", makeCurrent: false)
        let span = OPNJarvisSentryTelemetrySpan(transaction: transaction)
        if let operation { span.setAttribute("jarvis.operation", value: operation.rawValue) }
        for (key, value) in attributes { span.setAttribute(key, value: value) }
        return span
    }

    func recordBreadcrumb(_ message: String, attributes: [String: String]) {
        let suffix = attributes.isEmpty ? "" : " " + attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        OPNSentry.logInfoMessage(OPNSentry.formattedLogMessage(level: "info", area: "Jarvis", message: "\(message)\(suffix)"))
    }

    func recordCounter(name: String, attributes: [String: String]) {
        _ = OPNSentry.recordCounterMetric(key: name.isEmpty ? "jarvis.auth.count" : name, value: 1, attributes: attributes)
    }

    func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String]) {
        var parts = attributes
        if let operation { parts["jarvis.operation"] = operation.rawValue }
        let suffix = parts.isEmpty ? "" : " " + parts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        OPNSentry.logErrorMessage(OPNSentry.formattedLogMessage(level: "error", area: "Jarvis", message: "\(error.localizedDescription)\(suffix)"))
    }
}

private final class OPNJarvisSentryTelemetrySpan: JarvisTelemetrySpan, @unchecked Sendable {
    private let transaction: OPNSentryTransaction?

    init(transaction: OPNSentryTransaction?) {
        self.transaction = transaction
    }

    func setAttribute(_ key: String, value: String) {
        transaction?.setTag(key, value: value)
        transaction?.setData(key, value: value)
    }

    func finish(success: Bool) {
        transaction?.setStatus(success)
        transaction?.finish()
    }
}
