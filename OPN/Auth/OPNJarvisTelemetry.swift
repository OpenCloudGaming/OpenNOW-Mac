import Foundation

/// The Jarvis auth service's telemetry hook, wired to local support diagnostics.
///
/// Sentry is gone (NEC-47): transactions, spans and metric counters were Sentry-only, so a span is
/// now the module's own `JarvisNoOpTelemetrySpan` — the vendor protocol requires a handle and there
/// is no tracing sink left to give it to. Breadcrumbs and errors stay, because they were always
/// local log lines, and the counter keeps its count in the diagnostics file at debug level.
final class OPNJarvisTelemetry: JarvisTelemetry, @unchecked Sendable {
    static let shared = OPNJarvisTelemetry()

    private init() {}

    func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan {
        JarvisNoOpTelemetrySpan()
    }

    func recordBreadcrumb(_ message: String, attributes: [String: String]) {
        OPNDiagnostics.logInfoMessage(OPNDiagnostics.formattedLogMessage(level: "info", area: "Jarvis", message: "\(message)\(Self.attributeSuffix(attributes))"))
    }

    func recordCounter(name: String, attributes: [String: String]) {
        let resolvedName = name.isEmpty ? "jarvis.auth.count" : name
        OPNDiagnostics.logDebugMessage(OPNDiagnostics.formattedLogMessage(level: "debug", area: "Jarvis", message: "Counter name=\(resolvedName)\(Self.attributeSuffix(attributes))"))
    }

    func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String]) {
        var parts = attributes
        if let operation { parts["jarvis.operation"] = operation.rawValue }
        let level = Self.logLevel(error: error, attributes: parts)
        let message = OPNDiagnostics.formattedLogMessage(level: level, area: "Jarvis", message: "\(error.localizedDescription)\(Self.attributeSuffix(parts))")
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

    private static func logLevel(error: Error, attributes: [String: String]) -> String {
        let description = error.localizedDescription.lowercased()
        if attributes["phase"] == "callback" || description.contains("idp callback") { return "warning" }
        return "error"
    }
}
