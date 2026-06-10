import Foundation

@_silgen_name("OPNStreamSessionHandleBackendAvailable")
private func OPNStreamSessionHandleBackendAvailable() -> Bool

@_silgen_name("OPNStreamSessionHandleMaxGamepadControllers")
private func OPNStreamSessionHandleMaxGamepadControllers() -> UInt

@_silgen_name("OPNStreamSessionHandleIceUfragFromOfferSdp")
private func OPNStreamSessionHandleIceUfragFromOfferSdp(_ offerSdp: NSString) -> NSString

@_silgen_name("OPNStreamSessionHandleCreateRawSession")
private func OPNStreamSessionHandleCreateRawSession() -> UnsafeMutableRawPointer?

@_silgen_name("OPNStreamSessionHandleReleaseRawSession")
private func OPNStreamSessionHandleReleaseRawSession(_ session: UnsafeMutableRawPointer?)

@_silgen_name("OPNStreamSessionHandleInputReady")
private func OPNStreamSessionHandleInputReady(_ session: UnsafeMutableRawPointer?) -> Bool

@_silgen_name("OPNStreamSessionHandleSetNativeWindow")
private func OPNStreamSessionHandleSetNativeWindow(_ session: UnsafeMutableRawPointer?, _ nativeWindow: UnsafeMutableRawPointer?)

@_silgen_name("OPNStreamSessionHandleSetMaxBitrateMbps")
private func OPNStreamSessionHandleSetMaxBitrateMbps(_ session: UnsafeMutableRawPointer?, _ mbps: Int)

@_silgen_name("OPNStreamSessionHandleAddRemoteIceCandidatePayload")
private func OPNStreamSessionHandleAddRemoteIceCandidatePayload(_ session: UnsafeMutableRawPointer?, _ payload: NSDictionary)

@_silgen_name("OPNStreamSessionHandleLatestStatsSnapshot")
private func OPNStreamSessionHandleLatestStatsSnapshot(_ session: UnsafeMutableRawPointer?) -> OPNStreamStatsSnapshot

@objc(OPNStreamSessionHandle)
final class OPNStreamSessionHandle: NSObject {
    @objc private(set) var rawSession: UnsafeMutableRawPointer?

    @objc(isBackendAvailable)
    static func isBackendAvailable() -> Bool {
        OPNStreamSessionHandleBackendAvailable()
    }

    @objc(maxGamepadControllers)
    static func maxGamepadControllers() -> UInt {
        OPNStreamSessionHandleMaxGamepadControllers()
    }

    @objc(iceUfragFromOfferSdp:)
    static func iceUfrag(fromOfferSdp offerSdp: String) -> String {
        OPNStreamSessionHandleIceUfragFromOfferSdp(offerSdp as NSString) as String
    }

    @objc override init() {
        rawSession = OPNStreamSessionHandleCreateRawSession()
        super.init()
    }

    deinit {
        stop()
    }

    @objc var isValid: Bool {
        rawSession != nil
    }

    @objc var isInputReady: Bool {
        OPNStreamSessionHandleInputReady(rawSession)
    }

    @objc func stop() {
        guard let rawSession else { return }
        self.rawSession = nil
        OPNStreamSessionHandleReleaseRawSession(rawSession)
    }

    @objc func setNativeWindow(_ nativeWindow: UnsafeMutableRawPointer?) {
        OPNStreamSessionHandleSetNativeWindow(rawSession, nativeWindow)
    }

    @objc func setMaxBitrateMbps(_ mbps: Int) {
        OPNStreamSessionHandleSetMaxBitrateMbps(rawSession, mbps)
    }

    @objc func addRemoteIceCandidatePayload(_ payload: [AnyHashable: Any]) {
        OPNStreamSessionHandleAddRemoteIceCandidatePayload(rawSession, payload as NSDictionary)
    }

    @objc func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        OPNStreamSessionHandleLatestStatsSnapshot(rawSession)
    }
}

extension OPNStreamSessionHandle: @unchecked Sendable {}
