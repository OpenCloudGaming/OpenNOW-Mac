import Foundation
import WebRTC

@objc(OPNWebRTCCodecSupport)
final class OPNWebRTCCodecSupport: NSObject {
    @objc(receiverCapabilitiesSummary)
    static func receiverCapabilitiesSummary() -> String {
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        return receiverCapabilitiesSummary(factory: factory)
    }

    @objc(receiverCapabilitiesSummaryWithFactory:)
    static func receiverCapabilitiesSummary(factory: RTCPeerConnectionFactory?) -> String {
        guard let factory else { return "factory=unavailable" }
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        let codecs = capabilities.codecs.map { codec in
            let parameters = codec.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
            return parameters.isEmpty ? "\(codec.name)/\(codec.mimeType)" : "\(codec.name)/\(codec.mimeType)(\(parameters))"
        }
        return codecs.isEmpty ? "none" : codecs.joined(separator: ", ")
    }

    @objc(compatibleCodecForRequestedCodec:)
    static func compatibleCodec(requestedCodec: String) -> String {
        let requested = normalizedCodec(requestedCodec)
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        let supportedCodecs = supportedVideoCodecs(factory: factory)
        if supportedCodecs.contains(requested) { return requested }
        if supportedCodecs.contains("H264") { return "H264" }
        return requested.isEmpty ? "H264" : requested
    }

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

        WebRTCMediaTelemetry.capture("webrtc.native.codec.unsupported", level: .warning, message: "Requested receiver codec is unavailable.", attributes: ["codec": normalizedCodec, "available": codecNames.joined(separator: ",")])
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
                WebRTCMediaTelemetry.capture("webrtc.native.codec.preference", level: .debug, message: "Applied video codec preference.", attributes: ["codec": normalizedCodec, "mid": transceiver.mid, "count": String(preferredCodecs.count)])
            } catch {
                WebRTCMediaTelemetry.capture("webrtc.native.codec.preference.error", level: .warning, message: "Failed to apply video codec preference.", attributes: ["codec": normalizedCodec, "mid": transceiver.mid, "error": error.localizedDescription])
            }
        }
        return applied
    }

    @objc(resetVideoCodecPreferencesWithPeerConnection:)
    static func resetVideoCodecPreferences(peerConnection: RTCPeerConnection?) -> Bool {
        guard let peerConnection else { return false }
        var reset = false
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .video && !transceiver.isStopped {
            do {
                try transceiver.setCodecPreferences([], error: ())
                reset = true
                WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_reset", level: .debug, message: "Reset video codec preferences.", attributes: ["mid": transceiver.mid])
            } catch {
                WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_reset.error", level: .warning, message: "Failed to reset video codec preferences.", attributes: ["mid": transceiver.mid, "error": error.localizedDescription])
            }
        }
        return reset
    }

    private static func supportedVideoCodecs(factory: RTCPeerConnectionFactory) -> Set<String> {
        let capabilities = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
        var result = Set<String>()
        for codec in capabilities.codecs {
            if codecCapability(codec, matches: "H264") { result.insert("H264") }
            if codecCapability(codec, matches: "H265") { result.insert("H265") }
            if codecCapability(codec, matches: "AV1") { result.insert("AV1") }
        }
        return result
    }

    private static func normalizedCodec(_ codec: String) -> String {
        let upper = codec.uppercased()
        if upper == "HEVC" { return "H265" }
        if ["H264", "H265", "AV1"].contains(upper) { return upper }
        return ""
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
