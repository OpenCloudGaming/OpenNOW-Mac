/// TLS 1.3 Server Name Indication Extension (RFC 6066 Section 3)
///
/// ```
/// struct {
///     NameType name_type;
///     select (name_type) {
///         case host_name: HostName;
///     } name;
/// } ServerName;
///
/// struct {
///     ServerName server_name_list<1..2^16-1>
/// } ServerNameList;
/// ```

import Foundation

// MARK: - Server Name Extension

/// Server Name Indication (SNI) extension
public struct ServerNameExtension: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .serverName }

    /// Name type for DNS hostname
    private static let hostNameType: UInt8 = 0

    /// The server hostname
    public let hostName: String?

    public init(hostName: String?) {
        self.hostName = hostName
    }

    public func encode() -> Data {
        guard let hostName = hostName else {
            // Empty extension for ServerHello acknowledgment
            return Data()
        }

        let hostNameData = Data(hostName.utf8)

        var serverNameData = Data(capacity: 3 + hostNameData.count)
        // name_type (1 byte)
        serverNameData.append(Self.hostNameType)
        // HostName length (2 bytes)
        serverNameData.append(UInt8((hostNameData.count >> 8) & 0xFF))
        serverNameData.append(UInt8(hostNameData.count & 0xFF))
        // HostName
        serverNameData.append(hostNameData)

        var writer = TLSWriter(capacity: 2 + serverNameData.count)
        writer.writeVector16(serverNameData)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> ServerNameExtension {
        // Empty data means ServerHello acknowledgment
        if data.isEmpty {
            return ServerNameExtension(hostName: nil)
        }

        var reader = TLSReader(data: data)
        let serverNameListData = try reader.readVector16()

        if serverNameListData.isEmpty {
            return ServerNameExtension(hostName: nil)
        }

        var listReader = TLSReader(data: serverNameListData)
        let nameType = try listReader.readUInt8()

        guard nameType == Self.hostNameType else {
            throw TLSDecodeError.invalidFormat("Unknown name type: \(nameType)")
        }

        let hostNameData = try listReader.readVector16()
        let hostName = String(data: hostNameData, encoding: .utf8)

        return ServerNameExtension(hostName: hostName)
    }
}
