import Foundation

enum OPNLogCapture {
    static func appendEvent(_ message: String) {
        NSLog("%@", message)
    }
}

enum OPNSentry {
    static func logInfoMessage(_ message: String) {
        NSLog("%@", message)
    }

    static func logErrorMessage(_ message: String) {
        NSLog("%@", message)
    }
}
