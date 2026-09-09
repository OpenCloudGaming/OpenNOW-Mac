//  The full-screen overlays controller mode pushes over the catalog: search, the sort/filter
//  picker and the action menu.
//

import AppKit
import SwiftUI

struct ControllerSearchOverlay: View {
    @Bindable var viewModel: CatalogViewModel
    let rowIndex: Int
    let filterOptionIndices: [String: Int]
    let resultIndex: Int
    let layout: ControllerLayoutMetrics
    let selectResult: (OPNCatalogGameObject) -> Void
    let close: () -> Void
    let focusSearchRow: () -> Void
    let openSortPicker: () -> Void
    let openFilterPicker: (OPNCatalogFilterGroupObject) -> Void

    /// The field is the focused row's real first responder, not just a highlighted box. The
    /// keyboard bridge already steps aside whenever a text field owns the keyboard, so focus here
    /// is what makes typing reach the query at all - without it the overlay opened with nothing
    /// focused and keystrokes went nowhere until the field was clicked with a mouse.
    @FocusState private var isSearchFieldFocused: Bool

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        GeometryReader { proxy in
            let columns = overlayColumnCount(width: layout.contentWidth, minimumWidth: 250 * uiScale, spacing: 14 * uiScale)
            VStack(alignment: .leading, spacing: 16 * uiScale) {
                searchField
                filterBar
                resultsGrid(columns: columns)
            }
            .frame(width: layout.contentWidth, alignment: .leading)
            .padding(.top, 16 * uiScale)
            .padding(.bottom, 12 * uiScale)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .opnTakingFocus($isSearchFieldFocused, while: rowIndex == 0)
        .onChange(of: rowIndex) { _, row in
            // Moving off the search row hands the keyboard back to the navigation bridge.
            if row != 0 { isSearchFieldFocused = false }
        }
        .onChange(of: isSearchFieldFocused) { _, isFocused in
            guard isFocused, rowIndex != 0 else { return }
            focusSearchRow()
        }
        .onExitCommand { close() }
    }

    private var searchField: some View {
        HStack(spacing: 14 * uiScale) {
            Image(systemName: "magnifyingglass")
                .catalogFont(size: 18, weight: .bold)
                .foregroundStyle(rowIndex == 0 ? OpenNOWDesign.accent : .white.opacity(0.62))
            TextField("Search", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .catalogFont(size: 20, weight: .medium)
                .foregroundStyle(.white)
                .focused($isSearchFieldFocused)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button("CLEAR", action: { viewModel.searchQuery = "" })
                    .buttonStyle(.plain)
                    .catalogFont(size: 12, weight: .bold)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 18 * uiScale)
        .frame(height: 58 * uiScale)
        .background(Color.white.opacity(rowIndex == 0 ? 0.12 : 0.075))
        .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        .openNowFocusRing(rowIndex == 0)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10 * uiScale) {
                sortChip
                ForEach(Array(viewModel.visibleFilterGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    filterChip(for: group, groupIndex: groupIndex)
                }
                if viewModel.selectedFilterCount > 0 {
                    clearFiltersChip
                }
            }
            .padding(.vertical, 4 * uiScale)
        }
    }

    /// Which chip in the filter bar is focused. The input side has always tracked this in
    /// `_barIndex`; nothing rendered from it, so moving along the bar was invisible and the sort
    /// chip looked permanently focused.
    private var focusedBarIndex: Int { filterOptionIndices[ControllerSearchBar.indexKey] ?? 0 }

    private var sortChip: some View {
        let sortLabel = viewModel.sortOptions.first { $0.id == viewModel.selectedSortId }?.label ?? viewModel.selectedSortLabel
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.sortIndex
        return Button {
            openSortPicker()
        } label: {
            HStack(spacing: 8 * uiScale) {
                Image(systemName: "arrow.up.arrow.down")
                    .catalogFont(size: 11, weight: .bold)
                Text("SORT: \(sortLabel.uppercased())")
                    .catalogFont(size: 12, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.82))
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.075))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused, onAccentFill: true)
        }
        .buttonStyle(.plain)
    }

    private func filterChip(for group: OPNCatalogFilterGroupObject, groupIndex: Int) -> some View {
        let selectedOption = group.options.first { viewModel.selectedFilterIds.contains($0.id) }
        let label = selectedOption?.label ?? group.label
        let isSelected = selectedOption != nil
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.filterIndex(groupIndex)
        return Button {
            openFilterPicker(group)
        } label: {
            HStack(spacing: 8 * uiScale) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .catalogFont(size: 10, weight: .bold)
                }
                Text("\(group.label.uppercased()): \(label.uppercased())")
                    .catalogFont(size: 12, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : (isSelected ? OpenNOWDesign.accent : .white.opacity(0.82)))
            .padding(.horizontal, 14 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : (isSelected ? OpenNOWDesign.accent.opacity(0.15) : Color.white.opacity(0.075)))
            .overlay { Rectangle().stroke(isSelected ? OpenNOWDesign.accent : OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused, onAccentFill: true)
        }
        .buttonStyle(.plain)
    }

    private var clearFiltersChip: some View {
        let isFocused = rowIndex == 1 && focusedBarIndex == ControllerSearchBar.clearIndex(groupCount: viewModel.visibleFilterGroups.count)
        return Button {
            viewModel.clearSearch()
            viewModel.clearFilters()
            viewModel.browseCatalog()
        } label: {
            HStack(spacing: 6 * uiScale) {
                Image(systemName: "xmark.circle.fill")
                    .catalogFont(size: 12, weight: .bold)
                Text("CLEAR FILTERS")
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(0.6)
            }
            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.72))
            .padding(.horizontal, 12 * uiScale)
            .frame(height: 36 * uiScale)
            .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.05))
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
            .openNowFocusRing(isFocused, onAccentFill: true)
        }
        .buttonStyle(.plain)
    }

    private func resultsGrid(columns: Int) -> some View {
        let isResultsRowFocused = rowIndex == 2
        return VStack(alignment: .leading, spacing: 10 * uiScale) {
            ControllerOverlaySectionTitle(viewModel.resultSummary.isEmpty ? "Results" : viewModel.resultSummary)
            GeometryReader { grid in
                // The same tile the rails use, so a game looks identical whether it was found by
                // browsing or by searching.
                let spacing = 14 * uiScale
                let tileWidth = max((grid.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
                let tileSize = CGSize(width: floor(tileWidth), height: floor(tileWidth * 9 / 16))
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileSize.width), spacing: spacing), count: columns), spacing: spacing) {
                        ForEach(Array(viewModel.catalogGames.enumerated()), id: \.element.catalogIdentity) { index, game in
                            ControllerGameTile(
                                game: game,
                                imageURL: viewModel.optimizedImageURL(game.bestWideImageURL, width: 720),
                                isFocused: isResultsRowFocused && resultIndex == index,
                                isQueuedForPatching: viewModel.isQueuedForPatching(game),
                                showsFreeAccountAccessBadges: viewModel.isFreeTierAccount,
                                tileSize: tileSize,
                                action: { selectResult(game) }
                            )
                            .equatable()
                        }
                    }
                    .padding(.bottom, 12 * uiScale)
                }
            }
        }
    }

}

struct ControllerSearchPickerOverlay: View {
    let picker: ControllerSearchPicker
    let selectedIndex: Int
    let selectedOptionIds: [String]
    let selectedSortId: String
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let select: (Int) -> Void
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    /// Sized from the row count rather than left to fill: the list is inside a ScrollView, which
    /// is greedy, so an unconstrained panel stretched to the full window height even for a
    /// three-option sort list.
    private var panelHeight: CGFloat {
        let rowHeight = 44 * uiScale
        let rowSpacing = 8 * uiScale
        let rows = CGFloat(picker.options.count)
        let chrome = 118 * uiScale
        let content = rows * rowHeight + max(rows - 1, 0) * rowSpacing + chrome
        return min(content, layout.size.height * 0.72)
    }

    private func isApplied(_ option: ControllerSearchPicker.Option) -> Bool {
        switch picker.kind {
        case .sort:
            return option.id == selectedSortId
        case .filter:
            guard option.id != ControllerSearchPicker.clearOptionId else {
                return !picker.options.contains { $0.id != ControllerSearchPicker.clearOptionId && selectedOptionIds.contains($0.id) }
            }
            return selectedOptionIds.contains(option.id)
        }
    }

    var body: some View {
        ZStack {
            OpenNOWDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(title: picker.title, subtitle: "Choose one", glyphs: glyphs, close: close)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.top, 18 * uiScale)
                    .padding(.bottom, 12 * uiScale)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8 * uiScale) {
                            ForEach(Array(picker.options.enumerated()), id: \.element.id) { index, option in
                                let isFocused = index == selectedIndex
                                Button { select(index) } label: {
                                    HStack(spacing: 13 * uiScale) {
                                        Image(systemName: isApplied(option) ? "checkmark.circle.fill" : "circle")
                                            .catalogFont(size: 13, weight: .bold)
                                            .foregroundStyle(isFocused ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                        Text(option.label)
                                            .catalogFont(size: 14, weight: .bold)
                                            .foregroundStyle(isFocused ? .black.opacity(0.88) : .white.opacity(0.88))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14 * uiScale)
                                    .frame(height: 44 * uiScale)
                                    .background(isFocused ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                                    .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                                    .openNowFocusRing(isFocused, onAccentFill: true)
                                }
                                .buttonStyle(.plain)
                                .id(option.id)
                            }
                        }
                        .padding(.horizontal, 22 * uiScale)
                        .padding(.bottom, 22 * uiScale)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard picker.options.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(picker.options[index].id, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: min(520 * uiScale, layout.contentWidth), height: panelHeight, alignment: .topLeading)
            .background(OpenNOWDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OpenNOWDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
        }
    }
}

private func overlayColumnCount(width: CGFloat, minimumWidth: CGFloat, spacing: CGFloat) -> Int {
    max(2, Int((width + spacing) / (minimumWidth + spacing)))
}

struct ControllerActionMenuOverlay: View {
    let items: [ControllerActionMenuItem]
    let selectedIndex: Int
    let glyphs: ControllerInputGlyphSet
    let layout: ControllerLayoutMetrics
    let topInset: CGFloat
    let isRefreshingCatalog: Bool
    let perform: (ControllerActionMenuItem) -> Void
    let close: () -> Void

    @Environment(\.opnUIScale) private var uiScale

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.58).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                ControllerOverlayHeader(title: "Controller Actions", subtitle: "Catalog navigation and account actions", glyphs: glyphs, close: close)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.top, 22 + topInset)
                    .padding(.bottom, 12 * uiScale)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8 * uiScale) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            Button { perform(item) } label: {
                                HStack(spacing: 13 * uiScale) {
                                    if item.isRefresh, isRefreshingCatalog {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(index == selectedIndex ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                            .scaleEffect(0.82)
                                            .frame(width: 28 * uiScale)
                                    } else {
                                        Image(systemName: item.icon)
                                            .catalogFont(size: 15, weight: .bold)
                                            .foregroundStyle(index == selectedIndex ? .black.opacity(0.86) : OpenNOWDesign.accent)
                                            .frame(width: 28 * uiScale)
                                    }
                                    Text(item.isRefresh && isRefreshingCatalog ? "Refreshing Catalog" : item.title)
                                        .catalogFont(size: 15, weight: .bold)
                                        .foregroundStyle(index == selectedIndex ? .black.opacity(0.88) : .white.opacity(0.88))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 14 * uiScale)
                                .frame(height: 48 * uiScale)
                                .background(index == selectedIndex ? OpenNOWDesign.accent : Color.white.opacity(0.055))
                                .overlay { Rectangle().stroke(OpenNOWDesign.Stroke.subtle, lineWidth: 1) }
                                .openNowFocusRing(index == selectedIndex)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.isRefresh && isRefreshingCatalog)
                        }
                    }
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.bottom, 22 * uiScale)
                }
            }
            .frame(maxWidth: 420 * uiScale, maxHeight: .infinity, alignment: .topLeading)
            .background(OpenNOWDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .leading) { Rectangle().fill(OpenNOWDesign.accent).frame(width: 3) }
            .padding(.leading, layout.leadingInset)
            .padding(.trailing, layout.trailingInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
