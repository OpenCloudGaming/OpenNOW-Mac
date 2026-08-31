//
//  RemoteCoOpHTTPRequest.swift
//  OpenNOW
//
//  Just enough HTTP for the embedded Remote Co-Op server: parse a request head, serve a file from
//  the bundled guest page, or complete a WebSocket upgrade.
//
//  Deliberately not a general-purpose server. It answers GET for a fixed set of files and refuses
//  everything else, which is the whole surface a guest browser needs and the smallest one that can
//  be exposed on a machine that is also running a game.
//

import Foundation

struct OPNRemoteCoOpHTTPRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]

    /// Header lookup is case-insensitive: HTTP field names are, and browsers disagree in practice
    /// about the casing of `Sec-WebSocket-Key` and `Origin`.
    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var isWebSocketUpgrade: Bool {
        header("upgrade")?.lowercased() == "websocket" &&
            (header("connection")?.lowercased().contains("upgrade") ?? false) &&
            header("sec-websocket-key") != nil
    }

    /// The path with any query string removed, which is what maps onto a file.
    var normalizedPath: String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return withoutQuery.isEmpty ? "/" : withoutQuery
    }
}

enum OPNRemoteCoOpHTTPParser {
    /// The largest request head accepted. A browser's GET is well under a kilobyte; a client that
    /// keeps sending headers without a blank line is trying to make the host buffer indefinitely.
    static let maximumHeadBytes = 16 * 1024

    enum ParseError: Error, Equatable {
        case headTooLarge
        case malformed
    }

    /// Returns nil while the head is still incomplete. `buffer` keeps whatever follows the blank
    /// line, which for a WebSocket upgrade is the first frames a browser may have already pipelined.
    static func parseRequest(from buffer: inout Data) throws -> OPNRemoteCoOpHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else {
            guard buffer.count <= maximumHeadBytes else { throw ParseError.headTooLarge }
            return nil
        }
        let headData = buffer[buffer.startIndex..<range.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { throw ParseError.malformed }
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw ParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return OPNRemoteCoOpHTTPRequest(method: String(requestLine[0]).uppercased(), path: String(requestLine[1]), headers: headers)
    }

    static func response(status: Int, reason: String, contentType: String? = nil, body: Data = Data(), extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "content-length: \(body.count)\r\n"
        if let contentType { head += "content-type: \(contentType)\r\n" }
        // The guest page is served from the app while a session is live; a cached copy from a
        // previous run could speak a different protocol version than the host it is talking to.
        head += "cache-control: no-store\r\n"
        head += "connection: close\r\n"
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func webSocketAcceptResponse(key: String) -> Data {
        let head = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(OPNRemoteCoOpWebSocketCodec.acceptToken(forKey: key))",
            "",
            ""
        ].joined(separator: "\r\n")
        return Data(head.utf8)
    }
}

/// Resolves a request path to a file inside the bundled guest page.
struct OPNRemoteCoOpStaticFileStore {
    let documentRoot: URL

    static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "ico": "image/x-icon"
    ]

    init(documentRoot: URL) {
        self.documentRoot = documentRoot.standardizedFileURL
    }

    struct File {
        let data: Data
        let contentType: String
    }

    /// Returns nil for anything outside the document root or absent.
    ///
    /// The traversal check compares standardized paths rather than filtering `..` out of the
    /// request: percent-encoding, redundant separators and symlinks all produce a path that looks
    /// clean and resolves somewhere else, and this server runs on a machine holding the user's
    /// session tokens.
    func file(for path: String) -> File? {
        let requested = path == "/" ? "/index.html" : path
        guard let decoded = requested.removingPercentEncoding else { return nil }
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !relative.isEmpty else { return nil }

        let candidate = documentRoot.appendingPathComponent(relative).standardizedFileURL
        let rootPath = documentRoot.path.hasSuffix("/") ? documentRoot.path : documentRoot.path + "/"
        guard candidate.path == documentRoot.path || candidate.path.hasPrefix(rootPath) else { return nil }
        guard let data = try? Data(contentsOf: candidate) else { return nil }
        let contentType = Self.contentTypes[candidate.pathExtension.lowercased()] ?? "application/octet-stream"
        return File(data: data, contentType: contentType)
    }
}
