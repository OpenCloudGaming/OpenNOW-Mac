//  Which controllers a stream should play with, decided before the stream exists.
//
//  The Detach New Session window picks an account and the pads to leave out of its stream. The
//  stream is created later, by the launch, so the choice waits here under the account's id and is
//  handed over once, when that account's stream first sees its controllers.

import Foundation

struct OPNStreamControllerSelection: Equatable, Sendable {
    /// Pads this stream leaves out.
    var disabled: Set<InputDeviceID> = []
    /// Whether the pads this stream plays with are taken out of every other live stream, so one
    /// tap sets a pad per player instead of the same pads answering in every window.
    var takesPadsFromOtherStreams = false

    /// The pads the new stream keeps, which are the ones the others give up.
    func handedOff(connected: [InputDeviceID]) -> Set<InputDeviceID> {
        guard takesPadsFromOtherStreams else { return [] }
        return Set(connected).subtracting(disabled)
    }
}

@MainActor
final class OPNStreamControllerPreset {
    static let shared = OPNStreamControllerPreset()

    private var selections: [String: OPNStreamControllerSelection] = [:]

    init() {}

    func store(_ selection: OPNStreamControllerSelection, forAccount accountID: String) {
        guard !accountID.isEmpty else { return }
        guard selection != OPNStreamControllerSelection() else {
            selections[accountID] = nil
            return
        }
        selections[accountID] = selection
    }

    func take(forAccount accountID: String) -> OPNStreamControllerSelection {
        selections.removeValue(forKey: accountID) ?? OPNStreamControllerSelection()
    }

    func peek(forAccount accountID: String) -> OPNStreamControllerSelection {
        selections[accountID] ?? OPNStreamControllerSelection()
    }
}
