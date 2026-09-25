/// TLS 1.3 Application-Layer Protocol Negotiation Extension (RFC 7301)
///
/// ```
/// struct {
///     ProtocolName protocol_name_list<2..2^16-1>
/// } ProtocolNameList;
///
/// opaque ProtocolName<1..2^8-1>;
/// ```

import Foundation

// MARK: - ALPN Extension

/// Application-Layer Protocol Negotiation extension
public struct ALPNExtension: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .alpn }

    /// List of protocol names in preference order
    public let protocols: [String]

    public init(protocols: [String]) {
        self.protocols = protocols
    }

    /// ALPN for HTTP/3
    public static var h3: ALPNExtension {
        ALPNExtension(protocols: ["h3"])
    }

    public func encode() -> Data {
        var protocolListData = Data()
        for proto in protocols {
            let protoData = Data(proto.utf8)
            protocolListData.append(UInt8(protoData.count))
            protocolListData.append(protoData)
        }

        var writer = TLSWriter(capacity: 2 + protocolListData.count)
        writer.writeVector16(protocolListData)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> ALPNExtension {
        var reader = TLSReader(data: data)
        let protocolListData = try reader.readVector16()

        var protocols: [String] = []
        var listReader = TLSReader(data: protocolListData)
        while listReader.hasMore {
            let protoData = try listReader.readVector8()
            if let proto = String(data: protoData, encoding: .utf8) {
                protocols.append(proto)
            }
        }

        return ALPNExtension(protocols: protocols)
    }

    /// Check if a protocol is supported
    public func supports(_ protocol: String) -> Bool {
        protocols.contains(`protocol`)
    }

    /// Find the first mutually supported protocol
    public func negotiate(with other: ALPNExtension) -> String? {
        for proto in protocols {
            if other.supports(proto) {
                return proto
            }
        }
        return nil
    }

    /// Get the selected protocol (for ServerHello - first in list)
    public var selectedProtocol: String? {
        protocols.first
    }
}
