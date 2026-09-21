//  The desktop surfaces for locally-owned collections: the per-game picker, the manager's
//  create/rename/delete dialog, and the warning that a collection is not backed up.

import SwiftUI

extension OPNUserCollection {
    /// The member count as every collection surface words it.
    var memberCountText: String {
        gameIds.count == 1 ? "1 game" : "\(gameIds.count) games"
    }
}

/// The warning shown wherever a collection is created, edited or opened. It renders nothing once
/// iCloud sync is carrying the catalog, so a reader is never told to back up what is already backed up.
struct CatalogCollectionsLocalOnlyNote: View {
    @Environment(\.opnUIScale) private var uiScale
    @AppStorage(OPNCloudSyncPreferences.enabledKey) private var isSyncEnabled = false
    @AppStorage(OPNCloudSyncPreferences.categoryKey(.catalog)) private var isCatalogSyncEnabled = true

    var body: some View {
        if !isCatalogBackedUp {
            HStack(alignment: .top, spacing: 7 * uiScale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .catalogFont(size: 11, weight: .bold)
                Text("iCloud Sync is off, so these collections live only on this Mac. Turn it on in Settings › iCloud to back them up.")
                    .catalogFont(size: 12, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(OPNDesign.Semantic.warning)
        }
    }

    private var isCatalogBackedUp: Bool { isSyncEnabled && isCatalogSyncEnabled }
}

/// The empty state a collection with no resolvable members draws instead of a blank grid.
struct CatalogEmptyCollectionView: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * uiScale) {
            HStack(spacing: 12 * uiScale) {
                Image(systemName: "square.stack.3d.up.fill")
                    .catalogFont(size: 22, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                VStack(alignment: .leading, spacing: 4 * uiScale) {
                    Text("Nothing in this collection yet")
                        .catalogFont(size: 24, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                    Text("Open a game's detail panel and use Add to collection to put it here.")
                        .catalogFont(size: 14, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
            }
            Button("BROWSE GAMES") { viewModel.closeShowAll() }
                .buttonStyle(VendorLaunchSecondaryButtonStyle())
                .padding(.top, 4 * uiScale)
        }
        .padding(22 * uiScale)
        .frame(maxWidth: 620, alignment: .leading)
        .background(OPNDesign.Fill.neutral(0.055))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 24 * uiScale)
    }
}

/// Picker for the selected game: one row per collection, checked when the game is a member, plus a
/// row that starts a new collection without leaving the panel.
struct CatalogCollectionsPickerOverlay: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismissCollectionsPicker() }

            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8 * uiScale) {
                        if viewModel.userCollections.isEmpty {
                            Text("No collections yet. Start one below.")
                                .catalogFont(size: 13, weight: .medium)
                                .foregroundStyle(OPNDesign.Text.tertiary)
                                .padding(.vertical, 6 * uiScale)
                        }
                        ForEach(viewModel.sortedUserCollections) { collection in
                            collectionRow(collection)
                        }
                        newCollectionRow
                    }
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.vertical, 16 * uiScale)
                }

                Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)
                footer
            }
            .frame(width: min(520 * uiScale, 520), alignment: .topLeading)
            .frame(maxHeight: 560 * uiScale, alignment: .topLeading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OPNDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
        .opnMotion(OPNDesign.Motion.panel, value: viewModel.isCollectionsPickerPresented)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            Text("ADD TO COLLECTION")
                .catalogFont(size: 11, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(OPNDesign.accentInk)
            Text(viewModel.selectedGame?.title ?? "Selected Game")
                .catalogFont(size: 19, weight: .bold)
                .foregroundStyle(OPNDesign.Text.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 16 * uiScale)
    }

    private func collectionRow(_ collection: OPNUserCollection) -> some View {
        let isMember = viewModel.selectedGame.map { viewModel.isInCollection($0, id: collection.id) } ?? false
        return Button {
            guard let game = viewModel.selectedGame else { return }
            viewModel.toggleMembership(collectionId: collection.id, game: game)
        } label: {
            HStack(spacing: 12 * uiScale) {
                Image(systemName: isMember ? "checkmark.square.fill" : "square")
                    .catalogFont(size: 16, weight: .bold)
                    .foregroundStyle(isMember ? OPNDesign.accentInk : OPNDesign.Text.secondary)
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(collection.name)
                        .catalogFont(size: 14, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text(collection.memberCountText)
                        .catalogFont(size: 11, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 48 * uiScale)
            .background(isMember ? OPNDesign.Fill.neutral(0.10) : OPNDesign.Fill.neutral(0.045))
            .overlay { Rectangle().stroke(isMember ? OPNDesign.accent.opacity(0.6) : OPNDesign.Stroke.subtle, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newCollectionRow: some View {
        Button {
            viewModel.presentCollectionsDialog(.create)
        } label: {
            HStack(spacing: 12 * uiScale) {
                Image(systemName: "plus.square")
                    .catalogFont(size: 16, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                Text("New collection…")
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 48 * uiScale)
            .background(OPNDesign.Fill.neutral(0.045))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12 * uiScale) {
            CatalogCollectionsLocalOnlyNote()
            Spacer(minLength: 0)
            Button("DONE") { viewModel.dismissCollectionsPicker() }
                .buttonStyle(VendorLaunchSecondaryButtonStyle())
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 14 * uiScale)
    }

}

/// Create, rename and delete, over the collections list.
struct CatalogCollectionsManagerOverlay: View {
    let viewModel: CatalogViewModel
    let close: () -> Void
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8 * uiScale) {
                        ForEach(viewModel.sortedUserCollections) { collection in
                            managerRow(collection)
                        }
                        newCollectionRow
                    }
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.vertical, 16 * uiScale)
                }

                Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)
                HStack {
                    CatalogCollectionsLocalOnlyNote()
                    Spacer(minLength: 0)
                    Button("DONE", action: close)
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                }
                .padding(.horizontal, 22 * uiScale)
                .padding(.vertical, 14 * uiScale)
            }
            .frame(width: min(560 * uiScale, 560), alignment: .topLeading)
            .frame(maxHeight: 600 * uiScale, alignment: .topLeading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OPNDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            Text("COLLECTIONS")
                .catalogFont(size: 11, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(OPNDesign.accentInk)
            Text("Manage your local collections")
                .catalogFont(size: 19, weight: .bold)
                .foregroundStyle(OPNDesign.Text.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 16 * uiScale)
    }

    private func managerRow(_ collection: OPNUserCollection) -> some View {
        HStack(spacing: 12 * uiScale) {
            Button {
                viewModel.openUserCollection(id: collection.id)
                close()
            } label: {
                VStack(alignment: .leading, spacing: 2 * uiScale) {
                    Text(collection.name)
                        .catalogFont(size: 14, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text(collection.memberCountText)
                        .catalogFont(size: 11, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            iconButton("pencil", label: "Rename \(collection.name)") {
                viewModel.presentCollectionsDialog(.rename(id: collection.id))
            }
            iconButton("trash", label: "Delete \(collection.name)", isDestructive: true) {
                viewModel.presentCollectionsDialog(.delete(id: collection.id))
            }
        }
        .padding(.horizontal, 13 * uiScale)
        .frame(height: 52 * uiScale)
        .background(OPNDesign.Fill.neutral(0.045))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
    }

    private var newCollectionRow: some View {
        Button {
            viewModel.presentCollectionsDialog(.create)
        } label: {
            HStack(spacing: 12 * uiScale) {
                Image(systemName: "plus.square")
                    .catalogFont(size: 16, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                Text("New collection…")
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13 * uiScale)
            .frame(height: 48 * uiScale)
            .background(OPNDesign.Fill.neutral(0.045))
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(_ systemName: String, label: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .catalogFont(size: 14, weight: .bold)
                .foregroundStyle(isDestructive ? OPNDesign.Semantic.destructive : OPNDesign.Text.secondary)
                .frame(width: 34 * uiScale, height: 34 * uiScale)
                .background(OPNDesign.Fill.neutral(0.08))
                .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

}

/// The create/rename/delete dialog, drawn over whatever raised it.
struct CatalogCollectionsDialogOverlay: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { viewModel.cancelCollectionsDialog() }

            VStack(alignment: .leading, spacing: 16 * uiScale) {
                Text(title)
                    .catalogFont(size: 18, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)

                switch viewModel.collectionsDialog {
                case .delete(let id):
                    Text("Delete “\(viewModel.collection(id: id)?.name ?? "this collection")”? Games in it stay in My Library, My Favorites and Recently Played.")
                        .catalogFont(size: 13, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    TextField("Collection name", text: $viewModel.collectionsDraftName)
                        .textFieldStyle(.plain)
                        .catalogFont(size: 15, weight: .medium)
                        .foregroundStyle(OPNDesign.Text.primary)
                        .padding(.horizontal, 12 * uiScale)
                        .frame(height: 44 * uiScale)
                        .background(OPNDesign.Fill.neutral(0.08))
                        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
                        .onSubmit { viewModel.confirmCollectionsDialog() }
                    if !viewModel.collectionsDialogError.isEmpty {
                        Text(viewModel.collectionsDialogError)
                            .catalogFont(size: 12, weight: .medium)
                            .foregroundStyle(OPNDesign.Semantic.destructive)
                    }
                }

                HStack(spacing: 10 * uiScale) {
                    Spacer(minLength: 0)
                    Button("CANCEL") { viewModel.cancelCollectionsDialog() }
                        .buttonStyle(VendorLaunchSecondaryButtonStyle())
                    Button(isDestructive ? "DELETE" : "SAVE") { viewModel.confirmCollectionsDialog() }
                        .buttonStyle(VendorGetInButtonStyle())
                }
            }
            .padding(22 * uiScale)
            .frame(width: min(440 * uiScale, 440), alignment: .leading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OPNDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
    }

    private var title: String {
        switch viewModel.collectionsDialog {
        case .create: return "New collection"
        case .rename: return "Rename collection"
        case .delete: return "Delete collection?"
        case .none: return ""
        }
    }

    private var isDestructive: Bool {
        if case .delete = viewModel.collectionsDialog { return true }
        return false
    }
}

/// The one-time explainer. Shown the first time the reader touches collections, never again.
struct CatalogCollectionsNoticeOverlay: View {
    let viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16 * uiScale) {
                HStack(spacing: 10 * uiScale) {
                    Image(systemName: "externaldrive.fill")
                        .catalogFont(size: 16, weight: .bold)
                        .foregroundStyle(OPNDesign.accentInk)
                    Text("Collections live on this Mac")
                        .catalogFont(size: 18, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.primary)
                }
                Text("Your collections are stored only on this Mac. They are not saved to your NVIDIA account, not synced between devices, and signing in somewhere else will not bring them back.")
                    .catalogFont(size: 13, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Turn on iCloud Sync in Settings › iCloud to keep them safe, or back them up yourself. There is no NVIDIA server copy to restore from.")
                    .catalogFont(size: 13, weight: .semibold)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer(minLength: 0)
                    Button("GOT IT") { viewModel.dismissCollectionsLocalOnlyNotice() }
                        .buttonStyle(VendorGetInButtonStyle())
                }
            }
            .padding(24 * uiScale)
            .frame(width: min(480 * uiScale, 480), alignment: .leading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OPNDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
    }
}
