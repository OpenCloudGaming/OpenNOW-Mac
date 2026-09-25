/// QLOG Logger
///
/// Logger for QUIC events following the QLOG specification.
/// Supports file output (JSON Lines format) and streaming output.
///
/// ## Usage
///
/// ```swift
/// let logger = QLOGLogger(
///     connectionID: "abc123",
///     output: .file(URL(fileURLWithPath: "/tmp/quic.qlog"))
/// )
///
/// logger.log(PacketSentEvent(...))
/// logger.finalize()
/// ```
///
/// ## Output Format
///
/// Events are written in JSON Lines format (one JSON object per line),
/// compatible with analysis tools like qvis.

import Foundation
import Synchronization

// MARK: - QLOG Output

/// QLOG output destination
public enum QLOGOutput: Sendable {
    /// Write to file (JSON Lines format)
    case file(URL)

    /// Stream to AsyncStream
    case stream(AsyncStream<any QLOGEvent>.Continuation)

    /// Callback for each event
    case callback(@Sendable (any QLOGEvent) -> Void)
}

// MARK: - QLOG Logger

/// Logger for QUIC events
///
/// Thread-safe logger that buffers events and writes them to the configured output.
/// Use `finalize()` to flush remaining events when the connection closes.
public final class QLOGLogger: Sendable {
    /// Output destination
    public let output: QLOGOutput

    /// Connection identifier for this log
    public let connectionID: String

    /// Connection start time (for relative timestamps)
    private let startTime: ContinuousClock.Instant

    /// Event buffer for batch writing
    private let state = Mutex<LoggerState>(LoggerState())

    /// Buffer flush threshold
    private let flushThreshold: Int

    /// Whether logging is enabled
    private let enabled: Bool

    private struct LoggerState: Sendable {
        var buffer: [any QLOGEvent] = []
        var isFinalized: Bool = false
    }

    /// Creates a new QLOG logger
    ///
    /// - Parameters:
    ///   - connectionID: Identifier for the connection being logged
    ///   - output: Where to write events
    ///   - enabled: Whether logging is enabled (default: true)
    ///   - flushThreshold: Number of events to buffer before flushing (default: 100)
    public init(
        connectionID: String,
        output: QLOGOutput,
        enabled: Bool = true,
        flushThreshold: Int = 100
    ) {
        self.connectionID = connectionID
        self.output = output
        self.enabled = enabled
        self.flushThreshold = flushThreshold
        self.startTime = .now
    }

    // MARK: - Logging

    /// Log an event
    ///
    /// Events are buffered and periodically flushed to the output.
    /// Call `finalize()` to ensure all events are written.
    ///
    /// - Parameter event: The event to log
    public func log(_ event: any QLOGEvent) {
        guard enabled else { return }

        state.withLock { s in
            guard !s.isFinalized else { return }

            s.buffer.append(event)

            if s.buffer.count >= flushThreshold {
                let events = s.buffer
                s.buffer.removeAll(keepingCapacity: true)
                flush(events: events)
            }
        }
    }

    /// Get current time as microseconds since connection start
    ///
    /// Use this when creating events to get consistent timestamps.
    ///
    /// - Returns: Microseconds since connection started
    public func relativeTime() -> UInt64 {
        let elapsed = ContinuousClock.now - startTime
        let seconds = elapsed.components.seconds
        let attoseconds = elapsed.components.attoseconds
        // Convert to microseconds
        return UInt64(seconds) * 1_000_000 + UInt64(attoseconds / 1_000_000_000_000)
    }

    /// Finalize the logger, flushing any remaining events
    ///
    /// Call this when the connection closes to ensure all events are written.
    /// After calling this, no more events will be logged.
    public func finalize() {
        let eventsToFlush: [any QLOGEvent] = state.withLock { s in
            guard !s.isFinalized else { return [] }
            s.isFinalized = true
            let events = s.buffer
            s.buffer.removeAll()
            return events
        }

        if !eventsToFlush.isEmpty {
            flush(events: eventsToFlush)
        }

        // Finish stream if applicable
        if case .stream(let continuation) = output {
            continuation.finish()
        }
    }

    // MARK: - Private

    private func flush(events: [any QLOGEvent]) {
        switch output {
        case .file(let url):
            writeToFile(events: events, url: url)
        case .stream(let continuation):
            for event in events {
                continuation.yield(event)
            }
        case .callback(let handler):
            for event in events {
                handler(event)
            }
        }
    }

    private func writeToFile(events: [any QLOGEvent], url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var lines = Data()
        for event in events {
            // Wrap in type-erased container for encoding
            let wrapper = AnyQLOGEvent(event: event)
            if let data = try? encoder.encode(wrapper) {
                lines.append(data)
                lines.append(Data("\n".utf8))
            }
        }

        // Append to file or create new
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(lines)
                try? handle.close()
            }
        } else {
            // Create directory if needed
            let directory = url.deletingLastPathComponent()
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? lines.write(to: url)
        }
    }
}

// MARK: - Type-Erased Event Wrapper

/// Type-erased wrapper for encoding QLOG events
private struct AnyQLOGEvent: Encodable {
    let event: any QLOGEvent

    func encode(to encoder: Encoder) throws {
        try event.encode(to: encoder)
    }
}

// MARK: - QLOG Configuration

/// Configuration for QLOG logging
public struct QLOGConfiguration: Sendable {
    /// Whether QLOG is enabled
    public var enabled: Bool

    /// Output directory for QLOG files
    public var outputDirectory: URL?

    /// File name prefix (default: "qlog")
    public var filePrefix: String

    /// Buffer flush threshold
    public var flushThreshold: Int

    /// Creates default QLOG configuration (disabled)
    public init() {
        self.enabled = false
        self.outputDirectory = nil
        self.filePrefix = "qlog"
        self.flushThreshold = 100
    }

    /// Creates an enabled QLOG configuration
    ///
    /// - Parameters:
    ///   - outputDirectory: Directory to write QLOG files
    ///   - filePrefix: Prefix for QLOG file names
    public static func enabled(
        outputDirectory: URL,
        filePrefix: String = "qlog"
    ) -> QLOGConfiguration {
        var config = QLOGConfiguration()
        config.enabled = true
        config.outputDirectory = outputDirectory
        config.filePrefix = filePrefix
        return config
    }
}
