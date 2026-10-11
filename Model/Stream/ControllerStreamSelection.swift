import Foundation

/// One live stream's controller admission: the devices it lets play, the Player 1–4 slots they hold,
/// and the session history the HUD renders. The shared registry still owns the order every stream
/// uses; this type owns only the per-stream decision on top of it.
struct ControllerStreamSelection: Equatable, Sendable {
    /// A device as the shared registry reports it. The name is remembered for the session, so a row
    /// can still be labelled after the hardware is gone.
    struct Device: Equatable, Sendable {
        let id: InputDeviceID
        let name: String
    }

    /// What the HUD shows for one row. The player index is the effective slot, never the position in
    /// the shared order — the two differ as soon as anything ahead of it is disabled.
    enum RowState: Equatable, Sendable {
        case active(playerIndex: Int)
        case waiting
        case disabled
        case newlyIdentified
        case disconnected
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: InputDeviceID
        let name: String
        /// The remembered choice, read-only once the device is disconnected.
        let isEnabled: Bool
        let state: RowState

        var playerIndex: Int? {
            if case .active(let playerIndex) = state { return playerIndex }
            return nil
        }
    }

    /// A device is known once this session has seen it, enabled only after an explicit decision, and
    /// holds a slot only while it is both enabled and connected inside the first four of the order.
    private(set) var isSessionStarted = false
    private var names: [InputDeviceID: String] = [:]
    private var knownIDs: Set<InputDeviceID> = []
    private var enabledIDs: Set<InputDeviceID> = []
    /// Connected devices first seen after the session began, still awaiting an explicit decision.
    private var newlyIdentifiedIDs: Set<InputDeviceID> = []
    /// The shared order as of the last synchronization, so rows and slots read one snapshot.
    private var connectedIDs: [InputDeviceID] = []
    /// This session's history: known devices that are no longer connected.
    private var disconnectedIDs: [InputDeviceID] = []

    var isEmpty: Bool { knownIDs.isEmpty }

    /// Opens the session with everything connected at stream launch admitted enabled and remembered.
    mutating func beginSession(devices: [Device]) {
        isSessionStarted = true
        names = [:]
        knownIDs = []
        enabledIDs = []
        newlyIdentifiedIDs = []
        for device in devices {
            names[device.id] = device.name
            knownIDs.insert(device.id)
            enabledIDs.insert(device.id)
        }
        connectedIDs = devices.map(\.id)
        disconnectedIDs = []
    }

    /// Folds the current discovery set, in shared order, into this session: a known device keeps its
    /// choice, a first-seen one is admitted disabled, and the arrivals come back to be announced.
    @discardableResult
    mutating func synchronize(devices: [Device]) -> [Device] {
        guard isSessionStarted else {
            beginSession(devices: devices)
            return []
        }
        let arrivals = devices.filter { !knownIDs.contains($0.id) }
        for device in devices { names[device.id] = device.name }
        for arrival in arrivals {
            knownIDs.insert(arrival.id)
            enabledIDs.remove(arrival.id)
            newlyIdentifiedIDs.insert(arrival.id)
        }
        connectedIDs = devices.map(\.id)
        disconnectedIDs = knownIDs.subtracting(connectedIDs).sorted { $0.rawValue < $1.rawValue }
        return arrivals
    }

    /// Enabling clears the new-device prompt; disabling keeps the row and the remembered choice, so
    /// the same device can be re-enabled without a reconnect. Returns whether anything changed.
    @discardableResult
    mutating func setEnabled(_ isEnabled: Bool, for id: InputDeviceID) -> Bool {
        guard knownIDs.contains(id) else { return false }
        if !isEnabled { return enabledIDs.remove(id) != nil }
        newlyIdentifiedIDs.remove(id)
        return enabledIDs.insert(id).inserted
    }

    func isEnabled(_ id: InputDeviceID) -> Bool { enabledIDs.contains(id) }
    func isNewlyIdentified(_ id: InputDeviceID) -> Bool { newlyIdentifiedIDs.contains(id) }
    func isConnected(_ id: InputDeviceID) -> Bool { connectedIDs.contains(id) }
    func name(for id: InputDeviceID) -> String? { names[id] }

    /// Enabled and connected, in the shared global order. This is the whole admitted set, not just
    /// the four that fit: everything past the fourth is the HUD's Waiting rows.
    var activeDeviceIDs: [InputDeviceID] {
        connectedIDs.filter { enabledIDs.contains($0) }
    }

    /// The effective Player 1–4 map: the first four admitted devices, compacted so disabling one
    /// promotes the next waiting device rather than leaving a gap.
    var playerIndices: [InputDeviceID: Int] {
        let admitted = activeDeviceIDs.prefix(ControllerPlayerOrder.maximumPlayers)
        return Dictionary(uniqueKeysWithValues: admitted.enumerated().map { ($0.element, $0.offset) })
    }

    func playerIndex(for id: InputDeviceID) -> Int? { playerIndices[id] }

    /// Connected rows in shared order, then this session's disconnected history.
    var rows: [Row] {
        let slots = playerIndices
        let connected = connectedIDs.map { id in
            makeRow(id, isEnabled: enabledIDs.contains(id), state: rowState(for: id, slots: slots))
        }
        let history = disconnectedIDs.map { id in
            makeRow(id, isEnabled: enabledIDs.contains(id), state: .disconnected)
        }
        return connected + history
    }

    private func makeRow(_ id: InputDeviceID, isEnabled: Bool, state: RowState) -> Row {
        Row(id: id, name: names[id] ?? "Unknown controller", isEnabled: isEnabled, state: state)
    }

    private func rowState(for id: InputDeviceID, slots: [InputDeviceID: Int]) -> RowState {
        guard enabledIDs.contains(id) else {
            return newlyIdentifiedIDs.contains(id) ? .newlyIdentified : .disabled
        }
        return slots[id].map(RowState.active(playerIndex:)) ?? .waiting
    }
}
