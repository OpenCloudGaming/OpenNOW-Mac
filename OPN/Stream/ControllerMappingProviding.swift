import Combine
import Foundation

@MainActor
protocol ControllerMappingProviding: AnyObject {
    var revisionPublisher: AnyPublisher<Int, Never> { get }
    var requiresRawSteamTrackpads: Bool { get }
    /// Whether any saved profile wants inertial data. The controller's IMU is off in firmware by
    /// default and costs battery, so motion reporting follows the profiles rather than the device:
    /// every profile with gyro off leaves it off.
    var wantsGyroMotion: Bool { get }
    /// The profile a pad of `family` resolves to right now: an enabled override for the running
    /// game, else that type's default, else `nil` for blank passthrough.
    func profile(for family: ControllerFamily) -> ControllerMappingProfile?
}

extension ControllerMappingStore: ControllerMappingProviding {}

