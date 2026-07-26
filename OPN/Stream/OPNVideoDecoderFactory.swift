import Foundation
import WebRTC

/// Video decoder factory that advertises H265 (HEVC) with explicit, decodable receiver parameters.
///
/// `RTCDefaultVideoDecoderFactory` lists H265 with EMPTY parameters. libwebrtc therefore cannot match
/// GeForce NOW's H265 offer (profile-id=1/2, level-id=153, tier-flag=1) and DROPS H265 from the SDP
/// answer entirely — the answer then only carries AV1 + H264, so every session falls back to **AV1**
/// (no hardware decode before Apple M3 → black screen / poor software decode) or low-level H264.
///
/// Advertising H265 Main (profile-id 1) and Main10 (profile-id 2) at high tier and level-id 186
/// (HEVC L6.2, which Apple Silicon VideoToolbox decodes up to 8K) lets H265 negotiate into the answer
/// and keeps full-resolution HEVC streaming (e.g. true 5120x2160). Decoding is delegated to the
/// default factory's RTCVideoDecoderH265, which matches on codec name and ignores these fmtp params.
final class OPNVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        base.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var result: [RTCVideoCodecInfo] = []
        var h265Name: String?
        for codec in base.supportedCodecs() {
            let name = codec.name.uppercased()
            if name == "H265" || name == "HEVC" {
                // Preserve the framework's exact spelling, then drop the empty-parameter entry.
                h265Name = codec.name
                continue
            }
            result.append(codec)
        }
        // Only advertise H265 if the framework actually ships an H265 decoder for it.
        guard let name = h265Name else { return result }
        result.append(RTCVideoCodecInfo(name: name, parameters: ["profile-id": "1", "tier-flag": "1", "level-id": "186"]))
        result.append(RTCVideoCodecInfo(name: name, parameters: ["profile-id": "2", "tier-flag": "1", "level-id": "186"]))
        return result
    }
}
