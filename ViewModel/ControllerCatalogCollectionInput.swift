//  Controller-mode input for the add-to-collection picker and its rename/delete/name editor, split
//  out of `ControllerCatalogInput` so the routing file stays under its length budget.

import Foundation

@MainActor
extension ControllerCatalogViewModel {
    // MARK: - Collections

    func openCollectionPicker(game: OPNCatalogGameObject) {
        guard let catalog else { return }
        catalog.revealCollectionsLocalOnlyNotice()
        closeCollectionNameEditor()
        collectionNameDraft = ""
        collectionPickerIndex = 0
        isCollectionPickerVisible = true
    }

    func closeCollectionPicker() {
        isCollectionPickerVisible = false
        closeCollectionNameEditor()
        collectionNameDraft = ""
    }

    /// View-facing entry points, so the overlay's row chips do not have to know the editor model.
    func beginCollectionNameFromView(renameID: String? = nil) {
        beginCollectionName(editor: renameID.map { ControllerCollectionEditor.rename(id: $0) } ?? .create)
    }

    func stageCollectionDeleteFromView(id: String) {
        collectionEditor = .confirmDelete(id: id)
        collectionEditorIndex = 0
    }

    func cancelCollectionEditorFromView() {
        collectionEditor = nil
    }

    func deleteCollectionFromView(id: String) {
        catalog?.deleteCollection(id: id)
        collectionEditor = nil
        collectionPickerIndex = min(collectionPickerIndex, max((catalog?.sortedUserCollections.count ?? 1) - 1, 0))
    }

    func handleCollectionPickerInput(_ command: ControllerInputCommand) {
        guard let catalog else { return }
        if isCollectionNameKeyboardVisible {
            handleCollectionNameKeyboardInput(command)
            return
        }
        if collectionEditor != nil {
            handleCollectionEditorInput(command)
            return
        }
        let collections = catalog.sortedUserCollections
        switch command {
        case .move(.up):
            collectionPickerIndex = max(collectionPickerIndex - 1, 0)
        case .move(.down):
            collectionPickerIndex = min(collectionPickerIndex + 1, max(collections.count, 0))
        case .confirm:
            confirmCollectionPickerSelection(collections: collections, catalog: catalog)
        case .search:
            openCollectionRowActions(collections: collections)
        case .back, .menu, .actions:
            closeCollectionPicker()
        default:
            break
        }
    }

    /// Confirming a collection toggles the game's membership; confirming the trailing row starts a
    /// new collection instead.
    private func confirmCollectionPickerSelection(collections: [OPNUserCollection], catalog: CatalogViewModel) {
        guard collections.indices.contains(collectionPickerIndex), let game = catalog.selectedGame else {
            beginCollectionName(editor: .create)
            return
        }
        catalog.toggleMembership(collectionId: collections[collectionPickerIndex].id, game: game)
    }

    private func openCollectionRowActions(collections: [OPNUserCollection]) {
        guard collections.indices.contains(collectionPickerIndex) else { return }
        collectionEditor = .rowActions(id: collections[collectionPickerIndex].id)
        collectionEditorIndex = 0
    }

    func handleCollectionEditorInput(_ command: ControllerInputCommand) {
        guard let editor = collectionEditor else { return }
        switch editor {
        case .rowActions(let id): handleCollectionRowActionsInput(command, id: id)
        case .confirmDelete(let id): handleCollectionDeleteConfirmInput(command, id: id)
        case .create, .rename: handleCollectionNameEditorInput(command)
        }
    }

    private func handleCollectionRowActionsInput(_ command: ControllerInputCommand, id: String) {
        switch command {
        case .move(.up), .move(.left):
            collectionEditorIndex = 0
        case .move(.down), .move(.right):
            collectionEditorIndex = 1
        case .confirm:
            guard collectionEditorIndex == 0 else {
                collectionEditor = .confirmDelete(id: id)
                collectionEditorIndex = 0
                return
            }
            beginCollectionName(editor: .rename(id: id))
        case .back, .menu, .actions:
            collectionEditor = nil
        default:
            break
        }
    }

    private func handleCollectionDeleteConfirmInput(_ command: ControllerInputCommand, id: String) {
        switch command {
        case .move(.up), .move(.left):
            collectionEditorIndex = 0
        case .move(.down), .move(.right):
            collectionEditorIndex = 1
        case .confirm:
            if collectionEditorIndex == 1 { catalog?.deleteCollection(id: id) }
            collectionEditor = nil
            collectionPickerIndex = min(collectionPickerIndex, max((catalog?.sortedUserCollections.count ?? 1) - 1, 0))
        case .back, .menu, .actions:
            collectionEditor = nil
        default:
            break
        }
    }

    private func handleCollectionNameEditorInput(_ command: ControllerInputCommand) {
        switch command {
        case .confirm:
            commitCollectionName()
        case .back, .menu, .actions:
            isCollectionNameKeyboardVisible = false
            collectionEditor = nil
        default:
            break
        }
    }

    func beginCollectionName(editor: ControllerCollectionEditor) {
        guard let catalog else { return }
        collectionEditor = editor
        collectionEditorIndex = 0
        switch editor {
        case .rename(let id):
            collectionNameDraft = catalog.collection(id: id)?.name ?? ""
        default:
            collectionNameDraft = ""
        }
        configureCollectionNameKeyboard()
        searchKeyboard.reset()
        isCollectionNameKeyboardVisible = true
    }

    func commitCollectionName() {
        guard let catalog, let editor = collectionEditor else {
            isCollectionNameKeyboardVisible = false
            return
        }
        switch editor {
        case .create:
            guard let created = catalog.createCollection(name: collectionNameDraft) else { return }
            closeCollectionNameEditor()
            collectionPickerIndex = catalog.sortedUserCollections.firstIndex(where: { $0.id == created.id }) ?? collectionPickerIndex
        case .rename(let id):
            guard catalog.renameCollection(id: id, name: collectionNameDraft) else { return }
            closeCollectionNameEditor()
        default:
            closeCollectionNameEditor()
        }
    }

    private func closeCollectionNameEditor() {
        isCollectionNameKeyboardVisible = false
        collectionEditor = nil
    }

    /// The on-screen keyboard is shared with search, so this rebinds its output to the name draft
    /// while a collection is being created or renamed. Search rebinds it back when it opens.
    func configureCollectionNameKeyboard() {
        searchKeyboard.onOutput = { [weak self] output in
            guard let self else { return }
            switch output {
            case .text(let text):
                self.collectionNameDraft.append(text)
            case .keyPress(let keyCode):
                switch keyCode {
                case 51: // backspace
                    guard !self.collectionNameDraft.isEmpty else { return }
                    self.collectionNameDraft.removeLast()
                case 36, 76: // return / enter
                    self.commitCollectionName()
                default:
                    break
                }
            }
        }
        searchKeyboard.onDismiss = { [weak self] in
            self?.isCollectionNameKeyboardVisible = false
            self?.collectionEditor = nil
        }
    }

    private func handleCollectionNameKeyboardInput(_ command: ControllerInputCommand) {
        switch command {
        case .move(.up): searchKeyboard.handleNavigationAction(.move(dx: 0, dy: -1))
        case .move(.down): searchKeyboard.handleNavigationAction(.move(dx: 0, dy: 1))
        case .move(.left): searchKeyboard.handleNavigationAction(.move(dx: -1, dy: 0))
        case .move(.right): searchKeyboard.handleNavigationAction(.move(dx: 1, dy: 0))
        case .confirm: searchKeyboard.handleNavigationAction(.activate)
        case .actions: searchKeyboard.handleNavigationAction(.backspace)
        case .pageLeft: searchKeyboard.handleNavigationAction(.shift)
        case .pageRight: searchKeyboard.handleNavigationAction(.space)
        case .back, .search, .menu:
            isCollectionNameKeyboardVisible = false
            collectionEditor = nil
        }
    }
}
