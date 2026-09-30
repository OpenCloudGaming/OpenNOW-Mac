import Foundation
@testable import OpenNOW

/// Whether this macOS can decode multistream Opus at all.
///
/// macOS only accepts a family 1 `OpusHead` from macOS 27: on 15–26 the six-channel `AudioConverter`
/// cannot be built, so a test that decodes 5.1 reports a skip there rather than failing the suite.
/// The app does not negotiate surround on such a macOS either — `NvstOpusMultistreamLayout.negotiated`
/// probes the same thing — so a skipped decode here and a stereo session there are the same fact.
enum OpusSurroundTestGate {
    static let fiveOne = NvstOpusMultistreamLayout(surroundParams: "64204123500")
    static let isUnavailable = !NvstOpusDecoder.canDecode(layout: fiveOne ?? .stereo)
    static let skipReason = "This macOS cannot build a multistream Opus decoder; the app negotiates stereo here."
}
