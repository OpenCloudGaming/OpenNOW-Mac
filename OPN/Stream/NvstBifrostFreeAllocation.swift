//  Reading the seat's allocation: the stream profile it implies, and where the session is running.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

extension NvstBifrostFreeTransport {
    // MARK: - Allocation plumbing

    struct StreamProfile: Equatable, Sendable {
        var resolution: String?
        var fps: Int?
        var codec: String?
        var bitrateKbps: Int?
        /// The user's ceiling specifically. `bitrateKbps` accepts either key and drives the initial
        /// and peak rates; this one only ever comes from `maxBitrateKbps`, because announcing a cap
        /// that was really an initial rate would clamp the stream to its starting point.
        var maximumBitrateKbps: Int?
    }

    /// Reads the negotiated profile out of the allocation's session JSON so ANNOUNCE advertises
    /// what the seat already agreed to.
    static func streamProfile(from allocation: NativeNVSTSessionAllocation) -> StreamProfile {
        var profile = StreamProfile()
        for json in [allocation.sessionInfoJSON, allocation.settingsJSON, allocation.rawSessionJSON] {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let negotiated = object["negotiatedStreamProfile"] as? [String: Any] ?? object
            if profile.resolution == nil, let resolution = negotiated["resolution"] as? String, !resolution.isEmpty {
                profile.resolution = resolution
            }
            // fps can live at the top level or inside `selectedVideoMode`/`selectedEncodeMode`,
            // and as a number or a string — the same places `NVSTCoreTransport` reads it. Missing it
            // is not cosmetic: the pacing feedback then defaults to 60 fps, and the seat's delay
            // controller holds the stream there even when 120 was negotiated.
            if profile.fps == nil {
                let candidates: [Any?] = [
                    negotiated["fps"], object["fps"],
                    (negotiated["selectedVideoMode"] as? [String: Any])?["fps"],
                    (object["selectedVideoMode"] as? [String: Any])?["fps"],
                    (negotiated["selectedEncodeMode"] as? [String: Any])?["fps"],
                    (object["selectedEncodeMode"] as? [String: Any])?["fps"],
                    negotiated["framesPerSecond"], object["framesPerSecond"],
                ]
                for candidate in candidates {
                    let value = (candidate as? NSNumber)?.intValue ?? (candidate as? String).flatMap(Int.init)
                    if let value, value > 0 { profile.fps = value; break }
                }
            }
            if profile.codec == nil, let codec = negotiated["codec"] as? String, !codec.isEmpty {
                profile.codec = codec
            }
            if profile.maximumBitrateKbps == nil,
               let cap = (negotiated["maxBitrateKbps"] as? NSNumber)?.intValue, cap > 0 {
                profile.maximumBitrateKbps = cap
            }
            if profile.bitrateKbps == nil {
                for key in ["maxBitrateKbps", "bitrateKbps"] {
                    guard let kbps = (negotiated[key] as? NSNumber)?.intValue, kbps > 0 else { continue }
                    profile.bitrateKbps = kbps
                    break
                }
            }
        }
        return profile
    }

    /// `host:port` or bare host → host.
    static func host(from signalingServer: String) -> String? {
        let trimmed = signalingServer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: ":").first.map(String.init)
    }

    static func mediaCodec(_ codec: NVSTVideoCodec) -> NativeNVSTVideoCodec {
        switch codec {
        case .h264: .h264
        case .hevc: .h265
        case .av1: .av1
        }
    }
}
