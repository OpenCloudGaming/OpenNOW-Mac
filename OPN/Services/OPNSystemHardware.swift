import Darwin
import Foundation

/// The few machine facts the survey endpoint expects. Kept in one place so the report form, the top
/// bar, and the Help menu all describe the same Mac.
enum OPNSystemHardware {
    /// The board model as `hw.model` reports it, such as "Mac14,14". Empty when the system call
    /// cannot answer, so callers send a blank field rather than a guessed one.
    static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// The running system version as "major.minor.patch", which is the shape the survey sends.
    static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
