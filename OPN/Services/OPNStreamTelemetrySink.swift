import Foundation

struct OPNStreamTelemetrySink: StreamTelemetrySink {
    func capture(_ event: StreamTelemetryEvent) {
        let suffix = event.attributes.isEmpty ? "" : " " + event.attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let level = Self.streamLevel(for: event)
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

    /// A session-provider failure on the WebRTC path is expected in the field, so it logs as a
    /// warning rather than an error.
    private static func streamLevel(for event: StreamTelemetryEvent) -> StreamTelemetryLevel {
        guard event.level == .error else { return event.level }
        if event.name == "webrtc.path.session_provider.error" { return .warning }
        return event.level
    }
}
