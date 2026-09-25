/// WebTransport Configuration
///
/// A unified configuration for WebTransport that composes the underlying
/// `QUICConfiguration` without duplicating its properties.
///
/// ## Design
///
/// `WebTransportConfiguration` is a composition, not a copy:
/// - `quic` is the actual `QUICConfiguration` (TLS, transport parameters, etc.)
/// - The remaining fields are WebTransport-specific (session limits, timeouts, headers)
///
/// ## Usage
///
/// ```swift
/// // Client
/// let config = WebTransportConfiguration(quic: .testing())
/// let session = try await WebTransportClient.connect(
///     url: "https://example.com:4433/wt",
///     configuration: config
/// )
///
/// // Server
/// var config = WebTransportConfiguration(quic: myProductionQuicConfig)
/// config.maxSessions = 4
/// let server = try await WebTransportServer.listen(
///     host: "0.0.0.0",
///     port: 443,
///     configuration: config
/// )
/// ```

import Foundation
import QUIC
import QUICCore

// MARK: - WebTransport Configuration

/// Unified configuration for WebTransport clients and servers.
///
/// Composes `QUICConfiguration` directly — no property duplication.
/// WebTransport-required HTTP/3 settings (`enableConnectProtocol`,
/// `enableH3Datagram`, `webtransportMaxSessions`) are always merged
/// automatically by the client/server implementations.
public struct WebTransportConfiguration: Sendable {

    // MARK: - QUIC (composed, not duplicated)

    /// The underlying QUIC transport configuration.
    ///
    /// Controls TLS mode, transport parameters, flow control, idle timeout,
    /// and all other QUIC-level knobs. Modify this directly:
    ///
    /// ```swift
    /// var config = WebTransportConfiguration(quic: .testing())
    /// config.quic.maxIdleTimeout = .seconds(30)
    /// ```
    public var quic: QUICConfiguration

    // MARK: - WebTransport-specific

    /// Maximum number of concurrent WebTransport sessions.
    ///
    /// Advertised via `SETTINGS_WEBTRANSPORT_MAX_SESSIONS`.
    /// Browsers require this to be > 0.
    ///
    /// - Default: 1
    public var maxSessions: UInt64

    /// Additional HTTP headers to include in the Extended CONNECT request.
    ///
    /// Use this for authentication tokens, origin headers, etc.
    /// (Client-side only; ignored on the server.)
    ///
    /// - Default: `[]`
    public var headers: [(String, String)]

    /// HTTP/3 settings overrides.
    ///
    /// WebTransport-required settings are always merged in automatically.
    /// Use this to override QPACK configuration or other HTTP/3 settings.
    ///
    /// - Default: literal-only QPACK
    public var http3Settings: HTTP3Settings

    /// Timeout for the HTTP/3 SETTINGS exchange.
    ///
    /// - Default: 10 seconds
    public var connectionReadyTimeout: Duration

    /// Timeout for the Extended CONNECT request/response handshake.
    ///
    /// - Default: 10 seconds
    public var connectTimeout: Duration

    // MARK: - Initialization

    /// Creates a WebTransport configuration.
    ///
    /// - Parameters:
    ///   - quic: The QUIC transport configuration (TLS, flow control, etc.)
    ///   - maxSessions: Max concurrent WebTransport sessions (default: 1)
    ///   - headers: Additional HTTP headers for CONNECT (default: [])
    ///   - http3Settings: HTTP/3 settings overrides (default: literal-only QPACK)
    ///   - connectionReadyTimeout: SETTINGS exchange timeout (default: 10s)
    ///   - connectTimeout: Extended CONNECT timeout (default: 10s)
    public init(
        quic: QUICConfiguration,
        maxSessions: UInt64 = 1,
        headers: [(String, String)] = [],
        http3Settings: HTTP3Settings = HTTP3Settings(),
        connectionReadyTimeout: Duration = .seconds(10),
        connectTimeout: Duration = .seconds(10)
    ) {
        self.quic = quic
        self.maxSessions = maxSessions
        self.headers = headers
        self.http3Settings = http3Settings
        self.connectionReadyTimeout = connectionReadyTimeout
        self.connectTimeout = connectTimeout
    }
}
