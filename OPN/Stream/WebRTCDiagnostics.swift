import Foundation

enum OPNLogCapture {
    static func appendEvent(_ message: String) {
        OPNStreamTelemetry.capture("webrtc.native.log", level: .info, message: message)
    }
}
