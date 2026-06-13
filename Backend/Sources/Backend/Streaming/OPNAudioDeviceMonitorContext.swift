import Foundation

@objc(OPNAudioDeviceMonitorContext)
final class OPNAudioDeviceMonitorContext: NSObject {
    @objc var owner: UnsafeMutableRawPointer?
    @objc(isActive) var active = false
}
