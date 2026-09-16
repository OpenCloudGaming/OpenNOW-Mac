import Foundation

struct ControllerPlayerOrder: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case earlier, later
    }

    static let maximumPlayers = 4
    private(set) var deviceIDs: [InputDeviceID] = []
    private(set) var isCustom = false

    var playerIndices: [InputDeviceID: Int] {
        Dictionary(uniqueKeysWithValues: deviceIDs.prefix(Self.maximumPlayers).enumerated().map { ($0.element, $0.offset) })
    }

    mutating func update(connectedIDs: [InputDeviceID]) {
        var seen: Set<InputDeviceID> = []
        let connected = connectedIDs.filter { seen.insert($0).inserted }
        guard isCustom, !connected.isEmpty else {
            deviceIDs = connected
            isCustom = false
            return
        }
        let available = Set(connected)
        deviceIDs.removeAll { !available.contains($0) }
        let retained = Set(deviceIDs)
        deviceIDs.append(contentsOf: connected.filter { !retained.contains($0) })
    }

    mutating func move(_ id: InputDeviceID, direction: Direction) {
        guard let index = deviceIDs.firstIndex(of: id) else { return }
        let destination = index + (direction == .earlier ? -1 : 1)
        guard deviceIDs.indices.contains(destination) else { return }
        deviceIDs.swapAt(index, destination)
        isCustom = true
    }

    mutating func reset(connectedIDs: [InputDeviceID]) {
        isCustom = false
        update(connectedIDs: connectedIDs)
    }
}
