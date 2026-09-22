//  The desktop collection icon picker: a searchable, categorized grid of the built-in SF Symbols,
//  plus a reader-imported image and a way to use any symbol name the bundled catalog does not list.
//  It edits the open dialog's icon draft; the dialog's SAVE is what stores it.

import SwiftUI
import UniformTypeIdentifiers

struct CatalogCollectionIconPickerOverlay: View {
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.opnUIScale) private var uiScale

    @State private var searchText = ""
    @State private var selectedCategoryID = OPNCollectionSymbolCatalog.popularCategoryID
    @State private var isImageImporterPresented = false
    @State private var importError = ""
    @FocusState private var isSearchFocused: Bool

    private struct IconCategoryOption: Identifiable {
        let id: String
        let title: String
    }

    private var categoryOptions: [IconCategoryOption] {
        [
            IconCategoryOption(id: OPNCollectionSymbolCatalog.popularCategoryID, title: "Popular"),
            IconCategoryOption(id: OPNCollectionSymbolCatalog.allCategoryID, title: "All"),
        ] + OPNCollectionSymbolCatalog.categories.map { IconCategoryOption(id: $0.id, title: $0.title) }
    }

    /// The picker draws at most this many glyphs at once. Browsing "All" without a query would
    /// otherwise build thousands of cells; a query or a category is the way to reach the rest.
    private static let maximumVisibleSymbols = 600

    private var draftIcon: OPNCollectionIcon { viewModel.collectionsDraftIcon ?? .fallback }

    private var matchingSymbols: [OPNCollectionSymbol] {
        OPNCollectionSymbolCatalog.search(searchText, categoryID: selectedCategoryID)
    }

    private var displayedSymbols: [OPNCollectionSymbol] {
        Array(matchingSymbols.prefix(Self.maximumVisibleSymbols))
    }

    var body: some View {
        ZStack {
            OPNDesign.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { viewModel.cancelCollectionsIconPicker() }

            VStack(alignment: .leading, spacing: 0) {
                header
                rule
                searchRow
                categoryRow
                if !trimmedSearch.isEmpty { customSymbolRow }
                rule
                grid
                rule
                footer
            }
            .frame(width: min(620 * uiScale, 620), alignment: .topLeading)
            .frame(maxHeight: 660 * uiScale, alignment: .topLeading)
            .background(OPNDesign.Surface.deep.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(OPNDesign.accent).frame(height: 2) }
            .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
        .fileImporter(isPresented: $isImageImporterPresented, allowedContentTypes: [.image]) { result in
            importImage(result)
        }
        .onAppear { isSearchFocused = true }
    }

    private var rule: some View {
        Rectangle().fill(OPNDesign.Stroke.subtle).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 14 * uiScale) {
            OPNCollectionIconView(icon: draftIcon, size: 30, weight: .medium)
                .foregroundStyle(OPNDesign.accentInk)
            VStack(alignment: .leading, spacing: 3 * uiScale) {
                Text("CHOOSE ICON")
                    .catalogFont(size: 11, weight: .bold)
                    .tracking(1.1)
                    .foregroundStyle(OPNDesign.accentInk)
                Text(viewModel.collectionsDraftName.isEmpty ? "Collection" : viewModel.collectionsDraftName)
                    .catalogFont(size: 19, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { viewModel.cancelCollectionsIconPicker() } label: {
                Image(systemName: "xmark")
                    .catalogFont(size: 14, weight: .bold)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .frame(width: 34 * uiScale, height: 34 * uiScale)
                    .background(OPNDesign.Fill.neutral(0.08))
                    .overlay { Rectangle().stroke(OPNDesign.Stroke.subtle, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close icon picker")
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 16 * uiScale)
    }

    private var searchRow: some View {
        HStack(spacing: 10 * uiScale) {
            Image(systemName: "magnifyingglass")
                .catalogFont(size: 14, weight: .bold)
                .foregroundStyle(OPNDesign.Text.tertiary)
            TextField("Search \(OPNCollectionSymbolCatalog.symbols.count) icons", text: $searchText)
                .textFieldStyle(.plain)
                .catalogFont(size: 14, weight: .medium)
                .foregroundStyle(OPNDesign.Text.primary)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .catalogFont(size: 13, weight: .bold)
                        .foregroundStyle(OPNDesign.Text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12 * uiScale)
        .frame(height: 44 * uiScale)
        .background(OPNDesign.Fill.neutral(0.08))
        .overlay { Rectangle().stroke(OPNDesign.Stroke.regular, lineWidth: 1) }
        .padding(.horizontal, 22 * uiScale)
        .padding(.top, 14 * uiScale)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6 * uiScale) {
                ForEach(categoryOptions) { category in
                    categoryChip(id: category.id, title: category.title)
                }
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.vertical, 12 * uiScale)
        }
    }

    private func categoryChip(id: String, title: String) -> some View {
        let isSelected = id == selectedCategoryID
        return Button {
            selectedCategoryID = id
        } label: {
            Text(title)
                .catalogFont(size: 12, weight: .bold)
                .foregroundStyle(isSelected ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                .padding(.horizontal, 12 * uiScale)
                .frame(height: 30 * uiScale)
                .background(isSelected ? OPNDesign.accent : OPNDesign.Fill.neutral(0.055))
                .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var customSymbolRow: some View {
        Button {
            viewModel.setCollectionsDraftIcon(.symbol(trimmedSearch))
        } label: {
            HStack(spacing: 10 * uiScale) {
                Image(systemName: "wand.and.stars")
                    .catalogFont(size: 13, weight: .bold)
                    .foregroundStyle(OPNDesign.accentInk)
                Text("Use “\(trimmedSearch)” as an exact symbol name")
                    .catalogFont(size: 12, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22 * uiScale)
            .padding(.bottom, 12 * uiScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            let symbols = displayedSymbols
            if symbols.isEmpty {
                Text("No icons match “\(trimmedSearch)”.")
                    .catalogFont(size: 13, weight: .medium)
                    .foregroundStyle(OPNDesign.Text.tertiary)
                    .padding(.horizontal, 22 * uiScale)
                    .padding(.vertical, 20 * uiScale)
            } else {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 44 * uiScale), spacing: 6 * uiScale)],
                        spacing: 6 * uiScale
                    ) {
                        ForEach(symbols, id: \.name) { symbol in
                            symbolCell(symbol)
                        }
                    }
                    if matchingSymbols.count > symbols.count {
                        Text("Showing \(symbols.count) of \(matchingSymbols.count). Search to narrow the list.")
                            .catalogFont(size: 11, weight: .medium)
                            .foregroundStyle(OPNDesign.Text.tertiary)
                    }
                }
                .padding(.horizontal, 22 * uiScale)
                .padding(.vertical, 14 * uiScale)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func symbolCell(_ symbol: OPNCollectionSymbol) -> some View {
        let isSelected = draftIcon == .symbol(symbol.name)
        return Button {
            viewModel.setCollectionsDraftIcon(.symbol(symbol.name))
        } label: {
            OPNCollectionIconView(icon: .symbol(symbol.name), size: 20, weight: .medium)
                .foregroundStyle(isSelected ? OPNDesign.onAccent : OPNDesign.Text.secondary)
                .frame(width: 44 * uiScale, height: 44 * uiScale)
                .background(isSelected ? OPNDesign.accent : OPNDesign.Fill.neutral(0.05))
                .overlay { Rectangle().stroke(isSelected ? OPNDesign.accent : OPNDesign.Stroke.subtle, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol.name)
    }

    private var footer: some View {
        HStack(spacing: 10 * uiScale) {
            Button("UPLOAD IMAGE…") { isImageImporterPresented = true }
                .buttonStyle(VendorLaunchSecondaryButtonStyle())
            Button("RESET") { viewModel.setCollectionsDraftIcon(nil) }
                .buttonStyle(VendorLaunchSecondaryButtonStyle())
            if !importError.isEmpty {
                Text(importError)
                    .catalogFont(size: 11, weight: .medium)
                    .foregroundStyle(OPNDesign.Semantic.destructive)
            }
            Spacer(minLength: 0)
            Button("CANCEL") { viewModel.cancelCollectionsIconPicker() }
                .buttonStyle(VendorLaunchSecondaryButtonStyle())
            Button("DONE") { viewModel.dismissCollectionsIconPicker() }
                .buttonStyle(VendorGetInButtonStyle())
        }
        .padding(.horizontal, 22 * uiScale)
        .padding(.vertical, 14 * uiScale)
    }

    private func importImage(_ result: Result<URL, Error>) {
        importError = ""
        switch result {
        case .success(let url):
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            guard let icon = viewModel.storeCollectionIconImage(from: url) else {
                importError = "That image could not be used."
                return
            }
            viewModel.setCollectionsDraftIcon(icon)
        case .failure:
            importError = "That image could not be opened."
        }
    }
}
