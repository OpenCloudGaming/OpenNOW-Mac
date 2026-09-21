//  Controller mode's add-to-collection picker and its layered rename/delete/name editor, split out
//  of `ControllerCatalogOverlays` so that file stays under its length budget.

import SwiftUI

/// The pad's add-to-collection picker and editor. Rows toggle membership, the focused row's X
/// opens rename/delete, and the trailing row starts a new collection.
struct ControllerCollectionPickerOverlay: View {
    let viewModel: CatalogViewModel
    @ObservedObject var controller: ControllerCatalogViewModel
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let topInset: CGFloat
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    private var collections: [OPNUserCollection] { viewModel.sortedUserCollections }

    var body: some View {
        ZStack(alignment: .trailing) {
            OPNDesign.Surface.scrim.onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(
                    title: "Add to Collection",
                    subtitle: viewModel.selectedGame?.title ?? "Selected game",
                    glyphs: glyphs,
                    close: close
                )
                .padding(.horizontal, 22 * uiScale)
                .padding(.top, 22 + topInset)
                .padding(.bottom, 12 * uiScale)

                pickerStageView

                CatalogCollectionsLocalOnlyNote()
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.bottom, 20 * uiScale)
            }
            .frame(maxWidth: 460 * uiScale, maxHeight: .infinity, alignment: .topLeading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .leading) { Rectangle().fill(OPNDesign.accent).frame(width: 3) }
            .padding(.leading, layout.leadingInset)
            .padding(.trailing, layout.trailingInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private enum PickerStage: Equatable {
        case picker
        case keyboard
        case editor(ControllerCollectionEditor)
    }

    private var pickerStage: PickerStage {
        if controller.isCollectionNameKeyboardVisible { return .keyboard }
        if let editor = controller.collectionEditor { return .editor(editor) }
        return .picker
    }

    @ViewBuilder private var pickerStageView: some View {
        switch pickerStage {
        case .picker: pickerBody
        case .keyboard: nameEntryBody
        case .editor(let editor): editorBody(editor)
        }
    }

    private var pickerBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8 * uiScale) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    pickerRow(collection, index: index)
                }
                newCollectionRow
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.bottom, 18 * uiScale)
        }
    }

    private func pickerRow(_ collection: OPNUserCollection, index: Int) -> some View {
        let isFocused = index == controller.collectionPickerIndex
        let isMember = viewModel.selectedGame.map { viewModel.isInCollection($0, id: collection.id) } ?? false
        return Button {
            guard let game = viewModel.selectedGame else { return }
            viewModel.toggleMembership(collectionId: collection.id, game: game)
        } label: {
            HStack(spacing: 13 * uiScale) {
                Image(systemName: isMember ? "checkmark.square.fill" : "square")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(isFocused ? .black.opacity(0.86) : OPNDesign.accent)
                    .frame(width: 28 * uiScale)
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(collection.name)
                        .catalogFont(size: 15, weight: .bold)
                        .foregroundStyle(isFocused ? .black.opacity(0.88) : OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text(collection.memberCountText)
                        .catalogFont(size: 11, weight: .medium)
                        .foregroundStyle(isFocused ? .black.opacity(0.6) : OPNDesign.Text.tertiary)
                }
                Spacer(minLength: 0)
                if isFocused {
                    HStack(spacing: 5 * uiScale) {
                        ControllerGlyphPill(glyph: glyphs.search)
                        Text("OPTIONS")
                            .catalogFont(size: 10, weight: .bold)
                            .tracking(0.5)
                    }
                    .foregroundStyle(.black.opacity(0.86))
                }
            }
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 52 * uiScale)
            .background(isFocused ? OPNDesign.accent : OPNDesign.Fill.neutral(0.055))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    private var newCollectionRow: some View {
        let isFocused = controller.collectionPickerIndex == collections.count
        return Button {
            controller.beginCollectionNameFromView()
        } label: {
            HStack(spacing: 13 * uiScale) {
                Image(systemName: "plus.square")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(isFocused ? .black.opacity(0.86) : OPNDesign.accent)
                    .frame(width: 28 * uiScale)
                Text("New collection…")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(isFocused ? .black.opacity(0.88) : OPNDesign.Text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 52 * uiScale)
            .background(isFocused ? OPNDesign.accent : OPNDesign.Fill.neutral(0.055))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editorBody(_ editor: ControllerCollectionEditor) -> some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            switch editor {
            case .rowActions(let id):
                Text(viewModel.collection(id: id)?.name ?? "Collection")
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                editorButton(title: "Rename", index: 0, isDestructive: false) {
                    controller.beginCollectionNameFromView(renameID: id)
                }
                editorButton(title: "Delete", index: 1, isDestructive: true) {
                    controller.stageCollectionDeleteFromView(id: id)
                }
            case .confirmDelete(let id):
                Text("Delete “\(viewModel.collection(id: id)?.name ?? "this collection")”? Games in it stay in My Library, My Favorites and Recently Played.")
                    .catalogFont(size: 13, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                editorButton(title: "Cancel", index: 0, isDestructive: false) {
                    controller.cancelCollectionEditorFromView()
                }
                editorButton(title: "Delete", index: 1, isDestructive: true) {
                    controller.deleteCollectionFromView(id: id)
                }
            case .create, .rename:
                EmptyView()
            }
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.bottom, 18 * uiScale)
    }

    private func editorButton(title: String, index: Int, isDestructive: Bool, action: @escaping () -> Void) -> some View {
        let isFocused = index == controller.collectionEditorIndex
        return Button(action: action) {
            HStack(spacing: 10 * uiScale) {
                Text(title)
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(isFocused ? .black.opacity(0.88) : (isDestructive ? OPNDesign.Semantic.destructive : OPNDesign.Text.primary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 46 * uiScale)
            .background(isFocused ? OPNDesign.accent : OPNDesign.Fill.neutral(0.055))
            .overlay { Rectangle().stroke(isDestructive ? OPNDesign.Semantic.destructive.opacity(0.5) : OPNDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused)
        }
        .buttonStyle(.plain)
    }

    private var nameEntryBody: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            Text("NAME")
                .catalogFont(size: 10, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(OPNDesign.Text.tertiary)
            Text(controller.collectionNameDraft.isEmpty ? "…" : controller.collectionNameDraft)
                .catalogFont(size: 18, weight: .bold)
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14 * uiScale)
                .frame(height: 52 * uiScale)
                .background(OPNDesign.Fill.neutral(0.08))
                .overlay { Rectangle().stroke(OPNDesign.accent, lineWidth: 1) }
            if !viewModel.collectionsDialogError.isEmpty {
                Text(viewModel.collectionsDialogError)
                    .catalogFont(size: 12, weight: .medium)
                    .foregroundStyle(OPNDesign.Semantic.destructive)
            }
            Text("Type on the on-screen keyboard, then press Enter to save.")
                .catalogFont(size: 12, weight: .medium)
                .foregroundStyle(OPNDesign.Text.tertiary)
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.bottom, 18 * uiScale)
    }

}
