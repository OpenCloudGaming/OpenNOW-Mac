import Foundation
import WebRTC

@objc(OPNWebRTCCodecSupport)
final class OPNWebRTCCodecSupport: NSObject {
    @objc(supportsCodecWithFactory:normalizedCodec:)
    static func supportsCodec(factory: RTCPeerConnectionFactory?, normalizedCodec: String) -> Bool {
        guard let factory, isSupportedCodecPreference(normalizedCodec) else { return false }
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)

        var codecNames: [String] = []
        for codec in capabilities.codecs {
            let combined = codecDescription(codec)
            if combined.count > 1 { codecNames.append(combined) }
            if codecCapability(codec, matches: normalizedCodec) { return true }
        }

        NSLog("[LibWebRTC] Receiver codec capabilities do not include %@; available=%@", normalizedCodec, codecNames.joined(separator: ", "))
        return false
    }

    @objc(h265ReceiverSupportWithFactory:)
    static func h265ReceiverSupport(factory: RTCPeerConnectionFactory?) -> NSDictionary {
        var maxMainLevelId = 0
        var maxMain10LevelId = 0
        var supportsHighTier = false
        var hasH265 = false

        if let factory {
            let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
            for codec in capabilities.codecs where codecCapability(codec, matches: "H265") {
                hasH265 = true
                let parameters = codec.parameters
                if let tierFlag = parameters["tier-flag"], Int(tierFlag) == 1 {
                    supportsHighTier = true
                }
                let profileId = Int(parameters["profile-id"] ?? "") ?? 0
                let levelId = Int(parameters["level-id"] ?? "") ?? 0
                guard levelId > 0 else { continue }
                if profileId == 2 {
                    maxMain10LevelId = max(maxMain10LevelId, levelId)
                } else {
                    maxMainLevelId = max(maxMainLevelId, levelId)
                }
            }
        }

        return [
            "supported": hasH265,
            "maxMainLevelId": maxMainLevelId,
            "maxMain10LevelId": maxMain10LevelId,
            "supportsHighTier": supportsHighTier,
        ]
    }

    @objc(applyVideoCodecPreferenceWithFactory:peerConnection:normalizedCodec:)
    static func applyVideoCodecPreference(factory: RTCPeerConnectionFactory?, peerConnection: RTCPeerConnection?, normalizedCodec: String) -> Bool {
        guard let factory, let peerConnection, isSupportedCodecPreference(normalizedCodec) else { return false }
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)

        var preferredCodecs: [RTCRtpCodecCapability] = []
        for codec in capabilities.codecs where codecCapability(codec, matches: normalizedCodec) {
            preferredCodecs.append(codec)
        }
        guard !preferredCodecs.isEmpty else { return false }
        for codec in capabilities.codecs where codecCapabilityIsTransportSupport(codec) {
            preferredCodecs.append(codec)
        }

        var applied = false
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video && !transceiver.isStopped {
            do {
                try transceiver.setCodecPreferences(preferredCodecs, error: ())
                applied = true
                NSLog("[LibWebRTC] Applied %@ codec preference to video transceiver mid=%@ (%lu codecs)", normalizedCodec, transceiver.mid, UInt(preferredCodecs.count))
            } catch {
                NSLog("[LibWebRTC] Failed to apply %@ codec preference to video transceiver mid=%@: %@", normalizedCodec, transceiver.mid, error.localizedDescription)
            }
        }
        return applied
    }

    private static func isSupportedCodecPreference(_ codec: String) -> Bool {
        codec == "H264" || codec == "H265" || codec == "AV1"
    }

    private static func codecDescription(_ codec: RTCRtpCodecCapability) -> String {
        "\(codec.name) \(codec.mimeType)".uppercased()
    }

    private static func codecCapability(_ codec: RTCRtpCodecCapability, matches normalizedCodec: String) -> Bool {
        let combined = codecDescription(codec)
        switch normalizedCodec {
        case "H265": return combined.contains("H265") || combined.contains("HEVC")
        case "H264": return combined.contains("H264")
        case "AV1": return combined.contains("AV1")
        default: return false
        }
    }

    private static func codecCapabilityIsTransportSupport(_ codec: RTCRtpCodecCapability) -> Bool {
        let name = codec.name.uppercased()
        let mimeType = codec.mimeType.uppercased()
        return name == "RTX" || name == "RED" || name == "ULPFEC" || name == "FLEXFEC-03" ||
            mimeType.contains("/RTX") || mimeType.contains("/RED") || mimeType.contains("/ULPFEC") || mimeType.contains("/FLEXFEC-03")
    }
}
