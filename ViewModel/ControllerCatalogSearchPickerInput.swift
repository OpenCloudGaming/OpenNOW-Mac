//  Controller-mode input for the search overlay's sort and filter picker. Split out of
//  `ControllerCatalogInput` so the routing file stays under its length budget.
//

import Foundation

@MainActor
extension ControllerCatalogViewModel {
    // MARK: - Sort and filter picker

    func handleSearchPickerInput(_ command: ControllerInputCommand) {
        guard let searchPicker else { return }
        switch command {
        case .move(.up): searchPickerIndex = max(searchPickerIndex - 1, 0)
        case .move(.down): searchPickerIndex = min(searchPickerIndex + 1, max(searchPicker.options.count - 1, 0))
        case .confirm: applySearchPickerSelection(at: searchPickerIndex)
        case .back, .search, .menu, .actions: closeSearchPicker()
        default: break
        }
    }

    func openSortPicker() {
        guard let catalog else { return }
        let options = catalog.sortOptions.map { ControllerSearchPicker.Option(id: $0.id, label: $0.label) }
        guard !options.isEmpty else { return }
        searchPickerIndex = options.firstIndex { $0.id == catalog.selectedSortId } ?? 0
        searchPicker = ControllerSearchPicker(title: "Sort", kind: .sort, options: options)
    }

    func openFilterPicker(group: OPNCatalogFilterGroupObject) {
        guard let catalog, !group.options.isEmpty else { return }
        var options = [ControllerSearchPicker.Option(id: ControllerSearchPicker.clearOptionId, label: "None")]
        options.append(contentsOf: group.options.map { ControllerSearchPicker.Option(id: $0.id, label: $0.label) })
        searchPickerIndex = options.firstIndex { catalog.selectedFilterIds.contains($0.id) } ?? 0
        searchPicker = ControllerSearchPicker(title: group.label, kind: .filter(groupId: group.id), options: options)
    }

    func closeSearchPicker() {
        searchPicker = nil
    }

    func applySearchPickerSelection(at index: Int) {
        guard let catalog, let searchPicker, searchPicker.options.indices.contains(index) else { return }
        let option = searchPicker.options[index]
        switch searchPicker.kind {
        case .sort:
            catalog.setSort(option.id)
        case .filter(let groupId):
            guard let group = catalog.visibleFilterGroups.first(where: { $0.id == groupId }) else { break }
            // One option per group: clear whatever this group already had before applying. "None"
            // stops there, which is how a group gets turned back off.
            for existing in group.options where catalog.selectedFilterIds.contains(existing.id) {
                catalog.toggleFilter(existing.id)
            }
            if option.id != ControllerSearchPicker.clearOptionId, !catalog.selectedFilterIds.contains(option.id) {
                catalog.toggleFilter(option.id)
            }
        }
        closeSearchPicker()
    }
}
