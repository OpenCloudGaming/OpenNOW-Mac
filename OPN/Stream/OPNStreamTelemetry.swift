import Foundation

public enum StreamTelemetryLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct StreamTelemetryEvent: Sendable {
    public let name: String
    public let level: StreamTelemetryLevel
    public let message: String
    public let attributes: [String: String]
    public let timestamp: Date
    /// Whether `message` has already been through the redaction pass. The stream transport scrubs
    /// its own lines so the durable session log gets the redacted text, and without this the sink
    /// scrubbed them a second time — on a counter dump that is the most expensive line the app
    /// writes.
    public let isRedacted: Bool

    public init(name: String,
                level: StreamTelemetryLevel,
                message: String,
                attributes: [String: String] = [:],
                timestamp: Date = Date(),
                isRedacted: Bool = false) {
        self.name = name
        self.level = level
        self.message = message
        self.attributes = attributes
        self.timestamp = timestamp
        self.isRedacted = isRedacted
    }
}

/// A stream telemetry sink. `capture` is the whole surface: it used to also carry counters, gauges
/// and distributions straight into Sentry metrics, and there is no metric sink left (NEC-47).
/// Numbers that were only ever metrics are now part of a log line's message — see
/// `StreamStartTrace` and `NativeNVSTHostViewModel.recordNativeNetworkTelemetry`.
public protocol StreamTelemetrySink: Sendable {
    func capture(_ event: StreamTelemetryEvent)
}

public enum OPNStreamTelemetry {
    static let lock = NSLock()
    private nonisolated(unsafe) static var sink: (any StreamTelemetrySink)?

    public static func configure(sink: (any StreamTelemetrySink)?) {
        lock.withLock {
            self.sink = sink
        }
    }

    public static func capture(_ name: String,
                               level: StreamTelemetryLevel,
                               message: String,
                               attributes: [String: String] = [:],
                               isRedacted: Bool = false) {
        let event = StreamTelemetryEvent(name: name, level: level, message: message, attributes: attributes, isRedacted: isRedacted)
        if let sink = currentSink() {
            sink.capture(event)
        } else if level != .debug {
            NSLog("%@", "[Stream][\(level.rawValue)] \(name): \(message)")
        }
    }

    private static func currentSink() -> (any StreamTelemetrySink)? {
        lock.withLock { sink }
    }
}
