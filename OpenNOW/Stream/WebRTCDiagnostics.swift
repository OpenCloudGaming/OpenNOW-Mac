import Foundation

enum OPNLogCapture {
    static func appendEvent(_ message: String) {
        WebRTCMediaTelemetry.capture("webrtc.native.log", level: .info, message: message)
    }
}
