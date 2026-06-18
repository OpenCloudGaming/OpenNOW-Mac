import Foundation

public struct MediaTrackID: Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

public struct MediaTimestamp: Codable, Comparable, Equatable, Hashable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: MediaTimestamp, rhs: MediaTimestamp) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

public enum MediaKind: String, Codable, Equatable, Hashable, Sendable {
    case audio
    case video
}

public enum VideoPixelFormat: Codable, Equatable, Hashable, Sendable {
    case i420
    case nv12
    case bgra
    case rgba
    case encoded(String)
}

public enum AudioSampleFormat: Codable, Equatable, Hashable, Sendable {
    case pcmInt16
    case pcmFloat32
    case opus
    case encoded(String)
}

public enum VideoRotation: Int, Codable, Equatable, Hashable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270
}

public struct VideoDimensions: Codable, Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }
}

public struct VideoFrame: Codable, Equatable, Sendable {
    public let trackID: MediaTrackID
    public let timestamp: MediaTimestamp
    public let durationNanoseconds: UInt64
    public let dimensions: VideoDimensions
    public let pixelFormat: VideoPixelFormat
    public let rotation: VideoRotation
    public let payload: Data
    public let metadata: [String: String]

    public init(trackID: MediaTrackID,
                timestamp: MediaTimestamp,
                durationNanoseconds: UInt64,
                dimensions: VideoDimensions,
                pixelFormat: VideoPixelFormat,
                rotation: VideoRotation = .degrees0,
                payload: Data,
                metadata: [String: String] = [:]) {
        self.trackID = trackID
        self.timestamp = timestamp
        self.durationNanoseconds = durationNanoseconds
        self.dimensions = dimensions
        self.pixelFormat = pixelFormat
        self.rotation = rotation
        self.payload = payload
        self.metadata = metadata
    }
}

public struct AudioFrame: Codable, Equatable, Sendable {
    public let trackID: MediaTrackID
    public let timestamp: MediaTimestamp
    public let durationNanoseconds: UInt64
    public let sampleRate: Int
    public let channelCount: Int
    public let sampleFormat: AudioSampleFormat
    public let payload: Data
    public let metadata: [String: String]

    public init(trackID: MediaTrackID,
                timestamp: MediaTimestamp,
                durationNanoseconds: UInt64,
                sampleRate: Int,
                channelCount: Int,
                sampleFormat: AudioSampleFormat,
                payload: Data,
                metadata: [String: String] = [:]) {
        self.trackID = trackID
        self.timestamp = timestamp
        self.durationNanoseconds = durationNanoseconds
        self.sampleRate = max(0, sampleRate)
        self.channelCount = max(0, channelCount)
        self.sampleFormat = sampleFormat
        self.payload = payload
        self.metadata = metadata
    }
}

public enum MediaFrame: Codable, Equatable, Sendable {
    case audio(AudioFrame)
    case video(VideoFrame)

    public var kind: MediaKind {
        switch self {
        case .audio:
            .audio
        case .video:
            .video
        }
    }

    public var trackID: MediaTrackID {
        switch self {
        case .audio(let frame):
            frame.trackID
        case .video(let frame):
            frame.trackID
        }
    }

    public var timestamp: MediaTimestamp {
        switch self {
        case .audio(let frame):
            frame.timestamp
        case .video(let frame):
            frame.timestamp
        }
    }
}
