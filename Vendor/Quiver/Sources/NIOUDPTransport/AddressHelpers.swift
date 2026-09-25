/// Address Helpers
///
/// Utility extensions for working with socket addresses.

import Foundation
import NIOCore
import Synchronization

extension SocketAddress {

    // MARK: - Address Cache

    /// Cache for parsed socket addresses (thread-safe).
    ///
    /// Parsing addresses from strings is relatively expensive (~3,600 ns).
    /// This cache can provide 10-100x speedup for frequently used addresses.
    private static let addressCache = Mutex<[String: SocketAddress]>([:])

    /// Maximum cache size to prevent unbounded memory growth.
    private static let maxCacheSize = 1000

    /// Creates a SocketAddress from a cached or newly parsed "host:port" string.
    ///
    /// This method first checks the cache for a previously parsed address.
    /// If not found, it parses the address and stores it in the cache.
    ///
    /// - Parameter hostPort: Address string in "host:port" format
    /// - Returns: The parsed SocketAddress
    /// - Throws: `UDPError.invalidAddress` if the format is invalid
    public static func cached(hostPort: String) throws -> SocketAddress {
        // Fast path: check cache
        if let cached = addressCache.withLock({ $0[hostPort] }) {
            return cached
        }

        // Slow path: parse and cache
        let address = try SocketAddress(hostPort: hostPort)

        // Store in cache (with size limit)
        addressCache.withLock { cache in
            if cache.count < maxCacheSize {
                cache[hostPort] = address
            } else {
                // Cache full: clear old entries (simple strategy: clear all)
                // A more sophisticated LRU cache could be implemented if needed
                cache.removeAll(keepingCapacity: true)
                cache[hostPort] = address
            }
        }

        return address
    }

    /// Clears the address cache (useful for testing or memory management).
    public static func clearCache() {
        addressCache.withLock { $0.removeAll() }
    }

    // MARK: - Parsing

    /// Creates a SocketAddress from a "host:port" string.
    ///
    /// Supports both IPv4 and IPv6 addresses:
    /// - IPv4: "192.168.1.10:8080"
    /// - IPv6: "[::1]:8080" (brackets required for IPv6 with port)
    ///
    /// - Parameter hostPort: Address string in "host:port" format
    /// - Throws: `UDPError.invalidAddress` if the format is invalid
    ///
    /// - Note: For IPv6 addresses with a port, brackets are required to avoid
    ///   ambiguity (e.g., use `[::1]:8080` not `::1:8080`).
    public init(hostPort: String) throws {
        // Handle IPv6 with brackets: [::1]:8080
        if hostPort.hasPrefix("[") {
            guard let closeBracket = hostPort.firstIndex(of: "]") else {
                throw UDPError.invalidAddress(hostPort)
            }

            let hostStart = hostPort.index(after: hostPort.startIndex)
            let host = String(hostPort[hostStart..<closeBracket])

            let afterBracket = hostPort.index(after: closeBracket)
            guard afterBracket < hostPort.endIndex,
                  hostPort[afterBracket] == ":" else {
                throw UDPError.invalidAddress(hostPort)
            }

            let portStart = hostPort.index(after: afterBracket)
            guard let port = Int(hostPort[portStart...]),
                  (0...65535).contains(port) else {
                throw UDPError.invalidAddress(hostPort)
            }

            try self.init(ipAddress: host, port: port)
            return
        }

        // Handle IPv4: host:port (exactly 2 parts separated by colon)
        let parts = hostPort.split(separator: ":")

        // IPv4 case: exactly 2 parts where second part is a valid port
        if parts.count == 2,
           let port = Int(parts[1]),
           (0...65535).contains(port) {
            try self.init(ipAddress: String(parts[0]), port: port)
            return
        }

        // Reject ambiguous IPv6 without brackets
        // For IPv6 with port, require bracket notation: [host]:port
        throw UDPError.invalidAddress(hostPort)
    }

    /// Returns the address as "host:port" string.
    ///
    /// - Returns: Address string, or nil for Unix domain sockets
    public var hostPortString: String? {
        guard let host = self.ipAddress, let port = self.port else {
            return nil
        }

        switch self {
        case .v4:
            return "\(host):\(port)"
        case .v6:
            return "[\(host)]:\(port)"
        case .unixDomainSocket:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Returns just the host/IP part of the address.
    public var host: String? {
        self.ipAddress
    }
}

extension Data {
    /// Creates Data from a ByteBuffer.
    ///
    /// - Parameter buffer: The ByteBuffer to read from
    @inlinable
    public init(buffer: ByteBuffer) {
        var buffer = buffer
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            self = Data(bytes)
        } else {
            self = Data()
        }
    }
}

extension ByteBuffer {
    /// Creates a ByteBuffer containing the given Data.
    ///
    /// - Parameters:
    ///   - data: The data to copy into the buffer
    ///   - allocator: The allocator to use
    /// - Returns: A new ByteBuffer containing the data
    @inlinable
    public static func from(_ data: Data, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }
}
