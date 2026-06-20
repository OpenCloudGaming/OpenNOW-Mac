import Foundation

enum OPNLogCapture {
    static func appendEvent(_ message: String) {
        WebRTCMediaTelemetry.capture("webrtc.native.log", level: .info, message: message)
    }
}

enum OPNSentry {
    static func logInfoMessage(_ message: String) {
        WebRTCMediaTelemetry.capture("webrtc.native.info", level: .info, message: message)
    }

    static func logErrorMessage(_ message: String) {
        WebRTCMediaTelemetry.capture("webrtc.native.error", level: .error, message: message)
    }
}
