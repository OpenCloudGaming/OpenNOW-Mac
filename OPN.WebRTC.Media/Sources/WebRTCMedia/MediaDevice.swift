import Foundation

public struct MediaDeviceID: Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public enum MediaDeviceKind: String, Codable, Equatable, Hashable, Sendable {
    case audioInput
    case audioOutput
    case videoInput
    case screenInput
}

public struct MediaDevice: Codable, Equatable, Hashable, Sendable {
    public let id: MediaDeviceID
    public let kind: MediaDeviceKind
    public let name: String
    public let isDefault: Bool
    public let metadata: [String: String]

    public init(id: MediaDeviceID,
                kind: MediaDeviceKind,
                name: String,
                isDefault: Bool = false,
                metadata: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isDefault = isDefault
        self.metadata = metadata
    }
}

public struct MediaCaptureConstraints: Codable, Equatable, Hashable, Sendable {
    public let dimensions: VideoDimensions?
    public let minimumFrameRate: Int?
    public let maximumFrameRate: Int?
    public let sampleRate: Int?
    public let channelCount: Int?
    public let metadata: [String: String]

    public init(dimensions: VideoDimensions? = nil,
                minimumFrameRate: Int? = nil,
                maximumFrameRate: Int? = nil,
                sampleRate: Int? = nil,
                channelCount: Int? = nil,
                metadata: [String: String] = [:]) {
        self.dimensions = dimensions
        self.minimumFrameRate = minimumFrameRate.map { max(0, $0) }
        self.maximumFrameRate = maximumFrameRate.map { max(0, $0) }
        self.sampleRate = sampleRate.map { max(0, $0) }
        self.channelCount = channelCount.map { max(0, $0) }
        self.metadata = metadata
    }
}

public protocol MediaDeviceProvider: Sendable {
    func availableDevices() async throws -> [MediaDevice]
    func frames(from deviceID: MediaDeviceID, constraints: MediaCaptureConstraints) async throws -> AsyncStream<MediaFrame>
}

public protocol MediaFrameReceiver: Sendable {
    func receive(_ frame: MediaFrame) async
}

public protocol MediaFrameTransmitter: Sendable {
    func transmit(_ frame: MediaFrame) async throws
}
