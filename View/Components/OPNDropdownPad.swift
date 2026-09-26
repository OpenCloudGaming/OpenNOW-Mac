//  The pad contract shared by the two dropdown components: the catalog menu (`OPNDropdownMenu`,
//  Settings/Catalog/Screenshots/Recordings) and the stream HUD's own (`StreamHUDDropdown`).
//
//  The rows and the open/highlight state live here rather than in either component because a
//  controller handler has to walk and commit rows before anything is drawn, and both components have
//  to select from one definition — the model's.
//

import Foundation

/// One row of a pad-drivable dropdown, owned by the model rather than the view.
struct OPNDropdownPadItem {
    let id: String
    let title: String
    var isSelected = false
    var isDestructive = false
    var startsGroup = false
    let action: () -> Void
}

/// Lets a pad-driven host own a dropdown's open state and highlighted row. A dropdown with no driver
/// is pointer-only, exactly as every dropdown was before, with its own internal open state.
struct OPNDropdownPadDriver<Value: Hashable> {
    /// Whether the panel is drawn.
    let isPresented: Bool
    /// The row the pad stands on, or nil when the panel just opened on nothing selectable.
    let highlightedValue: Value?
    /// Opens or closes the panel — a click on the trigger, and the pad's confirm on the trigger.
    let toggle: () -> Void
    /// Closes without selecting — an outside click, Escape, or the pad's cancel.
    let close: () -> Void
}
