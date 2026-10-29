//  State of one Detach New Session window: which account it streams for and which controllers it
//  leaves out, until the reader moves on to the catalog.

import Foundation
import Observation

@MainActor
@Observable
final class DetachedSessionViewModel {
    enum Phase: Equatable {
        case setup
        case catalog(email: String)
    }

    private(set) var phase: Phase = .setup
    var selectedEmail: String?
    private(set) var disabledControllers: Set<InputDeviceID> = []
    var takesPadsFromOtherStreams: Bool

    private let preset: OPNStreamControllerPreset
    private let registry: OPNGameSessionRegistry
    private var pendingAccountID: OPNAccountID?
    private var pendingSelection: OPNStreamControllerSelection?

    init(preset: OPNStreamControllerPreset = .shared, hasOtherStreams: Bool = OPNGameSessionRegistry.shared.hasSessions, registry: OPNGameSessionRegistry = .shared) {
        self.preset = preset
        self.registry = registry
        takesPadsFromOtherStreams = hasOtherStreams
    }

    func setController(_ id: InputDeviceID, enabled: Bool) {
        if enabled {
            disabledControllers.remove(id)
        } else {
            disabledControllers.insert(id)
        }
    }

    func isControllerEnabled(_ id: InputDeviceID) -> Bool {
        !disabledControllers.contains(id)
    }

    /// Stores the controller choice under the account, where the stream finds it when it starts, and
    /// moves on to the catalog the account will launch from.
    func confirm(row: DetachedAccountRow, accountID: OPNAccountID) {
        guard row.availability.isSelectable else { return }
        discardPendingSelection()
        let controllerSelection = DetachedSessionModel.selection(disabled: disabledControllers, takesPadsFromOtherStreams: takesPadsFromOtherStreams)
        preset.store(controllerSelection, forAccount: accountID.rawValue)
        pendingAccountID = accountID
        pendingSelection = controllerSelection
        selectedEmail = row.email
        phase = .catalog(email: row.email)
    }

    func backToSetup() {
        discardPendingSelection()
        selectedEmail = nil
        phase = .setup
    }

    /// A choice made for a stream that never started must not reach a later launch by the same
    /// account. Once the account owns a game the stream has taken it, so there is nothing to drop.
    func discardPendingSelection() {
        let selectionAccountID = pendingAccountID
        let controllerSelection = pendingSelection
        pendingAccountID = nil
        pendingSelection = nil
        guard let selectionAccountID, let controllerSelection, !registry.isOwned(by: selectionAccountID),
              preset.peek(forAccount: selectionAccountID.rawValue) == controllerSelection else { return }
        preset.store(OPNStreamControllerSelection(), forAccount: selectionAccountID.rawValue)
    }
}
