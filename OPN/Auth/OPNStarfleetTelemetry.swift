import Foundation

/// The Starfleet auth service's telemetry hook, wired to local support diagnostics.
///
/// Sentry is gone (NEC-47): transactions, spans and metric counters were Sentry-only, so a span is
/// now the module's own `StarfleetNoOpTelemetrySpan` — the vendor protocol requires a handle and
/// there is no tracing sink left to give it to. Errors stay, because they were always local log
/// lines, and the counter keeps its count in the diagnostics file at debug level.
final class OPNStarfleetTelemetry: StarfleetTelemetry, @unchecked Sendable {
    static let shared = OPNStarfleetTelemetry()

    private init() {}

    func startSpan(name: String, attributes: [String: String]) -> StarfleetTelemetrySpan {
        StarfleetNoOpTelemetrySpan()
    }

    func recordCounter(name: String, attributes: [String: String]) {
        let resolvedName = name.isEmpty ? "starfleet.auth.count" : name
        OPNDiagnostics.logDebugMessage(OPNDiagnostics.formattedLogMessage(level: "debug", area: "Starfleet", message: "Counter name=\(resolvedName)\(Self.attributeSuffix(attributes))"))
    }

    func recordError(_ error: Error, attributes: [String: String]) {
        let level = Self.logLevel(error: error)
        let message = OPNDiagnostics.formattedLogMessage(level: level, area: "Starfleet", message: "\(error.localizedDescription)\(Self.attributeSuffix(attributes))")
        if level == "error" {
            OPNDiagnostics.logErrorMessage(message)
        } else {
            OPNDiagnostics.logWarningMessage(message)
        }
    }

    private static func attributeSuffix(_ attributes: [String: String]) -> String {
        guard !attributes.isEmpty else { return "" }
        return " " + attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
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
