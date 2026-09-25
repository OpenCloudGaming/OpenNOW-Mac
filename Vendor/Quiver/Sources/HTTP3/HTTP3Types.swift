/// HTTP/3 Request/Response Types (RFC 9114)
///
/// Core types for representing HTTP/3 requests, responses, and
/// request handling contexts.
///
/// ## Pseudo-Headers (RFC 9114 Section 4.3)
///
/// HTTP/3 requests MUST include these pseudo-headers:
/// - `:method` — HTTP method (GET, POST, etc.)
/// - `:scheme` — URI scheme (https)
/// - `:authority` — Host + optional port
/// - `:path` — Request path
///
/// Extended CONNECT requests (RFC 9220) additionally include:
/// - `:protocol` — The protocol to use over the tunnel (e.g., "webtransport")
///
/// Regular CONNECT requests (RFC 9114 §4.4) omit `:scheme` and `:path`.
/// Extended CONNECT requests MUST include all five pseudo-headers:
/// `:method`, `:protocol`, `:scheme`, `:authority`, `:path`.
///
/// HTTP/3 responses MUST include:
/// - `:status` — HTTP status code as string ("200", "404", etc.)
///
/// Pseudo-headers MUST appear before regular headers and
/// MUST NOT appear in trailers (RFC 9114 Section 4.1.2).

import Foundation

// MARK: - Trailer Validation

/// Validates that a decoded trailer field section contains no pseudo-headers.
///
/// Per RFC 9114 Section 4.1.2, trailers MUST NOT contain pseudo-header
/// fields. Any header whose name starts with `:` is a pseudo-header.
///
/// - Parameter fields: The decoded (name, value) pairs from a trailing HEADERS frame.
/// - Returns: The validated fields (unchanged).
/// - Throws: `HTTP3TypeError.pseudoHeaderInTrailers` if a pseudo-header is found.
public func validateTrailers(_ fields: [(String, String)]) throws -> [(String, String)] {
    for (name, _) in fields {
        if name.hasPrefix(":") {
            throw HTTP3TypeError.pseudoHeaderInTrailers(name)
        }
    }
    return fields
}

// MARK: - HTTP Method

/// HTTP request methods (RFC 9110 Section 9)
///
/// Represents the standard HTTP methods used in HTTP/3 requests.
/// The raw value matches the method token sent on the wire.
public enum HTTPMethod: String, Sendable, Hashable, CaseIterable {
    /// GET method — retrieve a representation of a resource
    case get = "GET"

    /// POST method — submit data to a resource
    case post = "POST"

    /// PUT method — replace a resource
    case put = "PUT"

    /// DELETE method — remove a resource
    case delete = "DELETE"

    /// HEAD method — same as GET but without a response body
    case head = "HEAD"

    /// OPTIONS method — describe communication options
    case options = "OPTIONS"

    /// PATCH method — partially modify a resource
    case patch = "PATCH"

    /// CONNECT method — establish a tunnel
    case connect = "CONNECT"

    /// TRACE method — perform a message loop-back test
    case trace = "TRACE"
}

extension HTTPMethod: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

// MARK: - HTTP/3 Request

/// An HTTP/3 request (RFC 9114 Section 4)
///
/// Represents an outgoing or incoming HTTP/3 request with
/// pseudo-headers, regular headers, and an optional body.
///
/// ## Usage
///
/// ```swift
/// // Simple GET request
/// let request = HTTP3Request(method: .get, url: "https://example.com/api/data")
///
/// // POST request with body
/// let request = HTTP3Request(
///     method: .post,
///     url: "https://example.com/api/submit",
///     headers: [("content-type", "application/json")],
///     body: Data("{\"key\": \"value\"}".utf8)
/// )
/// ```
public struct HTTP3Request: Sendable, Hashable {
    /// The HTTP method
    public var method: HTTPMethod

    /// The URI scheme (e.g., "https")
    public var scheme: String

    /// The authority (host and optional port, e.g., "example.com:443")
    public var authority: String

    /// The request path (e.g., "/index.html")
    public var path: String

    /// The protocol for Extended CONNECT requests (RFC 9220).
    ///
    /// Corresponds to the `:protocol` pseudo-header. When non-nil and
    /// method is `.connect`, this indicates an Extended CONNECT request.
    ///
    /// For WebTransport, this value is `"webtransport"`.
    ///
    /// Per RFC 9220 §4:
    /// - `:protocol` MUST only be used with `:method = CONNECT`
    /// - When `:protocol` is present, `:scheme`, `:path`, and `:authority`
    ///   MUST also be present (unlike regular CONNECT which omits scheme/path)
    ///
    /// - Default: `nil` (regular request or regular CONNECT)
    public var connectProtocol: String?

    /// Regular (non-pseudo) header fields as (name, value) pairs.
    /// Names should be lowercase per HTTP/3 convention.
    public var headers: [(String, String)]

    /// Optional request body data
    public var body: Data?

    /// Optional trailing header fields (trailers).
    ///
    /// Per RFC 9114 Section 4.1, an HTTP message may end with a
    /// second HEADERS frame after all DATA frames. Trailers MUST NOT
    /// contain pseudo-header fields (names starting with `:`).
    ///
    /// Common uses include `grpc-status` / `grpc-message` in gRPC.
    public var trailers: [(String, String)]?

    /// Creates an HTTP/3 request from individual components.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (default: `.get`)
    ///   - scheme: The URI scheme (default: "https")
    ///   - authority: The host and optional port
    ///   - path: The request path (default: "/")
    ///   - connectProtocol: The `:protocol` value for Extended CONNECT (default: nil)
    ///   - headers: Regular header fields (default: empty)
    ///   - body: Optional request body (default: nil)
    ///   - trailers: Optional trailing header fields (default: nil)
    public init(
        method: HTTPMethod = .get,
        scheme: String = "https",
        authority: String,
        path: String = "/",
        connectProtocol: String? = nil,
        headers: [(String, String)] = [],
        body: Data? = nil,
        trailers: [(String, String)]? = nil
    ) {
        self.method = method
        self.scheme = scheme
        self.authority = authority
        self.path = path
        self.connectProtocol = connectProtocol
        self.headers = headers
        self.body = body
        self.trailers = trailers
    }

    /// Creates an HTTP/3 request from a URL string.
    ///
    /// Parses the URL to extract scheme, authority, and path.
    /// Supports URLs of the form `https://host:port/path`.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (default: `.get`)
    ///   - url: The full URL string
    ///   - connectProtocol: The `:protocol` value for Extended CONNECT (default: nil)
    ///   - headers: Regular header fields (default: empty)
    ///   - body: Optional request body (default: nil)
    public init(
        method: HTTPMethod = .get,
        url: String,
        connectProtocol: String? = nil,
        headers: [(String, String)] = [],
        body: Data? = nil
    ) {
        self.method = method
        self.connectProtocol = connectProtocol
        self.headers = headers
        self.body = body

        // Parse the URL
        // Expected format: scheme://authority/path
        if let schemeEnd = url.range(of: "://") {
            self.scheme = String(url[url.startIndex..<schemeEnd.lowerBound])
            let afterScheme = url[schemeEnd.upperBound...]

            if let pathStart = afterScheme.firstIndex(of: "/") {
                self.authority = String(afterScheme[afterScheme.startIndex..<pathStart])
                self.path = String(afterScheme[pathStart...])
            } else {
                self.authority = String(afterScheme)
                self.path = "/"
            }
        } else {
            // No scheme — treat whole string as authority
            self.scheme = "https"
            self.authority = url
            self.path = "/"
        }
    }

    // MARK: - Pseudo-Header Conversion

    /// Converts the request to a full header list including pseudo-headers.
    ///
    /// Pseudo-headers are placed before regular headers as required
    /// by RFC 9114 Section 4.3.
    ///
    /// The pseudo-header set depends on the request type:
    /// - **Regular request**: `:method`, `:scheme`, `:authority`, `:path`
    /// - **Regular CONNECT** (RFC 9114 §4.4): `:method`, `:authority`
    /// - **Extended CONNECT** (RFC 9220 §4): `:method`, `:protocol`, `:scheme`, `:authority`, `:path`
    ///
    /// - Returns: An array of (name, value) tuples suitable for QPACK encoding
    public func toHeaderList() -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []

        if method == .connect && connectProtocol == nil {
            // Regular CONNECT (RFC 9114 §4.4):
            // MUST include only :method and :authority
            // MUST NOT include :scheme or :path
            result.reserveCapacity(2 + headers.count)
            result.append((":method", method.rawValue))
            result.append((":authority", authority))
        } else if method == .connect, let proto = connectProtocol {
            // Extended CONNECT (RFC 9220 §4):
            // MUST include :method, :protocol, :scheme, :authority, :path
            result.reserveCapacity(5 + headers.count)
            result.append((":method", method.rawValue))
            result.append((":protocol", proto))
            result.append((":scheme", scheme))
            result.append((":authority", authority))
            result.append((":path", path))
        } else {
            // Regular request: :method, :scheme, :authority, :path
            result.reserveCapacity(4 + headers.count)
            result.append((":method", method.rawValue))
            result.append((":scheme", scheme))
            result.append((":authority", authority))
            result.append((":path", path))
        }

        // Regular headers
        for header in headers {
            result.append(header)
        }

        return result
    }

    /// Creates an HTTP/3 request from a decoded header list.
    ///
    /// Extracts pseudo-headers (`:method`, `:scheme`, `:authority`, `:path`,
    /// and optionally `:protocol` for Extended CONNECT) and separates them
    /// from regular headers.
    ///
    /// ## Pseudo-header requirements by request type:
    ///
    /// - **Regular request**: `:method`, `:scheme`, `:authority`, `:path` required
    /// - **Regular CONNECT** (RFC 9114 §4.4): `:method`, `:authority` required;
    ///   `:scheme` and `:path` MUST NOT be present
    /// - **Extended CONNECT** (RFC 9220 §4): `:method`, `:protocol`, `:scheme`,
    ///   `:authority`, `:path` all required
    ///
    /// - Parameter headers: The decoded header list from QPACK
    /// - Returns: The constructed request
    /// - Throws: `HTTP3TypeError` if required pseudo-headers are missing or invalid
    public static func fromHeaderList(_ headers: [(name: String, value: String)]) throws -> HTTP3Request {
        var method: HTTPMethod?
        var scheme: String?
        var authority: String?
        var path: String?
        var connectProtocol: String?
        var regularHeaders: [(String, String)] = []

        for (name, value) in headers {
            switch name {
            case ":method":
                guard let m = HTTPMethod(rawValue: value) else {
                    throw HTTP3TypeError.invalidPseudoHeaderValue(name: ":method", value: value)
                }
                guard method == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":method")
                }
                method = m
            case ":scheme":
                guard scheme == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":scheme")
                }
                scheme = value
            case ":authority":
                guard authority == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":authority")
                }
                authority = value
            case ":path":
                guard path == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":path")
                }
                path = value
            case ":protocol":
                guard connectProtocol == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":protocol")
                }
                connectProtocol = value
            default:
                // Pseudo-headers after regular headers is a malformed request
                if name.hasPrefix(":") {
                    throw HTTP3TypeError.unknownPseudoHeader(name)
                }
                regularHeaders.append((name, value))
            }
        }

        guard let resolvedMethod = method else {
            throw HTTP3TypeError.missingPseudoHeader(":method")
        }

        // Validate :protocol usage (RFC 9220 §4)
        if let proto = connectProtocol {
            // :protocol MUST only appear with :method = CONNECT
            guard resolvedMethod == .connect else {
                throw HTTP3TypeError.protocolWithNonConnect(proto)
            }

            // Extended CONNECT: all pseudo-headers required
            guard let resolvedAuthority = authority else {
                throw HTTP3TypeError.missingPseudoHeader(":authority")
            }
            guard let resolvedScheme = scheme else {
                throw HTTP3TypeError.missingPseudoHeader(":scheme")
            }
            guard let resolvedPath = path else {
                throw HTTP3TypeError.missingPseudoHeader(":path")
            }

            return HTTP3Request(
                method: resolvedMethod,
                scheme: resolvedScheme,
                authority: resolvedAuthority,
                path: resolvedPath,
                connectProtocol: proto,
                headers: regularHeaders
            )
        }

        // Regular CONNECT (RFC 9114 §4.4): only :method and :authority
        if resolvedMethod == .connect {
            guard let resolvedAuthority = authority else {
                throw HTTP3TypeError.missingPseudoHeader(":authority")
            }
            // Per RFC 9114 §4.4, :scheme and :path MUST NOT be present
            if scheme != nil {
                throw HTTP3TypeError.connectWithForbiddenPseudoHeader(":scheme")
            }
            if path != nil {
                throw HTTP3TypeError.connectWithForbiddenPseudoHeader(":path")
            }
            return HTTP3Request(
                method: resolvedMethod,
                scheme: "https",
                authority: resolvedAuthority,
                path: "/",
                headers: regularHeaders
            )
        }

        // Regular request: :method, :scheme, :authority (optional), :path required
        guard let resolvedScheme = scheme else {
            throw HTTP3TypeError.missingPseudoHeader(":scheme")
        }
        guard let resolvedPath = path else {
            throw HTTP3TypeError.missingPseudoHeader(":path")
        }

        return HTTP3Request(
            method: resolvedMethod,
            scheme: resolvedScheme,
            authority: authority ?? "",
            path: resolvedPath,
            headers: regularHeaders
        )
    }

    // MARK: - Hashable

    public static func == (lhs: HTTP3Request, rhs: HTTP3Request) -> Bool {
        lhs.method == rhs.method &&
        lhs.scheme == rhs.scheme &&
        lhs.authority == rhs.authority &&
        lhs.path == rhs.path &&
        lhs.connectProtocol == rhs.connectProtocol &&
        lhs.body == rhs.body &&
        lhs.headers.count == rhs.headers.count &&
        zip(lhs.headers, rhs.headers).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 } &&
        lhs.trailers?.count == rhs.trailers?.count &&
        (lhs.trailers == nil && rhs.trailers == nil ||
         lhs.trailers != nil && rhs.trailers != nil &&
         zip(lhs.trailers!, rhs.trailers!).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 })
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(method)
        hasher.combine(scheme)
        hasher.combine(authority)
        hasher.combine(path)
        hasher.combine(connectProtocol)
        hasher.combine(body)
        hasher.combine(headers.count)
        for (name, value) in headers {
            hasher.combine(name)
            hasher.combine(value)
        }
        if let trailers = trailers {
            hasher.combine(trailers.count)
            for (name, value) in trailers {
                hasher.combine(name)
                hasher.combine(value)
            }
        }
    }

    // MARK: - Extended CONNECT Helpers (RFC 9220)

    /// Whether this is an Extended CONNECT request (RFC 9220).
    ///
    /// An Extended CONNECT request has `:method = CONNECT` and a
    /// `:protocol` pseudo-header. This is used for protocols that
    /// are layered on top of HTTP, such as WebTransport.
    public var isExtendedConnect: Bool {
        method == .connect && connectProtocol != nil
    }

    /// Whether this is a WebTransport Extended CONNECT request.
    ///
    /// A WebTransport CONNECT request has `:method = CONNECT` and
    /// `:protocol = webtransport`. This is the entry point for
    /// establishing a WebTransport session over HTTP/3.
    ///
    /// - Reference: draft-ietf-webtrans-http3
    public var isWebTransportConnect: Bool {
        isExtendedConnect && connectProtocol == "webtransport"
    }

    /// Whether this is a regular (non-Extended) CONNECT request.
    ///
    /// A regular CONNECT request has `:method = CONNECT` without
    /// a `:protocol` pseudo-header (RFC 9114 §4.4).
    public var isRegularConnect: Bool {
        method == .connect && connectProtocol == nil
    }

    /// Creates a WebTransport Extended CONNECT request.
    ///
    /// Convenience factory that constructs a properly-formed
    /// Extended CONNECT request for WebTransport.
    ///
    /// - Parameters:
    ///   - scheme: URI scheme (default: "https")
    ///   - authority: The target authority (host:port)
    ///   - path: The WebTransport session path (default: "/")
    ///   - headers: Additional headers (default: empty)
    /// - Returns: An HTTP3Request configured for WebTransport CONNECT
    public static func webTransportConnect(
        scheme: String = "https",
        authority: String,
        path: String = "/",
        headers: [(String, String)] = []
    ) -> HTTP3Request {
        HTTP3Request(
            method: .connect,
            scheme: scheme,
            authority: authority,
            path: path,
            connectProtocol: "webtransport",
            headers: headers
        )
    }
}

// MARK: - CustomStringConvertible

extension HTTP3Request: CustomStringConvertible {
    public var description: String {
        if let proto = connectProtocol {
            return "\(method) \(scheme)://\(authority)\(path) [protocol=\(proto)]"
        }
        return "\(method) \(scheme)://\(authority)\(path)"
    }
}

// MARK: - HTTP/3 Response

/// An HTTP/3 response (RFC 9114 Section 4)
///
/// Represents an outgoing or incoming HTTP/3 response with
/// a status code, headers, and body data.
///
/// ## Usage
///
/// ```swift
/// let response = HTTP3Response(
///     status: 200,
///     headers: [("content-type", "text/plain")],
///     body: Data("Hello, World!".utf8)
/// )
/// ```
public struct HTTP3Response:  ~Copyable, Sendable {
    /// The HTTP status code (e.g., 200, 404, 500)
    public var status: Int

    /// Response header fields as (name, value) pairs.
    /// Names should be lowercase per HTTP/3 convention.
    public var headers: [(String, String)]
    /// Body stored directly. ~Copyable propagates to HTTP3Response.
    private let _body: HTTP3Body
    /// Optional pre-buffered data for server send paths that need
    /// synchronous access (e.g. `sendResponseHeadersOnly`).
    internal var _bufferedData: Data?

    /// Optional trailing header fields (trailers).
    ///
    /// Per RFC 9114 Section 4.1, a response may end with a trailing
    /// HEADERS frame after all DATA frames. Trailers MUST NOT contain
    /// pseudo-header fields (names starting with `:`).
    public var trailers: [(String, String)]?

    /// The response body as a move-only `HTTP3Body`.
    ///
    /// Each access creates a new `HTTP3Body` wrapping the underlying
    /// `AsyncStream<Data>`. The stream is destructive — consume it
    /// exactly once via `.data()`, `.text()`, `.json()`, or `.stream()`.
    /// Consuming accessor -- takes ownership of self.
    /// Read status/headers BEFORE calling this.
    public consuming func body() -> HTTP3Body {
        return _body
    }

    /// Creates an HTTP/3 response backed by a live `AsyncStream<Data>`.
    ///
    /// Used internally when reading DATA frames from a QUIC stream.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code
    ///   - headers: Response header fields (default: empty)
    ///   - bodyStream: The async stream of body data chunks
    ///   - trailers: Optional trailing header fields (default: nil)
    internal init(
        status: Int,
        headers: [(String, String)] = [],
        bodyStream: AsyncStream<Data>,
        trailers: [(String, String)]? = nil
    ) {
        self.status = status
        self.headers = headers
        self._bufferedData = nil
        self._body = HTTP3Body(stream: bodyStream)
        self.trailers = trailers
    }

    /// Creates an HTTP/3 response with pre-buffered `Data` body.
    ///
    /// The data is also wrapped into an `AsyncStream<Data>` so that
    /// `body.data()` / `.text()` / `.json()` work uniformly.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code
    ///   - headers: Response header fields (default: empty)
    ///   - body: Response body data (default: empty)
    ///   - trailers: Optional trailing header fields (default: nil)
    public init(
        status: Int,
        headers: [(String, String)] = [],
        body: Data = Data(),
        trailers: [(String, String)]? = nil
    ) {
        self.status = status
        self.headers = headers
        self._bufferedData = body
        self._body = HTTP3Body(data: body)
        self.trailers = trailers
    }

    /// The human-readable status text for common status codes.
    ///
    /// Returns a standard reason phrase for the status code,
    /// or "Unknown" for unrecognized codes.
    public var statusText: String {
        switch status {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 103: return "Early Hints"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 425: return "Too Early"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Unknown"
        }
    }

    /// Whether the status code indicates success (2xx)
    public var isSuccess: Bool {
        (200..<300).contains(status)
    }

    /// Whether the status code indicates a redirect (3xx)
    public var isRedirect: Bool {
        (300..<400).contains(status)
    }

    /// Whether the status code indicates a client error (4xx)
    public var isClientError: Bool {
        (400..<500).contains(status)
    }

    /// Whether the status code indicates a server error (5xx)
    public var isServerError: Bool {
        (500..<600).contains(status)
    }

    /// Whether the status code indicates an informational response (1xx)
    public var isInformational: Bool {
        (100..<200).contains(status)
    }

    /// The pre-buffered body data, if available.
    ///
    /// Used internally by server send paths and Extended CONNECT to
    /// extract Data without consuming the body stream.
    /// Returns empty `Data()` if not backed by buffered data.
    internal var bufferedBodyData: Data {
        _bufferedData ?? Data()
    }

    // MARK: - Pseudo-Header Conversion

    /// Converts the response to a full header list including pseudo-headers.
    ///
    /// The `:status` pseudo-header is placed first, followed by
    /// regular headers.
    ///
    /// - Returns: An array of (name, value) tuples suitable for QPACK encoding
    public func toHeaderList() -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        result.reserveCapacity(1 + headers.count)

        // :status pseudo-header MUST come first
        result.append((":status", String(status)))

        // Regular headers
        for header in headers {
            result.append(header)
        }

        return result
    }

    /// Creates an HTTP/3 response from a decoded header list.
    ///
    /// Extracts the `:status` pseudo-header and separates it from
    /// regular headers.
    ///
    /// - Parameter headers: The decoded header list from QPACK
    /// - Returns: The constructed response (body is empty; fill in from DATA frames)
    /// - Throws: `HTTP3TypeError` if the `:status` pseudo-header is missing or invalid
    public static func fromHeaderList(_ headers: [(name: String, value: String)]) throws -> HTTP3Response {
        var status: Int?
        var regularHeaders: [(String, String)] = []

        for (name, value) in headers {
            switch name {
            case ":status":
                guard status == nil else {
                    throw HTTP3TypeError.duplicatePseudoHeader(":status")
                }
                guard let code = Int(value), (100...599).contains(code) else {
                    throw HTTP3TypeError.invalidPseudoHeaderValue(name: ":status", value: value)
                }
                status = code
            default:
                if name.hasPrefix(":") {
                    throw HTTP3TypeError.unknownPseudoHeader(name)
                }
                regularHeaders.append((name, value))
            }
        }

        guard let resolvedStatus = status else {
            throw HTTP3TypeError.missingPseudoHeader(":status")
        }

        return HTTP3Response(
            status: resolvedStatus,
            headers: regularHeaders
        )
    }
}

// MARK: - CustomStringConvertible

extension HTTP3Response {
    public var description: String {
        if let data = _bufferedData {
            return "\(status) \(statusText) (\(data.count) bytes)"
        }
        return "\(status) \(statusText) (stream)"
    }
}

// MARK: - HTTP/3 Response Head (headers-only, no body)

/// Lightweight, Copyable response carrying only status + headers.
///
/// Used exclusively on the Extended CONNECT handshake path where the
/// response is always headers-only (no DATA frames, no body).
/// Being `Copyable` and `Sendable`, it can live inside tuples —
/// unlike `HTTP3Response` which is `~Copyable`.
public struct HTTP3ResponseHead: Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let trailers: [(String, String)]?

    public init(
        status: Int,
        headers: [(String, String)] = [],
        trailers: [(String, String)]? = nil
    ) {
        self.status = status
        self.headers = headers
        self.trailers = trailers
    }

    public var statusText: String {
        // Delegate to a temporary HTTP3Response for the lookup
        HTTP3Response(status: status).statusText
    }

    public var isSuccess: Bool { (200..<300).contains(status) }

    public func toHeaderList() -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        result.reserveCapacity(1 + headers.count)
        result.append((":status", String(status)))
        for header in headers { result.append(header) }
        return result
    }

    public static func fromHeaderList(_ headers: [(name: String, value: String)]) throws -> HTTP3ResponseHead {
        var status: Int?
        var regularHeaders: [(String, String)] = []
        for (name, value) in headers {
            switch name {
            case ":status":
                guard status == nil else { throw HTTP3TypeError.duplicatePseudoHeader(":status") }
                guard let code = Int(value), (100...599).contains(code) else {
                    throw HTTP3TypeError.invalidPseudoHeaderValue(name: ":status", value: value)
                }
                status = code
            default:
                if name.hasPrefix(":") { throw HTTP3TypeError.unknownPseudoHeader(name) }
                regularHeaders.append((name, value))
            }
        }
        guard let s = status else { throw HTTP3TypeError.missingPseudoHeader(":status") }
        return HTTP3ResponseHead(status: s, headers: regularHeaders)
    }
}
// MARK: - HTTP/3 Request Context

/// Context for handling an incoming HTTP/3 request (server-side).
///
/// Wraps a received request along with the stream ID and provides
/// a mechanism to send back a response.
///
/// ## Usage
///
/// ```swift
/// for await context in connection.incomingRequests {
///     print("Received: \(context.request)")
///     let response = HTTP3Response(
///         status: 200,
///         headers: [("content-type", "text/plain")],
///         body: Data("Hello!".utf8)
///     )
///     try await context.respond(response)
/// }
/// ```
// MARK: - Streaming Body Support

/// Writes response body data in chunks over an HTTP/3 stream.
///
/// Each call to ``write(_:)`` encodes a DATA frame and sends it on the
/// underlying QUIC stream. This keeps memory flat regardless of total
/// response size.
///
/// ```swift
/// try await context.respond(status: 200, headers: [("content-type", "application/octet-stream")]) { writer in
///     while let chunk = fileHandle.readData(ofLength: 65536) {
///         if chunk.isEmpty { break }
///         try await writer.write(chunk)
///     }
/// }
/// ```
public struct HTTP3BodyWriter: Sendable {
    /// Internal closure that encodes a DATA frame and writes it to the QUIC stream.
    internal let _write: @Sendable (Data) async throws -> Void

    /// Writes a chunk of body data as an HTTP/3 DATA frame.
    ///
    /// - Parameter data: The chunk to send. Empty data is a no-op.
    /// - Throws: If the underlying QUIC stream write fails.
    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await _write(data)
    }
}

// MARK: - Request Context

public struct HTTP3RequestContext: Sendable {
    /// The received HTTP/3 request (headers only; body NOT pre-read).
    ///
    /// `request.body` is always `nil`. Use `body.data()`, `body.text()`,
    /// `body.json()`, or `body.stream()` to consume the request body.
    public let request: HTTP3Request

    /// The QUIC stream ID this request arrived on.
    public let streamID: UInt64

    /// Internal stream backing the request body.
    /// Copyable + Sendable — allows HTTP3RequestContext to flow through AsyncStream.
    internal let _bodyStream: AsyncStream<Data>

    /// The request body as a move-only `HTTP3Body`.
    ///
    /// Always present (empty body = zero-yield stream that finishes immediately).
    /// Consume with exactly one of:
    ///
    /// ```swift
    /// let data = try await context.body.data()            // full body as Data
    /// let text = try await context.body.text()            // full body as String
    /// let obj  = try await context.body.json(MyType.self) // JSON decode
    /// for await chunk in context.body.stream() {          // raw iteration
    ///     process(chunk)
    /// }
    /// ```
    ///
    /// The underlying stream is destructive — consume it exactly once.
    public var body: HTTP3Body {
        HTTP3Body(stream: _bodyStream)
    }

    /// Closure to send a buffered response (status + headers + Data body + FIN).
    internal let _respond: @Sendable (Int, [(String, String)], Data, [(String, String)]?) async throws -> Void

    /// Closure to send a streaming response (HEADERS, then chunked DATA via writer, then FIN).
    internal let _respondStreaming: @Sendable (
        Int, [(String, String)], [(String, String)]?, @Sendable (HTTP3BodyWriter) async throws -> Void
    ) async throws -> Void

    /// Creates a request context with body stream and response closures.
    ///
    /// - Parameters:
    ///   - request: The received request (headers only)
    ///   - streamID: The QUIC stream ID
    ///   - bodyStream: The request body as `AsyncStream<Data>`
    ///   - respond: Closure to send a buffered response
    ///   - respondStreaming: Closure to send a streaming response
    public init(
        request: HTTP3Request,
        streamID: UInt64,
        bodyStream: AsyncStream<Data>,
        respond: @escaping @Sendable (Int, [(String, String)], Data, [(String, String)]?) async throws -> Void,
        respondStreaming: @escaping @Sendable (
            Int, [(String, String)], [(String, String)]?, @Sendable (HTTP3BodyWriter) async throws -> Void
        ) async throws -> Void
    ) {
        self.request = request
        self.streamID = streamID
        self._bodyStream = bodyStream
        self._respond = respond
        self._respondStreaming = respondStreaming
    }

    /// Convenience initializer with empty body and no streaming support.
    ///
    /// The body stream finishes immediately (empty body). The streaming
    /// respond closure throws an error if called.
    public init(
        request: HTTP3Request,
        streamID: UInt64,
        respond: @escaping @Sendable (Int, [(String, String)], Data, [(String, String)]?) async throws -> Void
    ) {
        self.request = request
        self.streamID = streamID
        self._bodyStream = AsyncStream<Data> { $0.finish() }
        self._respond = respond
        self._respondStreaming = { _, _, _, _ in
            throw HTTP3Error(
                code: .internalError,
                reason: "Streaming respond not available (context created without streaming support)"
            )
        }
    }

    // MARK: - Response Sending

    /// Sends a buffered response with a `Data` body.
    ///
    /// Sends HEADERS frame + DATA frame (if body non-empty) + FIN.
    ///
    /// ```swift
    /// try await context.respond(status: 200, headers: [("content-type", "text/plain")], Data("OK".utf8))
    /// try await context.respond(status: 204)
    /// ```
    ///
    /// - Parameters:
    ///   - status: HTTP status code
    ///   - headers: Response headers (default: empty)
    ///   - body: Response body data (default: empty)
    ///   - trailers: Optional trailing headers (default: nil)
    /// - Throws: If sending the response fails
    public func respond(
        status: Int,
        headers: [(String, String)] = [],
        _ body: Data = Data(),
        trailers: [(String, String)]? = nil
    ) async throws {
        try await _respond(status, headers, body, trailers)
    }

    /// Sends a streaming response via a writer closure.
    ///
    /// Sends the HEADERS frame immediately, then invokes the writer
    /// closure. Each `writer.write()` call sends a DATA frame. When
    /// the closure returns, FIN is sent.
    ///
    /// Memory usage is flat regardless of total response size.
    ///
    /// ```swift
    /// try await context.respond(status: 200, headers: [("content-type", "application/octet-stream")]) { writer in
    ///     for chunk in fileChunks {
    ///         try await writer.write(chunk)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - status: HTTP status code
    ///   - headers: Response headers (default: empty)
    ///   - trailers: Optional trailing headers sent after body (default: nil)
    ///   - writer: Closure that writes body chunks via ``HTTP3BodyWriter``
    /// - Throws: If sending headers, body chunks, or FIN fails
    public func respond(
        status: Int,
        headers: [(String, String)] = [],
        trailers: [(String, String)]? = nil,
        _ writer: @escaping @Sendable (HTTP3BodyWriter) async throws -> Void
    ) async throws {
        try await _respondStreaming(status, headers, trailers, writer)
    }
}

// MARK: - Errors

/// Errors related to HTTP/3 type construction and validation
public enum HTTP3TypeError: Error, Sendable, CustomStringConvertible {
    /// A required pseudo-header is missing
    case missingPseudoHeader(String)

    /// A pseudo-header appeared more than once
    case duplicatePseudoHeader(String)

    /// A pseudo-header has an invalid value
    case invalidPseudoHeaderValue(name: String, value: String)

    /// An unknown pseudo-header was encountered
    case unknownPseudoHeader(String)

    /// Pseudo-headers appeared after regular headers
    case pseudoHeaderAfterRegularHeader(String)

    /// A pseudo-header appeared in a trailer section (RFC 9114 §4.1.2)
    case pseudoHeaderInTrailers(String)

    /// `:protocol` pseudo-header used with a non-CONNECT method (RFC 9220 §4)
    case protocolWithNonConnect(String)

    /// A regular CONNECT request included a forbidden pseudo-header (RFC 9114 §4.4)
    ///
    /// Regular CONNECT requests MUST NOT include `:scheme` or `:path`.
    /// Use Extended CONNECT (with `:protocol`) if you need these headers.
    case connectWithForbiddenPseudoHeader(String)

    public var description: String {
        switch self {
        case .missingPseudoHeader(let name):
            return "Missing required pseudo-header: \(name)"
        case .duplicatePseudoHeader(let name):
            return "Duplicate pseudo-header: \(name)"
        case .invalidPseudoHeaderValue(let name, let value):
            return "Invalid value for pseudo-header \(name): \(value)"
        case .unknownPseudoHeader(let name):
            return "Unknown pseudo-header: \(name)"
        case .pseudoHeaderAfterRegularHeader(let name):
            return "Pseudo-header \(name) appeared after regular headers"
        case .pseudoHeaderInTrailers(let name):
            return "Pseudo-header \(name) is not allowed in trailers (RFC 9114 §4.1.2)"
        case .protocolWithNonConnect(let proto):
            return ":protocol pseudo-header ('\(proto)') is only allowed with :method=CONNECT (RFC 9220 §4)"
        case .connectWithForbiddenPseudoHeader(let name):
            return "Regular CONNECT MUST NOT include \(name) (RFC 9114 §4.4). Use Extended CONNECT with :protocol instead."
        }
    }
}
