import OpenNOWTelemetry
import Starfleet

final class OPNStarfleetSentryTelemetry: StarfleetTelemetry, @unchecked Sendable {
    static let shared = OPNStarfleetSentryTelemetry()

    private init() {}

    func startSpan(name: String, attributes: [String: String]) -> StarfleetTelemetrySpan {
        let transaction = OPNSentry.startTransaction(name: name.isEmpty ? "Starfleet auth" : name, operation: "starfleet.auth", makeCurrent: false)
        let span = OPNStarfleetSentryTelemetrySpan(transaction: transaction)
        for (key, value) in attributes { span.setAttribute(key, value: value) }
        return span
    }

    func recordCounter(name: String, attributes: [String: String]) {
        _ = OPNSentry.recordCounterMetric(key: name.isEmpty ? "starfleet.auth.count" : name, value: 1, attributes: attributes)
    }

    func recordError(_ error: Error, attributes: [String: String]) {
        let suffix = attributes.isEmpty ? "" : " " + attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let level = Self.logLevel(error: error)
        let message = OPNSentry.formattedLogMessage(level: level, area: "Starfleet", message: "\(error.localizedDescription)\(suffix)")
        if level == "error" {
            OPNSentry.logErrorMessage(message)
        } else {
            OPNSentry.logWarningMessage(message)
        }
    }

    private static func logLevel(error: Error) -> String {
        guard let error = error as? StarfleetAuthError else { return "error" }
        switch error.category {
        case .authorization, .missingData:
            return "warning"
        case .invalidRequest, .offline, .timeout, .server, .rateLimited, .unavailable, .parsing, .unknown:
            return "error"
        }
    }
}

private final class OPNStarfleetSentryTelemetrySpan: StarfleetTelemetrySpan, @unchecked Sendable {
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
