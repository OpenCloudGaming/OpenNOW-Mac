import Foundation

struct ControllerSlotAssignments: Equatable, Sendable {
    let steam: [InputDeviceID: Int]
    let native: [ObjectIdentifier: Int]

    init(order: ControllerPlayerOrder, steamIDs: Set<InputDeviceID>, nativeIDs: [InputDeviceID: ObjectIdentifier]) {
        self.init(deviceIDs: order.deviceIDs, steamIDs: steamIDs, nativeIDs: nativeIDs)
    }

    /// The filtered form: a stream hands in only the devices it admits, in shared order, so the
    /// first four of *that* list take Player 1–4 and a disabled device leaves no gap behind it.
    init(deviceIDs: [InputDeviceID], steamIDs: Set<InputDeviceID>, nativeIDs: [InputDeviceID: ObjectIdentifier]) {
        var steam: [InputDeviceID: Int] = [:]
        var native: [ObjectIdentifier: Int] = [:]
        var slot = 0
        for id in deviceIDs where slot < ControllerPlayerOrder.maximumPlayers {
            if steamIDs.contains(id) {
                steam[id] = slot
            } else if let identifier = nativeIDs[id] {
                native[identifier] = slot
            } else {
                continue
            }
            slot += 1
        }
        self.steam = steam
        self.native = native
    }
}
