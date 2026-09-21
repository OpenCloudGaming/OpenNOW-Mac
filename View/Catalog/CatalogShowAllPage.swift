import SwiftUI

struct CatalogShowAllPage: View {
    @Bindable var viewModel: CatalogViewModel
    let onBack: () -> Void
    @State private var isSortMenuPresented = false
    @AppStorage(OPNHomeLayout.modeKey) private var homeLayoutRawValue = OPNHomeLayout.Mode.classic.rawValue

    private var isPosterLayout: Bool {
        (OPNHomeLayout.Mode(rawValue: homeLayoutRawValue) ?? .classic) == .poster
    }

    private func gridImageURL(for game: OPNCatalogGameObject) -> URL? {
        guard isPosterLayout else { return viewModel.optimizedImageURL(game.bestWideImageURL, width: 620) }
        return viewModel.optimizedImageURL(game.bestPosterImageURL, width: 512)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    mainColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if !viewModel.isShowingLocalCollection {
                        CatalogShowAllFilterPanel(viewModel: viewModel)
                            .frame(width: 280)
                            .background(OPNDesign.Surface.overlay)
                            .overlay(alignment: .leading) { Rectangle().fill(OPNDesign.Stroke.subtle).frame(width: 1) }
                    }
                }
                if isSortMenuPresented {
                    CatalogSortDropdownOverlay(viewModel: viewModel, isPresented: $isSortMenuPresented, screenWidth: proxy.size.width)
                }
            }
        }
        .background(OPNDesign.Surface.app)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // Above the back button and the sort control, not between the header and the grid: a
            // banner sitting over the tiles reads as part of the results, and the results are the
            // one thing on this page that keeps moving. Show All replaces the whole home body,
            // banner included, so without this a launch refused by the seat had nowhere to appear.
            errorBanner
            header
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(height: 1)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 2)
                if viewModel.showsCatalogLoadingIndicator {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(OPNDesign.accent)
                        .frame(height: 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.showsCatalogLoadingIndicator)
            let showsSkeleton = !viewModel.isShowingLocalCollection && viewModel.isLoading && viewModel.catalogGames.isEmpty
            let showsEmptyCollection = !showsSkeleton && viewModel.displayedShowAllGames.isEmpty
            let showsGrid = !showsSkeleton && !showsEmptyCollection
            if showsSkeleton {
                CatalogGridSkeletonView(isPosterLayout: isPosterLayout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
            if showsEmptyCollection {
                CatalogEmptyCollectionView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showsGrid {
                CatalogShowAllGridView(
                    viewModel: viewModel,
                    games: viewModel.displayedShowAllGames,
                    selectedGame: viewModel.selectedGame,
                    isQueuedForPatching: { viewModel.isQueuedForPatching($0) },
                    imageURL: { gridImageURL(for: $0) },
                    onSelect: { viewModel.toggleGameSelection($0, inSection: viewModel.selectedShowAllSection?.id ?? "") },
                    onPlay: { viewModel.launch(game: $0) },
                    onMarkOwned: { game in
                        viewModel.selectGame(game, inSection: viewModel.selectedShowAllSection?.id ?? "")
                        viewModel.handleUnownedSelectedVariantPrimaryAction()
                    },
                    onQueueForPatching: { viewModel.queuePatchingLaunch(game: $0) }
                )
                .opacity(viewModel.isRefetchingCatalog ? 0.45 : 1)
                .animation(.easeOut(duration: 0.2), value: viewModel.isRefetchingCatalog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var errorBanner: some View {
        let message = viewModel.displayedErrorMessage
        if !message.isEmpty {
            CatalogMessageView(
                message: message,
                systemImage: "exclamationmark.triangle.fill",
                diagnosticsState: viewModel.diagnosticsState,
                onGenerateDiagnostics: {
                    viewModel.presentDiagnosticsUploadConfirmation(context: message)
                },
                onDismiss: { viewModel.dismissLaunchError() }
            )
            .padding(.horizontal, 22)
            .padding(.top, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Button(action: onBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                        Text("BACK")
                    }
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                }
                .buttonStyle(.plain)
                Spacer()
                if !viewModel.isShowingLocalCollection {
                    sortMenu
                }
            }
            .frame(height: 44)

            HStack(spacing: 12) {
                Text(resultCount)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.tertiary)
                Spacer(minLength: 0)
            }
            if viewModel.isShowingLocalCollection {
                localOnlyNote
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var resultCount: String {
        let count = viewModel.isShowingLocalCollection
            ? viewModel.displayedShowAllGames.count
            : (viewModel.totalCatalogCount > 0 ? viewModel.totalCatalogCount : viewModel.catalogGames.count)
        return count == 1 ? "1 game" : "\(count) games"
    }

    private var localOnlyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "externaldrive.fill")
                    .catalogFont(size: 11, weight: .bold)
                Text("Stored on this Mac only. Not synced to NVIDIA. Back up your collections yourself.")
                    .catalogFont(size: 12, weight: .medium)
            }
            .foregroundStyle(OPNDesign.Text.secondary)
            if viewModel.localShowAllUnavailableCount > 0 {
                Text("\(viewModel.localShowAllUnavailableCount) of these games aren't in your loaded catalog right now.")
                    .catalogFont(size: 12, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.tertiary)
            }
        }
    }

    private var sortMenu: some View {
        Button { isSortMenuPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                Image(systemName: "chevron.down")
            }
            .catalogFont(size: 12, weight: .bold)
            .foregroundStyle(OPNDesign.Text.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(OPNDesign.Fill.neutral(0.08))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.sortOptions.isEmpty)
    }
}

private struct CatalogSortDropdownOverlay: View {
    let viewModel: CatalogViewModel
    @Binding var isPresented: Bool
    let screenWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }

                CatalogSortDropdownPanel(viewModel: viewModel, isPresented: $isPresented)
                    .padding(.top, 70)
                    .padding(.trailing, 280 + 22)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onExitCommand { isPresented = false }
    }
}

private struct CatalogSortDropdownPanel: View {
    let viewModel: CatalogViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.sortOptions, id: \.id) { option in
                let selected = viewModel.selectedSortId == option.id
                let label = option.label.isEmpty ? option.id : option.label
                Button {
                    viewModel.setSort(option.id)
                    isPresented = false
                } label: {
                    HStack(spacing: 12) {
                        Text(label)
                            .catalogFont(size: 14, weight: selected ? .bold : .medium)
                            .foregroundStyle(selected ? OPNDesign.Text.primary : OPNDesign.Text.secondary)
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark")
                                .catalogFont(size: 12, weight: .bold)
                                .foregroundStyle(OPNDesign.accentInk)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 220, height: 38, alignment: .leading)
                    .background(selected ? OPNDesign.Fill.neutral(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(OPNDesign.Surface.overlay.opacity(0.985))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(OPNDesign.accent)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(OPNDesign.Stroke.subtle)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
    }
}

private struct CatalogShowAllFilterPanel: View {
    let viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("FILTER")
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                Spacer()
                Button("CLEAR ALL") {
                    viewModel.clearSearch()
                    viewModel.clearFilters()
                    viewModel.browseCatalog()
                }
                    .buttonStyle(.plain)
                    .catalogFont(size: 11, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .disabled(!viewModel.isBrowseMode)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(viewModel.visibleFilterGroups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text((group.label.isEmpty ? group.id : group.label).uppercased())
                                .catalogFont(size: 12, weight: .bold)
                                .foregroundStyle(OPNDesign.Text.tertiary)
                            ForEach(group.options, id: \.id) { option in
                                filterRow(option: option)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filterRow(option: OPNCatalogFilterOptionObject) -> some View {
        let selected = viewModel.selectedFilterIds.contains(option.id)
        return Button { viewModel.toggleFilter(option.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .catalogFont(size: 15, weight: .bold)
                    .foregroundStyle(selected ? OPNDesign.accentInk : OPNDesign.Text.secondary)
                Text(option.label.isEmpty ? option.id : option.label)
                    .catalogFont(size: 13, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }
}
