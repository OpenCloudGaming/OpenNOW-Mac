//  Cycling a value forward through its options, the shape every "cycle this control" HUD row and
//  shortcut handler uses. One implementation rather than an index lookup re-derived per control.
//

import Foundation

extension Array where Element: Equatable {
    /// The element after `current`, wrapping to the first so a one-action-per-press control cycles
    /// instead of stopping at the end. Returns `current` unchanged when there is nothing to cycle.
    func wrappingNext(after current: Element) -> Element {
        guard !isEmpty else { return current }
        guard let index = firstIndex(of: current) else { return self[0] }
        return self[(index + 1) % count]
    }
}
