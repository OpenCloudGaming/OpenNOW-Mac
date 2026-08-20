import SwiftUI

struct CatalogShowAllPage: View {
    @Bindable var viewModel: CatalogViewModel
    let onBack: () -> Void
    @State private var isSortMenuPresented = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    mainColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CatalogShowAllFilterPanel(viewModel: viewModel)
                        .frame(width: 280)
                        .background(MacForceNowDesign.Surface.overlay)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1) }
                }
                if isSortMenuPresented {
                    CatalogSortDropdownOverlay(viewModel: viewModel, isPresented: $isSortMenuPresented, screenWidth: proxy.size.width)
                }
            }
        }
        .background(MacForceNowDesign.Surface.app)
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 1)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 2)
                if viewModel.showsCatalogLoadingIndicator {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(MacForceNowDesign.accent)
                        .frame(height: 2)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.showsCatalogLoadingIndicator)
            if viewModel.isLoading && viewModel.catalogGames.isEmpty {
                CatalogGridSkeletonView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                CatalogShowAllGridView(
                    viewModel: viewModel,
                    games: viewModel.catalogGames,
                    selectedGame: viewModel.selectedGame,
                    isQueuedForPatching: { viewModel.isQueuedForPatching($0) },
                    imageURL: { viewModel.optimizedImageURL($0.bestWideImageURL, width: 620) },
                    onSelect: { viewModel.toggleGameSelection($0, inSection: viewModel.selectedShowAllSection?.id ?? "") },
                    onPlay: { viewModel.launch(game: $0) },
                    onQueueForPatching: { viewModel.queuePatchingLaunch(game: $0) }
                )
                .opacity(viewModel.isRefetchingCatalog ? 0.45 : 1)
                .animation(.easeOut(duration: 0.2), value: viewModel.isRefetchingCatalog)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.84))
                }
                .buttonStyle(.plain)
                Spacer()
                sortMenu
            }
            .frame(height: 44)

            HStack(spacing: 12) {
                Text(resultCount)
                    .nvidiaFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var resultCount: String {
        let count = viewModel.totalCatalogCount > 0 ? viewModel.totalCatalogCount : viewModel.catalogGames.count
        return count == 1 ? "1 game" : "\(count) games"
    }

    private var sortMenu: some View {
        Button { isSortMenuPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                Image(systemName: "chevron.down")
            }
            .nvidiaFont(size: 12, weight: .bold)
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.white.opacity(0.08))
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
                            .nvidiaFont(size: 14, weight: selected ? .bold : .medium)
                            .foregroundStyle(.white.opacity(selected ? 0.96 : 0.84))
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark")
                                .nvidiaFont(size: 12, weight: .bold)
                                .foregroundStyle(MacForceNowDesign.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 220, height: 38, alignment: .leading)
                    .background(selected ? Color.white.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(MacForceNowDesign.Surface.overlay.opacity(0.985))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(MacForceNowDesign.accent)
                .frame(height: 2)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
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
                    .nvidiaFont(size: 14, weight: .bold)
                    .foregroundStyle(.white.opacity(0.96))
                Spacer()
                Button("CLEAR ALL") { viewModel.clearSearchAndFilters() }
                    .buttonStyle(.plain)
                    .nvidiaFont(size: 11, weight: .bold)
                    .foregroundStyle(.white.opacity(0.72))
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
                                .nvidiaFont(size: 12, weight: .bold)
                                .foregroundStyle(.white.opacity(0.56))
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
                    .nvidiaFont(size: 15, weight: .bold)
                    .foregroundStyle(selected ? MacForceNowDesign.accent : .white.opacity(0.72))
                Text(option.label.isEmpty ? option.id : option.label)
                    .nvidiaFont(size: 13, weight: .medium)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 28)
        }
        .buttonStyle(.plain)
    }
}
