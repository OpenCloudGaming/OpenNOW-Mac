//  CatalogView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Backend
import Combine
import CoreText
import ImageIO
import SwiftUI

private enum CatalogVendorLayout {
    static let appBarHeight: CGFloat = 56
    static let appBarBackground = Color(red: 57 / 255, green: 57 / 255, blue: 57 / 255)
    static let mallSurface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let tileTray = Color(red: 41 / 255, green: 41 / 255, blue: 41 / 255)
    static let sectionHeaderMargin: CGFloat = 40
    static let carouselContainerMargin: CGFloat = 32
    static let tileHorizontalMargin: CGFloat = 8
    static let tileTopMargin: CGFloat = 16
    static let cardTrayHeight: CGFloat = 40
    static let wideTileWidth: CGFloat = 272
    static let wideTileHeight: CGFloat = 153
    static let tileScaleFactor: CGFloat = 1.12
}

private enum CatalogVendorFont {
    enum Weight: Hashable {
        case regular
        case medium
        case bold
    }

    static func font(size: CGFloat, weight: Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: weight))
    }

    private static func nsFont(size: CGFloat, weight: Weight) -> NSFont {
        if let descriptor = descriptor(weight: weight) {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        return NSFont.systemFont(ofSize: size, weight: fallbackWeight(weight))
    }

    private static func fallbackWeight(_ weight: Weight) -> NSFont.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    private static func descriptor(weight: Weight) -> CTFontDescriptor? {
        descriptors[weight] ?? nil
    }

    private static let descriptors: [Weight: CTFontDescriptor?] = [
        .regular: loadDescriptor(named: "NVIDIASans_W_Rg"),
        .medium: loadDescriptor(named: "NVIDIASans_W_Md"),
        .bold: loadDescriptor(named: "NVIDIASans_W_Bd")
    ]

    private static func loadDescriptor(named name: String) -> CTFontDescriptor? {
        for subdirectory in ["NVIDIA", "Resources/NVIDIA", nil] as [String?] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: subdirectory),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { continue }
            return descriptor
        }
        return nil
    }
}

private extension Font {
    static func nvidia(size: CGFloat, weight: CatalogVendorFont.Weight = .regular) -> Font {
        CatalogVendorFont.font(size: size, weight: weight)
    }
}

struct CatalogView: View {
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    let onRefreshAuth: () -> Void

    @StateObject private var viewModel: CatalogViewModel

    init(
        account: LoginAccount,
        session: LoginSession,
        accounts: [LoginAccount],
        onSwitch: @escaping (LoginAccount) -> Void,
        onSignOut: @escaping () -> Void,
        onForget: @escaping (LoginAccount) -> Void,
        onRefreshAuth: @escaping () -> Void
    ) {
        self.accounts = accounts
        self.onSwitch = onSwitch
        self.onSignOut = onSignOut
        self.onForget = onForget
        self.onRefreshAuth = onRefreshAuth
        _viewModel = StateObject(wrappedValue: CatalogViewModel(account: account, session: session, onRefreshAuth: onRefreshAuth))
    }

    var body: some View {
        VStack(spacing: 0) {
            CatalogTopBar(viewModel: viewModel, accounts: accounts, onSwitch: onSwitch, onSignOut: onSignOut, onForget: onForget)
            CatalogContentView(viewModel: viewModel)
        }
        .background(Color.black)
        .task { viewModel.loadIfNeeded() }
        .preferredColorScheme(.dark)
    }
}

private struct CatalogTopBar: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 28) {
                Image(systemName: "line.3.horizontal")
                    .font(.nvidia(size: 21))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Games")
                    .font(.nvidia(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(.leading, 20)

            catalogSearchField
                .frame(width: 540)

            HStack(spacing: 24) {
                Spacer()
                Image(systemName: "questionmark.circle.fill")
                    .font(.nvidia(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.openNowGreen)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }

                Menu {
                    ForEach(accounts) { account in
                        Button(account.displayName) { onSwitch(account) }
                    }
                    Divider()
                    Button("Sign Out", action: onSignOut)
                    ForEach(accounts) { account in
                        Button("Forget \(account.displayName)", role: .destructive) { onForget(account) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "headphones")
                            .font(.nvidia(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(viewModel.account.displayName)
                                .font(.nvidia(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("Performance")
                                .font(.nvidia(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        Image(systemName: "chevron.down")
                            .font(.nvidia(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                    }
                }
                .menuStyle(.button)
            }
            .padding(.trailing, 22)
        }
        .frame(height: CatalogVendorLayout.appBarHeight)
        .background(CatalogVendorLayout.appBarBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1) }
    }

    private var catalogSearchField: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
            TextField("Search games, stores, or genres", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.nvidia(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .onSubmit { viewModel.browseCatalog() }
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.52))
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 40)
        .background(Color(red: 0.145, green: 0.145, blue: 0.145))
        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct CatalogContentView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var heroIndex = 0
    @State private var heroAutoScrollEnabled = true
    private let heroTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let heroes = heroGames
        let hero = heroes.indices.contains(heroIndex) ? heroes[heroIndex] : heroes.first
        let sections = viewModel.catalogSections
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if hero != nil {
                    CatalogHeroView(
                        viewModel: viewModel,
                        games: heroes,
                        activeIndex: heroes.indices.contains(heroIndex) ? heroIndex : 0,
                        onSelectSlide: { index in
                            heroAutoScrollEnabled = false
                            heroIndex = index
                        }
                    )
                }

                if !viewModel.errorMessage.isEmpty {
                    CatalogMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                }
                CatalogBrowseControlsView(viewModel: viewModel)
                    .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                if viewModel.isLoading || viewModel.isLoadingPanels {
                    CatalogLoadingStrip()
                        .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                }

                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    CatalogRailView(viewModel: viewModel, section: section)
                    if shouldShowDetail(afterSectionAt: index, sections: sections) {
                        GameDetailPanel(viewModel: viewModel)
                            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)
                            .padding(.top, -CatalogVendorLayout.cardTrayHeight)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(.bottom, 44)
        }
        .background(Color.black)
        .onReceive(heroTimer) { _ in
            guard heroAutoScrollEnabled, heroes.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                heroIndex = (heroIndex + 1) % heroes.count
            }
        }
        .onChange(of: heroIdentityList) { _, identities in
            guard !identities.isEmpty else {
                heroIndex = 0
                return
            }
            if heroIndex >= identities.count { heroIndex = 0 }
        }
    }

    private var heroGames: [OPNCatalogGameObject] {
        let featuredGames = viewModel.featuredGames
        if !featuredGames.isEmpty { return Array(featuredGames.prefix(8)) }
        return Array(viewModel.catalogGames.prefix(8))
    }

    private var heroIdentityList: [String] {
        heroGames.map { CatalogViewModel.identity(for: $0) }
    }

    private func shouldShowDetail(afterSectionAt index: Int, sections: [CatalogSectionModel]) -> Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        let selectedIdentity = CatalogViewModel.identity(for: selectedGame)
        guard sections[index].games.contains(where: { CatalogViewModel.identity(for: $0) == selectedIdentity }) else {
            return false
        }
        return !sections.prefix(index).contains { section in
            section.games.contains { CatalogViewModel.identity(for: $0) == selectedIdentity }
        }
    }
}

private struct CatalogHeroView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let games: [OPNCatalogGameObject]
    let activeIndex: Int
    let onSelectSlide: (Int) -> Void
    @State private var scrimColor = CatalogMarqueeScrimColor.black

    private var game: OPNCatalogGameObject? {
        games.indices.contains(activeIndex) ? games[activeIndex] : games.first
    }

    var body: some View {
        if let game {
            ZStack(alignment: .bottom) {
                CatalogHeroVendorBackgroundScrim(color: scrimColor)
                CatalogHeroRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1400), contentMode: .fill) { color in
                    scrimColor = color
                }
                    .frame(maxWidth: .infinity, minHeight: 486, maxHeight: 486)
                    .clipped()
                    .id(game.catalogIdentity)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                CatalogHeroVendorForegroundScrim()

                VStack(spacing: 26) {
                    Spacer(minLength: 108)
                    Text(game.mallDisplayTitle)
                        .font(.nvidia(size: 52))
                        .tracking(8)
                        .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    Spacer(minLength: 42)
                    VStack(spacing: 2) {
                        Text(game.primaryStoreLabel)
                            .font(.nvidia(size: 13, weight: .bold))
                        Text(game.ratingLabel)
                            .font(.nvidia(size: 13, weight: .bold))
                    }
                    .foregroundStyle(scrimColor.preferredTextColor.opacity(0.94))
                    Button { viewModel.selectGame(game) } label: {
                        Text("VIEW DETAILS")
                            .font(.nvidia(size: 14, weight: .bold))
                            .frame(width: 142, height: 41)
                    }
                    .buttonStyle(VendorGetInButtonStyle())
                    Spacer(minLength: 58)
                }
                .frame(width: 470)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 38)

                HStack(spacing: 8) {
                    ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { index, _ in
                        Button { onSelectSlide(index) } label: {
                            Circle()
                                .fill(index == activeIndex ? Color.openNowGreen : Color.white.opacity(0.58))
                                .frame(width: index == activeIndex ? 12 : 9, height: index == activeIndex ? 12 : 9)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 34)
            }
            .clipShape(Rectangle())
        }
    }
}

private struct CatalogBrowseControlsView: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if !viewModel.resultSummary.isEmpty {
                    Text(viewModel.resultSummary.uppercased())
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                }
                if viewModel.hasMoreCatalogResults {
                    Text("SHOWING TOP RESULTS")
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(Color.openNowGreen.opacity(0.88))
                }
                Spacer()
                if !viewModel.searchQuery.trimmed.isEmpty || viewModel.selectedFilterCount > 0 {
                    Button("CLEAR") { viewModel.clearSearchAndFilters() }
                        .buttonStyle(.plain)
                        .font(.nvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.84))
                }
                Menu {
                    ForEach(viewModel.sortOptions, id: \.id) { option in
                        Button(option.label.isEmpty ? option.id : option.label) { viewModel.setSort(option.id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("SORT: \(viewModel.selectedSortLabel.uppercased())")
                        Image(systemName: "chevron.down")
                    }
                    .font(.nvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.08))
                }
                .menuStyle(.button)
                .disabled(viewModel.sortOptions.isEmpty)
            }

            if !viewModel.visibleFilterGroups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.visibleFilterGroups, id: \.id) { group in
                            Menu {
                                ForEach(group.options, id: \.id) { option in
                                    Button(filterTitle(option: option)) { viewModel.toggleFilter(option.id) }
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Text((group.label.isEmpty ? group.id : group.label).uppercased())
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .font(.nvidia(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(Color.white.opacity(0.075))
                                .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
                            }
                            .menuStyle(.button)
                        }
                        ForEach(selectedFilterOptions, id: \.id) { option in
                            Button { viewModel.toggleFilter(option.id) } label: {
                                HStack(spacing: 7) {
                                    Text(option.label.uppercased())
                                    Image(systemName: "xmark")
                                }
                                .font(.nvidia(size: 11, weight: .bold))
                                .foregroundStyle(.black.opacity(0.88))
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(Color.openNowGreen)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var selectedFilterOptions: [OPNCatalogFilterOptionObject] {
        viewModel.visibleFilterGroups.flatMap(\.options).filter { viewModel.selectedFilterIds.contains($0.id) }
    }

    private func filterTitle(option: OPNCatalogFilterOptionObject) -> String {
        let selectedPrefix = viewModel.selectedFilterIds.contains(option.id) ? "✓ " : ""
        return selectedPrefix + (option.label.isEmpty ? option.id : option.label)
    }
}

private struct CatalogRailView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let section: CatalogSectionModel
    @State private var scrollIndex = 0

    private var isExpanded: Bool { viewModel.expandedSectionIds.contains(section.id) }
    private var games: [OPNCatalogGameObject] { section.visibleGames(expanded: isExpanded) }
    private var canSeeAll: Bool { section.games.count > games.count || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(section.title)
                    .font(.nvidia(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canSeeAll {
                    Button(isExpanded ? "SHOW LESS" : "SEE ALL") { viewModel.toggleSectionExpansion(section.id) }
                        .buttonStyle(.plain)
                        .font(.nvidia(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .frame(height: 28)
            .padding(.horizontal, CatalogVendorLayout.sectionHeaderMargin)

            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(games.enumerated()), id: \.element.catalogIdentity) { _, game in
                                CatalogGameTile(viewModel: viewModel, game: game)
                                    .id(game.catalogIdentity)
                            }
                            if section.games.count > games.count {
                                CatalogSeeMoreTile(title: "See All") { viewModel.toggleSectionExpansion(section.id) }
                            }
                        }
                        .padding(.horizontal, CatalogVendorLayout.carouselContainerMargin)
                        .padding(.bottom, 4)
                    }
                    if games.count > 3 {
                        HStack {
                            CatalogRailArrow(systemName: "chevron.left") {
                                moveRail(proxy: proxy, delta: -3)
                            }
                            Spacer()
                            CatalogRailArrow(systemName: "chevron.right") {
                                moveRail(proxy: proxy, delta: 3)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    private func moveRail(proxy: ScrollViewProxy, delta: Int) {
        guard !games.isEmpty else { return }
        scrollIndex = min(max(scrollIndex + delta, 0), max(games.count - 1, 0))
        withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(games[scrollIndex].catalogIdentity, anchor: .leading)
        }
    }
}

private struct CatalogRailArrow: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.nvidia(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.24), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct CatalogSeeMoreTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "ellipsis")
                    .font(.nvidia(size: 34, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(title.uppercased())
                    .font(.nvidia(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
            .background(Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.24), lineWidth: 2) }
            .scaleEffect(isHovering ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
        .padding(.top, CatalogVendorLayout.tileTopMargin)
        .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.cardTrayHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
        .onHover { isHovering = $0 }
        .accessibilityLabel("See all")
    }
}

private struct CatalogGameTile: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: OPNCatalogGameObject
    @State private var isHovering = false

    private var isSelected: Bool {
        guard let selectedGame = viewModel.selectedGame else { return false }
        return CatalogViewModel.identity(for: selectedGame) == game.catalogIdentity
    }

    private var shouldDim: Bool {
        viewModel.selectedGame != nil && !isSelected
    }

    var body: some View {
        Button { viewModel.selectGame(game) } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestWideImageURL, width: 620), contentMode: .fill)
                        .frame(width: CatalogVendorLayout.wideTileWidth, height: CatalogVendorLayout.wideTileHeight)
                        .clipped()
                    if shouldDim {
                        Color.black.opacity(0.80)
                    }
                    if isHovering || isSelected {
                        Color.black.opacity(0.50)
                        LinearGradient(colors: [CatalogVendorLayout.tileTray, CatalogVendorLayout.tileTray.opacity(0)], startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.63))
                    }
                    if game.isInLibrary {
                        MallRibbonShape()
                            .fill(Color.openNowGreen)
                            .frame(width: 7, height: 24)
                    }
                }
                if isHovering || isSelected {
                    HStack(spacing: 8) {
                        Text(game.title.isEmpty ? "GeForce NOW" : game.title)
                            .font(.nvidia(size: 12, weight: isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .white.opacity(0.90) : .white.opacity(0.60))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.nvidia(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .frame(width: CatalogVendorLayout.wideTileWidth - 32, height: CatalogVendorLayout.cardTrayHeight)
                    .padding(.horizontal, 16)
                    .background(CatalogVendorLayout.tileTray)
                }
            }
            .frame(width: CatalogVendorLayout.wideTileWidth, alignment: .top)
            .overlay(alignment: .top) {
                if isSelected {
                    Rectangle()
                        .fill(Color.openNowGreen)
                        .frame(width: CatalogVendorLayout.wideTileWidth, height: 4)
                        .offset(y: CatalogVendorLayout.wideTileHeight + 4)
                }
            }
            .shadow(color: isSelected ? .black.opacity(0.28) : .clear, radius: 5, x: 0, y: 3)
            .scaleEffect(isHovering && !viewModel.selectedGameExists ? CatalogVendorLayout.tileScaleFactor : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovering)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CatalogVendorLayout.tileHorizontalMargin)
        .padding(.top, CatalogVendorLayout.tileTopMargin)
        .frame(width: CatalogVendorLayout.wideTileWidth + CatalogVendorLayout.tileHorizontalMargin * 2, height: CatalogVendorLayout.wideTileHeight + CatalogVendorLayout.cardTrayHeight + CatalogVendorLayout.tileTopMargin, alignment: .top)
        .onHover { isHovering = $0 }
        .accessibilityLabel(game.title.isEmpty ? "Game tile" : game.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? "Details open" : "")
    }
}

private extension CatalogViewModel {
    var selectedGameExists: Bool { selectedGame != nil }
}

private struct MallRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct GameDetailPanel: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        if let game = viewModel.selectedGame {
            ZStack(alignment: .topTrailing) {
                CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestHeroImageURL, width: 1400), contentMode: .fill)
                    .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 430)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.98), .black.opacity(0.72), .black.opacity(0.22)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)

                HStack(alignment: .top, spacing: 28) {
                    CatalogRemoteImage(url: viewModel.optimizedImageURL(game.bestTileImageURL, width: 460), contentMode: .fill)
                        .frame(width: 180, height: 254)
                        .clipped()

                    VStack(alignment: .leading, spacing: 16) {
                        Text(game.title.isEmpty ? "Selected Game" : game.title)
                            .font(.nvidia(size: 34, weight: .bold))
                            .lineLimit(2)

                        if !game.detailChips.isEmpty {
                            detailChips(game: game)
                        }

                        Text(game.gameDescription.isEmpty ? "Play instantly through GeForce NOW cloud streaming." : game.gameDescription)
                            .font(.nvidia(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .lineSpacing(4)
                            .lineLimit(5)
                            .frame(maxWidth: 640, alignment: .leading)

                        HStack(spacing: 14) {
                            Button { primaryAction(game: game) } label: {
                                Text(primaryActionTitle(game: game))
                                    .font(.nvidia(size: 15, weight: .bold))
                                    .frame(width: 152, height: 42)
                            }
                            .buttonStyle(VendorGetInButtonStyle())

                            Button("Open Store") { viewModel.openStoreForSelectedVariant() }
                                .buttonStyle(SecondaryLoginButtonStyle(compact: true))
                                .opacity(game.variants.isEmpty ? 0.5 : 1)
                                .disabled(game.variants.isEmpty)

                            Menu {
                                Button("Share") { viewModel.shareSelectedGame() }
                                if selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || game.isInLibrary {
                                    Button("Remove from Library", role: .destructive) { viewModel.removeSelectedVariantOwned() }
                                } else if selectedVariant != nil {
                                    Button("Mark as Owned") { viewModel.markSelectedVariantOwned() }
                                }
                                if selectedVariant?.appStore.isEmpty == false {
                                    Button("Sync \(viewModel.displayName(forStore: selectedVariant?.appStore ?? ""))") { viewModel.syncSelectedStoreAccount() }
                                    Button("Connect \(viewModel.displayName(forStore: selectedVariant?.appStore ?? ""))") { viewModel.linkSelectedStoreAccount() }
                                }
                            } label: {
                                Image(systemName: "ellipsis.vertical")
                                    .font(.nvidia(size: 16, weight: .bold))
                                    .frame(width: 42, height: 42)
                            }
                            .menuStyle(.button)
                        }

                        if !game.variants.isEmpty {
                            Picker("Store", selection: selectedVariantBinding(game: game)) {
                                ForEach(Array(game.variants.enumerated()), id: \.offset) { index, variant in
                                    Text(storePickerTitle(variant: variant)).tag(index)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 360)
                        }

                        if let selectedVariant, !selectedVariant.appStore.isEmpty {
                            storeAccountStatus(store: selectedVariant.appStore)
                        }

                        if !viewModel.launchMessage.isEmpty {
                            CatalogMessageView(message: viewModel.launchMessage, systemImage: "play.circle.fill")
                                .frame(maxWidth: 520)
                        }

                        if !viewModel.actionMessage.isEmpty {
                            CatalogMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: 520)
                        }

                        detailRows(game: game)
                    }

                    Spacer(minLength: 0)
                }
                .padding(28)
                .padding(.trailing, 54)

                Button { viewModel.selectGame(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.nvidia(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.62))
                }
                .buttonStyle(.plain)
                .padding(18)
            }
            .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 430)
            .background(CatalogVendorLayout.mallSurface)
            .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
            .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 18)
        }
    }

    private func detailChips(game: OPNCatalogGameObject) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(game.detailChips, id: \.self) { chip in
                Text(chip)
                    .font(.nvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.09))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            }
        }
    }

    private var selectedVariant: OPNCatalogGameVariantObject? {
        viewModel.selectedVariant(in: viewModel.selectedGame)
    }

    private func primaryActionTitle(game: OPNCatalogGameObject) -> String {
        if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true { return "PLAY" }
        if selectedVariant != nil { return "MARK OWNED" }
        return "PLAY"
    }

    private func primaryAction(game: OPNCatalogGameObject) {
        if game.isInLibrary || selectedVariant?.inLibrary == true || selectedVariant?.librarySelected == true || selectedVariant == nil {
            viewModel.launchSelectedGame()
        } else {
            viewModel.markSelectedVariantOwned()
        }
    }

    private func selectedVariantBinding(game: OPNCatalogGameObject) -> Binding<Int> {
        Binding(
            get: { viewModel.selectedVariantIndex },
            set: { index in
                viewModel.selectedVariantIndex = index
                guard index >= 0, index < game.variants.count else { return }
                let variant = game.variants[index]
                if variant.inLibrary || variant.librarySelected { viewModel.selectOwnedVariant(variant) }
            }
        )
    }

    private func storePickerTitle(variant: OPNCatalogGameVariantObject) -> String {
        let store = variant.appStore.isEmpty ? "GeForce NOW" : viewModel.displayName(forStore: variant.appStore)
        if variant.librarySelected { return "✓ \(store)" }
        if variant.inLibrary { return "• \(store)" }
        return store
    }

    private func storeAccountStatus(store: String) -> some View {
        let account = viewModel.accountStatus(forStore: store)
        let storeName = viewModel.displayName(forStore: store)
        return HStack(spacing: 8) {
            Image(systemName: account?.hasAccountLinkingData == true ? "link.circle.fill" : "link.circle")
                .foregroundStyle(Color.openNowGreen)
            Text(accountStatusText(account: account, storeName: storeName))
                .font(.nvidia(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 520)
    }

    private func accountStatusText(account: CatalogStoreAccount?, storeName: String) -> String {
        guard let account else { return "Connect \(storeName) to sync owned games." }
        if !account.userDisplayName.isEmpty { return "Connected to \(storeName) as \(account.userDisplayName)." }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) \(storeName) games synced." }
        if !account.syncState.isEmpty { return "\(storeName) sync state: \(account.syncState)." }
        return "\(storeName) account connected."
    }

    private func detailRows(game: OPNCatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CatalogDetailRow(label: "Developer", value: game.developerName)
            CatalogDetailRow(label: "Publisher", value: game.publisherName)
            CatalogDetailRow(label: "Stores", value: game.storeLine)
            CatalogDetailRow(label: "Controls", value: game.supportedControls.joined(separator: ", "))
            CatalogDetailRow(label: "Features", value: game.featureLabels.joined(separator: ", "))
        }
    }
}

private struct CatalogDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .top) {
                Text(label.uppercased())
                    .font(.nvidia(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 84, alignment: .leading)
                Text(value)
                    .font(.nvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CatalogHeroRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode
    let onScrimColorChange: (CatalogMarqueeScrimColor) -> Void

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if hasFailed {
                CatalogImageFallback()
            } else {
                CatalogImageFallback()
                    .overlay {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let url else {
            onScrimColorChange(.black)
            return
        }

        onScrimColorChange(.black)
        isLoading = true
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let loadedImage = NSImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }
            image = loadedImage
            hasFailed = false
            isLoading = false
            onScrimColorChange(CatalogHeroImageMetadata.scrimColor(from: data) ?? .black)
        } catch {
            guard !Task.isCancelled else { return }
            image = nil
            hasFailed = true
            isLoading = false
            onScrimColorChange(.black)
        }
    }
}

private struct CatalogHeroVendorBackgroundScrim: View {
    let color: CatalogMarqueeScrimColor

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: color.color.opacity(0.00), location: 0.0000),
                .init(color: color.color.opacity(0.02), location: 0.0342),
                .init(color: color.color.opacity(0.05), location: 0.0668),
                .init(color: color.color.opacity(0.12), location: 0.0955),
                .init(color: color.color.opacity(0.20), location: 0.1230),
                .init(color: color.color.opacity(0.29), location: 0.1500),
                .init(color: color.color.opacity(0.39), location: 0.1752),
                .init(color: color.color.opacity(0.50), location: 0.2000),
                .init(color: color.color.opacity(0.61), location: 0.2248),
                .init(color: color.color.opacity(0.71), location: 0.2500),
                .init(color: color.color.opacity(0.80), location: 0.2770),
                .init(color: color.color.opacity(0.88), location: 0.3045),
                .init(color: color.color.opacity(0.95), location: 0.3332),
                .init(color: color.color.opacity(0.98), location: 0.3658),
                .init(color: color.color.opacity(1.00), location: 0.4000)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

private struct CatalogHeroVendorForegroundScrim: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0000),
                        .init(color: .black, location: 0.6662),
                        .init(color: .black, location: 1.0000)
                    ],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: proxy.size.width * 0.58)
                .frame(maxWidth: .infinity, alignment: .leading)

                LinearGradient(
                    colors: [.clear, CatalogVendorLayout.mallSurface.opacity(0.25)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
                .frame(width: proxy.size.width * 0.34)
                .frame(maxWidth: .infinity, alignment: .leading)

                LinearGradient(
                    colors: [CatalogVendorLayout.mallSurface.opacity(0.00), CatalogVendorLayout.mallSurface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: proxy.size.height * 0.33)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CatalogMarqueeScrimColor: Equatable, Sendable {
    static let black = CatalogMarqueeScrimColor(red: 0, green: 0, blue: 0)

    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }

    var preferredTextColor: Color {
        red * 0.299 + green * 0.587 + blue * 0.114 > 150 ? .black : .white
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = value.hasPrefix("#") ? String(value.dropFirst()) : value
        let expanded: String
        if sanitized.count == 3 {
            expanded = sanitized.map { String(repeating: String($0), count: 2) }.joined()
        } else {
            expanded = sanitized
        }
        guard expanded.count == 6, let number = Int(expanded, radix: 16) else { return nil }
        red = Double((number >> 16) & 0xFF)
        green = Double((number >> 8) & 0xFF)
        blue = Double(number & 0xFF)
    }
}

private enum CatalogHeroImageMetadata {
    private struct Metadata: Decodable {
        let colors: Colors?
    }

    private struct Colors: Decodable {
        let left: String?
        let right: String?
        let bottom: String?
    }

    static func scrimColor(from data: Data) -> CatalogMarqueeScrimColor? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let metadataColor = metadataScrimColor(from: source) {
            return metadataColor
        }
        return sampledLeftEdgeColor(from: source)
    }

    private static func metadataScrimColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let userComment = findUserComment(in: properties),
              let jsonStart = userComment.firstIndex(of: "{") else { return nil }
        let json = String(userComment[jsonStart...])
        guard let data = json.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              let hexColor = metadata.colors?.left ?? metadata.colors?.right ?? metadata.colors?.bottom else { return nil }
        return CatalogMarqueeScrimColor(hex: hexColor)
    }

    private static func findUserComment(in value: Any) -> String? {
        if let string = value as? String, string.contains("colors") {
            return string
        }
        if let data = value as? Data, let string = String(data: data, encoding: .utf8), string.contains("colors") {
            return string
        }
        if let dictionary = value as? [String: Any] {
            if let directValue = dictionary[kCGImagePropertyExifUserComment as String] {
                return findUserComment(in: directValue)
            }
            for nestedValue in dictionary.values {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        if let array = value as? [Any] {
            let scalarValues = array.compactMap { $0 as? UInt8 }
            if scalarValues.count == array.count,
               let string = String(bytes: scalarValues, encoding: .utf8),
               string.contains("colors") {
                return string
            }
            for nestedValue in array {
                if let match = findUserComment(in: nestedValue) {
                    return match
                }
            }
        }
        return nil
    }

    private static func sampledLeftEdgeColor(from source: CGImageSource) -> CatalogMarqueeScrimColor? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drewImage = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        let sampleWidth = min(max(width / 8, 1), width)
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var count = 0.0
        for y in 0..<height {
            for x in 0..<sampleWidth {
                let index = (y * width + x) * 4
                red += Double(pixels[index])
                green += Double(pixels[index + 1])
                blue += Double(pixels[index + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return CatalogMarqueeScrimColor(red: red / count, green: green / count, blue: blue / count)
    }
}

private struct CatalogRemoteImage: View {
    let url: URL?
    let contentMode: ContentMode

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                CatalogImageFallback()
            case .empty:
                CatalogImageFallback().overlay { ProgressView().controlSize(.small) }
            @unknown default:
                CatalogImageFallback()
            }
        }
    }
}

private struct CatalogImageFallback: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "play.rectangle.fill")
                .font(.nvidia(size: 34, weight: .bold))
                .foregroundStyle(Color.openNowGreen.opacity(0.78))
        }
    }
}

private struct CatalogMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.openNowGreen)
            Text(message)
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct CatalogLoadingStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Loading GeForce NOW catalog")
                .font(.nvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(12)
        .background(Color.white.opacity(0.055))
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}

private extension OPNCatalogGameObject {
    var catalogIdentity: String { CatalogViewModel.identity(for: self) }

    var bestHeroImageURL: String {
        if !heroImageUrl.isEmpty { return heroImageUrl }
        for key in ["HERO_IMAGE", "HERO", "BACKGROUND", "KEY_ART"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        return bestTileImageURL
    }

    var bestTileImageURL: String {
        if !imageUrl.isEmpty { return imageUrl }
        for key in ["BOX_ART", "BOXART", "TILE", "GAME_BOX_ART", "HERO_IMAGE"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        return heroImageUrl
    }

    var bestWideImageURL: String {
        for key in ["TILE", "HERO_IMAGE", "HERO", "BACKGROUND", "KEY_ART", "SCREENSHOT"] {
            if let value = imageUrlsByType[key]?.first, !value.isEmpty { return value }
        }
        if let value = screenshotUrls.first, !value.isEmpty { return value }
        if !heroImageUrl.isEmpty { return heroImageUrl }
        return imageUrl
    }

    var mallDisplayTitle: String {
        let displayTitle = shortName.isEmpty ? title : shortName
        return displayTitle.isEmpty ? "GEFORCE NOW" : displayTitle.uppercased()
    }

    var primaryStoreLabel: String {
        if let store = availableStores.first, !store.isEmpty { return store.capitalized }
        if let store = variants.first?.appStore, !store.isEmpty { return store.capitalized }
        return "GeForce NOW"
    }

    var ratingLabel: String {
        if let rating = contentRatings.first, !rating.isEmpty { return rating }
        if !playType.isEmpty { return playType }
        return primaryStoreLabel
    }

    var genreLine: String { genres.prefix(3).joined(separator: " / ") }

    var storeLine: String {
        let stores = availableStores.isEmpty ? variants.map(\.appStore) : availableStores
        return stores.filter { !$0.isEmpty }.map { $0.uppercased() }.joined(separator: ", ")
    }

    var detailChips: [String] {
        var chips: [String] = []
        if isInLibrary { chips.append("IN LIBRARY") }
        if !membershipTierLabel.isEmpty { chips.append(membershipTierLabel.uppercased()) }
        if !playabilityState.isEmpty { chips.append(playabilityState.replacingOccurrences(of: "_", with: " ").uppercased()) }
        chips.append(contentsOf: genres.prefix(3).map { $0.uppercased() })
        return chips.isEmpty ? ["CLOUD READY"] : chips
    }
}
