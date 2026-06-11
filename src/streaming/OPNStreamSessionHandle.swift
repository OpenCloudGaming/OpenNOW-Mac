import Foundation

@objc(OPNStreamSessionHandle)
final class OPNStreamSessionHandle: NSObject {
    private(set) var session: OPNLibWebRTCStreamSession?

    @objc var rawSession: UnsafeMutableRawPointer? {
        guard let session else { return nil }
        return Unmanaged.passUnretained(session).toOpaque()
    }

    @objc(isBackendAvailable)
    static func isBackendAvailable() -> Bool {
        OPNLibWebRTCStreamSession.isAvailable()
    }

    @objc(maxGamepadControllers)
    static func maxGamepadControllers() -> UInt {
        UInt(OPNLibWebRTCStreamSession.maxGamepadControllers)
    }

    @objc(iceUfragFromOfferSdp:)
    static func iceUfrag(fromOfferSdp offerSdp: String) -> String {
        OPNLibWebRTCStreamSession.iceUfrag(fromOfferSdp: offerSdp)
    }

    @objc override init() {
        session = OPNLibWebRTCStreamSession()
        super.init()
    }

    deinit {
        stop()
    }

    @objc var isValid: Bool {
        session != nil
    }

    @objc var isInputReady: Bool {
        session?.isInputReady ?? false
    }

    @objc func stop() {
        session?.stop()
        session = nil
    }

    @objc func setNativeWindow(_ nativeWindow: UnsafeMutableRawPointer?) {
        session?.setNativeWindow(nativeWindow)
    }

    @objc func setMaxBitrateMbps(_ mbps: Int) {
        session?.setMaxBitrateMbps(mbps)
    }

    @objc func addRemoteIceCandidatePayload(_ payload: [AnyHashable: Any]) {
        session?.addRemoteIceCandidatePayload(payload)
    }

    @objc func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        session?.latestStatsSnapshot() ?? OPNStreamStatsSnapshot(available: false, latencyMs: -1, jitterMs: -1, inboundBitrateMbps: -1, packetLossPercent: -1, decodeTimeMs: -1, renderFps: -1, framesReceived: 0, framesDropped: 0, packetsLost: 0, fps: 0, resolution: "", codec: "", videoEnhancementActiveTier: "", videoEnhancementConfiguredTier: "", videoEnhancementSourceResolution: "", videoEnhancementDrawableResolution: "", videoEnhancementFallbackReason: "", videoEnhancementDiagnostics: "", videoEnhancementFrameTimeMs: -1, videoEnhancementDroppedFrames: 0)
    }

    func start(sessionInfo: NSDictionary, offerSdp: String, settings: NSDictionary, answerHandler: @escaping @convention(block) (NSString, NSString) -> Void, localIceCandidateHandler: @escaping @convention(block) (NSDictionary) -> Void, stateHandler: @escaping @convention(block) (Bool, NSString) -> Void) {
        session?.start(sessionInfo: sessionInfo as? [String: Any] ?? [:], offerSdp: offerSdp, settings: settings as? [String: Any] ?? [:], answerHandler: answerHandler, localIceCandidateHandler: localIceCandidateHandler, stateHandler: stateHandler)
    }

    func injectManualIceCandidate(sessionInfo: NSDictionary, offerSdp: String, serverIceUfrag: String) {
        session?.injectManualIceCandidate(sessionInfo: sessionInfo as? [String: Any] ?? [:], offerSdp: offerSdp, serverIceUfrag: serverIceUfrag)
    }

    @MainActor func configureSurface(streamView: OPNStreamView?, recordingManager: OPNStreamRecordingManager?) {
        session?.configureSurface(streamView: streamView, recordingManager: recordingManager)
    }

    @MainActor func clearSurfaceCallbacks(streamView: OPNStreamView?) {
        session?.clearSurfaceCallbacks(streamView: streamView)
    }
}

extension OPNStreamSessionHandle: @unchecked Sendable {}
