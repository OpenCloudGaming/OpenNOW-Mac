import Foundation

public enum StreamTelemetryLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum StreamTelemetryMetricKind: String, Sendable {
    case counter
    case gauge
    case distribution
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

public struct StreamTelemetryMetric: Sendable {
    public let key: String
    public let kind: StreamTelemetryMetricKind
    public let value: Double
    public let unit: String?
    public let attributes: [String: String]

    public init(key: String,
                kind: StreamTelemetryMetricKind,
                value: Double,
                unit: String? = nil,
                attributes: [String: String] = [:]) {
        self.key = key
        self.kind = kind
        self.value = value
        self.unit = unit
        self.attributes = attributes
    }
}

public protocol StreamTelemetrySink: Sendable {
    func capture(_ event: StreamTelemetryEvent)
    func record(_ metric: StreamTelemetryMetric)
}

public extension StreamTelemetrySink {
    func record(_ metric: StreamTelemetryMetric) {}
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

    public static func record(_ key: String,
                              kind: StreamTelemetryMetricKind,
                              value: Double,
                              unit: String? = nil,
                              attributes: [String: String] = [:]) {
        currentSink()?.record(StreamTelemetryMetric(key: key, kind: kind, value: value, unit: unit, attributes: attributes))
    }

    private static func currentSink() -> (any StreamTelemetrySink)? {
        lock.withLock { sink }
    }
}
