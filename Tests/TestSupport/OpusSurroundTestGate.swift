import Foundation
@testable import OpenNOW

/// Whether this macOS can decode multistream Opus at all: it only accepts a family 1 `OpusHead` from
/// macOS 27, and the app negotiates stereo where it cannot, so a skip here matches the app's behaviour.
enum OpusSurroundTestGate {
    static let fiveOne = NvstOpusMultistreamLayout(surroundParams: "64204123500")
    static let isUnavailable = !NvstOpusDecoder.isDecodable(layout: fiveOne ?? .stereo)
    static let skipReason = "This macOS cannot build a multistream Opus decoder; the app negotiates stereo here."
}
