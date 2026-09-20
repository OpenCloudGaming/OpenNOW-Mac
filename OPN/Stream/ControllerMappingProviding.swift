import Combine
import Foundation

@MainActor
protocol ControllerMappingProviding: AnyObject {
    var activeProfile: ControllerMappingProfile? { get }
    var revisionPublisher: AnyPublisher<Int, Never> { get }
    var requiresRawSteamTrackpads: Bool { get }
    /// Whether any saved profile wants inertial data. The controller's IMU is off in firmware by
    /// default and costs battery, so motion reporting follows the profiles rather than the device:
    /// every profile with gyro off leaves it off.
    var wantsGyroMotion: Bool { get }
    func profile(for deviceID: InputDeviceID, family: ControllerFamily) -> ControllerMappingProfile?
}

extension ControllerMappingStore: ControllerMappingProviding {
    var wantsGyroMotion: Bool {
        profiles.contains { $0.family == .steam && $0.gyro.needsMotionReporting }
    }
}
