import SwiftUI

/// The Collections tab: the account's collections, and the games inside one of them. Collections are
/// local, so the list paints at once; members' titles and box art need the catalog.
struct OPNMenuBarCollectionsCard: View {
    @ObservedObject var session: OPNMenuBarSessionModel
    @Binding var selectedCollectionId: String?
    let onLaunchGame: (OPNMenuBarGame) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            if let collection = selectedCollection {
                detail(collection)
            } else {
                list
            }
        }
        .opnMenuBarCard()
    }

    /// The open detail's collection, or nil when there is none to show — which is also what a just
    /// deleted collection resolves to, so the card returns to the list by itself.
    private var selectedCollection: OPNMenuBarCollection? {
        guard let selectedCollectionId else { return nil }
        return session.collections.first { $0.id == selectedCollectionId }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            OPNMenuBarEyebrow(text: "COLLECTIONS")
            if session.collections.isEmpty {
                OPNMenuBarEmptyText(text: "Collections you create show up here.")
            } else {
                OPNMenuBarCappedList(rowCount: session.collections.count) {
                    collectionRows
                }
            }
        }
    }

    private var collectionRows: some View {
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            ForEach(session.collections) { collection in
                collectionButton(collection)
            }
        }
    }

    private func collectionButton(_ collection: OPNMenuBarCollection) -> some View {
        Button { open(collection) } label: {
            HStack(spacing: 9) {
                OPNMenuBarCollectionTile(icon: collection.resolvedIcon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(collection.name)
                        .font(.opnUI(size: 12.5, weight: .semibold))
                        .foregroundStyle(OPNDesign.Text.primary)
                        .lineLimit(1)
                    Text(gameCountText(collection.gameCount))
                        .font(.opnUI(size: 10.5, weight: .medium))
                        .foregroundStyle(OPNDesign.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.opnUI(size: 10, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.muted)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: OPNMenuBarListMetrics.rowHeight)
            .opnMenuBarRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open collection \(collection.name), \(gameCountText(collection.gameCount))")
    }

    // MARK: - Detail

    private func detail(_ collection: OPNMenuBarCollection) -> some View {
        VStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
            backButton
            detailHeader(collection)
            detailBody(collection)
        }
        // A new identity per collection, so opening another one starts its list at the top.
        .id(collection.id)
    }

    @ViewBuilder private func detailBody(_ collection: OPNMenuBarCollection) -> some View {
        if collection.games.isEmpty {
            OPNMenuBarEmptyText(text: emptyDetailText(for: collection))
        } else {
            resolvedGames(collection)
        }
    }

    @ViewBuilder private func resolvedGames(_ collection: OPNMenuBarCollection) -> some View {
        OPNMenuBarCappedList(rowCount: collection.games.count) {
            LazyVStack(alignment: .leading, spacing: OPNMenuBarListMetrics.rowSpacing) {
                ForEach(collection.games) { game in
                    OPNMenuBarGameButton(game: game, isEnabled: session.canLaunchCollections) {
                        onLaunchGame(game)
                    }
                }
            }
        }
        if let partialText = partialDetailText(for: collection) {
            OPNMenuBarEmptyText(text: partialText)
        }
    }

    private var backButton: some View {
        Button { closeDetail() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.opnUI(size: 9, weight: .bold))
                OPNMenuBarEyebrow(text: "COLLECTIONS")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Collections")
    }

    private func detailHeader(_ collection: OPNMenuBarCollection) -> some View {
        HStack(spacing: 9) {
            OPNMenuBarCollectionTile(icon: collection.resolvedIcon)
            VStack(alignment: .leading, spacing: 1) {
                Text(collection.name)
                    .font(.opnUI(size: 13.5, weight: .bold))
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Text(gameCountText(collection.gameCount))
                    .font(.opnUI(size: 10.5, weight: .medium))
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
    }

    /// What a detail with no rows to show has to say: an empty collection, members still resolving,
    /// or members the catalog does not carry.
    private func emptyDetailText(for collection: OPNMenuBarCollection) -> String {
        if collection.gameCount == 0 { return "This collection is empty." }
        if session.isResolvingCollectionGames { return "Loading games…" }
        return unavailableGamesText(unresolvedCount: collection.gameCount)
    }

    /// What a partially resolved detail adds below its rows, or nil when every member is shown.
    private func partialDetailText(for collection: OPNMenuBarCollection) -> String? {
        let unresolvedCount = max(0, collection.gameCount - collection.games.count)
        guard unresolvedCount > 0 else { return nil }
        if session.isResolvingCollectionGames { return loadingGamesText(resolvingCount: unresolvedCount) }
        return unavailableGamesText(unresolvedCount: unresolvedCount)
    }

    private func loadingGamesText(resolvingCount: Int) -> String {
        if resolvingCount == 1 { return "Loading 1 more game…" }
        return "Loading \(resolvingCount) more games…"
    }

    private func unavailableGamesText(unresolvedCount: Int) -> String {
        if unresolvedCount == 1 { return "1 game is not available right now." }
        return "\(unresolvedCount) games are not available right now."
    }

    private func gameCountText(_ count: Int) -> String {
        if count == 1 { return "1 game" }
        return "\(count) games"
    }

    private func open(_ collection: OPNMenuBarCollection) {
        withAnimation(OPNDesign.Motion.toggle) { selectedCollectionId = collection.id }
    }

    private func closeDetail() {
        withAnimation(OPNDesign.Motion.toggle) { selectedCollectionId = nil }
    }
}

/// A collection's glyph in a tile shaped like a game row's artwork, so the two lists read as one kind
/// of row.
private struct OPNMenuBarCollectionTile: View {
    let icon: OPNCollectionIcon

    var body: some View {
        OPNCollectionIconView(icon: icon, size: 16)
            .frame(width: 34, height: 34)
            .background(OPNDesign.Fill.neutral(0.08))
            // swiftlint:disable:next design_no_corner_radius -- status-item popover chrome: icon tiles match the Control Center cards this surface is modelled on
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
