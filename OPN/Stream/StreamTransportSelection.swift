import Foundation

public enum OPNSelectedStreamTransport: String, Equatable, Sendable {
    case webRTC = "webrtc"
    case nativeNVST = "nvst"
}

public enum OPNStreamTransportSelector {
    public static func selectedTransport(forGame applicationID: String,
                                         capabilities: OPNStreamDeviceCapabilities = OPNStreamPreferences.loadDeviceCapabilities()) -> OPNSelectedStreamTransport {
        let profile = OPNStreamPreferences.launchProfile(forGame: applicationID, capabilities: capabilities)
        return profile.transportMode.value.caseInsensitiveCompare(OPNSelectedStreamTransport.nativeNVST.rawValue) == .orderedSame ? .nativeNVST : .webRTC
    }
}
