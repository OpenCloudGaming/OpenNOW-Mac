import Combine
import Foundation

@MainActor
protocol ControllerMappingProviding: AnyObject {
    var activeProfile: ControllerMappingProfile? { get }
    var revisionPublisher: AnyPublisher<Int, Never> { get }
    var requiresRawSteamTrackpads: Bool { get }
    func profile(for deviceID: InputDeviceID, family: ControllerFamily) -> ControllerMappingProfile?
}

extension ControllerMappingStore: ControllerMappingProviding {}
