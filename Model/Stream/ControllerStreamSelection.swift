import Foundation

/// One live stream's controller admission: which connected devices this stream lets play, which of
/// them hold a Player 1–4 slot, and the session history the HUD renders beside them.
///
/// The app-wide `ControllerMappingDevices` registry owns the *order* every stream shares; this type
/// owns only the per-stream decision layered on top of it. Two concurrent streams therefore enable
/// different subsets of one order without either one mutating the registry or an app-wide default,
/// and neither one can reorder or disconnect the other's hardware.
///
/// Connection, enablement and effective slot are three separate facts here. A device is `known`
/// once this session has seen it, `enabled` only after an explicit admission decision, and holds a
/// slot only while it is both enabled and connected inside the first four of the shared order.
struct ControllerStreamSelection: Equatable, Sendable {
    /// A device as the shared registry currently reports it. `name` is remembered for the session so
    /// a row can still be labelled after the hardware is gone.
    struct Device: Equatable, Sendable {
        let id: InputDeviceID
        let name: String
    }

    /// What the HUD shows for one row. The player index is the *effective* slot, never the position
    /// in the global order — the two differ as soon as anything before it is disabled.
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
        /// The remembered choice, including for a disconnected row, where it is read-only.
        let isEnabled: Bool
        let state: RowState

        var playerIndex: Int? {
            if case .active(let playerIndex) = state { return playerIndex }
            return nil
        }
    }

    static let maximumPlayers = ControllerPlayerOrder.maximumPlayers

    private(set) var hasBegunSession = false
    private var names: [InputDeviceID: String] = [:]
    private var knownIDs: Set<InputDeviceID> = []
    private var enabledIDs: Set<InputDeviceID> = []
    /// Connected devices first seen after the session began, still awaiting an explicit decision.
    private var newlyIdentifiedIDs: Set<InputDeviceID> = []
    /// The shared order as of the last synchronization, so the rows and slots read one snapshot.
    private var connectedIDs: [InputDeviceID] = []
    /// This session's history: known devices that are no longer connected, oldest name first.
    private var disconnectedIDs: [InputDeviceID] = []

    var isEmpty: Bool { knownIDs.isEmpty }

    /// Opens the session. Everything connected when the stream starts is admitted enabled and
    /// remembered, which is what makes a later reconnect able to restore this stream's choice.
    mutating func beginSession(devices: [Device]) {
        hasBegunSession = true
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

    /// Folds in the current discovery set, in shared order.
    ///
    /// A device this session already knows keeps its choice, whether it is connected or was
    /// disconnected earlier. A device seen for the first time mid-session is admitted disabled and
    /// requires an explicit enable; it is never matched to an earlier device by name or model, so a
    /// changed identity becomes a new row rather than inheriting a selection. Returns the arrivals
    /// so the caller can announce them.
    @discardableResult
    mutating func synchronize(devices: [Device]) -> [Device] {
        guard hasBegunSession else {
            beginSession(devices: devices)
            return []
        }
        var arrivals: [Device] = []
        for device in devices {
            names[device.id] = device.name
            guard !knownIDs.contains(device.id) else { continue }
            knownIDs.insert(device.id)
            enabledIDs.remove(device.id)
            newlyIdentifiedIDs.insert(device.id)
            arrivals.append(device)
        }
        connectedIDs = devices.map(\.id)
        let connected = Set(connectedIDs)
        disconnectedIDs = knownIDs.subtracting(connected).sorted { $0.rawValue < $1.rawValue }
        return arrivals
    }

    /// Enabling clears the new-device prompt; disabling keeps the row and the remembered choice, so
    /// the same device can be re-enabled without a reconnect. Returns whether anything changed.
    @discardableResult
    mutating func setEnabled(_ enabled: Bool, for id: InputDeviceID) -> Bool {
        guard knownIDs.contains(id) else { return false }
        if enabled {
            newlyIdentifiedIDs.remove(id)
            return enabledIDs.insert(id).inserted
        }
        return enabledIDs.remove(id) != nil
    }

    func isEnabled(_ id: InputDeviceID) -> Bool { enabledIDs.contains(id) }
    func isNewlyIdentified(_ id: InputDeviceID) -> Bool { newlyIdentifiedIDs.contains(id) }
    func name(for id: InputDeviceID) -> String? { names[id] }
    func isConnected(_ id: InputDeviceID) -> Bool { connectedIDs.contains(id) }

    /// Enabled and connected, in the shared global order. This is the whole admitted set, not just
    /// the four that fit: everything past the fourth is the HUD's Waiting rows.
    var activeDeviceIDs: [InputDeviceID] {
        connectedIDs.filter { enabledIDs.contains($0) }
    }

    /// The effective Player 1–4 map: the first four admitted devices, in shared order, compacted so
    /// disabling one promotes the next waiting device rather than leaving a gap.
    var playerIndices: [InputDeviceID: Int] {
        Dictionary(uniqueKeysWithValues: activeDeviceIDs.prefix(Self.maximumPlayers).enumerated().map { ($0.element, $0.offset) })
    }

    func playerIndex(for id: InputDeviceID) -> Int? { playerIndices[id] }

    /// Connected rows in shared order, then this session's disconnected history.
    var rows: [Row] {
        let slots = playerIndices
        var rows = connectedIDs.map { id in
            Row(id: id, name: names[id] ?? "Controller", isEnabled: enabledIDs.contains(id),
                state: rowState(for: id, slots: slots))
        }
        rows += disconnectedIDs.map { id in
            Row(id: id, name: names[id] ?? "Controller", isEnabled: enabledIDs.contains(id), state: .disconnected)
        }
        return rows
    }

    private func rowState(for id: InputDeviceID, slots: [InputDeviceID: Int]) -> RowState {
        guard enabledIDs.contains(id) else {
            return newlyIdentifiedIDs.contains(id) ? .newlyIdentified : .disabled
        }
        return slots[id].map(RowState.active(playerIndex:)) ?? .waiting
    }
}
