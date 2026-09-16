import Combine
import Foundation

@MainActor
final class ControllerOrderNavigationModel: ObservableObject {
    struct Focus: Equatable {
        let deviceID: InputDeviceID
        var direction: ControllerPlayerOrder.Direction
    }
    enum Action: Equatable {
        case move(InputDeviceID, ControllerPlayerOrder.Direction)
        case close
    }

    @Published private(set) var focus: Focus?
    private let tracker = StreamHUDGamepadTracker()

    func reconcile(_ deviceIDs: [InputDeviceID]) {
        let connected = Set(deviceIDs)
        tracker.lastButtons = tracker.lastButtons.filter { connected.contains($0.key) }
        tracker.lastStickDirection = tracker.lastStickDirection.filter { connected.contains($0.key) }
        guard deviceIDs.count > 1 else {
            if focus != nil { focus = nil }
            return
        }
        let id = focus?.deviceID ?? deviceIDs[0]
        let index = deviceIDs.firstIndex(of: id) ?? 0
        var direction = focus?.direction ?? .later
        if index == 0 { direction = .later }
        if index == deviceIDs.count - 1 { direction = .earlier }
        let next = Focus(deviceID: deviceIDs[index], direction: direction)
        if focus != next { focus = next }
    }

    func process(_ state: GamepadState, deviceIDs: [InputDeviceID]) -> Action? {
        guard let step = tracker.navigationStep(state) else { return nil }
        return process(step, deviceIDs: deviceIDs)
    }

    func process(_ step: StreamHUDGamepadTracker.NavigationStep, deviceIDs: [InputDeviceID]) -> Action? {
        reconcile(deviceIDs)
        if step == .back { return .close }
        guard let focus, let index = deviceIDs.firstIndex(of: focus.deviceID) else { return nil }
        switch step {
        case .activate:
            return .move(focus.deviceID, focus.direction)
        case .move(let direction):
            switch direction {
            case .up, .down:
                let next = min(deviceIDs.count - 1, max(0, index + (direction == .up ? -1 : 1)))
                self.focus = Focus(deviceID: deviceIDs[next], direction: focus.direction)
                reconcile(deviceIDs)
            case .left where index > 0:
                self.focus = Focus(deviceID: focus.deviceID, direction: .earlier)
            case .right where index < deviceIDs.count - 1:
                self.focus = Focus(deviceID: focus.deviceID, direction: .later)
            default:
                break
            }
        case .back:
            return .close
        }
        return nil
    }

    func reset() { tracker.reset() }
}
