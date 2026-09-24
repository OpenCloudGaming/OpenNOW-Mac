import Foundation
import Testing
@testable import OpenNOW

/// Surround sound is one channel count threaded through four places that must agree: the
/// resolver, the session request, the SDP the decoder is built from, and the NVST announce.
@Suite struct SurroundAudioTests {
    private typealias Resolver = StreamSettingsResolver

    @Test func theChannelCountFollowsDeviceEntitlementAndMode() {
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 2, entitledChannels: 0) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 6, entitledChannels: 0) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 8, entitledChannels: 0) == 8)
        // No 4-channel format exists on the wire.
        #expect(Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: 4, entitledChannels: 0) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "stereo", deviceOutputChannels: 8, entitledChannels: 8) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "5.1", deviceOutputChannels: 8, entitledChannels: 0) == 6)
        // A stereo device can never take a surround decode: libwebrtc cannot fold it down.
        #expect(Resolver.audioChannelCount(surroundMode: "5.1", deviceOutputChannels: 2, entitledChannels: 8) == 2)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 6, entitledChannels: 0) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 8, entitledChannels: 6) == 6)
        #expect(Resolver.audioChannelCount(surroundMode: "7.1", deviceOutputChannels: 8, entitledChannels: 2) == 2)
    }

    @Test func thePreferredCountKeepsTheReadersPickApartFromTheClamp() {
        // An explicit pick is reported as picked however little the device can deliver: this is
        // what lets the HUD say "Stereo (7.1 asked)" instead of reporting the clamp as the request.
        #expect(Resolver.preferredAudioChannelCount(surroundMode: "7.1", deviceOutputChannels: 2) == 8)
        #expect(Resolver.preferredAudioChannelCount(surroundMode: "5.1", deviceOutputChannels: 2) == 6)
        #expect(Resolver.preferredAudioChannelCount(surroundMode: "stereo", deviceOutputChannels: 8) == 2)
        // Auto has no opinion, so it can never read as short-changed whatever the device offers.
        for channels in [2, 6, 8] {
            #expect(Resolver.preferredAudioChannelCount(surroundMode: "auto", deviceOutputChannels: channels)
                    == Resolver.audioChannelCount(surroundMode: "auto", deviceOutputChannels: channels, entitledChannels: 0))
        }
    }

    @Test func theHudNamesTheAskedLayoutOnlyWhenItDiffers() {
        #expect(snapshot(negotiated: 2, preferred: 8).audioFormatSummary == "Stereo (7.1 asked)")
        #expect(snapshot(negotiated: 6, preferred: 8).audioFormatSummary == "5.1 (7.1 asked)")
        #expect(snapshot(negotiated: 8, preferred: 8).audioFormatSummary == "7.1")
        #expect(snapshot(negotiated: 2, preferred: 2).audioFormatSummary == "Stereo")
    }

    private func snapshot(negotiated: Int, preferred: Int) -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(
            available: true,
            gameFramesPerSecond: 0, streamFramesPerSecond: 0,
            latencyMilliseconds: 0, jitterMilliseconds: 0,
            frameLoss: 0, totalFrameLoss: 0, packetLoss: 0, totalPacketLoss: 0,
            bitrateMegabitsPerSecond: 0, bandwidthUtilizationPercent: 0,
            resolution: "", codec: "", serverLocation: "",
            audioChannelCount: negotiated, requestedAudioChannelCount: preferred
        )
    }

    @Test func resolvedSettingsCarryTheChannelCountAndMode() {
        let resolved = Resolver.resolve(
            profile: StreamProfile(surroundMode: "5.1"),
            capabilities: StreamDeviceCapabilities(audioOutputChannelCount: 8)
        )
        #expect(resolved.audioChannelCount == 6)
        let dictionary = resolved.dictionary(gameLanguage: "en_US", accountLinked: true, selectedStore: "STEAM")
        #expect(dictionary["audioChannelCount"] as? Int == 6)
        #expect(dictionary["surroundMode"] as? String == "5.1")
        // The dictionary round-trips through the bridge without losing the mode.
        #expect(streamProfile(from: dictionary).surroundMode == "5.1")
    }

    @Test func theSessionRequestNamesTheAudioFormatTheWayTheOfficialClientDoes() {
        let manager = OPNSessionManager()
        #expect(manager.requestedAudioFormat([:]) == 1)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 2]) == 1)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 6]) == 2)
        #expect(manager.requestedAudioFormat(["audioChannelCount": 8]) == 3)
        #expect(manager.requestedAudioChannelCount(["audioChannelCount": 7]) == 6)
    }

    @Test func theAnnounceCarriesTheSurroundBlockOnlyAboveStereo() {
        let stereo = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions())
        #expect(!stereo.contains("x-nv-audio.surround.enable"))
        #expect(stereo.contains("a=x-nv-audio.surround.version:2"))
        let fiveOne = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(audioChannelCount: 6))
        #expect(fiveOne.contains("a=x-nv-audio.surround.enable:1"))
        #expect(fiveOne.contains("a=x-nv-audio.surround.numChannels:6"))
        #expect(fiveOne.contains("a=x-nv-audio.surround.channelMask:63"))
        let sevenOne = NvstRtspSdp.buildAnnounceSdp(NvstRtspSdp.AnnounceOptions(audioChannelCount: 8))
        #expect(sevenOne.contains("a=x-nv-audio.surround.numChannels:8"))
        #expect(sevenOne.contains("a=x-nv-audio.surround.channelMask:1599"))
    }

    @Test func theSeatsSurroundInfoParses() {
        var writer = NvstByteWriter(capacity: 24)
        writer.u32LE(6)
        writer.u32LE(4)
        writer.u32LE(2)
        writer.u32LE(0)
        for value in [0, 4, 1, 2, 3, 5] as [UInt8] { writer.u8(value) }
        let info = NvstAudioSurroundInfo.parse(NvstControlCommand(code: .audioSurroundInfo, payload: writer.data))
        #expect(info?.channels == 6)
        #expect(info?.streams == 4)
        #expect(info?.coupledStreams == 2)
        #expect(info?.usesMultiMappingMode == false)
        #expect(info?.channelMapping == [0, 4, 1, 2, 3, 5])
        #expect(NvstAudioSurroundInfo.parse(NvstControlCommand(code: .remoteInput, payload: writer.data)) == nil)
        #expect(NvstAudioSurroundInfo.parse(NvstControlCommand(code: .audioSurroundInfo, payload: Data([1, 2]))) == nil)
    }

    /// The HUD is the only place a listener can confirm what the seat actually sent, so it has to
    /// name the negotiated layout, and say what was asked for when the two differ.
    @Test func theHudNamesTheNegotiatedLayoutAndFlagsAShortfall() {
        func snapshot(negotiated: Int, requested: Int) -> NativeNVSTPerformanceSnapshot {
            NativeNVSTPerformanceSnapshot(
                available: true, gameFramesPerSecond: 0, streamFramesPerSecond: 0,
                latencyMilliseconds: 0, jitterMilliseconds: 0, frameLoss: 0, totalFrameLoss: 0,
                packetLoss: 0, totalPacketLoss: 0, bitrateMegabitsPerSecond: 0,
                bandwidthUtilizationPercent: 0, resolution: "", codec: "", serverLocation: "",
                audioChannelCount: negotiated, requestedAudioChannelCount: requested
            )
        }
        #expect(snapshot(negotiated: 6, requested: 6).audioFormatSummary == "5.1")
        #expect(snapshot(negotiated: 8, requested: 8).audioFormatSummary == "7.1")
        #expect(snapshot(negotiated: 2, requested: 2).audioFormatSummary == "Stereo")
        // A request the seat did not honour reads as what arrived, plus what was asked.
        #expect(snapshot(negotiated: 2, requested: 6).audioFormatSummary == "Stereo (5.1 asked)")
        #expect(snapshot(negotiated: 6, requested: 8).audioFormatSummary == "5.1 (7.1 asked)")
        // Nothing negotiated yet is not a claim about the layout.
        #expect(snapshot(negotiated: 0, requested: 6).audioFormatSummary == "-")
    }

    @Test func theSubscriptionFeatureMapsToAChannelCount() {
        let service = OPNGameService()
        #expect(service.entitledAudioChannelCount(features: nil) == 0)
        #expect(service.entitledAudioChannelCount(features: [["key": "HDR_ENABLED", "textValue": "true"]]) == 0)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "STEREO"]]) == 2)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "UP_TO_5_1_SURROUND_PCM"]]) == 6)
        #expect(service.entitledAudioChannelCount(features: [["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "UP_TO_7_1_SURROUND_PCM"]]) == 8)
    }

    @Test func theMembershipReadsItsFeaturesFromTheNestedShape() {
        let service = OPNGameService()
        let payload: NSDictionary = [
            "membershipTier": "ULTIMATE",
            "autoPaymentState": "ON",
            "features": ["features": [
                ["key": "HDR_ENABLED", "textValue": "true"],
                ["key": "SUPPORTED_AUDIO_FORMATS", "textValue": "UP_TO_7_1_SURROUND_PCM"],
                ["key": "IN_GAME_SETTINGS_PERSISTENCE_ENABLED", "textValue": "true"],
            ]],
        ]

        let info = service.parseSubscriptionInfo(payload)

        #expect(info.membershipTier == "ULTIMATE")
        #expect(info.entitledAudioChannelCount == 8)
        #expect(info.isInGameSettingsPersistenceEntitled)
    }

    @Test func theMembershipEntitlesInGameSettingsPersistence() {
        let key = "IN_GAME_SETTINGS_PERSISTENCE_ENABLED"
        #expect(OPNGameService.featureIsEnabled(nil, key: key) == false)
        #expect(OPNGameService.featureIsEnabled(["key": "HDR_ENABLED", "textValue": "true"], key: key) == false)
        #expect(OPNGameService.featureIsEnabled([["key": key, "textValue": "true"]], key: key) == true)
        #expect(OPNGameService.featureIsEnabled([["key": key, "value": "true"]], key: key) == true)
        #expect(OPNGameService.featureIsEnabled([["features": [["key": key, "value": true]]]], key: key) == true)
        #expect(OPNGameService.featureIsEnabled([["key": key, "textValue": "false"]], key: key) == false)
    }

    @Test func hdrLiftsTheColourTierAndNeedsAModernCodec() {
        let capabilities = StreamDeviceCapabilities(h265HardwareDecodeSupported: true, hdrDisplaySupported: true)
        let hevc = Resolver.resolve(profile: StreamProfile(codec: "H265", colorQuality: "8bit_420", enableHdr: true), capabilities: capabilities)
        #expect(hevc.enableHdr)
        #expect(hevc.colorQuality == "10bit_420")
        let hevcFull = Resolver.resolve(profile: StreamProfile(codec: "H265", colorQuality: "10bit_444", enableHdr: true), capabilities: capabilities)
        #expect(hevcFull.colorQuality == "10bit_444")
        let h264 = Resolver.resolve(profile: StreamProfile(codec: "H264", colorQuality: "8bit_420", enableHdr: true), capabilities: capabilities)
        #expect(!h264.enableHdr)
        #expect(h264.colorQuality == "8bit_420")
        let sdrDisplay = Resolver.resolve(profile: StreamProfile(codec: "H265", enableHdr: true), capabilities: StreamDeviceCapabilities(h265HardwareDecodeSupported: true))
        #expect(!sdrDisplay.enableHdr)
        #expect(sdrDisplay.colorQuality == "8bit_420")
    }
}
