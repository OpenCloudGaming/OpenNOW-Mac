import Foundation

public enum WebRTCMediaTelemetryLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum WebRTCMediaTelemetryMetricKind: String, Sendable {
    case counter
    case gauge
    case distribution
}

public struct WebRTCMediaTelemetryEvent: Sendable {
    public let name: String
    public let level: WebRTCMediaTelemetryLevel
    public let message: String
    public let attributes: [String: String]
    public let timestamp: Date

    public init(name: String,
                level: WebRTCMediaTelemetryLevel,
                message: String,
                attributes: [String: String] = [:],
                timestamp: Date = Date()) {
        self.name = name
        self.level = level
        self.message = message
        self.attributes = attributes
        self.timestamp = timestamp
    }
}

public struct WebRTCMediaTelemetryMetric: Sendable {
    public let key: String
    public let kind: WebRTCMediaTelemetryMetricKind
    public let value: Double
    public let unit: String?
    public let attributes: [String: String]

    public init(key: String,
                kind: WebRTCMediaTelemetryMetricKind,
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

public protocol WebRTCMediaTelemetrySink: Sendable {
    func capture(_ event: WebRTCMediaTelemetryEvent)
    func record(_ metric: WebRTCMediaTelemetryMetric)
}

public extension WebRTCMediaTelemetrySink {
    func record(_ metric: WebRTCMediaTelemetryMetric) {}
}

public enum WebRTCMediaTelemetry {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sink: (any WebRTCMediaTelemetrySink)?

    public static func configure(sink: (any WebRTCMediaTelemetrySink)?) {
        lock.withLock {
            self.sink = sink
        }
    }

    public static func capture(_ name: String,
                               level: WebRTCMediaTelemetryLevel,
                               message: String,
                               attributes: [String: String] = [:]) {
        let event = WebRTCMediaTelemetryEvent(name: name, level: level, message: message, attributes: attributes)
        NSLog("%@", "[WebRTCMedia][\(level.rawValue)] \(name): \(message)")
        currentSink()?.capture(event)
    }

    public static func record(_ key: String,
                              kind: WebRTCMediaTelemetryMetricKind,
                              value: Double,
                              unit: String? = nil,
                              attributes: [String: String] = [:]) {
        currentSink()?.record(WebRTCMediaTelemetryMetric(key: key, kind: kind, value: value, unit: unit, attributes: attributes))
    }

    private static func currentSink() -> (any WebRTCMediaTelemetrySink)? {
        lock.withLock { sink }
    }
}
