import Foundation

/// Controller-generated keys/buttons share one remote keyboard and mouse across player slots.
struct ControllerBindingOutputLedger {
    private var keys: [UInt16: [InputDeviceID: KeyboardModifiers]] = [:]
    private var mouseButtons: [MouseButton: Set<InputDeviceID>] = [:]

    mutating func events(for event: UserInputEvent) -> [UserInputEvent] {
        switch event {
        case .keyboard(let key):
            return keyboardEvents(for: key)
        case .mouse(.button(let deviceID, let button, let isPressed, _)):
            let wasHeld = !(mouseButtons[button]?.isEmpty ?? true)
            if isPressed {
                mouseButtons[button, default: []].insert(deviceID)
            } else {
                mouseButtons[button]?.remove(deviceID)
            }
            let isHeld = !(mouseButtons[button]?.isEmpty ?? true)
            if !isHeld { mouseButtons.removeValue(forKey: button) }
            return wasHeld != isHeld ? [event] : []
        default:
            return [event]
        }
    }

    mutating func releaseHeldOutputs(timestamp: MediaTimestamp) -> [UserInputEvent] {
        var releaseEvents: [UserInputEvent] = []
        for keyCode in keys.keys.sorted() {
            guard let ownerDeviceID = keys[keyCode]?.keys.sorted(by: { $0.rawValue < $1.rawValue }).first else { continue }
            releaseEvents.append(.keyboard(KeyboardEvent(deviceID: ownerDeviceID, keyCode: keyCode, scanCode: keyCode,
                                                         modifiers: [], isPressed: false, timestamp: timestamp)))
        }
        for mouseButton in mouseButtons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let ownerDeviceID = mouseButtons[mouseButton]?.sorted(by: { $0.rawValue < $1.rawValue }).first else { continue }
            releaseEvents.append(.mouse(.button(deviceID: ownerDeviceID, button: mouseButton, isPressed: false, timestamp: timestamp)))
        }
        keys.removeAll()
        mouseButtons.removeAll()
        return releaseEvents
    }

    private mutating func keyboardEvents(for event: KeyboardEvent) -> [UserInputEvent] {
        let previous = keys
        let previousModifiers = modifiers
        if event.isPressed {
            keys[event.keyCode, default: [:]][event.deviceID] = event.modifiers
        } else {
            keys[event.keyCode]?.removeValue(forKey: event.deviceID)
            if keys[event.keyCode]?.isEmpty == true { keys.removeValue(forKey: event.keyCode) }
        }
        let nextModifiers = modifiers
        var events: [UserInputEvent] = []
        for code in previous.keys.sorted() where keys[code] == nil || previousModifiers != nextModifiers {
            let owner = previous[code]?.keys.sorted(by: { $0.rawValue < $1.rawValue }).first ?? event.deviceID
            events.append(.keyboard(KeyboardEvent(deviceID: owner, keyCode: code, scanCode: code,
                                                  modifiers: nextModifiers, isPressed: false, timestamp: event.timestamp)))
        }
        for code in keys.keys.sorted() where previous[code] == nil || previousModifiers != nextModifiers {
            let owner = keys[code]?.keys.sorted(by: { $0.rawValue < $1.rawValue }).first ?? event.deviceID
            events.append(.keyboard(KeyboardEvent(deviceID: owner, keyCode: code, scanCode: code,
                                                  modifiers: nextModifiers, isPressed: true, timestamp: event.timestamp)))
        }
        return events
    }

    private var modifiers: KeyboardModifiers {
        keys.values.reduce(into: KeyboardModifiers()) { result, owners in
            for value in owners.values { result.formUnion(value) }
        }
    }
}
