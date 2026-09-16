struct ControllerTestSelection: Equatable {
    private(set) var deviceID: InputDeviceID?

    mutating func reconcile(connectedIDs: [InputDeviceID]) {
        if let deviceID, connectedIDs.contains(deviceID) { return }
        deviceID = connectedIDs.first
    }

    mutating func select(_ id: InputDeviceID, connectedIDs: [InputDeviceID]) {
        guard connectedIDs.contains(id) else { return }
        deviceID = id
    }
}
