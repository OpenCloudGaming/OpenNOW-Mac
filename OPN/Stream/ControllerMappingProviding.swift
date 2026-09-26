import Combine
import Foundation

@MainActor
protocol ControllerMappingProviding: AnyObject {
    var revisionPublisher: AnyPublisher<Int, Never> { get }
    var requiresRawSteamTrackpads: Bool { get }
    /// Whether any saved profile wants inertial data. The IMU costs battery, so motion reporting
    /// follows the saved profiles rather than the device.
    var wantsGyroMotion: Bool { get }
    /// The profile a pad of `family` resolves to now: an enabled override for the running game,
    /// else that type's default, else `nil` for blank passthrough.
    func profile(for family: ControllerFamily) -> ControllerMappingProfile?
}

extension ControllerMappingStore: ControllerMappingProviding {}
