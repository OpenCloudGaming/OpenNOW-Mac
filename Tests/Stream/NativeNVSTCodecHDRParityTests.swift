import Foundation
import Testing
@testable import OpenNOW

@_silgen_name("OpenNOWNativeNVSTGeronimoVideoDecoderCreationCodec")
private func nativeVideoDecoderCreationCodec(_ requestedCodec: UInt32) -> UInt32

@_silgen_name("OpenNOWNativeNVSTGeronimoAudioFrameTriggersRendererReopen")
private func nativeAudioFrameTriggersRendererReopen(_ configuredChannelCount: UInt32, _ incomingChannelCount: UInt32) -> Int32

@Test func nativeVideoDecoderCreationUsesRequestedCodecEnum() {
    #expect(nativeVideoDecoderCreationCodec(1) == 1)
    #expect(nativeVideoDecoderCreationCodec(2) == 2)
    #expect(nativeVideoDecoderCreationCodec(4) == 4)
    #expect(nativeVideoDecoderCreationCodec(0) == 0)
    #expect(nativeVideoDecoderCreationCodec(3) == 0)
}

@Test func nativePresentationCapabilityIsCodecAndEDRSpecific() {
    var capabilities = OPNStreamDeviceCapabilities()
    capabilities.h265HardwareDecodeSupported = true
    capabilities.av1HardwareDecodeSupported = true
    capabilities.hdrDisplaySupported = true

    #expect(OPNStreamPreferences.presentationCapability(codec: "H264", capabilities: capabilities) == OPNStreamPresentationCapability(supportsTenBit: false, supportsHDR: false))
    #expect(OPNStreamPreferences.presentationCapability(codec: "H265", capabilities: capabilities) == OPNStreamPresentationCapability(supportsTenBit: true, supportsHDR: true))
    #expect(OPNStreamPreferences.presentationCapability(codec: "AV1", capabilities: capabilities) == OPNStreamPresentationCapability(supportsTenBit: true, supportsHDR: false))

    capabilities.hdrDisplaySupported = false
    #expect(OPNStreamPreferences.presentationCapability(codec: "HEVC", capabilities: capabilities) == OPNStreamPresentationCapability(supportsTenBit: true, supportsHDR: false))
}

@Test @MainActor func nativePresentationEnablesEDROnlyWhenEveryConditionIsMet() {
    #expect(NativeWebRTCStreamView.nativeNVSTPresentationUsesEDR(requestedHDR: true, codecSupportsHDR: true, screenSupportsEDR: true))
    #expect(!NativeWebRTCStreamView.nativeNVSTPresentationUsesEDR(requestedHDR: false, codecSupportsHDR: true, screenSupportsEDR: true))
    #expect(!NativeWebRTCStreamView.nativeNVSTPresentationUsesEDR(requestedHDR: true, codecSupportsHDR: false, screenSupportsEDR: true))
    #expect(!NativeWebRTCStreamView.nativeNVSTPresentationUsesEDR(requestedHDR: true, codecSupportsHDR: true, screenSupportsEDR: false))
}

@Test @MainActor func nativeDrawableSizeTracksBackingScaleDeterministically() {
    #expect(NativeWebRTCStreamView.nativeNVSTDrawableSize(boundsSize: CGSize(width: 640.5, height: 360.5), backingScaleFactor: 2) == CGSize(width: 1_281, height: 721))
    #expect(NativeWebRTCStreamView.nativeNVSTDrawableSize(boundsSize: CGSize(width: 640, height: 360), backingScaleFactor: 1) == CGSize(width: 640, height: 360))
    #expect(NativeWebRTCStreamView.nativeNVSTDrawableSize(boundsSize: .zero, backingScaleFactor: 2) == nil)
    #expect(NativeWebRTCStreamView.nativeNVSTDrawableSize(boundsSize: CGSize(width: .nan, height: 360), backingScaleFactor: 2) == nil)
    #expect(NativeWebRTCStreamView.nativeNVSTDrawableSize(boundsSize: CGSize(width: 640, height: 360), backingScaleFactor: .infinity) == nil)
}

@Test func nativeModeSelectionSuppressesUnsupportedCodecHDRClaims() throws {
    var capabilities = OPNStreamDeviceCapabilities()
    capabilities.h265HardwareDecodeSupported = true
    capabilities.av1HardwareDecodeSupported = true
    capabilities.hdrDisplaySupported = true

    let h264 = try selectedFeatures(codec: "H264", capabilities: capabilities)
    #expect(h264["bitDepth"] as? Int == 8)
    #expect(h264["hdr"] as? Bool == false)
    #expect(h264["trueHdr"] as? Bool == false)

    let hevc = try selectedFeatures(codec: "H265", capabilities: capabilities)
    #expect(hevc["bitDepth"] as? Int == 10)
    #expect(hevc["hdr"] as? Bool == true)
    #expect(hevc["trueHdr"] as? Bool == true)

    let av1 = try selectedFeatures(codec: "AV1", capabilities: capabilities)
    #expect(av1["bitDepth"] as? Int == 10)
    #expect(av1["hdr"] as? Bool == false)
    #expect(av1["trueHdr"] as? Bool == false)
}

@Test func incomingSurroundFramesTriggerVendorRendererReopenDecision() {
    #expect(nativeAudioFrameTriggersRendererReopen(2, 6) == 1)
    #expect(nativeAudioFrameTriggersRendererReopen(2, 8) == 1)
    #expect(nativeAudioFrameTriggersRendererReopen(6, 6) == 0)
    #expect(nativeAudioFrameTriggersRendererReopen(8, 8) == 0)
}

@Test func nativeStreamHealthRequiresFramesAndDetectsSustainedStalls() {
    var health = NativeNVSTStreamHealthMonitor(firstFrameSampleLimit: 2, stalledSampleLimit: 2, rendererSampleLimit: 2)
    let stopped = nativePerformanceSnapshot(streamFramesPerSecond: 0)
    let running = nativePerformanceSnapshot(streamFramesPerSecond: 60)

    #expect(health.observe(snapshot: stopped, rendererReady: true) == nil)
    #expect(health.observe(snapshot: running, rendererReady: true) == nil)
    #expect(health.receivedFrames)
    #expect(health.observe(snapshot: stopped, rendererReady: true) == nil)
    #expect(health.observe(snapshot: stopped, rendererReady: true) == .streamStalled)
}

@Test func nativeStreamHealthDetectsMissingInitialFramesAndRenderer() {
    var missingFrames = NativeNVSTStreamHealthMonitor(firstFrameSampleLimit: 2, stalledSampleLimit: 2, rendererSampleLimit: 3)
    let stopped = nativePerformanceSnapshot(streamFramesPerSecond: 0)
    #expect(missingFrames.observe(snapshot: stopped, rendererReady: true) == nil)
    #expect(missingFrames.observe(snapshot: stopped, rendererReady: true) == .firstFrameTimedOut)

    var missingRenderer = NativeNVSTStreamHealthMonitor(firstFrameSampleLimit: 3, stalledSampleLimit: 2, rendererSampleLimit: 2)
    #expect(missingRenderer.observe(snapshot: stopped, rendererReady: false) == nil)
    #expect(missingRenderer.observe(snapshot: stopped, rendererReady: false) == .rendererUnavailable)
}

private func nativePerformanceSnapshot(streamFramesPerSecond: Double) -> NativeNVSTPerformanceSnapshot {
    NativeNVSTPerformanceSnapshot(
        available: true,
        gameFramesPerSecond: streamFramesPerSecond,
        streamFramesPerSecond: streamFramesPerSecond,
        latencyMilliseconds: 20,
        jitterMilliseconds: 1,
        frameLoss: 0,
        totalFrameLoss: 0,
        packetLoss: 0,
        totalPacketLoss: 0,
        bitrateMegabitsPerSecond: 20,
        bandwidthUtilizationPercent: 50,
        resolution: "1920x1080",
        codec: "H265",
        serverLocation: "test"
    )
}

private func selectedFeatures(codec: String, capabilities: OPNStreamDeviceCapabilities) throws -> [String: Any] {
    let json = try NativeNVSTBifrostTransport.streamingProfileJSON(
        rawSessionJSON: "{\"streamingProfile\":{\"resolution\":\"1920x1080\",\"fps\":60,\"codec\":\"\(codec)\",\"colorQuality\":\"10bit_420\"}}",
        sessionInfoJSON: "{}",
        settingsJSON: "{\"enableHdr\":true}",
        presentationCapabilities: capabilities
    )
    let profile = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    return try #require(profile["selectedFeatures"] as? [String: Any])
}
