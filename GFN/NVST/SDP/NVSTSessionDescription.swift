import Foundation

public struct NVSTIceCredentials: Equatable, Sendable {
    public var usernameFragment: String
    public var password: String
    public var fingerprint: String

    public init(usernameFragment: String = "", password: String = "", fingerprint: String = "") {
        self.usernameFragment = usernameFragment
        self.password = password
        self.fingerprint = fingerprint
    }
}

public struct NVSTSessionDescriptionSettings: Equatable, Sendable {
    public var resolution: String
    public var fps: Int
    public var maxBitrateMbps: Int
    public var colorQuality: String
    public var codec: String
    public var prefilterMode: Int
    public var prefilterSharpness: Int
    public var prefilterDenoise: Int
    public var prefilterModel: Int

    public init(resolution: String = "1920x1080",
                fps: Int = 60,
                maxBitrateMbps: Int = 50,
                colorQuality: String = "8bit_420",
                codec: String = "H264",
                prefilterMode: Int = 0,
                prefilterSharpness: Int = 0,
                prefilterDenoise: Int = 0,
                prefilterModel: Int = 0) {
        self.resolution = resolution
        self.fps = fps
        self.maxBitrateMbps = maxBitrateMbps
        self.colorQuality = colorQuality
        self.codec = codec
        self.prefilterMode = prefilterMode
        self.prefilterSharpness = prefilterSharpness
        self.prefilterDenoise = prefilterDenoise
        self.prefilterModel = prefilterModel
    }

    public init(dictionary: [String: Any]) {
        self.init(
            resolution: nvstString(dictionary["resolution"], fallback: "1920x1080"),
            fps: nvstInt(dictionary["fps"], fallback: 60),
            maxBitrateMbps: nvstInt(dictionary["maxBitrateMbps"], fallback: 50),
            colorQuality: nvstString(dictionary["colorQuality"], fallback: "8bit_420"),
            codec: nvstString(dictionary["codec"], fallback: "H264"),
            prefilterMode: nvstInt(dictionary["prefilterMode"]),
            prefilterSharpness: nvstInt(dictionary["prefilterSharpness"]),
            prefilterDenoise: nvstInt(dictionary["prefilterDenoise"]),
            prefilterModel: nvstInt(dictionary["prefilterModel"])
        )
    }
}

public enum NVSTSessionDescriptionBuilder {
    public static func buildAnswerExtension(settings: [String: Any], credentials: NVSTIceCredentials) -> String {
        buildAnswerExtension(settings: NVSTSessionDescriptionSettings(dictionary: settings), credentials: credentials)
    }

    public static func buildAnswerExtension(settings: NVSTSessionDescriptionSettings, credentials: NVSTIceCredentials) -> String {
        let parts = settings.resolution.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 1920
        let height = parts.count > 1 ? parts[1] : 1080
        let fps = settings.fps
        let maxBitrateKbps = max(1000, settings.maxBitrateMbps * 1000)
        let minBitrateKbps = max(5000, maxBitrateKbps * 35 / 100)
        let initialBitrateKbps = max(minBitrateKbps, maxBitrateKbps * 70 / 100)
        let bitDepth = settings.colorQuality.hasPrefix("10bit") ? 10 : 8
        let codec = normalizedNVSTCodec(settings.codec)
        let prefilterMode = max(0, min(settings.prefilterMode, 2))
        let prefilterSharpness = max(0, min(settings.prefilterSharpness, 10))
        let prefilterDenoise = max(0, min(settings.prefilterDenoise, 10))
        let prefilterModel = max(0, settings.prefilterModel)
        let maxReferenceFrames = codec == "H265" ? 1 : 4
        let isAv1 = codec == "AV1"
        let isHighFps = fps >= 90
        let is120Fps = fps == 120
        let is240Fps = fps >= 240
        var lines = [
            "v=0",
            "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=general.icePassword:\(credentials.password)",
            "a=general.iceUserNameFragment:\(credentials.usernameFragment)",
            "a=general.dtlsFingerprint:\(credentials.fingerprint)",
            "m=video 0 RTP/AVP",
            "a=msid:fbc-video-0",
            "a=vqos.fec.rateDropWindow:10",
            "a=vqos.fec.minRequiredFecPackets:2",
            "a=vqos.fec.repairMinPercent:5",
            "a=vqos.fec.repairPercent:5",
            "a=vqos.fec.repairMaxPercent:35",
            "a=vqos.dynamicStreamingMode:0",
            "a=vqos.drc.enable:0",
            "a=vqos.dfc.enable:0",
            "a=vqos.dfc.adjustResAndFps:0",
            "a=video.dx9EnableNv12:1",
            "a=video.dx9EnableHdr:1",
            "a=vqos.qpg.enable:1",
            "a=vqos.resControl.qp.qpg.featureSetting:7",
            "a=bwe.useOwdCongestionControl:1",
            "a=video.enableRtpNack:1",
            "a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200",
            "a=vqos.drc.bitrateIirFilterFactor:18",
            "a=video.packetSize:1140",
            "a=packetPacing.minNumPacketsPerGroup:15",
        ]
        if isHighFps {
            lines.append(contentsOf: [
                "a=bwe.iirFilterFactor:8",
                "a=video.encoderFeatureSetting:47",
                "a=video.encoderPreset:6",
                "a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600",
                "a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:9",
                "a=video.fbcDynamicFpsGrabTimeoutMs:\(is120Fps ? 6 : 18)",
                "a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:\(is120Fps ? 6000 : 12000)",
            ])
        }
        if is240Fps {
            lines.append(contentsOf: [
                "a=video.enableNextCaptureMode:1",
                "a=vqos.maxStreamFpsEstimate:240",
                "a=video.videoSplitEncodeStripsPerFrame:3",
                "a=video.updateSplitEncodeStateDynamically:1",
            ])
        }
        lines.append(contentsOf: [
            "a=vqos.adjustStreamingFpsDuringOutOfFocus:1",
            "a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
            "a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1",
            "a=vqos.resControl.cpmRtc.featureMask:0",
            "a=vqos.resControl.cpmRtc.enable:0",
            "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
            "a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999",
            "a=packetPacing.numGroups:\(is120Fps ? 3 : 5)",
            "a=packetPacing.maxDelayUs:1000",
            "a=packetPacing.minNumPacketsFrame:10",
            "a=video.rtpNackQueueLength:1024",
            "a=video.rtpNackQueueMaxPackets:512",
            "a=video.rtpNackMaxPacketCount:25",
            "a=vqos.drc.qpMaxResThresholdAdj:4",
            "a=vqos.grc.qpMaxResThresholdAdj:4",
            "a=vqos.drc.iirFilterFactor:100",
        ])
        if isAv1 {
            lines.append(contentsOf: [
                "a=vqos.drc.minQpHeadroom:20",
                "a=vqos.drc.lowerQpThreshold:100",
                "a=vqos.drc.upperQpThreshold:200",
                "a=vqos.drc.minAdaptiveQpThreshold:180",
                "a=vqos.drc.qpCodecThresholdAdj:0",
                "a=vqos.drc.qpMaxResThresholdAdj:20",
                "a=vqos.dfc.minQpHeadroom:20",
                "a=vqos.dfc.qpLowerLimit:100",
                "a=vqos.dfc.qpMaxUpperLimit:200",
                "a=vqos.dfc.qpMinUpperLimit:180",
                "a=vqos.dfc.qpMaxResThresholdAdj:20",
                "a=vqos.dfc.qpCodecThresholdAdj:0",
                "a=vqos.grc.minQpHeadroom:20",
                "a=vqos.grc.lowerQpThreshold:100",
                "a=vqos.grc.upperQpThreshold:200",
                "a=vqos.grc.minAdaptiveQpThreshold:180",
                "a=vqos.grc.qpMaxResThresholdAdj:20",
                "a=vqos.grc.qpCodecThresholdAdj:0",
                "a=video.minQp:25",
                "a=video.enableAv1RcPrecisionFactor:1",
            ])
        }
        lines.append(contentsOf: [
            "a=video.clientViewportWd:\(width)",
            "a=video.clientViewportHt:\(height)",
            "a=video.maxFPS:\(fps)",
            "a=video.initialBitrateKbps:\(initialBitrateKbps)",
            "a=video.initialPeakBitrateKbps:\(maxBitrateKbps)",
            "a=vqos.bw.maximumBitrateKbps:\(maxBitrateKbps)",
            "a=vqos.bw.minimumBitrateKbps:\(minBitrateKbps)",
            "a=vqos.bw.peakBitrateKbps:\(maxBitrateKbps)",
            "a=vqos.bw.serverPeakBitrateKbps:\(maxBitrateKbps)",
            "a=vqos.bw.enableBandwidthEstimation:1",
            "a=vqos.bw.disableBitrateLimit:0",
            "a=vqos.grc.maximumBitrateKbps:\(maxBitrateKbps)",
            "a=vqos.grc.enable:0",
            "a=video.maxNumReferenceFrames:\(maxReferenceFrames)",
            "a=video.mapRtpTimestampsToFrames:1",
            "a=video.encoderCscMode:3",
            "a=video.dynamicRangeMode:0",
            "a=video.bitDepth:\(bitDepth)",
            "a=video.scalingFeature1:\(isAv1 ? 1 : 0)",
            "a=video.prefilterParams.prefilterMode:\(prefilterMode)",
            "a=video.prefilterParams.prefilterModel:\(prefilterModel)",
            "a=video.prefilterParams.sharpnessLevel:\(prefilterSharpness)",
            "a=video.prefilterParams.denoiseLevel:\(prefilterDenoise)",
            "m=audio 0 RTP/AVP",
            "a=msid:audio",
            "m=mic 0 RTP/AVP",
            "a=msid:mic",
            "a=rtpmap:0 PCMU/8000",
            "m=application 0 RTP/AVP",
            "a=msid:input_1",
            "a=ri.partialReliableThresholdMs:\(GeronimoInputChannel.partialReliableInputLifetimeMs)",
            "a=ri.hidDeviceMask:4294967295",
            "a=ri.enablePartiallyReliableTransferGamepad:15",
            "a=ri.enablePartiallyReliableTransferHid:4294967295",
            "",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    public static func iceCredentials(from sdp: String) -> NVSTIceCredentials {
        var credentials = NVSTIceCredentials()
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("a=ice-ufrag:") {
                credentials.usernameFragment = String(line.dropFirst("a=ice-ufrag:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.hasPrefix("a=ice-pwd:") {
                credentials.password = String(line.dropFirst("a=ice-pwd:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.hasPrefix("a=fingerprint:") {
                credentials.fingerprint = String(line.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return credentials
    }

    public static func iceUsernameFragment(from sdp: String) -> String {
        iceCredentials(from: sdp).usernameFragment
    }
}

private func normalizedNVSTCodec(_ codec: String) -> String {
    let value = codec.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if value == "H.265" || value == "HEVC" { return "H265" }
    if value == "H.264" || value == "AVC" { return "H264" }
    return value
}

private func nvstString(_ value: Any?, fallback: String = "") -> String {
    if let value = value as? String { return value.isEmpty ? fallback : value }
    if let value = value as? NSString {
        let string = value as String
        return string.isEmpty ? fallback : string
    }
    if let value = value as? NSNumber { return value.stringValue }
    return fallback
}

private func nvstInt(_ value: Any?, fallback: Int = 0) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) ?? fallback }
    return fallback
}
