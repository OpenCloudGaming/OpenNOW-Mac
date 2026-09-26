import Combine
import Foundation

/// Carries pad commands from the stream HUD to the controller-mapping sheet.
///
/// The sheet is a separate presentation with no reference to the host view model, so the HUD
/// forwards the commands it already receives rather than the sheet reaching back into it.
@MainActor
final class StreamMappingPadRelay {
    private let commandSubject = PassthroughSubject<ControllerInputCommand, Never>()

    var commands: AnyPublisher<ControllerInputCommand, Never> { commandSubject.eraseToAnyPublisher() }

    func send(_ command: ControllerInputCommand) { commandSubject.send(command) }
}
