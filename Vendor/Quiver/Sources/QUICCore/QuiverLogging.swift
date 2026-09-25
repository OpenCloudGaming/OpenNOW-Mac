// QuiverLogging.swift
// Centralized logger factory for Quiver modules.
//
// All Quiver modules should use `QuiverLogging.logger(label:)` instead of
// `Logger(label:)` directly. This allows the log level to be controlled
// either programmatically (via `overrideLogLevel`) or via the `LOG_LEVEL`
// environment variable, without requiring `LoggingSystem.bootstrap` (which
// can only be called once per process and is unreliable in test targets
// that mix XCTest and Swift Testing).
//
// Priority order:
//   1. `QuiverLogging.overrideLogLevel` (set programmatically, e.g. from tests)
//   2. `LOG_LEVEL` environment variable
//   3. Default handler level (unchanged)
//
// Supported values for `LOG_LEVEL`:
//   trace, debug, info, notice, warning, error, critical
//
// Example (tests):
//   QuiverLogging.overrideLogLevel = .critical   // silence all logs
//
// Example (CLI):
//   LOG_LEVEL=critical swift test                 // silence all logs
//   LOG_LEVEL=trace swift test                    // maximum verbosity

import Foundation
import Logging
import Synchronization

public enum QuiverLogging: Sendable {
    /// Thread-safe storage for the programmatic log-level override.
    private static let _overrideLogLevel = Mutex<Logger.Level?>(nil)

    /// Programmatic log-level override.
    ///
    /// When set, every logger created via `QuiverLogging.logger(label:)` will
    /// use this level, regardless of the `LOG_LEVEL` environment variable.
    ///
    /// Set this as early as possible — ideally in an XCTestCase
    /// `override class func setUp()` that sorts first alphabetically
    /// (e.g. `AAA_TestLoggingBootstrap`).
    public static var overrideLogLevel: Logger.Level? {
        get { _overrideLogLevel.withLock { $0 } }
        set { _overrideLogLevel.withLock { $0 = newValue } }
    }

    /// Reads the `LOG_LEVEL` environment variable and returns the
    /// corresponding `Logger.Level`, or `nil` if unset / unrecognised.
    public static var environmentLogLevel: Logger.Level? {
        guard let raw = ProcessInfo.processInfo.environment["LOG_LEVEL"]?.lowercased() else {
            return nil
        }
        switch raw {
        case "trace":    return .trace
        case "debug":    return .debug
        case "info":     return .info
        case "notice":   return .notice
        case "warning":  return .warning
        case "error":    return .error
        case "critical": return .critical
        default:         return nil
        }
    }

    /// The effective log level override (programmatic first, then env var).
    public static var effectiveLogLevel: Logger.Level? {
        overrideLogLevel ?? environmentLogLevel
    }

    /// Creates a `Logger` with the given label, applying the effective
    /// log level override when present.
    ///
    /// Use this instead of `Logger(label:)` throughout Quiver source code.
    ///
    /// - Parameter label: The logger label (e.g. `"quic.endpoint"`).
    /// - Returns: A configured `Logger`.
    public static func logger(label: String) -> Logger {
        var l = Logger(label: label)
        if let level = effectiveLogLevel {
            l.logLevel = level
        }
        return l
    }
}