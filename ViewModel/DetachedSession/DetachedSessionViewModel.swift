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

    init(preset: OPNStreamControllerPreset = .shared, hasOtherStreams: Bool = OPNGameSessionRegistry.shared.hasSessions) {
        self.preset = preset
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
        preset.store(
            DetachedSessionModel.selection(disabled: disabledControllers, takesPadsFromOtherStreams: takesPadsFromOtherStreams),
            forAccount: accountID.rawValue
        )
        phase = .catalog(email: row.email)
    }

    func backToSetup(accountID: OPNAccountID?) {
        discardPendingSelection(for: accountID)
        phase = .setup
    }

    /// A choice made for a stream that never started must not reach a later launch by the same
    /// account. Once the account owns a game the stream has taken it, so there is nothing to drop.
    func discardPendingSelection(for accountID: OPNAccountID?) {
        guard let accountID, !OPNGameSessionRegistry.shared.isOwned(by: accountID) else { return }
        preset.store(OPNStreamControllerSelection(), forAccount: accountID.rawValue)
    }
}
