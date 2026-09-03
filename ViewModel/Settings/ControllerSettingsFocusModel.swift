//  Pad focus for the settings surface: which row is focused, what order they traverse in, and the
//  command aimed at the focused row.
//
//  The SwiftUI modifier and environment keys that feed it stayed in `View/Settings`; only the
//  registry itself moved, because it is state, not presentation.
//

import Combine
import Foundation

/// Makes the Settings pages operable from a pad.
///
/// The settings surface is built from a handful of reusable rows, so rather than annotating every
/// page, each row type opts in once with `controllerFocusable`. Rows report their vertical position
/// through a preference, which is what gives the pad a traversal order that always matches what is
/// on screen - including rows that appear and disappear as other settings change - without any page
/// having to declare one.
@MainActor
final class ControllerSettingsFocusModel: ObservableObject {
    @Published private(set) var focusedID: String?
    @Published private(set) var isActive = false
    /// The latest command aimed at the focused row. Rows act on it from their current render, so
    /// they always read live values.
    @Published private(set) var rowCommand: ControllerPageCommand?

    private var orderedIDs: [String] = []
    private var commandSequence = 0

    /// Sends a command to whichever row is focused.
    ///
    /// Deliberately not a stored per-row closure: a closure captured when the row appeared holds
    /// that render's values forever, so a toggle's `activate` kept writing `!staleIsOn` and stopped
    /// having any effect after the first press. Publishing the command instead lets the row handle
    /// it from its current body, where `isOn`/`value`/`selectedIndex` are live.
    func send(_ command: ControllerInputCommand) {
        guard focusedID != nil else { return }
        commandSequence += 1
        rowCommand = ControllerPageCommand(command: command, sequence: commandSequence)
    }

    /// Called with every row's measured position; the pad walks them top to bottom.
    func setOrder(_ entries: [ControllerFocusEntry]) {
        let ids = entries.sorted { $0.y < $1.y }.map(\.id)
        guard ids != orderedIDs else { return }
        orderedIDs = ids
        guard let focusedID, !ids.contains(focusedID) else { return }
        self.focusedID = ids.first
    }

    /// Controller mode drives this; on the desktop surface it stays off so no focus ring appears.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active { focusedID = nil }
    }

    func focus(_ id: String) {
        guard orderedIDs.contains(id) else { return }
        focusedID = id
    }

    @discardableResult
    func focusFirstIfNeeded() -> Bool {
        guard focusedID == nil, let first = orderedIDs.first else { return false }
        focusedID = first
        return true
    }

    func move(delta: Int) {
        guard !orderedIDs.isEmpty else { return }
        guard let focusedID, let current = orderedIDs.firstIndex(of: focusedID) else {
            self.focusedID = orderedIDs.first
            return
        }
        let next = min(max(current + delta, 0), orderedIDs.count - 1)
        self.focusedID = orderedIDs[next]
    }

}
