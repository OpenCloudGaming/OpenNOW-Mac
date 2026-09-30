import CoreAudio
import Foundation

/// How the seat packs one audio frame into Opus streams: RFC 7845 channel mapping family 1 for
/// surround, a single coupled stream for stereo.
public struct NvstOpusMultistreamLayout: Equatable, Sendable {
    public let channels: Int
    public let streams: Int
    public let coupledStreams: Int
    public let mapping: [UInt8]

    public static let stereo = NvstOpusMultistreamLayout(channels: 2, streams: 1, coupledStreams: 1, mapping: [0, 1])

    public var isSurround: Bool { channels > 2 }

    public var summary: String {
        "\(channels)ch streams=\(streams) coupled=\(coupledStreams) mapping=\(mapping.map(String.init).joined(separator: ","))"
    }

    init(channels: Int, streams: Int, coupledStreams: Int, mapping: [UInt8]) {
        self.channels = channels
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.mapping = mapping
    }

    /// One entry of the DESCRIBE's `nv-audio-surround-opus-params`: channel count, stream count,
    /// coupled stream count, then eight one-digit mapping slots ("64204123500" is 5.1 in four streams).
    public init?(surroundParams entry: String) {
        guard entry.utf8.count == 11, entry.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else { return nil }
        let digits = entry.utf8.map { Int($0 - UInt8(ascii: "0")) }
        let channels = digits[0]
        let streams = digits[1]
        let coupled = digits[2]
        let mapping = digits.dropFirst(3).prefix(channels).map(UInt8.init)
        guard (1...8).contains(channels), streams > 0, coupled <= streams, mapping.count == channels,
              mapping.allSatisfy({ Int($0) < streams + coupled }) else { return nil }
        self.init(channels: channels, streams: streams, coupledStreams: coupled, mapping: mapping)
    }

    public static func offered(inDescribe body: String) -> [NvstOpusMultistreamLayout] {
        let prefix = "a=nv-audio-surround-opus-params:"
        let line = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
        guard let line else { return [] }
        return line.dropFirst(prefix.count)
            .split(separator: ";")
            .compactMap { NvstOpusMultistreamLayout(surroundParams: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The widest surround layout the seat offered within the request, or stereo: a count the seat
    /// did not describe cannot be decoded, and multistream Opus fed to a stereo decoder plays as a
    /// muffled smear rather than failing.
    public static func negotiated(requestedChannels: Int, offered: [NvstOpusMultistreamLayout]) -> NvstOpusMultistreamLayout {
        offered
            .filter { $0.isSurround && $0.channels <= requestedChannels
                && NvstCoreAudioFormat.supportedPlayoutChannelCount($0.channels) == $0.channels }
            .max { $0.channels < $1.channels } ?? .stereo
    }

    /// The order the decoder emits channels in: RFC 7845 section 5.1.1.2 for family 1.
    public var speakers: [AudioChannelLabel] {
        let left = kAudioChannelLabel_Left
        let right = kAudioChannelLabel_Right
        let center = kAudioChannelLabel_Center
        let lfe = kAudioChannelLabel_LFEScreen
        let leftSurround = kAudioChannelLabel_LeftSurround
        let rightSurround = kAudioChannelLabel_RightSurround
        return switch channels {
        case 1: [kAudioChannelLabel_Mono]
        case 3: [left, center, right]
        case 4: [left, right, leftSurround, rightSurround]
        case 5: [left, center, right, leftSurround, rightSurround]
        case 6: [left, center, right, leftSurround, rightSurround, lfe]
        case 7: [left, center, right, leftSurround, rightSurround, kAudioChannelLabel_CenterSurround, lfe]
        case 8: [left, center, right, leftSurround, rightSurround,
                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight, lfe]
        default: [left, right]
        }
    }
}
